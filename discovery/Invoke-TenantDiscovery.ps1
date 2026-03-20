<#
.SYNOPSIS
    Runs all discovery queries and produces a consolidated report.

.DESCRIPTION
    Executes every .kql file in the discovery/ directory against Azure Resource Graph,
    paginates through large result sets, exports individual CSVs, and generates
    a summary report with key metrics and recommendations.

    Also runs supplemental checks that cannot be expressed in KQL alone:
    - Activity Log analysis (last-activity date per resource group)
    - Cost data from Consumption API (top spenders, zero-cost resources)
    - Entra ID cross-reference for orphan detection

.PARAMETER OutputDir
    Directory to write reports. Default: ./reports/{date}

.PARAMETER SubscriptionId
    Limit discovery to specific subscription(s). Accepts an array. If omitted, scans all enabled subscriptions.

.PARAMETER SkipActivityLog
    Skip the Activity Log scan (can be slow on large tenants).

.PARAMETER SkipCostData
    Skip the cost/consumption data pull.

.PARAMETER SkipEntraId
    Skip the Entra ID orphan cross-reference.

.PARAMETER LookbackDays
    How many days of Activity Log to scan. Default: 90.

.PARAMETER CostLookbackDays
    How many days of cost data to pull. Default: 30.

.PARAMETER PageSize
    Number of results per Resource Graph page. Default: 1000 (API max).

.EXAMPLE
    # Full discovery across all subscriptions
    .\Invoke-TenantDiscovery.ps1

    # Quick scan — KQL queries only, skip slow checks
    .\Invoke-TenantDiscovery.ps1 -SkipActivityLog -SkipCostData -SkipEntraId

    # Target a single subscription
    .\Invoke-TenantDiscovery.ps1 -SubscriptionId "xxxx-xxxx-xxxx"
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputDir = "./reports/$(Get-Date -Format 'yyyy-MM-dd-HHmmss')",

    [Parameter()]
    [string[]]$SubscriptionId,

    [Parameter()]
    [switch]$SkipActivityLog,

    [Parameter()]
    [switch]$SkipCostData,

    [Parameter()]
    [switch]$SkipEntraId,

    [Parameter()]
    [ValidateRange(1, 365)]
    [int]$LookbackDays = 90,

    [Parameter()]
    [ValidateRange(1, 365)]
    [int]$CostLookbackDays = 30,

    [Parameter()]
    [ValidateRange(100, 1000)]
    [int]$PageSize = 1000
)

$ErrorActionPreference = "Stop"
$startTime = Get-Date

# ── Logging ──────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Write-Output $line
    $line | Out-File -FilePath "$OutputDir/discovery.log" -Append -ErrorAction SilentlyContinue
}

# ── Setup ────────────────────────────────────────────────────────────────────

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
New-Item -ItemType Directory -Path "$OutputDir/queries" -Force | Out-Null

Write-Log "=== Azure Tenant Discovery Started ==="
Write-Log "Output directory: $OutputDir"

# Resolve subscriptions
if ($SubscriptionId) {
    $subscriptions = $SubscriptionId | ForEach-Object { Get-AzSubscription -SubscriptionId $_ }
} else {
    $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
}
$subIds = $subscriptions | ForEach-Object { $_.Id }
Write-Log "Target subscriptions: $($subscriptions.Count)"

# Summary collector
$summary = [ordered]@{
    RunDate           = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    SubscriptionCount = $subscriptions.Count
    Subscriptions     = ($subscriptions | ForEach-Object { "$($_.Name) ($($_.Id))" }) -join "; "
}

# ── Phase 1: Resource Graph Queries ──────────────────────────────────────────

Write-Log "--- Phase 1: Resource Graph Queries ---"

$discoveryDir = Join-Path $PSScriptRoot "../discovery"
if (-not (Test-Path $discoveryDir)) {
    $discoveryDir = "./discovery"
}

$queryFiles = Get-ChildItem -Path $discoveryDir -Filter "*.kql" | Sort-Object Name

if ($queryFiles.Count -eq 0) {
    Write-Log "No .kql files found in $discoveryDir" -Level "WARN"
} else {
    Write-Log "Found $($queryFiles.Count) KQL queries to run"
}

$queryResults = @{}

foreach ($queryFile in $queryFiles) {
    $queryName = $queryFile.BaseName
    Write-Log "Running: $queryName"

    # Read and strip comments
    $rawQuery = Get-Content $queryFile.FullName -Raw
    $cleanQuery = ($rawQuery -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
    $cleanQuery = $cleanQuery.Trim()

    if ([string]::IsNullOrWhiteSpace($cleanQuery)) {
        Write-Log "  Skipped (empty after stripping comments)" -Level "SKIP"
        continue
    }

    try {
        # Paginate through results
        $allResults = @()
        $skipToken = $null

        do {
            $graphParams = @{
                Query = $cleanQuery
                First = $PageSize
                Subscription = $subIds
            }
            if ($skipToken) {
                $graphParams.SkipToken = $skipToken
            }

            $page = Search-AzGraph @graphParams
            $allResults += $page.Data
            $skipToken = $page.SkipToken
        } while ($null -ne $skipToken)

        $queryResults[$queryName] = $allResults.Count

        if ($allResults.Count -gt 0) {
            $csvPath = "$OutputDir/queries/$queryName.csv"
            $allResults | Export-Csv -Path $csvPath -NoTypeInformation
            Write-Log "  $($allResults.Count) results -> $csvPath"
        } else {
            Write-Log "  0 results"
        }
    } catch {
        Write-Log "  Query failed: $_" -Level "ERROR"
        $queryResults[$queryName] = "ERROR"
    }
}

$summary.QueryResultCounts = $queryResults

# ── Phase 2: Activity Log Analysis ──────────────────────────────────────────

if (-not $SkipActivityLog) {
    Write-Log "--- Phase 2: Activity Log Analysis ---"

    $activityStart = (Get-Date).AddDays(-$LookbackDays)
    $rgActivity = @{}

    foreach ($sub in $subscriptions) {
        Write-Log "  Scanning activity logs: $($sub.Name)"
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null

        try {
            $activityLogLimit = 5000
            $logs = Get-AzActivityLog -StartTime $activityStart -EndTime (Get-Date) `
                -MaxRecord $activityLogLimit -WarningAction SilentlyContinue

            if ($logs.Count -ge $activityLogLimit) {
                Write-Log "  WARNING: Activity log hit $activityLogLimit record limit for $($sub.Name) — results may be truncated. Consider reducing LookbackDays." -Level "WARN"
            }

            foreach ($log in $logs) {
                if ($null -eq $log.ResourceId) { continue }

                # Extract resource group from resource ID
                $parts = $log.ResourceId -split '/'
                $rgIdx = [array]::IndexOf($parts, 'resourceGroups')
                if ($rgIdx -ge 0 -and $rgIdx + 1 -lt $parts.Length) {
                    $rgName = $parts[$rgIdx + 1]
                    $key = "$($sub.Id)/$rgName"

                    if (-not $rgActivity.ContainsKey($key) -or $log.EventTimestamp -gt $rgActivity[$key].LastActivity) {
                        $rgActivity[$key] = [PSCustomObject]@{
                            SubscriptionId   = $sub.Id
                            SubscriptionName = $sub.Name
                            ResourceGroup    = $rgName
                            LastActivity     = $log.EventTimestamp
                            LastOperation    = $log.OperationName.Value
                            LastCaller       = $log.Caller
                            DaysSinceActive  = [math]::Round(((Get-Date) - $log.EventTimestamp).TotalDays)
                        }
                    }
                }
            }
        } catch {
            Write-Log "  Activity log failed for $($sub.Name): $_" -Level "ERROR"
        }
    }

    if ($rgActivity.Count -gt 0) {
        $activityReport = $rgActivity.Values | Sort-Object DaysSinceActive -Descending
        $activityReport | Export-Csv -Path "$OutputDir/resource-group-activity.csv" -NoTypeInformation
        Write-Log "Resource group activity: $($activityReport.Count) groups analyzed"

        $dormantCount = ($activityReport | Where-Object { $_.DaysSinceActive -gt 60 }).Count
        $summary.DormantResourceGroups = $dormantCount
        Write-Log "  $dormantCount resource groups with no activity in 60+ days"
    }
} else {
    Write-Log "--- Phase 2: Activity Log Analysis (SKIPPED) ---"
}

# ── Phase 3: Cost Analysis ──────────────────────────────────────────────────

if (-not $SkipCostData) {
    Write-Log "--- Phase 3: Cost Analysis ---"

    $costStart = (Get-Date).AddDays(-$CostLookbackDays).ToString("yyyy-MM-dd")
    $costEnd = (Get-Date).ToString("yyyy-MM-dd")
    $costByRG = @{}

    foreach ($sub in $subscriptions) {
        Write-Log "  Pulling cost data: $($sub.Name)"
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null

        try {
            $usage = Get-AzConsumptionUsageDetail -StartDate $costStart -EndDate $costEnd `
                -ErrorAction Stop

            foreach ($item in $usage) {
                $rg = if ($item.InstanceId) {
                    $parts = $item.InstanceId -split '/'
                    $rgIdx = [array]::IndexOf($parts, 'resourceGroups')
                    if ($rgIdx -ge 0 -and $rgIdx + 1 -lt $parts.Length) { $parts[$rgIdx + 1] } else { "(unknown)" }
                } else { "(unknown)" }

                $key = "$($sub.Id)/$rg"
                if (-not $costByRG.ContainsKey($key)) {
                    $costByRG[$key] = [PSCustomObject]@{
                        SubscriptionId   = $sub.Id
                        SubscriptionName = $sub.Name
                        ResourceGroup    = $rg
                        TotalCost        = [decimal]0
                        Currency         = $item.BillingCurrency
                    }
                }
                $costByRG[$key].TotalCost += [decimal]$item.PretaxCost
            }
        } catch {
            Write-Log "  Cost data failed for $($sub.Name): $_" -Level "ERROR"
        }
    }

    if ($costByRG.Count -gt 0) {
        $costReport = $costByRG.Values | Sort-Object TotalCost -Descending
        $costReport | Export-Csv -Path "$OutputDir/cost-by-resource-group.csv" -NoTypeInformation
        Write-Log "Cost analysis: $($costReport.Count) resource groups"

        $totalCost = ($costReport | Measure-Object -Property TotalCost -Sum).Sum
        $zeroCostRGs = ($costReport | Where-Object { $_.TotalCost -eq 0 }).Count
        $summary.TotalCostLast30Days = [math]::Round($totalCost, 2)
        $summary.ZeroCostResourceGroups = $zeroCostRGs
        Write-Log "  Total cost (last $CostLookbackDays days): $([math]::Round($totalCost, 2))"
        Write-Log "  Resource groups with zero cost: $zeroCostRGs"

        # Top 20 spenders
        $topSpenders = $costReport | Select-Object -First 20
        $topSpenders | Export-Csv -Path "$OutputDir/top-20-cost-resource-groups.csv" -NoTypeInformation
    }
} else {
    Write-Log "--- Phase 3: Cost Analysis (SKIPPED) ---"
}

# ── Phase 4: Entra ID Orphan Detection ──────────────────────────────────────

if (-not $SkipEntraId) {
    Write-Log "--- Phase 4: Entra ID Orphan Detection ---"

    try {
        $allUsers = Get-AzADUser -First 10000
        $activeUPNs = @{}
        $knownUPNs = @{}
        foreach ($u in $allUsers) {
            $knownUPNs[$u.UserPrincipalName] = $u.AccountEnabled
            if ($u.AccountEnabled) { $activeUPNs[$u.UserPrincipalName] = $true }
        }
        Write-Log "  Loaded $($allUsers.Count) Entra ID users ($($activeUPNs.Count) active)"
        if ($allUsers.Count -ge 10000) {
            Write-Log "  WARNING: User count hit the 10,000 limit — results may be incomplete. Consider paginating." -Level "WARN"
        }

        $orphanedRGs = @()
        $activityStart = (Get-Date).AddDays(-365)

        foreach ($sub in $subscriptions) {
            Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null

            try {
                $orphanLogLimit = 5000
                $rawOrphanLogs = Get-AzActivityLog -StartTime $activityStart -EndTime (Get-Date) `
                    -MaxRecord $orphanLogLimit -WarningAction SilentlyContinue

                if ($rawOrphanLogs.Count -ge $orphanLogLimit) {
                    Write-Log "  WARNING: Orphan detection activity log hit $orphanLogLimit record limit for $($sub.Name) — results may be truncated" -Level "WARN"
                }

                $createLogs = $rawOrphanLogs | Where-Object {
                        $_.OperationName.Value -match "resourcegroups/write$" -and
                        $_.Status.Value -eq "Succeeded" -and
                        $_.Caller -match "@"
                    }

                foreach ($log in $createLogs) {
                    $creator = $log.Caller
                    if (-not $activeUPNs.ContainsKey($creator)) {
                        # Extract RG name from the resourceGroups segment, not the last path element
                        $idParts = $log.ResourceId -split '/'
                        $rgIdx = [array]::IndexOf($idParts, 'resourceGroups')
                        $rgName = if ($rgIdx -ge 0 -and $rgIdx + 1 -lt $idParts.Length) { $idParts[$rgIdx + 1] } else { $idParts[-1] }

                        $orphanedRGs += [PSCustomObject]@{
                            SubscriptionId   = $sub.Id
                            SubscriptionName = $sub.Name
                            ResourceGroup    = $rgName
                            Creator          = $creator
                            CreatorStatus    = if ($knownUPNs.ContainsKey($creator)) { "Disabled" } else { "Deleted" }
                            CreatedDate      = $log.EventTimestamp
                        }
                    }
                }
            } catch {
                Write-Log "  Entra ID check failed for $($sub.Name): $_" -Level "ERROR"
            }
        }

        if ($orphanedRGs.Count -gt 0) {
            $orphanedRGs | Export-Csv -Path "$OutputDir/orphaned-resource-groups.csv" -NoTypeInformation
            $summary.OrphanedResourceGroups = $orphanedRGs.Count
            Write-Log "  Found $($orphanedRGs.Count) resource groups created by departed users"
        } else {
            Write-Log "  No orphaned resource groups found"
        }
    } catch {
        Write-Log "  Entra ID access failed: $_" -Level "ERROR"
    }
} else {
    Write-Log "--- Phase 4: Entra ID Orphan Detection (SKIPPED) ---"
}

# ── Generate Summary Report ──────────────────────────────────────────────────

Write-Log "--- Generating Summary Report ---"

$elapsed = (Get-Date) - $startTime
$summary.ElapsedMinutes = [math]::Round($elapsed.TotalMinutes, 1)

# Write summary JSON
$summary | ConvertTo-Json -Depth 5 | Out-File -FilePath "$OutputDir/summary.json"

# Write human-readable summary
$reportLines = @(
    "# Azure Tenant Discovery Report"
    "Generated: $($summary.RunDate)"
    "Duration: $($summary.ElapsedMinutes) minutes"
    ""
    "## Scope"
    "Subscriptions scanned: $($summary.SubscriptionCount)"
    ""
    "| Subscription | ID |"
    "|--------------|----|"
)

foreach ($sub in $subscriptions) {
    $reportLines += "| $($sub.Name) | $($sub.Id) |"
}

$reportLines += @(
    ""
    "## Resource Graph Query Results"
    ""
    "| Query | Result Count |"
    "|-------|-------------|"
)

foreach ($key in $queryResults.Keys | Sort-Object) {
    $reportLines += "| $key | $($queryResults[$key]) |"
}

if ($summary.ContainsKey("DormantResourceGroups")) {
    $reportLines += @(
        ""
        "## Activity Analysis"
        "- Resource groups with no activity in 60+ days: **$($summary.DormantResourceGroups)**"
    )
}

if ($summary.ContainsKey("TotalCostLast30Days")) {
    $reportLines += @(
        ""
        "## Cost Analysis (last $CostLookbackDays days)"
        "- Total spend: **$($summary.TotalCostLast30Days)**"
        "- Resource groups with zero cost: **$($summary.ZeroCostResourceGroups)**"
        "- See ``top-20-cost-resource-groups.csv`` for top spenders"
    )
}

if ($summary.ContainsKey("OrphanedResourceGroups")) {
    $reportLines += @(
        ""
        "## Orphan Detection"
        "- Resource groups created by departed users: **$($summary.OrphanedResourceGroups)**"
    )
}

$reportLines += @(
    ""
    "## Output Files"
    ""
)

$outputFiles = Get-ChildItem -Path $OutputDir -Recurse -File | Sort-Object FullName
foreach ($f in $outputFiles) {
    $relativePath = $f.FullName.Replace($OutputDir, "").TrimStart("/\")
    $sizeKB = [math]::Round($f.Length / 1KB, 1)
    $reportLines += "- ``$relativePath`` ($sizeKB KB)"
}

$reportLines += @(
    ""
    "## Recommended Next Steps"
    "1. Review ``queries/03-empty-resource-groups.csv`` — safe quick wins"
    "2. Review ``queries/05-unattached-disks.csv`` — immediate cost savings"
    "3. Cross-reference ``resource-group-activity.csv`` with ``cost-by-resource-group.csv`` to find expensive + dormant resources"
    "4. Review ``orphaned-resource-groups.csv`` with team leads for reassignment or cleanup"
)

$reportContent = $reportLines -join "`n"
$reportContent | Out-File -FilePath "$OutputDir/REPORT.md"

Write-Log "=== Discovery Complete ==="
Write-Log "Report: $OutputDir/REPORT.md"
Write-Log "Summary: $OutputDir/summary.json"
Write-Log "Total time: $($summary.ElapsedMinutes) minutes"

return $summary

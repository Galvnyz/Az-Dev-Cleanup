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

# ── Shared: Capture Az profile for parallel runspaces ─────────────────────────
# Disable context autosave to prevent token cache contention across parallel runspaces
Disable-AzContextAutosave -Scope Process -ErrorAction SilentlyContinue | Out-Null
$azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile

# ── Phase 2: Activity Log Analysis (parallel with date windowing) ─────────────

if (-not $SkipActivityLog) {
    Write-Log "--- Phase 2: Activity Log Analysis ---"

    $activityLogLimit = 5000
    $windowDays = 7
    $rgActivity = @{}

    # Build date windows (e.g., 90 days / 7-day windows = 13 windows)
    $windows = @()
    $now = Get-Date
    $daysRemaining = $LookbackDays
    while ($daysRemaining -gt 0) {
        $chunkSize = [math]::Min($windowDays, $daysRemaining)
        $windowEnd = $now.AddDays(-($LookbackDays - $daysRemaining))
        $windowStart = $windowEnd.AddDays(-$chunkSize)
        $windows += [PSCustomObject]@{ Start = $windowStart; End = $windowEnd }
        $daysRemaining -= $chunkSize
    }

    # Build job list: every subscription × every window
    $jobs = @()
    foreach ($sub in $subscriptions) {
        foreach ($w in $windows) {
            $jobs += [PSCustomObject]@{
                SubId   = $sub.Id
                SubName = $sub.Name
                Start   = $w.Start
                End     = $w.End
            }
        }
    }

    $totalWindows = $windows.Count
    Write-Log "  $($subscriptions.Count) subscription(s) x $totalWindows windows ($windowDays-day each) = $($jobs.Count) parallel jobs"

    $phase2Timer = [System.Diagnostics.Stopwatch]::StartNew()

    $activityResults = $jobs | ForEach-Object -Parallel {
        $job = $_
        Import-Module Az.Accounts, Az.Monitor -ErrorAction Stop
        Disable-AzContextAutosave -Scope Process -ErrorAction SilentlyContinue | Out-Null
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile = $using:azProfile
        Set-AzContext -SubscriptionId $job.SubId -ErrorAction Stop | Out-Null

        $limit = $using:activityLogLimit
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            $logs = Get-AzActivityLog -StartTime $job.Start -EndTime $job.End `
                -MaxRecord $limit -WarningAction SilentlyContinue
            $sw.Stop()

            [PSCustomObject]@{
                SubId      = $job.SubId
                SubName    = $job.SubName
                WindowStart = $job.Start.ToString("MM/dd")
                WindowEnd   = $job.End.ToString("MM/dd")
                Logs       = $logs
                LogCount   = if ($null -ne $logs) { $logs.Count } else { 0 }
                Elapsed    = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                HitLimit   = ($null -ne $logs -and $logs.Count -ge $limit)
                Error      = $null
            }
        } catch {
            $sw.Stop()
            [PSCustomObject]@{
                SubId       = $job.SubId
                SubName     = $job.SubName
                WindowStart = $job.Start.ToString("MM/dd")
                WindowEnd   = $job.End.ToString("MM/dd")
                Logs        = @()
                LogCount    = 0
                Elapsed     = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                HitLimit    = $false
                Error       = $_.ToString()
            }
        }
    } -ThrottleLimit 4

    # Process parallel results in main thread — group by subscription for clean logging
    $resultsBySub = $activityResults | Group-Object SubName
    $totalRecords = 0
    $truncatedWindows = 0

    foreach ($subGroup in $resultsBySub) {
        $subRecords = 0
        $subErrors = 0
        $subTruncated = 0

        foreach ($r in ($subGroup.Group | Sort-Object WindowStart)) {
            if ($r.Error) {
                $subErrors++
                continue
            }
            $subRecords += $r.LogCount
            if ($r.HitLimit) { $subTruncated++ }

            foreach ($log in $r.Logs) {
                if ($null -eq $log.ResourceId) { continue }

                $parts = $log.ResourceId -split '/'
                $rgIdx = [array]::IndexOf($parts, 'resourceGroups')
                if ($rgIdx -ge 0 -and $rgIdx + 1 -lt $parts.Length) {
                    $rgName = $parts[$rgIdx + 1]
                    $key = "$($r.SubId)/$rgName"

                    if (-not $rgActivity.ContainsKey($key) -or $log.EventTimestamp -gt $rgActivity[$key].LastActivity) {
                        $rgActivity[$key] = [PSCustomObject]@{
                            SubscriptionId   = $r.SubId
                            SubscriptionName = $r.SubName
                            ResourceGroup    = $rgName
                            LastActivity     = $log.EventTimestamp
                            LastOperation    = $log.OperationName.Value
                            LastCaller       = $log.Caller
                            DaysSinceActive  = [math]::Round(((Get-Date) - $log.EventTimestamp).TotalDays)
                        }
                    }
                }
            }
        }

        $totalRecords += $subRecords
        $truncatedWindows += $subTruncated
        $statusMsg = "$($subGroup.Name): $subRecords records across $totalWindows windows"
        if ($subErrors -gt 0) { $statusMsg += " ($subErrors window errors)" }
        if ($subTruncated -gt 0) { $statusMsg += " [!] $subTruncated window(s) hit $activityLogLimit limit" }
        Write-Log "  $statusMsg"
    }

    $phase2Timer.Stop()
    Write-Log "  Phase 2 total: $totalRecords records in $([math]::Round($phase2Timer.Elapsed.TotalSeconds, 1))s"
    if ($truncatedWindows -gt 0) {
        Write-Log "  WARNING: $truncatedWindows window(s) hit the $activityLogLimit record limit — some data may still be truncated. Consider reducing the window size." -Level "WARN"
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
    Write-Log "  Querying $($subscriptions.Count) subscription(s) in parallel..."

    $costStart = (Get-Date).AddDays(-$CostLookbackDays).ToString("yyyy-MM-dd")
    $costEnd = (Get-Date).ToString("yyyy-MM-dd")
    $costByRG = @{}

    $phase3Timer = [System.Diagnostics.Stopwatch]::StartNew()

    $costResults = $subscriptions | ForEach-Object -Parallel {
        $sub = $_
        Import-Module Az.Accounts, Az.Billing -ErrorAction Stop
        Disable-AzContextAutosave -Scope Process -ErrorAction SilentlyContinue | Out-Null
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile = $using:azProfile
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $usage = Get-AzConsumptionUsageDetail -StartDate $using:costStart -EndDate $using:costEnd -ErrorAction Stop
            $sw.Stop()
            [PSCustomObject]@{
                SubId   = $sub.Id
                SubName = $sub.Name
                Usage   = $usage
                Elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                Error   = $null
            }
        } catch {
            $sw.Stop()
            [PSCustomObject]@{
                SubId   = $sub.Id
                SubName = $sub.Name
                Usage   = @()
                Elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                Error   = $_.ToString()
            }
        }
    } -ThrottleLimit 4

    foreach ($r in $costResults) {
        if ($r.Error) {
            Write-Log "  $($r.SubName): FAILED after $($r.Elapsed)s — $($r.Error)" -Level "ERROR"
            continue
        }

        Write-Log "  $($r.SubName): $($r.Usage.Count) usage records in $($r.Elapsed)s"

        foreach ($item in $r.Usage) {
            $rg = if ($item.InstanceId) {
                $parts = $item.InstanceId -split '/'
                $rgIdx = [array]::IndexOf($parts, 'resourceGroups')
                if ($rgIdx -ge 0 -and $rgIdx + 1 -lt $parts.Length) { $parts[$rgIdx + 1] } else { "(unknown)" }
            } else { "(unknown)" }

            $key = "$($r.SubId)/$rg"
            if (-not $costByRG.ContainsKey($key)) {
                $costByRG[$key] = [PSCustomObject]@{
                    SubscriptionId   = $r.SubId
                    SubscriptionName = $r.SubName
                    ResourceGroup    = $rg
                    TotalCost        = [decimal]0
                    Currency         = $item.BillingCurrency
                }
            }
            $costByRG[$key].TotalCost += [decimal]$item.PretaxCost
        }
    }

    $phase3Timer.Stop()
    Write-Log "  Phase 3 total: $([math]::Round($phase3Timer.Elapsed.TotalSeconds, 1))s"

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

        $topSpenders = $costReport | Select-Object -First 20
        $topSpenders | Export-Csv -Path "$OutputDir/top-20-cost-resource-groups.csv" -NoTypeInformation
    }
} else {
    Write-Log "--- Phase 3: Cost Analysis (SKIPPED) ---"
}

# ── Phase 4: Entra ID Orphan Detection ──────────────────────────────────────

if (-not $SkipEntraId) {
    Write-Log "--- Phase 4: Entra ID Orphan Detection ---"

    $phase4Timer = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $userTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $allUsers = Get-AzADUser -First 10000
        $userTimer.Stop()

        $activeUPNs = @{}
        $knownUPNs = @{}
        foreach ($u in $allUsers) {
            $knownUPNs[$u.UserPrincipalName] = $u.AccountEnabled
            if ($u.AccountEnabled) { $activeUPNs[$u.UserPrincipalName] = $true }
        }
        Write-Log "  Loaded $($allUsers.Count) Entra ID users ($($activeUPNs.Count) active) in $([math]::Round($userTimer.Elapsed.TotalSeconds, 1))s"
        if ($allUsers.Count -ge 10000) {
            Write-Log "  WARNING: User count hit the 10,000 limit — results may be incomplete. Consider paginating." -Level "WARN"
        }

        # Activity Log API supports max 90 days — use LookbackDays (capped at 90)
        $orphanLookback = [math]::Min($LookbackDays, 90)
        $orphanLogLimit = 5000

        # Build date windows for orphan detection (same windowing as Phase 2)
        $orphanWindows = @()
        $daysLeft = $orphanLookback
        while ($daysLeft -gt 0) {
            $chunkSize = [math]::Min($windowDays, $daysLeft)
            $wEnd = $now.AddDays(-($orphanLookback - $daysLeft))
            $wStart = $wEnd.AddDays(-$chunkSize)
            $orphanWindows += [PSCustomObject]@{ Start = $wStart; End = $wEnd }
            $daysLeft -= $chunkSize
        }

        # Build job list: subscription × window
        $orphanJobs = @()
        foreach ($sub in $subscriptions) {
            foreach ($w in $orphanWindows) {
                $orphanJobs += [PSCustomObject]@{
                    SubId   = $sub.Id
                    SubName = $sub.Name
                    Start   = $w.Start
                    End     = $w.End
                }
            }
        }

        Write-Log "  $($subscriptions.Count) subscription(s) x $($orphanWindows.Count) windows = $($orphanJobs.Count) parallel jobs"

        $orphanLogResults = $orphanJobs | ForEach-Object -Parallel {
            $job = $_
            Import-Module Az.Accounts, Az.Monitor -ErrorAction Stop
            [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile = $using:azProfile
            Set-AzContext -SubscriptionId $job.SubId -ErrorAction Stop | Out-Null

            $limit = $using:orphanLogLimit
            $sw = [System.Diagnostics.Stopwatch]::StartNew()

            try {
                $rawLogs = Get-AzActivityLog -StartTime $job.Start -EndTime $job.End `
                    -MaxRecord $limit -WarningAction SilentlyContinue
                $sw.Stop()

                # Filter to RG creation events in the parallel block
                $createLogs = $rawLogs | Where-Object {
                    $_.OperationName.Value -match "resourcegroups/write$" -and
                    $_.Status.Value -eq "Succeeded" -and
                    $_.Caller -match "@"
                }

                [PSCustomObject]@{
                    SubId       = $job.SubId
                    SubName     = $job.SubName
                    WindowStart = $job.Start.ToString("MM/dd")
                    WindowEnd   = $job.End.ToString("MM/dd")
                    CreateLogs  = @($createLogs)
                    RawCount    = if ($null -ne $rawLogs) { $rawLogs.Count } else { 0 }
                    Elapsed     = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                    HitLimit    = ($null -ne $rawLogs -and $rawLogs.Count -ge $limit)
                    Error       = $null
                }
            } catch {
                $sw.Stop()
                [PSCustomObject]@{
                    SubId       = $job.SubId
                    SubName     = $job.SubName
                    WindowStart = $job.Start.ToString("MM/dd")
                    WindowEnd   = $job.End.ToString("MM/dd")
                    CreateLogs  = @()
                    RawCount    = 0
                    Elapsed     = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                    HitLimit    = $false
                    Error       = $_.ToString()
                }
            }
        } -ThrottleLimit 4

        # Process parallel results — group by subscription
        $orphanedRGs = @()
        $orphanResultsBySub = $orphanLogResults | Group-Object SubName

        foreach ($subGroup in $orphanResultsBySub) {
            $subCreates = 0
            $subTruncated = 0

            foreach ($r in ($subGroup.Group | Sort-Object WindowStart)) {
                if ($r.Error) { continue }
                if ($r.HitLimit) { $subTruncated++ }

                foreach ($log in $r.CreateLogs) {
                    $subCreates++
                    $creator = $log.Caller
                    if (-not $activeUPNs.ContainsKey($creator)) {
                        $idParts = $log.ResourceId -split '/'
                        $rgIdx = [array]::IndexOf($idParts, 'resourceGroups')
                        $rgName = if ($rgIdx -ge 0 -and $rgIdx + 1 -lt $idParts.Length) { $idParts[$rgIdx + 1] } else { $idParts[-1] }

                        $orphanedRGs += [PSCustomObject]@{
                            SubscriptionId   = $r.SubId
                            SubscriptionName = $r.SubName
                            ResourceGroup    = $rgName
                            Creator          = $creator
                            CreatorStatus    = if ($knownUPNs.ContainsKey($creator)) { "Disabled" } else { "Deleted" }
                            CreatedDate      = $log.EventTimestamp
                        }
                    }
                }
            }

            $statusMsg = "$($subGroup.Name): $subCreates RG creation events"
            if ($subTruncated -gt 0) { $statusMsg += " [!] $subTruncated window(s) hit limit" }
            Write-Log "  $statusMsg"
        }

        $phase4Timer.Stop()
        Write-Log "  Phase 4 total: $([math]::Round($phase4Timer.Elapsed.TotalSeconds, 1))s"

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

if ($summary.Contains("DormantResourceGroups")) {
    $reportLines += @(
        ""
        "## Activity Analysis"
        "- Resource groups with no activity in 60+ days: **$($summary.DormantResourceGroups)**"
    )
}

if ($summary.Contains("TotalCostLast30Days")) {
    $reportLines += @(
        ""
        "## Cost Analysis (last $CostLookbackDays days)"
        "- Total spend: **$($summary.TotalCostLast30Days)**"
        "- Resource groups with zero cost: **$($summary.ZeroCostResourceGroups)**"
        "- See ``top-20-cost-resource-groups.csv`` for top spenders"
    )
}

if ($summary.Contains("OrphanedResourceGroups")) {
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

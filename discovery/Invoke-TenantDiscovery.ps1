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

# ── Phase 2: Activity Log Analysis (lightweight, parallel per-sub) ─────────────

if (-not $SkipActivityLog) {
    Write-Log "--- Phase 2: Activity Log Analysis ---"

    $activityLogLimit = 5000
    $rgActivity = @{}
    $activityStart = (Get-Date).AddDays(-$LookbackDays)

    Write-Log "  Querying $($subscriptions.Count) subscription(s) in parallel ($LookbackDays-day lookback, write ops only)..."

    $phase2Timer = [System.Diagnostics.Stopwatch]::StartNew()

    # One query per subscription — server-side filtered to Succeeded write ops
    $activityResults = $subscriptions | ForEach-Object -Parallel {
        $sub = $_
        Import-Module Az.Accounts, Az.Monitor -ErrorAction Stop
        Disable-AzContextAutosave -Scope Process -ErrorAction SilentlyContinue | Out-Null
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile = $using:azProfile
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null

        $limit = $using:activityLogLimit
        $start = $using:activityStart
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            $logs = Get-AzActivityLog -StartTime $start -EndTime (Get-Date) `
                -MaxRecord $limit -WarningAction SilentlyContinue

            # Client-side filter: write/delete/action ops with a resource ID
            $filtered = @($logs | Where-Object {
                $null -ne $_.ResourceId -and
                $_.OperationName.Value -match "/write$|/delete$|/action$" -and
                $_.Status.Value -eq "Succeeded"
            })

            $sw.Stop()

            [PSCustomObject]@{
                SubId    = $sub.Id
                SubName  = $sub.Name
                Logs     = $filtered
                RawCount = if ($null -ne $logs) { $logs.Count } else { 0 }
                Count    = $filtered.Count
                Elapsed  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                HitLimit = ($null -ne $logs -and $logs.Count -ge $limit)
                Error    = $null
            }
        } catch {
            $sw.Stop()
            [PSCustomObject]@{
                SubId    = $sub.Id
                SubName  = $sub.Name
                Logs     = @()
                RawCount = 0
                Count    = 0
                Elapsed  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                HitLimit = $false
                Error    = $_.ToString()
            }
        }
    } -ThrottleLimit 4

    # Process results
    $totalRecords = 0
    foreach ($r in $activityResults) {
        if ($r.Error) {
            Write-Log "  $($r.SubName): FAILED after $($r.Elapsed)s — $($r.Error)" -Level "ERROR"
            continue
        }

        $statusMsg = "$($r.SubName): $($r.Count) human write ops (from $($r.RawCount) raw records) in $($r.Elapsed)s"
        if ($r.HitLimit) { $statusMsg += " [!] hit $activityLogLimit limit" }
        Write-Log "  $statusMsg"
        $totalRecords += $r.Count

        foreach ($log in $r.Logs) {
            if ($null -eq $log.ResourceId) { continue }

            # RG-level activity tracking
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

    $phase2Timer.Stop()
    Write-Log "  Phase 2 total: $totalRecords records in $([math]::Round($phase2Timer.Elapsed.TotalSeconds, 1))s"

    if ($rgActivity.Count -gt 0) {
        $activityReport = $rgActivity.Values | Sort-Object DaysSinceActive -Descending
        $activityReport | Export-Csv -Path "$OutputDir/resource-group-activity.csv" -NoTypeInformation
        Write-Log "Resource group activity: $($activityReport.Count) groups analyzed"

        $dormantCount = ($activityReport | Where-Object { $_.DaysSinceActive -gt 60 }).Count
        $summary.DormantResourceGroups = $dormantCount
        Write-Log "  $dormantCount resource groups with no activity in 60+ days"
    }

    # Build per-resource last-touch index from filtered activity logs
    $resourceLastTouch = @{}
    foreach ($r in $activityResults) {
        if ($r.Error) { continue }
        foreach ($log in $r.Logs) {
            if ($null -eq $log.ResourceId) { continue }
            $rid = $log.ResourceId.ToLower()
            if (-not $resourceLastTouch.ContainsKey($rid) -or $log.EventTimestamp -gt $resourceLastTouch[$rid].Timestamp) {
                $resourceLastTouch[$rid] = @{
                    Timestamp = $log.EventTimestamp
                    Operation = $log.OperationName.Value
                    Caller    = $log.Caller
                }
            }
        }
    }

    if ($resourceLastTouch.Count -gt 0) {
        $touchReport = $resourceLastTouch.GetEnumerator() | ForEach-Object {
            $parts = $_.Key -split '/'
            $rgIdx = [array]::IndexOf($parts, 'resourcegroups')
            $rg = if ($rgIdx -ge 0 -and $rgIdx + 1 -lt $parts.Length) { $parts[$rgIdx + 1] } else { "" }
            [PSCustomObject]@{
                ResourceId       = $_.Key
                ResourceGroup    = $rg
                ResourceName     = $parts[-1]
                LastTouchTime    = $_.Value.Timestamp
                DaysSinceTouch   = [math]::Round(((Get-Date) - $_.Value.Timestamp).TotalDays)
                LastOperation    = $_.Value.Operation
                LastCaller       = $_.Value.Caller
            }
        } | Sort-Object DaysSinceTouch -Descending

        $touchReport | Export-Csv -Path "$OutputDir/resource-last-touch.csv" -NoTypeInformation
        $summary.ResourcesWithLastTouch = $touchReport.Count
        $dormantResources = ($touchReport | Where-Object { $_.DaysSinceTouch -gt 60 }).Count
        $summary.DormantResources = $dormantResources
        Write-Log "  Per-resource last-touch: $($touchReport.Count) resources indexed, $dormantResources dormant (60+ days)"
    }
} else {
    Write-Log "--- Phase 2: Activity Log Analysis (SKIPPED) ---"
}

# ── Phase 3: Cost Analysis (Cost Management Query API) ────────────────────────

if (-not $SkipCostData) {
    Write-Log "--- Phase 3: Cost Analysis ---"
    Write-Log "  Querying $($subscriptions.Count) subscription(s) in parallel..."

    $costStart = (Get-Date).AddDays(-$CostLookbackDays).ToString("yyyy-MM-dd")
    $costEnd = (Get-Date).ToString("yyyy-MM-dd")
    $costByRG = @{}

    $phase3Timer = [System.Diagnostics.Stopwatch]::StartNew()

    # Cost Management Query API — server-side aggregation by resource group
    $costQueryBody = @{
        type = "ActualCost"
        timeframe = "Custom"
        timePeriod = @{ from = $costStart; to = $costEnd }
        dataset = @{
            granularity = "None"
            aggregation = @{
                totalCost = @{ name = "Cost"; function = "Sum" }
            }
            grouping = @(
                @{ type = "Dimension"; name = "ResourceGroupName" }
            )
        }
    } | ConvertTo-Json -Depth 5

    $costResults = $subscriptions | ForEach-Object -Parallel {
        $sub = $_
        Import-Module Az.Accounts -ErrorAction Stop
        Disable-AzContextAutosave -Scope Process -ErrorAction SilentlyContinue | Out-Null
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile = $using:azProfile
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $apiPath = "/subscriptions/$($sub.Id)/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
            $response = Invoke-AzRestMethod -Path $apiPath -Method POST -Payload $using:costQueryBody
            $sw.Stop()

            if ($response.StatusCode -ne 200) {
                $errBody = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
                $errMsg = if ($errBody.error.message) { $errBody.error.message } else { "HTTP $($response.StatusCode)" }
                [PSCustomObject]@{
                    SubId   = $sub.Id
                    SubName = $sub.Name
                    Rows    = @()
                    Elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                    Error   = $errMsg
                }
            } else {
                $parsed = $response.Content | ConvertFrom-Json
                [PSCustomObject]@{
                    SubId   = $sub.Id
                    SubName = $sub.Name
                    Rows    = @($parsed.properties.rows)
                    Columns = @($parsed.properties.columns)
                    Elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                    Error   = $null
                }
            }
        } catch {
            $sw.Stop()
            [PSCustomObject]@{
                SubId   = $sub.Id
                SubName = $sub.Name
                Rows    = @()
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

        Write-Log "  $($r.SubName): $($r.Rows.Count) resource groups in $($r.Elapsed)s"

        foreach ($row in $r.Rows) {
            # Cost Management query returns: [cost, resourceGroupName, currency]
            $cost = [decimal]$row[0]
            $rg = $row[1]
            $currency = $row[2]

            $key = "$($r.SubId)/$rg"
            $costByRG[$key] = [PSCustomObject]@{
                SubscriptionId   = $r.SubId
                SubscriptionName = $r.SubName
                ResourceGroup    = $rg
                TotalCost        = [math]::Round($cost, 2)
                Currency         = $currency
            }
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
        Write-Log "  Total cost (last $CostLookbackDays days): `$$([math]::Round($totalCost, 2))"
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
        $nullAccountEnabled = 0
        foreach ($u in $allUsers) {
            if ($null -eq $u.AccountEnabled) { $nullAccountEnabled++ }
            $knownUPNs[$u.UserPrincipalName] = $u.AccountEnabled
            if ($u.AccountEnabled) { $activeUPNs[$u.UserPrincipalName] = $true }
        }
        Write-Log "  Loaded $($allUsers.Count) Entra ID users ($($activeUPNs.Count) active) in $([math]::Round($userTimer.Elapsed.TotalSeconds, 1))s"

        # Detect missing AccountEnabled property — indicates insufficient Graph permissions
        if ($allUsers.Count -gt 0 -and $activeUPNs.Count -eq 0 -and $nullAccountEnabled -gt 0) {
            Write-Log "  WARNING: AccountEnabled is null for all $nullAccountEnabled users — your token likely lacks User.Read.All Graph permissions. Orphan detection will produce false positives. Skipping." -Level "WARN"
            Write-Log "  To fix: Connect-AzAccount -AuthScope 'https://graph.microsoft.com/.default' or grant User.Read.All to your service principal" -Level "WARN"
            $phase4Timer.Stop()
            Write-Log "  Phase 4 total: $([math]::Round($phase4Timer.Elapsed.TotalSeconds, 1))s (skipped — insufficient permissions)"
        } else {

        if ($allUsers.Count -ge 10000) {
            Write-Log "  WARNING: User count hit the 10,000 limit — results may be incomplete. Consider paginating." -Level "WARN"
        }

        # Activity Log API supports max 90 days — use LookbackDays (capped at 90)
        $orphanLookback = [math]::Min($LookbackDays, 90)
        $orphanStart = (Get-Date).AddDays(-$orphanLookback)

        Write-Log "  Querying $($subscriptions.Count) subscription(s) for RG creation events ($orphanLookback-day lookback)..."

        # One query per subscription — server-side filter to Succeeded only
        $orphanLogResults = $subscriptions | ForEach-Object -Parallel {
            $sub = $_
            Import-Module Az.Accounts, Az.Monitor -ErrorAction Stop
            Disable-AzContextAutosave -Scope Process -ErrorAction SilentlyContinue | Out-Null
            [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile = $using:azProfile
            Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $rawLogs = Get-AzActivityLog -StartTime $using:orphanStart -EndTime (Get-Date) `
                    -MaxRecord 5000 -WarningAction SilentlyContinue

                $createLogs = @($rawLogs | Where-Object {
                    $_.OperationName.Value -match "resourcegroups/write$" -and
                    $_.Status.Value -eq "Succeeded" -and
                    $_.Caller -match "@"
                })
                $sw.Stop()

                [PSCustomObject]@{
                    SubId      = $sub.Id
                    SubName    = $sub.Name
                    CreateLogs = $createLogs
                    Elapsed    = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                    Error      = $null
                }
            } catch {
                $sw.Stop()
                [PSCustomObject]@{
                    SubId      = $sub.Id
                    SubName    = $sub.Name
                    CreateLogs = @()
                    Elapsed    = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                    Error      = $_.ToString()
                }
            }
        } -ThrottleLimit 4

        $orphanedRGs = @()
        foreach ($r in $orphanLogResults) {
            if ($r.Error) {
                Write-Log "  $($r.SubName): FAILED after $($r.Elapsed)s — $($r.Error)" -Level "ERROR"
                continue
            }

            Write-Log "  $($r.SubName): $($r.CreateLogs.Count) RG creation events in $($r.Elapsed)s"

            foreach ($log in $r.CreateLogs) {
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

        $phase4Timer.Stop()
        Write-Log "  Phase 4 total: $([math]::Round($phase4Timer.Elapsed.TotalSeconds, 1))s"

        if ($orphanedRGs.Count -gt 0) {
            $orphanedRGs | Export-Csv -Path "$OutputDir/orphaned-resource-groups.csv" -NoTypeInformation
            $summary.OrphanedResourceGroups = $orphanedRGs.Count
            Write-Log "  Found $($orphanedRGs.Count) resource groups created by departed users"
        } else {
            Write-Log "  No orphaned resource groups found"
        }

        } # end else (sufficient permissions)
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

# ── Generate XLSX Report (if ImportExcel available) ───────────────────────────

$exportScript = Join-Path $PSScriptRoot "../reporting/Export-DiscoveryReport.ps1"
if (-not (Test-Path $exportScript)) {
    $exportScript = "./reporting/Export-DiscoveryReport.ps1"
}

if ((Get-Module ImportExcel -ListAvailable) -and (Test-Path $exportScript)) {
    Write-Log "--- Generating Excel Report ---"
    try {
        & $exportScript -ReportDir $OutputDir
        Write-Log "Excel report: $OutputDir/discovery-report.xlsx"
    } catch {
        Write-Log "Excel report generation failed: $_" -Level "WARN"
    }
} else {
    if (-not (Get-Module ImportExcel -ListAvailable)) {
        Write-Log "Skipping Excel report — ImportExcel module not installed (Install-Module ImportExcel)" -Level "SKIP"
    }
}

Write-Log "=== Discovery Complete ==="
Write-Log "Report: $OutputDir/REPORT.md"
Write-Log "Summary: $OutputDir/summary.json"
Write-Log "Total time: $($summary.ElapsedMinutes) minutes"

return $summary

<#
.SYNOPSIS
    Exports discovery results to a formatted Excel workbook.

.DESCRIPTION
    Takes a discovery report directory (produced by Invoke-TenantDiscovery.ps1)
    and combines all CSV outputs into a single .xlsx workbook with:
    - Summary dashboard sheet with key metrics
    - One worksheet per discovery query result
    - Activity, cost, and orphan sheets (when present)
    - Cost analysis sheets from external cost CSV (when provided)
    - Conditional formatting for age and cost columns
    - Auto-sized columns and Excel table formatting

    Requires the ImportExcel module (Install-Module ImportExcel).

.PARAMETER ReportDir
    Path to a discovery report directory (e.g., ./reports/2026-03-19-183339).

.PARAMETER CostCsv
    Optional. Path to a cost analysis CSV exported from Azure Cost Management.
    Expected columns: UsageDate, ResourceId, ResourceType, ResourceLocation,
    ResourceGroupName, ServiceName, Meter, CostUSD

.PARAMETER OutputPath
    Path for the .xlsx file. Default: {ReportDir}/discovery-report-{timestamp}.xlsx

.EXAMPLE
    # Generate XLSX from the latest report
    .\Export-DiscoveryReport.ps1 -ReportDir ./reports/2026-03-19-183339

    # Include cost data
    .\Export-DiscoveryReport.ps1 -ReportDir ./reports/2026-03-19-193430 -CostCsv ./reports/cost-analysis.csv
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$ReportDir,

    [Parameter()]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CostCsv,

    [Parameter()]
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

# ── Prerequisites ─────────────────────────────────────────────────────────────

if (-not (Get-Module ImportExcel -ListAvailable)) {
    Write-Error "ImportExcel module is required. Install it with: Install-Module ImportExcel -Scope CurrentUser"
    return
}

Import-Module ImportExcel

# ── Setup ─────────────────────────────────────────────────────────────────────

$ReportDir = (Resolve-Path $ReportDir).Path

if (-not $OutputPath) {
    # Extract timestamp from report directory name (yyyy-MM-dd-HHmmss) or use current time
    $dirName = Split-Path $ReportDir -Leaf
    if ($dirName -match '^\d{4}-\d{2}-\d{2}-\d{6}$') {
        $timestamp = $dirName
    } else {
        $timestamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
    }
    $OutputPath = Join-Path $ReportDir "discovery-report-$timestamp.xlsx"
}

# Remove existing file — Export-Excel appends by default
if (Test-Path $OutputPath) {
    Remove-Item $OutputPath -Force
}

# ── Worksheet mapping ────────────────────────────────────────────────────────
# Maps CSV files to friendly worksheet names and display order

$worksheetMap = [ordered]@{
    "queries/01-full-resource-inventory"  = "Resource Inventory"
    "queries/02-untagged-resources"       = "Untagged Resources"
    "queries/03-empty-resource-groups"    = "Empty Resource Groups"
    "queries/04-stopped-deallocated-vms"  = "Stopped VMs"
    "queries/05-unattached-disks"         = "Unattached Disks"
    "queries/06-unused-public-ips"        = "Unused Public IPs"
    "queries/07-unused-nsgs"             = "Unused NSGs"
    "queries/08-old-snapshots"           = "Old Snapshots"
    "queries/09-resource-age-summary"    = "Resource Age Summary"
    "queries/10-subscription-overview"   = "Subscription Overview"
    "queries/11-resource-change-analysis" = "Change Analysis"
    "queries/12-empty-app-service-plans" = "Empty App Plans"
    "queries/13-orphaned-nics"           = "Orphaned NICs"
    "queries/14-storage-account-inventory" = "Storage Accounts"
    "queries/15-app-insights-inventory"  = "App Insights"
    "queries/16-log-analytics-workspaces" = "Log Analytics"
    "queries/17-orphaned-route-tables"   = "Orphaned Route Tables"
    "queries/18-empty-load-balancers"    = "Empty Load Balancers"
    "queries/19-key-vault-inventory"     = "Key Vaults"
    "queries/20-sql-database-inventory"  = "SQL Databases"
    "resource-group-activity"            = "RG Activity"
    "resource-last-touch"                = "Resource Last Touch"
    "metric-staleness"                   = "Metric Staleness"
    "cost-by-resource-group"             = "Cost by RG"
    "top-20-cost-resource-groups"        = "Top 20 Cost RGs"
    "orphaned-resource-groups"           = "Orphaned RGs"
}

# ── Summary sheet ─────────────────────────────────────────────────────────────

$summaryFile = Join-Path $ReportDir "summary.json"
if (Test-Path $summaryFile) {
    $summary = Get-Content $summaryFile -Raw | ConvertFrom-Json

    $summaryRows = @(
        [PSCustomObject]@{ Metric = "Report Date";           Value = $summary.RunDate }
        [PSCustomObject]@{ Metric = "Subscriptions Scanned"; Value = $summary.SubscriptionCount }
        [PSCustomObject]@{ Metric = "Scan Duration (min)";   Value = $summary.ElapsedMinutes }
    )

    # Add query result counts
    if ($summary.QueryResultCounts) {
        $summaryRows += [PSCustomObject]@{ Metric = ""; Value = "" }
        $summaryRows += [PSCustomObject]@{ Metric = "--- Query Results ---"; Value = "" }

        $queryProps = $summary.QueryResultCounts.PSObject.Properties | Sort-Object Name
        foreach ($prop in $queryProps) {
            $friendlyName = if ($worksheetMap.Contains($("queries/$($prop.Name)"))) {
                $worksheetMap["queries/$($prop.Name)"]
            } else {
                $prop.Name
            }
            $summaryRows += [PSCustomObject]@{ Metric = $friendlyName; Value = $prop.Value }
        }
    }

    # Add analysis metrics
    $summaryRows += [PSCustomObject]@{ Metric = ""; Value = "" }
    $summaryRows += [PSCustomObject]@{ Metric = "--- Analysis ---"; Value = "" }

    if ($null -ne $summary.DormantResourceGroups) {
        $summaryRows += [PSCustomObject]@{ Metric = "Dormant RGs (60+ days)"; Value = $summary.DormantResourceGroups }
    }
    if ($null -ne $summary.TotalCostLast30Days) {
        $summaryRows += [PSCustomObject]@{ Metric = "Total Cost (30 days)"; Value = $summary.TotalCostLast30Days }
    }
    if ($null -ne $summary.ZeroCostResourceGroups) {
        $summaryRows += [PSCustomObject]@{ Metric = "Zero-Cost RGs"; Value = $summary.ZeroCostResourceGroups }
    }
    if ($null -ne $summary.OrphanedResourceGroups) {
        $summaryRows += [PSCustomObject]@{ Metric = "Orphaned RGs"; Value = $summary.OrphanedResourceGroups }
    }

    # Add subscription list
    if ($summary.Subscriptions) {
        $summaryRows += [PSCustomObject]@{ Metric = ""; Value = "" }
        $summaryRows += [PSCustomObject]@{ Metric = "--- Subscriptions ---"; Value = "" }
        $subs = $summary.Subscriptions -split "; "
        foreach ($s in $subs) {
            $summaryRows += [PSCustomObject]@{ Metric = $s; Value = "" }
        }
    }

    $summaryRows | Export-Excel -Path $OutputPath -WorksheetName "Summary" `
        -AutoSize -BoldTopRow -FreezeTopRow `
        -Title "Azure Tenant Discovery Report" -TitleBold -TitleSize 16

    Write-Output "[INFO] Summary sheet created"
} else {
    Write-Output "[WARN] No summary.json found — skipping Summary sheet"
}

# ── Data sheets ───────────────────────────────────────────────────────────────

$sheetsCreated = 0

foreach ($entry in $worksheetMap.GetEnumerator()) {
    $csvPath = Join-Path $ReportDir "$($entry.Key).csv"

    if (-not (Test-Path $csvPath)) {
        continue
    }

    $data = Import-Csv -Path $csvPath
    if ($data.Count -eq 0) {
        continue
    }

    $sheetName = $entry.Value
    $excelParams = @{
        Path          = $OutputPath
        WorksheetName = $sheetName
        AutoSize      = $true
        AutoFilter    = $true
        BoldTopRow    = $true
        FreezeTopRow  = $true
        TableStyle    = "Medium2"
    }

    # Apply conditional formatting based on sheet content
    $conditionalFormats = @()

    # Age-based highlighting (red for old resources)
    $ageColumns = @("age_days", "AgeDays", "DaysSinceActive", "daysSinceModified", "daysSinceLastChange")
    foreach ($col in $ageColumns) {
        if ($data[0].PSObject.Properties.Name -contains $col) {
            $colLetter = [char](65 + [array]::IndexOf($data[0].PSObject.Properties.Name, $col))
            $conditionalFormats += New-ConditionalText -Range "${colLetter}:${colLetter}" -ConditionalType GreaterThan -Text "90" -BackgroundColor "#FFC7CE" -ConditionalTextColor "#9C0006"
            $conditionalFormats += New-ConditionalText -Range "${colLetter}:${colLetter}" -ConditionalType GreaterThan -Text "60" -BackgroundColor "#FFEB9C" -ConditionalTextColor "#9C6500"
        }
    }

    # Cost-based highlighting
    $costColumns = @("TotalCost", "PretaxCost")
    foreach ($col in $costColumns) {
        if ($data[0].PSObject.Properties.Name -contains $col) {
            $colLetter = [char](65 + [array]::IndexOf($data[0].PSObject.Properties.Name, $col))
            $conditionalFormats += New-ConditionalText -Range "${colLetter}:${colLetter}" -ConditionalType GreaterThan -Text "100" -BackgroundColor "#FFC7CE" -ConditionalTextColor "#9C0006"
        }
    }

    if ($conditionalFormats.Count -gt 0) {
        $excelParams.ConditionalFormat = $conditionalFormats
    }

    $data | Export-Excel @excelParams

    $sheetsCreated++
    Write-Output "[INFO] $sheetName`: $($data.Count) rows"
}

# ── Cross-Reference & Findings ────────────────────────────────────────────────

# Build RG-level cross-reference: cost + resources + activity + dormancy
$inventoryCsv = Join-Path $ReportDir "queries/01-full-resource-inventory.csv"
$activityCsv = Join-Path $ReportDir "resource-group-activity.csv"
$costRGCsv = Join-Path $ReportDir "cost-by-resource-group.csv"
$lastTouchCsv = Join-Path $ReportDir "resource-last-touch.csv"
$stoppedVmsCsv = Join-Path $ReportDir "queries/04-stopped-deallocated-vms.csv"
$emptyRGsCsv = Join-Path $ReportDir "queries/03-empty-resource-groups.csv"
$emptyPlansCsv = Join-Path $ReportDir "queries/12-empty-app-service-plans.csv"
$orphanedNicsCsv = Join-Path $ReportDir "queries/13-orphaned-nics.csv"
$unusedNsgsCsv = Join-Path $ReportDir "queries/07-unused-nsgs.csv"
$emptyLBsCsv = Join-Path $ReportDir "queries/18-empty-load-balancers.csv"
$sqlDbsCsv = Join-Path $ReportDir "queries/20-sql-database-inventory.csv"

# Load available data
$inventory = if (Test-Path $inventoryCsv) { Import-Csv $inventoryCsv } else { @() }
$activity = if (Test-Path $activityCsv) { Import-Csv $activityCsv } else { @() }
$costRG = if (Test-Path $costRGCsv) { Import-Csv $costRGCsv } else { @() }
$lastTouch = if (Test-Path $lastTouchCsv) { Import-Csv $lastTouchCsv } else { @() }

if ($inventory.Count -gt 0) {

    # ── RG Scorecard: join cost + resource count + activity ──
    $activityByRG = @{}
    foreach ($a in $activity) { $activityByRG[$a.ResourceGroup.ToLower()] = $a }

    $costByRGMap = @{}
    foreach ($c in $costRG) { $costByRGMap[$c.ResourceGroup.ToLower()] = $c }

    # Count dormant resources per RG from last-touch data
    $dormantByRG = @{}
    $totalByRG = @{}
    foreach ($t in $lastTouch) {
        $rg = $t.ResourceGroup.ToLower()
        if (-not $totalByRG.ContainsKey($rg)) { $totalByRG[$rg] = 0; $dormantByRG[$rg] = 0 }
        $totalByRG[$rg]++
        if ([int]$t.DaysSinceTouch -gt 60) { $dormantByRG[$rg]++ }
    }

    $rgScorecard = $inventory |
        Group-Object resourceGroup |
        ForEach-Object {
            $rgName = $_.Name
            $rgLower = $rgName.ToLower()
            $resourceCount = $_.Count
            $types = ($_.Group | Select-Object -ExpandProperty type -Unique).Count

            $act = $activityByRG[$rgLower]
            $cost = $costByRGMap[$rgLower]

            $monthlyCost = if ($cost) { [math]::Round([decimal]$cost.TotalCost, 2) } else { 0 }
            $lastActivityDays = if ($act) { [int]$act.DaysSinceActive } else { $null }
            $lastCaller = if ($act) { $act.LastCaller } else { "" }
            $dormant = if ($dormantByRG.ContainsKey($rgLower)) { $dormantByRG[$rgLower] } else { 0 }
            $touched = if ($totalByRG.ContainsKey($rgLower)) { $totalByRG[$rgLower] } else { 0 }
            $dormantPct = if ($touched -gt 0) { [math]::Round(($dormant / $touched) * 100) } else { $null }

            [PSCustomObject]@{
                ResourceGroup       = $rgName
                Resources           = $resourceCount
                ResourceTypes       = $types
                MonthlyCost         = $monthlyCost
                DaysSinceActivity   = $lastActivityDays
                LastCaller          = $lastCaller
                DormantResources    = $dormant
                TouchedResources    = $touched
                DormantPct          = $dormantPct
            }
        } |
        Sort-Object MonthlyCost -Descending

    $rgScorecard | Export-Excel -Path $OutputPath -WorksheetName "RG Scorecard" `
        -AutoSize -AutoFilter -BoldTopRow -FreezeTopRow -TableStyle "Medium2"
    $sheetsCreated++
    Write-Output "[INFO] RG Scorecard: $($rgScorecard.Count) resource groups cross-referenced"

    # ── Findings Sheet ──
    $findings = @()

    # Stopped VMs
    $stoppedVms = if (Test-Path $stoppedVmsCsv) { Import-Csv $stoppedVmsCsv } else { @() }
    if ($stoppedVms.Count -gt 0) {
        foreach ($vm in $stoppedVms) {
            $rgCost = $costByRGMap[$vm.resourceGroup.ToLower()]
            $rgMonthlyCost = if ($rgCost) { [math]::Round([decimal]$rgCost.TotalCost, 2) } else { 0 }
            $findings += [PSCustomObject]@{
                Priority      = "HIGH"
                Category      = "Stopped VM"
                ResourceGroup = $vm.resourceGroup
                Resource      = $vm.name
                Detail        = "$($vm.vmSize), deallocated $($vm.age_days) days"
                RGMonthlyCost = $rgMonthlyCost
                Owner         = if ($vm.tags -match 'Owner=([^;}"]+)') { $Matches[1] } else { "" }
                Action        = "Delete or snapshot+delete (disks still billing)"
            }
        }
    }

    # Empty RGs
    $emptyRGs = if (Test-Path $emptyRGsCsv) { Import-Csv $emptyRGsCsv } else { @() }
    foreach ($rg in $emptyRGs) {
        $findings += [PSCustomObject]@{
            Priority      = "LOW"
            Category      = "Empty RG"
            ResourceGroup = $rg.name
            Resource      = ""
            Detail        = "Zero resources"
            RGMonthlyCost = 0
            Owner         = if ($rg.tags -match 'Owner=([^;}"]+)') { $Matches[1] } else { "" }
            Action        = "Delete via Remove-EmptyResourceGroups.ps1"
        }
    }

    # SQL databases — paused or sample
    $sqlDbs = if (Test-Path $sqlDbsCsv) { Import-Csv $sqlDbsCsv } else { @() }
    foreach ($db in $sqlDbs) {
        if ($db.status -eq "Paused" -or $db.name -match "AdventureWorks|sample|test") {
            $rgCost = $costByRGMap[$db.resourceGroup.ToLower()]
            $rgMonthlyCost = if ($rgCost) { [math]::Round([decimal]$rgCost.TotalCost, 2) } else { 0 }
            $findings += [PSCustomObject]@{
                Priority      = "HIGH"
                Category      = "Idle SQL DB"
                ResourceGroup = $db.resourceGroup
                Resource      = $db.name
                Detail        = "$($db.skuTier)/$($db.skuName), $($db.status), $($db.age_days) days old"
                RGMonthlyCost = $rgMonthlyCost
                Owner         = if ($db.tags -match 'Owner=([^;}"]+)') { $Matches[1] } else { "" }
                Action        = if ($db.status -eq "Paused") { "Delete (still billing min vCores)" } else { "Delete sample/test database" }
            }
        }
    }

    # Empty App Service Plans
    $emptyPlans = if (Test-Path $emptyPlansCsv) { Import-Csv $emptyPlansCsv } else { @() }
    foreach ($plan in $emptyPlans) {
        $tier = if ($plan.skuTier) { $plan.skuTier } else { "Unknown" }
        $priority = if ($tier -in @("Free","Dynamic","Shared")) { "LOW" } else { "HIGH" }
        $findings += [PSCustomObject]@{
            Priority      = $priority
            Category      = "Empty App Plan"
            ResourceGroup = $plan.resourceGroup
            Resource      = $plan.name
            Detail        = "$tier / $($plan.skuName), 0 apps deployed"
            RGMonthlyCost = 0
            Owner         = if ($plan.tags -match 'Owner=([^;}"]+)') { $Matches[1] } else { "" }
            Action        = if ($priority -eq "HIGH") { "Delete (paid plan with no apps)" } else { "Delete (free tier, cleanup only)" }
        }
    }

    # Orphaned NICs
    $orphanedNics = if (Test-Path $orphanedNicsCsv) { Import-Csv $orphanedNicsCsv } else { @() }
    if ($orphanedNics.Count -gt 0) {
        $findings += [PSCustomObject]@{
            Priority      = "LOW"
            Category      = "Orphaned NICs"
            ResourceGroup = "(multiple)"
            Resource      = "$($orphanedNics.Count) NICs"
            Detail        = "Not attached to any VM"
            RGMonthlyCost = 0
            Owner         = ""
            Action        = "Review — may be PE-managed"
        }
    }

    # Unused NSGs
    $unusedNsgs = if (Test-Path $unusedNsgsCsv) { Import-Csv $unusedNsgsCsv } else { @() }
    if ($unusedNsgs.Count -gt 0) {
        foreach ($nsg in $unusedNsgs) {
            $findings += [PSCustomObject]@{
                Priority      = "LOW"
                Category      = "Unused NSG"
                ResourceGroup = $nsg.resourceGroup
                Resource      = $nsg.name
                Detail        = "$($nsg.ruleCount) rules, no associations"
                RGMonthlyCost = 0
                Owner         = if ($nsg.tags -match 'Owner=([^;}"]+)') { $Matches[1] } else { "" }
                Action        = "Delete"
            }
        }
    }

    # Empty Load Balancers
    $emptyLBs = if (Test-Path $emptyLBsCsv) { Import-Csv $emptyLBsCsv } else { @() }
    foreach ($lb in $emptyLBs) {
        $priority = if ($lb.skuName -eq "Standard") { "MEDIUM" } else { "LOW" }
        $findings += [PSCustomObject]@{
            Priority      = $priority
            Category      = "Empty Load Balancer"
            ResourceGroup = $lb.resourceGroup
            Resource      = $lb.name
            Detail        = "$($lb.skuName) SKU, no backends"
            RGMonthlyCost = 0
            Owner         = if ($lb.tags -match 'Owner=([^;}"]+)') { $Matches[1] } else { "" }
            Action        = if ($priority -eq "MEDIUM") { "Delete (Standard SKU = ~`$18/mo)" } else { "Delete (Basic SKU, free)" }
        }
    }

    # Dormant RGs with high cost
    foreach ($rg in $rgScorecard) {
        if ($null -ne $rg.DaysSinceActivity -and $rg.DaysSinceActivity -gt 60 -and $rg.MonthlyCost -gt 50) {
            $findings += [PSCustomObject]@{
                Priority      = "HIGH"
                Category      = "Dormant + Costly RG"
                ResourceGroup = $rg.ResourceGroup
                Resource      = "$($rg.Resources) resources"
                Detail        = "No activity in $($rg.DaysSinceActivity) days, `$$($rg.MonthlyCost)/mo"
                RGMonthlyCost = $rg.MonthlyCost
                Owner         = $rg.LastCaller
                Action        = "Review with owner — likely abandoned"
            }
        }
    }

    # Sort findings: HIGH first, then by cost
    $priorityOrder = @{ "HIGH" = 1; "MEDIUM" = 2; "LOW" = 3 }
    $findings = $findings | Sort-Object { $priorityOrder[$_.Priority] }, { -$_.RGMonthlyCost }

    if ($findings.Count -gt 0) {
        $findings | Export-Excel -Path $OutputPath -WorksheetName "Findings" `
            -AutoSize -AutoFilter -BoldTopRow -FreezeTopRow -TableStyle "Medium2" `
            -MoveToStart
        $sheetsCreated++
        $highCount = ($findings | Where-Object { $_.Priority -eq "HIGH" }).Count
        $medCount = ($findings | Where-Object { $_.Priority -eq "MEDIUM" }).Count
        $lowCount = ($findings | Where-Object { $_.Priority -eq "LOW" }).Count
        Write-Output "[INFO] Findings: $($findings.Count) items ($highCount high, $medCount medium, $lowCount low)"
    }
}

# ── Cost Analysis sheets (from external CSV) ──────────────────────────────────

if ($CostCsv) {
    Write-Output "[INFO] Loading cost data from: $CostCsv"
    $costData = Import-Csv -Path $CostCsv

    if ($costData.Count -eq 0) {
        Write-Output "[WARN] Cost CSV is empty — skipping cost analysis sheets"
    } else {
        $totalCost = ($costData | Measure-Object -Property CostUSD -Sum).Sum
        $dates = $costData | ForEach-Object { [datetime]$_.UsageDate } | Sort-Object
        $dateRange = "$($dates[0].ToString('yyyy-MM-dd')) to $($dates[-1].ToString('yyyy-MM-dd'))"

        Write-Output "[INFO] Cost data: $($costData.Count) records, $dateRange, total `$$([math]::Round($totalCost, 2))"

        # ── Cost Summary (add to Summary sheet) ──
        # We'll create a separate Cost Overview sheet instead of modifying Summary
        $costSummaryRows = @(
            [PSCustomObject]@{ Metric = "Date Range"; Value = $dateRange }
            [PSCustomObject]@{ Metric = "Total Spend"; Value = "`$$([math]::Round($totalCost, 2))" }
            [PSCustomObject]@{ Metric = "Monthly Average"; Value = "`$$([math]::Round($totalCost / (($dates[-1] - $dates[0]).Days / 30.44), 2))" }
            [PSCustomObject]@{ Metric = "Total Records"; Value = $costData.Count }
            [PSCustomObject]@{ Metric = ""; Value = "" }
        )

        # Monthly trend rows for the overview
        $monthlyData = $costData |
            ForEach-Object { [PSCustomObject]@{ Month = ([datetime]$_.UsageDate).ToString('yyyy-MM'); Cost = [decimal]$_.CostUSD } } |
            Group-Object Month |
            ForEach-Object { [PSCustomObject]@{ Month = $_.Name; Spend = [math]::Round(($_.Group | Measure-Object Cost -Sum).Sum, 2) } } |
            Sort-Object Month

        $costSummaryRows += [PSCustomObject]@{ Metric = "--- Monthly Trend ---"; Value = "" }
        foreach ($m in $monthlyData) {
            $costSummaryRows += [PSCustomObject]@{ Metric = $m.Month; Value = $m.Spend }
        }

        $costSummaryRows | Export-Excel -Path $OutputPath -WorksheetName "Cost Overview" `
            -AutoSize -BoldTopRow -FreezeTopRow `
            -Title "Cost Analysis" -TitleBold -TitleSize 14
        $sheetsCreated++
        Write-Output "[INFO] Cost Overview: summary + monthly trend"

        # ── Monthly Trend (chart-friendly format) ──
        $monthlyData | Export-Excel -Path $OutputPath -WorksheetName "Monthly Trend" `
            -AutoSize -BoldTopRow -FreezeTopRow -TableStyle "Medium2"
        $sheetsCreated++
        Write-Output "[INFO] Monthly Trend: $($monthlyData.Count) months with chart"

        # ── Cost by Resource Group ──
        $costByRG = $costData |
            Group-Object ResourceGroupName |
            ForEach-Object {
                $annualCost = [math]::Round(($_.Group | Measure-Object -Property CostUSD -Sum).Sum, 2)
                $monthlyCost = [math]::Round($annualCost / (($dates[-1] - $dates[0]).Days / 30.44), 2)
                $resourceCount = ($_.Group | Select-Object -ExpandProperty ResourceId -Unique).Count
                $topService = ($_.Group | Group-Object ServiceName | Sort-Object Count -Descending | Select-Object -First 1).Name
                [PSCustomObject]@{
                    ResourceGroup   = $_.Name
                    AnnualCost      = $annualCost
                    MonthlyCost     = $monthlyCost
                    ResourceCount   = $resourceCount
                    TopService      = $topService
                }
            } |
            Sort-Object AnnualCost -Descending

        $costByRG | Export-Excel -Path $OutputPath -WorksheetName "Cost by RG" `
            -AutoSize -AutoFilter -BoldTopRow -FreezeTopRow -TableStyle "Medium2"
        $sheetsCreated++
        Write-Output "[INFO] Cost by RG: $($costByRG.Count) resource groups"

        # ── Cost by Service ──
        $costByService = $costData |
            Group-Object ServiceName |
            ForEach-Object {
                $annualCost = [math]::Round(($_.Group | Measure-Object -Property CostUSD -Sum).Sum, 2)
                $pctOfTotal = [math]::Round(($annualCost / $totalCost) * 100, 1)
                $resourceCount = ($_.Group | Select-Object -ExpandProperty ResourceId -Unique).Count
                [PSCustomObject]@{
                    Service         = $_.Name
                    AnnualCost      = $annualCost
                    PctOfTotal      = $pctOfTotal
                    ResourceCount   = $resourceCount
                }
            } |
            Sort-Object AnnualCost -Descending

        $costByService | Export-Excel -Path $OutputPath -WorksheetName "Cost by Service" `
            -AutoSize -AutoFilter -BoldTopRow -FreezeTopRow -TableStyle "Medium2"
        $sheetsCreated++
        Write-Output "[INFO] Cost by Service: $($costByService.Count) services"

        # ── Top 50 Resources by Cost ──
        $costByResource = $costData |
            Group-Object ResourceId |
            ForEach-Object {
                $parts = $_.Name -split '/'
                $rgIdx = [array]::IndexOf($parts, 'resourcegroups')
                $rg = if ($rgIdx -ge 0 -and $rgIdx + 1 -lt $parts.Length) { $parts[$rgIdx + 1] } else { "" }
                $annualCost = [math]::Round(($_.Group | Measure-Object -Property CostUSD -Sum).Sum, 2)
                $monthlyCost = [math]::Round($annualCost / (($dates[-1] - $dates[0]).Days / 30.44), 2)
                [PSCustomObject]@{
                    Resource        = $parts[-1]
                    ResourceGroup   = $rg
                    ResourceType    = $_.Group[0].ResourceType
                    Service         = $_.Group[0].ServiceName
                    AnnualCost      = $annualCost
                    MonthlyCost     = $monthlyCost
                }
            } |
            Sort-Object AnnualCost -Descending |
            Select-Object -First 50

        $costByResource | Export-Excel -Path $OutputPath -WorksheetName "Top 50 Resources" `
            -AutoSize -AutoFilter -BoldTopRow -FreezeTopRow -TableStyle "Medium2"
        $sheetsCreated++
        Write-Output "[INFO] Top 50 Resources: by annual cost"

        # ── Cost by Resource Type ──
        $costByType = $costData |
            Group-Object ResourceType |
            ForEach-Object {
                $annualCost = [math]::Round(($_.Group | Measure-Object -Property CostUSD -Sum).Sum, 2)
                $pctOfTotal = [math]::Round(($annualCost / $totalCost) * 100, 1)
                $resourceCount = ($_.Group | Select-Object -ExpandProperty ResourceId -Unique).Count
                $costPerResource = if ($resourceCount -gt 0) { [math]::Round($annualCost / $resourceCount, 2) } else { 0 }
                [PSCustomObject]@{
                    ResourceType    = $_.Name
                    AnnualCost      = $annualCost
                    PctOfTotal      = $pctOfTotal
                    ResourceCount   = $resourceCount
                    AvgCostPerResource = $costPerResource
                }
            } |
            Sort-Object AnnualCost -Descending

        $costByType | Export-Excel -Path $OutputPath -WorksheetName "Cost by Type" `
            -AutoSize -AutoFilter -BoldTopRow -FreezeTopRow -TableStyle "Medium2"
        $sheetsCreated++
        Write-Output "[INFO] Cost by Type: $($costByType.Count) resource types"

        # ── Zero/Low Cost RGs (cleanup candidates) ──
        $lowCostRGs = $costByRG | Where-Object { $_.AnnualCost -lt 10 } |
            Sort-Object AnnualCost

        if ($lowCostRGs.Count -gt 0) {
            $lowCostRGs | Export-Excel -Path $OutputPath -WorksheetName "Low Cost RGs (<10 yr)" `
                -AutoSize -AutoFilter -BoldTopRow -FreezeTopRow -TableStyle "Medium2"
            $sheetsCreated++
            Write-Output "[INFO] Low Cost RGs: $($lowCostRGs.Count) RGs under `$10/year"
        }

        # ── Raw Cost Data ──
        $costData | Export-Excel -Path $OutputPath -WorksheetName "Raw Cost Data" `
            -AutoSize -AutoFilter -BoldTopRow -FreezeTopRow -TableStyle "Medium2"
        $sheetsCreated++
        Write-Output "[INFO] Raw Cost Data: $($costData.Count) records"
    }
}

# ── Final output ──────────────────────────────────────────────────────────────

Write-Output ""
Write-Output "[DONE] Workbook saved: $OutputPath"
Write-Output "       Sheets: Summary + $sheetsCreated data sheets"

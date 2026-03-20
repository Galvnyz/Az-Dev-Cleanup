<#
.SYNOPSIS
    Exports discovery results to a formatted Excel workbook.

.DESCRIPTION
    Takes a discovery report directory (produced by Invoke-TenantDiscovery.ps1)
    and combines all CSV outputs into a single .xlsx workbook with:
    - Summary dashboard sheet with key metrics
    - One worksheet per discovery query result
    - Activity, cost, and orphan sheets (when present)
    - Conditional formatting for age and cost columns
    - Auto-sized columns and Excel table formatting

    Requires the ImportExcel module (Install-Module ImportExcel).

.PARAMETER ReportDir
    Path to a discovery report directory (e.g., ./reports/2026-03-19-183339).

.PARAMETER OutputPath
    Path for the .xlsx file. Default: {ReportDir}/discovery-report.xlsx

.EXAMPLE
    # Generate XLSX from the latest report
    .\Export-DiscoveryReport.ps1 -ReportDir ./reports/2026-03-19-183339

    # Custom output path
    .\Export-DiscoveryReport.ps1 -ReportDir ./reports/2026-03-19-183339 -OutputPath ./final-report.xlsx
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$ReportDir,

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
    $OutputPath = Join-Path $ReportDir "discovery-report.xlsx"
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
    "resource-group-activity"            = "RG Activity"
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

# ── Final output ──────────────────────────────────────────────────────────────

Write-Output ""
Write-Output "[DONE] Workbook saved: $OutputPath"
Write-Output "       Sheets: Summary + $sheetsCreated data sheets"

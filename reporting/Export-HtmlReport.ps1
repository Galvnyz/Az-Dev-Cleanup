<#
.SYNOPSIS
    Exports discovery results to a self-contained dark-themed HTML report.

.DESCRIPTION
    Takes a discovery report directory (produced by Invoke-TenantDiscovery.ps1)
    and generates a single self-contained HTML file with:
    - Dark-themed CSS with fixed sidebar navigation
    - KPI cards showing key metrics
    - Placeholder sections for data tables (added by later tasks)

    No external dependencies — the HTML is fully self-contained.

.PARAMETER ReportDir
    Path to a discovery report directory (e.g., ./reports/2026-04-02-153244).

.PARAMETER OutputPath
    Path for the .html file. Default: {ReportDir}/discovery-report.html

.EXAMPLE
    .\Export-HtmlReport.ps1 -ReportDir ./reports/2026-04-02-153244
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

# ── Setup ─────────────────────────────────────────────────────────────────────

$ReportDir = (Resolve-Path $ReportDir).Path

if (-not $OutputPath) {
    $OutputPath = Join-Path $ReportDir "discovery-report.html"
}

Write-Output "[INFO] Generating HTML report from: $ReportDir"

# ── Load summary.json ─────────────────────────────────────────────────────────

$summaryPath = Join-Path $ReportDir "summary.json"
if (-not (Test-Path $summaryPath)) {
    Write-Error "summary.json not found in $ReportDir"
    return
}

$summary = Get-Content $summaryPath -Raw | ConvertFrom-Json
Write-Output "[INFO] Loaded summary.json — RunDate: $($summary.RunDate)"

# ── Helper: Import-OptionalCsv ────────────────────────────────────────────────

function Import-OptionalCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-Path $Path) {
        $rows = @(Import-Csv $Path)
        Write-Verbose "Loaded $($rows.Count) rows from $(Split-Path $Path -Leaf)"
        return , $rows
    }
    else {
        Write-Verbose "File not found, skipping: $(Split-Path $Path -Leaf)"
        return , @()
    }
}

# ── Load CSVs ─────────────────────────────────────────────────────────────────

$queriesDir = Join-Path $ReportDir "queries"

$inventory      = Import-OptionalCsv (Join-Path $queriesDir "01-full-resource-inventory.csv")
$untagged       = Import-OptionalCsv (Join-Path $queriesDir "02-untagged-resources.csv")
$emptyRGs       = Import-OptionalCsv (Join-Path $queriesDir "03-empty-resource-groups.csv")
$stoppedVMs     = Import-OptionalCsv (Join-Path $queriesDir "04-stopped-deallocated-vms.csv")
$unusedNSGs     = Import-OptionalCsv (Join-Path $queriesDir "07-unused-nsgs.csv")
$ageSummary     = Import-OptionalCsv (Join-Path $queriesDir "09-resource-age-summary.csv")
$subOverview    = Import-OptionalCsv (Join-Path $queriesDir "10-subscription-overview.csv")
$emptyAppPlans  = Import-OptionalCsv (Join-Path $queriesDir "12-empty-app-service-plans.csv")
$orphanedNICs   = Import-OptionalCsv (Join-Path $queriesDir "13-orphaned-nics.csv")
$emptyLBs       = Import-OptionalCsv (Join-Path $queriesDir "18-empty-load-balancers.csv")

$costByRG       = Import-OptionalCsv (Join-Path $ReportDir "cost-by-resource-group.csv")
$topCostRGs     = Import-OptionalCsv (Join-Path $ReportDir "top-20-cost-resource-groups.csv")
$rgActivity     = Import-OptionalCsv (Join-Path $ReportDir "resource-group-activity.csv")
$lastTouch      = Import-OptionalCsv (Join-Path $ReportDir "resource-last-touch.csv")

# ── Derived Metrics ───────────────────────────────────────────────────────────

$totalResources   = $inventory.Count
$totalCost        = if ($summary.TotalCost) { [double]$summary.TotalCost } else { 0.0 }
$costDays         = if ($summary.CostLookbackDays) { [int]$summary.CostLookbackDays } else { 30 }
$cleanupCandidates = $emptyRGs.Count + $stoppedVMs.Count + $unusedNSGs.Count +
                     $emptyAppPlans.Count + $orphanedNICs.Count + $emptyLBs.Count
$untaggedCount    = $untagged.Count

Write-Output "[INFO] Metrics — Resources: $totalResources | Cost: `$$($totalCost.ToString('N2')) ($costDays days) | Cleanup: $cleanupCandidates | Untagged: $untaggedCount"

# ── HTML Builder ──────────────────────────────────────────────────────────────

$html = [System.Text.StringBuilder]::new(65536)

function Add-Html {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Content
    )

    [void]$html.AppendLine($Content)
}

# ── Subscription list for header ──────────────────────────────────────────────

$subscriptionLines = ($summary.Subscriptions -split '; ') -join '<br>'

# ── Build HTML Document ───────────────────────────────────────────────────────

Add-Html '<!DOCTYPE html>'
Add-Html '<html lang="en">'
Add-Html '<head>'
Add-Html '<meta charset="UTF-8">'
Add-Html '<meta name="viewport" content="width=device-width, initial-scale=1.0">'
Add-Html '<title>Azure Tenant Discovery Report</title>'

# ── CSS Theme ─────────────────────────────────────────────────────────────────

$css = @'
<style>
:root {
    --bg: #0a0a1a;
    --bg-card: #112240;
    --text: #ccd6f6;
    --text-muted: #8892b0;
    --accent-teal: #64ffda;
    --accent-amber: #f59e0b;
    --accent-red: #ef4444;
    --accent-purple: #8b5cf6;
    --accent-blue: #3b82f6;
    --accent-green: #10b981;
    --accent-pink: #ec4899;
}

* {
    box-sizing: border-box;
}

body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font-family: 'Segoe UI', system-ui, sans-serif;
    line-height: 1.6;
}

.nav {
    position: fixed;
    left: 0;
    top: 0;
    width: 220px;
    height: 100vh;
    background: #0d1117;
    padding: 24px 0;
    overflow-y: auto;
    z-index: 100;
    border-right: 1px solid rgba(255,255,255,0.05);
}

.nav .nav-title {
    padding: 0 16px 16px;
    font-size: 14px;
    font-weight: 700;
    color: var(--accent-teal);
    text-transform: uppercase;
    letter-spacing: 1.5px;
    border-bottom: 1px solid rgba(255,255,255,0.05);
    margin-bottom: 8px;
}

.nav a {
    display: block;
    padding: 10px 16px;
    color: var(--text-muted);
    text-decoration: none;
    border-left: 3px solid transparent;
    transition: all 0.2s ease;
    font-size: 13px;
}

.nav a.active {
    color: var(--accent-teal);
    border-left-color: var(--accent-teal);
    background: rgba(100,255,218,0.05);
}

.nav a:hover {
    color: var(--text);
    background: rgba(255,255,255,0.05);
}

.main {
    margin-left: 220px;
    padding: 32px 48px;
    max-width: 1200px;
}

.report-header {
    margin-bottom: 32px;
}

.report-header h1 {
    font-size: 28px;
    color: #e6f1ff;
    margin-bottom: 8px;
    margin-top: 0;
}

.report-header .meta {
    color: var(--text-muted);
    font-size: 14px;
    line-height: 1.8;
}

.kpi-grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 16px;
    margin-bottom: 40px;
}

.kpi-card {
    background: var(--bg-card);
    border-radius: 8px;
    padding: 20px;
    border-left: 4px solid;
}

.kpi-card .label {
    font-size: 11px;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 1px;
    margin-bottom: 8px;
}

.kpi-card .value {
    font-size: 36px;
    font-weight: 700;
    color: #e6f1ff;
    line-height: 1.1;
}

.kpi-card .subtitle {
    font-size: 12px;
    margin-top: 6px;
    color: var(--text-muted);
}

section {
    margin-bottom: 48px;
    scroll-margin-top: 24px;
}

section h2 {
    font-size: 22px;
    color: #e6f1ff;
    margin-bottom: 16px;
    padding-bottom: 8px;
    border-bottom: 1px solid rgba(255,255,255,0.1);
}

table {
    width: 100%;
    border-collapse: collapse;
    font-size: 13px;
}

th {
    text-align: left;
    padding: 10px 12px;
    background: var(--bg-card);
    color: var(--accent-teal);
    font-weight: 600;
    border-bottom: 2px solid rgba(100,255,218,0.3);
    cursor: pointer;
    user-select: none;
}

th:hover {
    background: rgba(100,255,218,0.1);
}

td {
    padding: 8px 12px;
    border-bottom: 1px solid rgba(255,255,255,0.05);
}

tr:hover td {
    background: rgba(255,255,255,0.03);
}

tr:nth-child(even) td {
    background: rgba(255,255,255,0.02);
}

.badge {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 4px;
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
}

.badge-high {
    background: rgba(239,68,68,0.2);
    color: #ef4444;
}

.badge-medium {
    background: rgba(245,158,11,0.2);
    color: #f59e0b;
}

.badge-low {
    background: rgba(100,255,218,0.2);
    color: #64ffda;
}

.chart-container {
    margin: 20px 0;
    overflow-x: auto;
}

svg text {
    font-family: inherit;
    fill: var(--text-muted);
    font-size: 12px;
}

.search-input {
    width: 100%;
    max-width: 400px;
    padding: 10px 16px;
    background: var(--bg-card);
    border: 1px solid rgba(255,255,255,0.1);
    border-radius: 6px;
    color: var(--text);
    font-size: 14px;
    outline: none;
    margin-bottom: 16px;
}

.search-input:focus {
    border-color: var(--accent-teal);
}

.search-input::placeholder {
    color: var(--text-muted);
}

details {
    margin-bottom: 12px;
    background: var(--bg-card);
    border-radius: 8px;
    overflow: hidden;
}

summary {
    padding: 14px 20px;
    cursor: pointer;
    font-weight: 600;
    color: #e6f1ff;
    display: flex;
    align-items: center;
    gap: 12px;
}

summary:hover {
    background: rgba(255,255,255,0.03);
}

details[open] summary {
    border-bottom: 1px solid rgba(255,255,255,0.05);
}

details .detail-content {
    padding: 16px 20px;
}

.tag-pill {
    display: inline-block;
    padding: 1px 6px;
    background: rgba(139,92,246,0.15);
    color: #8b5cf6;
    border-radius: 3px;
    font-size: 11px;
    margin: 1px;
}

.stat-row {
    display: flex;
    gap: 24px;
    margin-bottom: 24px;
    flex-wrap: wrap;
}

.stat-box {
    background: var(--bg-card);
    border-radius: 8px;
    padding: 16px 24px;
    min-width: 150px;
}

.stat-box .stat-value {
    font-size: 28px;
    font-weight: 700;
    color: #e6f1ff;
}

.stat-box .stat-label {
    font-size: 12px;
    color: var(--text-muted);
    margin-top: 4px;
}

.recommendation-card {
    background: var(--bg-card);
    border-radius: 8px;
    padding: 20px;
    margin-bottom: 12px;
    border-left: 4px solid var(--accent-teal);
    display: flex;
    gap: 16px;
    align-items: flex-start;
}

.recommendation-card .rec-icon {
    font-size: 24px;
    flex-shrink: 0;
}

.recommendation-card .rec-title {
    font-weight: 600;
    color: #e6f1ff;
    margin-bottom: 4px;
}

.recommendation-card .rec-detail {
    color: var(--text-muted);
    font-size: 13px;
}

.footer {
    margin-top: 64px;
    padding-top: 24px;
    border-top: 1px solid rgba(255,255,255,0.1);
    color: var(--text-muted);
    font-size: 12px;
    text-align: center;
}

.hamburger {
    display: none;
}

.warning-row td {
    background: rgba(245,158,11,0.08) !important;
}

@media (max-width: 1024px) {
    .main {
        margin-left: 0;
        padding: 24px;
    }
    .nav {
        position: fixed;
        transform: translateX(-100%);
        transition: transform 0.3s ease;
    }
    .nav.open {
        transform: translateX(0);
    }
    .hamburger {
        display: block;
        position: fixed;
        top: 16px;
        left: 16px;
        z-index: 200;
        background: var(--bg-card);
        border: none;
        color: var(--text);
        padding: 8px 12px;
        border-radius: 6px;
        cursor: pointer;
        font-size: 18px;
    }
    .kpi-grid {
        grid-template-columns: repeat(2, 1fr);
    }
}

@media (max-width: 768px) {
    .kpi-grid {
        grid-template-columns: 1fr;
    }
    .stat-row {
        flex-direction: column;
    }
}

@media print {
    body {
        background: white;
        color: #1a1a2e;
    }
    .nav {
        display: none;
    }
    .main {
        margin-left: 0;
    }
    .kpi-card {
        background: #f0f0f0;
    }
    th {
        background: #e0e0e0;
        color: #1a1a2e;
    }
}
</style>
'@

Add-Html $css
Add-Html '</head>'
Add-Html '<body>'

# ── Hamburger Button ──────────────────────────────────────────────────────────

Add-Html '<button class="hamburger" id="hamburgerBtn" aria-label="Toggle navigation">&#9776;</button>'

# ── Sidebar Navigation ────────────────────────────────────────────────────────

Add-Html '<nav class="nav" id="sideNav">'
Add-Html '  <div class="nav-title">Discovery Report</div>'
Add-Html '  <a href="#overview">Overview</a>'
Add-Html '  <a href="#cost-analysis">Cost Analysis</a>'
Add-Html '  <a href="#cleanup-candidates">Cleanup Candidates</a>'
Add-Html '  <a href="#governance">Governance</a>'
Add-Html '  <a href="#inventory">Inventory</a>'
Add-Html '  <a href="#activity">Activity</a>'
Add-Html '  <a href="#recommendations">Recommendations</a>'
Add-Html '</nav>'

# ── Main Content ──────────────────────────────────────────────────────────────

Add-Html '<div class="main">'

# ── Report Header ─────────────────────────────────────────────────────────────

Add-Html '<div class="report-header">'
Add-Html '  <h1>Azure Tenant Discovery Report</h1>'
Add-Html "  <div class=`"meta`">"
Add-Html "    <strong>Run Date:</strong> $($summary.RunDate)<br>"
Add-Html "    <strong>Subscriptions:</strong><br>$subscriptionLines<br>"
Add-Html "    <strong>Elapsed:</strong> $($summary.ElapsedMinutes) minutes"
Add-Html '  </div>'
Add-Html '</div>'

# ── KPI Cards ─────────────────────────────────────────────────────────────────

$costFormatted = $totalCost.ToString('N2')

Add-Html '<div class="kpi-grid">'

Add-Html '  <div class="kpi-card" style="border-left-color: #64ffda;">'
Add-Html '    <div class="label">Total Resources</div>'
Add-Html "    <div class=`"value`">$totalResources</div>"
Add-Html "    <div class=`"subtitle`">$($subOverview.Count) subscriptions</div>"
Add-Html '  </div>'

Add-Html '  <div class="kpi-card" style="border-left-color: #f59e0b;">'
Add-Html '    <div class="label">Monthly Cost</div>'
Add-Html "    <div class=`"value`">`$$costFormatted</div>"
Add-Html "    <div class=`"subtitle`">${costDays}-day spend</div>"
Add-Html '  </div>'

Add-Html '  <div class="kpi-card" style="border-left-color: #ef4444;">'
Add-Html '    <div class="label">Cleanup Candidates</div>'
Add-Html "    <div class=`"value`">$cleanupCandidates</div>"
Add-Html '    <div class="subtitle">across 6 categories</div>'
Add-Html '  </div>'

Add-Html '  <div class="kpi-card" style="border-left-color: #8b5cf6;">'
Add-Html '    <div class="label">Untagged</div>'
Add-Html "    <div class=`"value`">$untaggedCount</div>"
Add-Html '    <div class="subtitle">missing governance</div>'
Add-Html '  </div>'

Add-Html '</div>'

# ── Helper: HTML-encode ──────────────────────────────────────────────────────

function ConvertTo-SafeHtml {
    [CmdletBinding()]
    param([Parameter()][AllowEmptyString()][string]$Text = '')
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $Text -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'
}

# ── Section: Overview ────────────────────────────────────────────────────────

Add-Html '<section id="overview">'
Add-Html '  <h2>Overview</h2>'

# --- Subscription table ---
Add-Html '<table>'
Add-Html '  <tr><th>Subscription</th><th>Resources</th><th>Types</th><th>Resource Groups</th><th>Locations</th></tr>'
foreach ($sub in $subOverview) {
    $subName = ConvertTo-SafeHtml $sub.subscriptionName
    Add-Html "  <tr><td>$subName</td><td>$($sub.total_resources)</td><td>$($sub.resource_types)</td><td>$($sub.resource_groups)</td><td>$($sub.locations)</td></tr>"
}
Add-Html '</table>'

# --- Resource type distribution (horizontal bar chart) ---
$typeGroups = $inventory | Group-Object -Property type |
    Sort-Object Count -Descending | Select-Object -First 15
$maxTypeCount = if ($typeGroups.Count -gt 0) { ($typeGroups | Measure-Object -Property Count -Maximum).Maximum } else { 1 }
$barHeight   = 22
$barGap      = 4
$labelX      = 10
$barStartX   = 350
$barMaxW     = 380
$chartH      = ($barHeight + $barGap) * [math]::Max($typeGroups.Count, 1) + 30

Add-Html '<div class="chart-container">'
Add-Html '  <h3>Resource Type Distribution (Top 15)</h3>'
Add-Html "  <svg viewBox=`"0 0 800 $chartH`" xmlns=`"http://www.w3.org/2000/svg`">"

$yPos = 20
foreach ($tg in $typeGroups) {
    $typeName = ConvertTo-SafeHtml $tg.Name
    $cnt      = $tg.Count
    $barW     = [math]::Max([math]::Round(($cnt / $maxTypeCount) * $barMaxW, 1), 2)
    Add-Html "    <text x=`"$($barStartX - 8)`" y=`"$($yPos + 15)`" text-anchor=`"end`" fill=`"#8892b0`" font-size=`"11`">$typeName</text>"
    Add-Html "    <rect x=`"$barStartX`" y=`"$yPos`" width=`"$barW`" height=`"$barHeight`" rx=`"3`" fill=`"#64ffda`" opacity=`"0.8`"/>"
    Add-Html "    <text x=`"$($barStartX + $barW + 6)`" y=`"$($yPos + 15)`" fill=`"#e6f1ff`" font-size=`"12`">$cnt</text>"
    $yPos += ($barHeight + $barGap)
}

Add-Html '  </svg>'
Add-Html '</div>'

# --- Resource age histogram (vertical bar chart) ---
$ageBrackets = $ageSummary | Group-Object -Property age_bracket | ForEach-Object {
    [PSCustomObject]@{
        Bracket = $_.Name
        Total   = ($_.Group | Measure-Object -Property count_ -Sum).Sum
    }
}
# Sort brackets in logical order
$bracketOrder = @('< 1 year','1-2 years','2-3 years','3-5 years','5+ years')
$sortedBrackets = @()
foreach ($bo in $bracketOrder) {
    $match = $ageBrackets | Where-Object { $_.Bracket -eq $bo }
    if ($match) { $sortedBrackets += $match }
}
# Add any brackets not in the predefined order
foreach ($ab in $ageBrackets) {
    if ($ab.Bracket -notin $bracketOrder) { $sortedBrackets += $ab }
}
$ageBrackets = $sortedBrackets

$maxAgeCount = if ($ageBrackets.Count -gt 0) { ($ageBrackets | Measure-Object -Property Total -Maximum).Maximum } else { 1 }
$ageBarColors = @('#64ffda','#10b981','#f59e0b','#ef8c00','#ef4444')

Add-Html '<div class="chart-container">'
Add-Html '  <h3>Resource Age Distribution</h3>'
Add-Html '  <svg viewBox="0 0 600 300" xmlns="http://www.w3.org/2000/svg">'

$chartBottom = 250
$chartTop    = 30
$ageBarW     = 60
$ageGap      = 30
$ageStartX   = 80
for ($i = 0; $i -lt $ageBrackets.Count; $i++) {
    $ab       = $ageBrackets[$i]
    $barH     = [math]::Max([math]::Round(($ab.Total / [math]::Max($maxAgeCount, 1)) * ($chartBottom - $chartTop), 1), 2)
    $barX     = $ageStartX + $i * ($ageBarW + $ageGap)
    $barY     = $chartBottom - $barH
    $color    = if ($i -lt $ageBarColors.Count) { $ageBarColors[$i] } else { '#8892b0' }
    $label    = ConvertTo-SafeHtml $ab.Bracket

    Add-Html "    <rect x=`"$barX`" y=`"$barY`" width=`"$ageBarW`" height=`"$barH`" rx=`"3`" fill=`"$color`" opacity=`"0.85`"/>"
    Add-Html "    <text x=`"$($barX + $ageBarW / 2)`" y=`"$($barY - 6)`" text-anchor=`"middle`" fill=`"#e6f1ff`" font-size=`"12`">$([int]$ab.Total)</text>"
    Add-Html "    <text x=`"$($barX + $ageBarW / 2)`" y=`"$($chartBottom + 18)`" text-anchor=`"middle`" fill=`"#8892b0`" font-size=`"11`">$label</text>"
}

# Baseline
Add-Html "    <line x1=`"$($ageStartX - 10)`" y1=`"$chartBottom`" x2=`"$($ageStartX + $ageBrackets.Count * ($ageBarW + $ageGap))`" y2=`"$chartBottom`" stroke=`"#8892b0`" stroke-width=`"1`"/>"

Add-Html '  </svg>'
Add-Html '</div>'

Add-Html '</section>'

# ── Section: Cost Analysis ───────────────────────────────────────────────────

Add-Html '<section id="cost-analysis">'
Add-Html '  <h2>Cost Analysis</h2>'

# --- Stat boxes ---
$costFmt = $totalCost.ToString('N2')
$zeroCostRGs = if ($summary.ZeroCostResourceGroups) { $summary.ZeroCostResourceGroups } else { 0 }

Add-Html '<div class="stat-row">'
Add-Html '  <div class="stat-box">'
Add-Html "    <div class=`"stat-value`">`$$costFmt</div>"
Add-Html '    <div class="stat-label">Total Spend</div>'
Add-Html '  </div>'
Add-Html '  <div class="stat-box">'
Add-Html "    <div class=`"stat-value`">$costDays days</div>"
Add-Html '    <div class="stat-label">Lookback Period</div>'
Add-Html '  </div>'
Add-Html '  <div class="stat-box">'
Add-Html "    <div class=`"stat-value`">$zeroCostRGs</div>"
Add-Html '    <div class="stat-label">Zero-Cost RGs</div>'
Add-Html '  </div>'
Add-Html '</div>'

# --- Top 20 RGs by cost (horizontal bar chart) ---
$maxCost = if ($topCostRGs.Count -gt 0) { ($topCostRGs | ForEach-Object { [double]$_.TotalCost } | Measure-Object -Maximum).Maximum } else { 1 }
$costBarH  = 22
$costBarG  = 4
$costStartX = 300
$costBarMax = 420
$costChartH = ($costBarH + $costBarG) * [math]::Max($topCostRGs.Count, 1) + 30

Add-Html '<div class="chart-container">'
Add-Html '  <h3>Top Resource Groups by Cost</h3>'
Add-Html "  <svg viewBox=`"0 0 800 $costChartH`" xmlns=`"http://www.w3.org/2000/svg`">"

$yPos = 20
foreach ($rg in $topCostRGs) {
    $rgName  = ConvertTo-SafeHtml $rg.ResourceGroup
    $rgCost  = [double]$rg.TotalCost
    $barW    = [math]::Max([math]::Round(($rgCost / $maxCost) * $costBarMax, 1), 2)
    $costLbl = '$' + $rgCost.ToString('N2')
    Add-Html "    <text x=`"$($costStartX - 8)`" y=`"$($yPos + 15)`" text-anchor=`"end`" fill=`"#8892b0`" font-size=`"11`">$rgName</text>"
    Add-Html "    <rect x=`"$costStartX`" y=`"$yPos`" width=`"$barW`" height=`"$costBarH`" rx=`"3`" fill=`"#f59e0b`" opacity=`"0.85`"/>"
    Add-Html "    <text x=`"$($costStartX + $barW + 6)`" y=`"$($yPos + 15)`" fill=`"#e6f1ff`" font-size=`"12`">$costLbl</text>"
    $yPos += ($costBarH + $costBarG)
}

Add-Html '  </svg>'
Add-Html '</div>'

# --- Cost table ---
Add-Html '<table>'
Add-Html '  <tr><th>Resource Group</th><th>Subscription</th><th style="text-align:right">Cost</th></tr>'
foreach ($rg in $topCostRGs) {
    $rgName  = ConvertTo-SafeHtml $rg.ResourceGroup
    $subName = ConvertTo-SafeHtml $rg.SubscriptionName
    $costVal = '$' + ([double]$rg.TotalCost).ToString('N2')
    Add-Html "  <tr><td>$rgName</td><td>$subName</td><td style=`"text-align:right`">$costVal</td></tr>"
}
Add-Html '</table>'

Add-Html '</section>'

# ── Section: Cleanup Candidates ──────────────────────────────────────────────

Add-Html '<section id="cleanup-candidates">'
Add-Html '  <h2>Cleanup Candidates</h2>'

# --- Donut chart ---
$categories = @(
    [PSCustomObject]@{ Name='Stopped VMs';       Count=$stoppedVMs.Count;   Color='#ef4444' }
    [PSCustomObject]@{ Name='Empty RGs';          Count=$emptyRGs.Count;     Color='#64ffda' }
    [PSCustomObject]@{ Name='Empty App Plans';    Count=$emptyAppPlans.Count; Color='#8b5cf6' }
    [PSCustomObject]@{ Name='Unused NSGs';        Count=$unusedNSGs.Count;   Color='#3b82f6' }
    [PSCustomObject]@{ Name='Orphaned NICs';      Count=$orphanedNICs.Count; Color='#f59e0b' }
    [PSCustomObject]@{ Name='Empty LBs';          Count=$emptyLBs.Count;     Color='#ec4899' }
)
$activeCats = $categories | Where-Object { $_.Count -gt 0 }
$totalCands = ($categories | Measure-Object -Property Count -Sum).Sum

Add-Html '<div class="chart-container" style="display:flex;gap:40px;align-items:center;flex-wrap:wrap;">'

if ($totalCands -gt 0) {
    $radius     = 90
    $cx         = 150
    $cy         = 150
    $circumf    = 2 * [math]::PI * $radius
    $strokeW    = 35
    $offset     = 0

    Add-Html "  <svg viewBox=`"0 0 300 300`" width=`"300`" height=`"300`" xmlns=`"http://www.w3.org/2000/svg`">"
    # Background circle
    Add-Html "    <circle cx=`"$cx`" cy=`"$cy`" r=`"$radius`" fill=`"none`" stroke=`"#1e293b`" stroke-width=`"$strokeW`"/>"

    foreach ($cat in $activeCats) {
        $pct        = $cat.Count / $totalCands
        $dashLen    = [math]::Round($pct * $circumf, 2)
        $dashGap    = [math]::Round($circumf - $dashLen, 2)
        $dashOffset = [math]::Round(-$offset, 2)
        Add-Html "    <circle cx=`"$cx`" cy=`"$cy`" r=`"$radius`" fill=`"none`" stroke=`"$($cat.Color)`" stroke-width=`"$strokeW`" stroke-dasharray=`"$dashLen $dashGap`" stroke-dashoffset=`"$dashOffset`" transform=`"rotate(-90 $cx $cy)`"/>"
        $offset += $dashLen
    }

    # Center text
    Add-Html "    <text x=`"$cx`" y=`"$($cy - 6)`" text-anchor=`"middle`" fill=`"#e6f1ff`" font-size=`"32`" font-weight=`"700`">$totalCands</text>"
    Add-Html "    <text x=`"$cx`" y=`"$($cy + 16)`" text-anchor=`"middle`" fill=`"#8892b0`" font-size=`"12`">candidates</text>"
    Add-Html '  </svg>'
}

# Legend
Add-Html '  <div>'
foreach ($cat in $activeCats) {
    Add-Html "    <div style=`"display:flex;align-items:center;gap:8px;margin-bottom:6px;`">"
    Add-Html "      <span style=`"width:12px;height:12px;border-radius:50%;background:$($cat.Color);display:inline-block;`"></span>"
    Add-Html "      <span style=`"color:#ccd6f6;font-size:13px;`">$($cat.Name) ($($cat.Count))</span>"
    Add-Html '    </div>'
}
Add-Html '  </div>'
Add-Html '</div>'

# --- Collapsible detail tables ---

# Stopped VMs (HIGH)
if ($stoppedVMs.Count -gt 0) {
    Add-Html '<details>'
    Add-Html "  <summary><span class=`"badge badge-high`">HIGH</span> Stopped VMs ($($stoppedVMs.Count))</summary>"
    Add-Html '  <div class="detail-content">'
    Add-Html '    <table>'
    Add-Html '      <tr><th>Name</th><th>Resource Group</th><th>Location</th><th>VM Size</th><th>Age (days)</th><th>Tags</th></tr>'
    foreach ($vm in $stoppedVMs) {
        $vmName = ConvertTo-SafeHtml $vm.name
        $vmRG   = ConvertTo-SafeHtml $vm.resourceGroup
        $vmTags = ConvertTo-SafeHtml "$($vm.tags)"
        Add-Html "      <tr><td>$vmName</td><td>$vmRG</td><td>$($vm.location)</td><td>$($vm.vmSize)</td><td>$($vm.age_days)</td><td>$vmTags</td></tr>"
    }
    Add-Html '    </table>'
    Add-Html '  </div>'
    Add-Html '</details>'
}

# Empty App Service Plans (HIGH if paid, LOW if free)
if ($emptyAppPlans.Count -gt 0) {
    $paidPlans = @($emptyAppPlans | Where-Object { $_.skuTier -notin @('Free','Dynamic') })
    $planBadge = if ($paidPlans.Count -gt 0) { 'badge-high' } else { 'badge-low' }
    $planPrio  = if ($paidPlans.Count -gt 0) { 'HIGH' } else { 'LOW' }

    Add-Html '<details>'
    Add-Html "  <summary><span class=`"badge $planBadge`">$planPrio</span> Empty App Service Plans ($($emptyAppPlans.Count))</summary>"
    Add-Html '  <div class="detail-content">'
    Add-Html '    <table>'
    Add-Html '      <tr><th>Name</th><th>Resource Group</th><th>SKU Tier</th><th>SKU Name</th><th>Age (days)</th></tr>'
    foreach ($ap in $emptyAppPlans) {
        $apName = ConvertTo-SafeHtml $ap.name
        $apRG   = ConvertTo-SafeHtml $ap.resourceGroup
        Add-Html "      <tr><td>$apName</td><td>$apRG</td><td>$($ap.skuTier)</td><td>$($ap.skuName)</td><td>$($ap.age_days)</td></tr>"
    }
    Add-Html '    </table>'
    Add-Html '  </div>'
    Add-Html '</details>'
}

# Orphaned NICs (LOW)
if ($orphanedNICs.Count -gt 0) {
    Add-Html '<details>'
    Add-Html "  <summary><span class=`"badge badge-low`">LOW</span> Orphaned NICs ($($orphanedNICs.Count))</summary>"
    Add-Html '  <div class="detail-content">'
    Add-Html '    <table>'
    Add-Html '      <tr><th>Name</th><th>Resource Group</th><th>Private IP</th><th>Managed By</th></tr>'
    foreach ($nic in $orphanedNICs) {
        $nicName = ConvertTo-SafeHtml $nic.name
        $nicRG   = ConvertTo-SafeHtml $nic.resourceGroup
        $nicMB   = ConvertTo-SafeHtml "$($nic.managedBy)"
        Add-Html "      <tr><td>$nicName</td><td>$nicRG</td><td>$($nic.privateIP)</td><td>$nicMB</td></tr>"
    }
    Add-Html '    </table>'
    Add-Html '  </div>'
    Add-Html '</details>'
}

# Empty Resource Groups (LOW)
if ($emptyRGs.Count -gt 0) {
    Add-Html '<details>'
    Add-Html "  <summary><span class=`"badge badge-low`">LOW</span> Empty Resource Groups ($($emptyRGs.Count))</summary>"
    Add-Html '  <div class="detail-content">'
    Add-Html '    <table>'
    Add-Html '      <tr><th>Name</th><th>Location</th></tr>'
    foreach ($rg in $emptyRGs) {
        $rgName = ConvertTo-SafeHtml $rg.name
        Add-Html "      <tr><td>$rgName</td><td>$($rg.location)</td></tr>"
    }
    Add-Html '    </table>'
    Add-Html '  </div>'
    Add-Html '</details>'
}

# Unused NSGs (LOW)
if ($unusedNSGs.Count -gt 0) {
    Add-Html '<details>'
    Add-Html "  <summary><span class=`"badge badge-low`">LOW</span> Unused NSGs ($($unusedNSGs.Count))</summary>"
    Add-Html '  <div class="detail-content">'
    Add-Html '    <table>'
    Add-Html '      <tr><th>Name</th><th>Resource Group</th></tr>'
    foreach ($nsg in $unusedNSGs) {
        $nsgName = ConvertTo-SafeHtml $nsg.name
        $nsgRG   = ConvertTo-SafeHtml $nsg.resourceGroup
        Add-Html "      <tr><td>$nsgName</td><td>$nsgRG</td></tr>"
    }
    Add-Html '    </table>'
    Add-Html '  </div>'
    Add-Html '</details>'
}

# Empty Load Balancers (MEDIUM)
if ($emptyLBs.Count -gt 0) {
    Add-Html '<details>'
    Add-Html "  <summary><span class=`"badge badge-medium`">MEDIUM</span> Empty Load Balancers ($($emptyLBs.Count))</summary>"
    Add-Html '  <div class="detail-content">'
    Add-Html '    <table>'
    Add-Html '      <tr><th>Name</th><th>Resource Group</th></tr>'
    foreach ($lb in $emptyLBs) {
        $lbName = ConvertTo-SafeHtml $lb.name
        $lbRG   = ConvertTo-SafeHtml $lb.resourceGroup
        Add-Html "      <tr><td>$lbName</td><td>$lbRG</td></tr>"
    }
    Add-Html '    </table>'
    Add-Html '  </div>'
    Add-Html '</details>'
}

Add-Html '</section>'

# ── Section: Governance Gaps ─────────────────────────────────────────────────

Add-Html '<section id="governance">'
Add-Html '  <h2>Governance Gaps</h2>'

# --- Tag coverage progress bar ---
$taggedPct = [math]::Round(($totalResources - $untaggedCount) / [math]::Max($totalResources, 1) * 100, 1)
$taggedCount = $totalResources - $untaggedCount
$fillW = [math]::Round($taggedPct / 100 * 560, 1)

Add-Html '<div class="chart-container">'
Add-Html '  <h3>Tag Coverage</h3>'
Add-Html '  <svg viewBox="0 0 600 50" xmlns="http://www.w3.org/2000/svg">'
Add-Html '    <rect x="20" y="10" width="560" height="28" rx="6" fill="#ef4444" opacity="0.3"/>'
Add-Html "    <rect x=`"20`" y=`"10`" width=`"$fillW`" height=`"28`" rx=`"6`" fill=`"#10b981`" opacity=`"0.85`"/>"
Add-Html "    <text x=`"300`" y=`"30`" text-anchor=`"middle`" fill=`"#e6f1ff`" font-size=`"13`" font-weight=`"600`">$taggedPct% tagged ($taggedCount of $totalResources)</text>"
Add-Html '  </svg>'
Add-Html '</div>'

# --- Untagged by type table ---
$untaggedByType = $untagged | Group-Object -Property type | ForEach-Object {
    [PSCustomObject]@{
        Type  = $_.Name
        Count = ($_.Group | Measure-Object -Property count_ -Sum).Sum
    }
} | Sort-Object Count -Descending

Add-Html '<table>'
Add-Html '  <tr><th>Resource Type</th><th>Count</th></tr>'
foreach ($ut in $untaggedByType) {
    $utType = ConvertTo-SafeHtml $ut.Type
    Add-Html "  <tr><td>$utType</td><td>$([int]$ut.Count)</td></tr>"
}
Add-Html '</table>'

Add-Html '</section>'

Add-Html '<section id="inventory">'
Add-Html '  <h2>Inventory</h2>'
Add-Html '  <!-- Section: Inventory -->'
Add-Html '</section>'

Add-Html '<section id="activity">'
Add-Html '  <h2>Activity</h2>'
Add-Html '  <!-- Section: Activity -->'
Add-Html '</section>'

Add-Html '<section id="recommendations">'
Add-Html '  <h2>Recommendations</h2>'
Add-Html '  <!-- Section: Recommendations -->'
Add-Html '</section>'

# ── Footer ────────────────────────────────────────────────────────────────────

Add-Html '<div class="footer">'
Add-Html "  Generated on $($summary.RunDate) by Az-Dev-Cleanup &middot; Tenant Discovery Report"
Add-Html '</div>'

Add-Html '</div><!-- /.main -->'

# ── JavaScript ────────────────────────────────────────────────────────────────

$js = @'
<script>
(function() {
    // Scroll-spy: highlight nav link for visible section
    var navLinks = document.querySelectorAll('.nav a');
    var sections = document.querySelectorAll('section');

    var observer = new IntersectionObserver(function(entries) {
        entries.forEach(function(entry) {
            if (entry.isIntersecting) {
                var id = entry.target.getAttribute('id');
                navLinks.forEach(function(link) {
                    link.classList.remove('active');
                    if (link.getAttribute('href') === '#' + id) {
                        link.classList.add('active');
                    }
                });
            }
        });
    }, { rootMargin: '-20% 0px -60% 0px' });

    sections.forEach(function(section) {
        observer.observe(section);
    });

    // Hamburger toggle
    var hamburger = document.getElementById('hamburgerBtn');
    var nav = document.getElementById('sideNav');
    if (hamburger && nav) {
        hamburger.addEventListener('click', function() {
            nav.classList.toggle('open');
        });
        // Close nav when a link is clicked (mobile)
        navLinks.forEach(function(link) {
            link.addEventListener('click', function() {
                nav.classList.remove('open');
            });
        });
    }
})();
</script>
'@

Add-Html $js
Add-Html '</body>'
Add-Html '</html>'

# ── Write Output ──────────────────────────────────────────────────────────────

$html.ToString() | Set-Content -Path $OutputPath -Encoding UTF8 -Force
Write-Output "[INFO] HTML report written to: $OutputPath"
Write-Output "[INFO] File size: $([math]::Round((Get-Item $OutputPath).Length / 1KB, 1)) KB"

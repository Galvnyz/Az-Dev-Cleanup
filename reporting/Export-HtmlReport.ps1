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

# ── Placeholder Sections ─────────────────────────────────────────────────────

Add-Html '<section id="overview">'
Add-Html '  <h2>Overview</h2>'
Add-Html '  <!-- Section: Overview -->'
Add-Html '</section>'

Add-Html '<section id="cost-analysis">'
Add-Html '  <h2>Cost Analysis</h2>'
Add-Html '  <!-- Section: Cost Analysis -->'
Add-Html '</section>'

Add-Html '<section id="cleanup-candidates">'
Add-Html '  <h2>Cleanup Candidates</h2>'
Add-Html '  <!-- Section: Cleanup Candidates -->'
Add-Html '</section>'

Add-Html '<section id="governance">'
Add-Html '  <h2>Governance</h2>'
Add-Html '  <!-- Section: Governance -->'
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

# HTML Discovery Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `reporting/Export-HtmlReport.ps1` — a PowerShell script that generates a single self-contained HTML report from discovery output.

**Architecture:** The script reads `summary.json` and all CSVs from a discovery report directory, builds an HTML string section-by-section using a StringBuilder, and writes it to a single `.html` file. Charts are inline SVG. Interactive features (table sort/filter, sticky nav) use minimal inline JS. Zero external dependencies.

**Tech Stack:** PowerShell 7.x, HTML5, CSS3, inline SVG, vanilla JavaScript

**Spec:** `docs/superpowers/specs/2026-04-02-html-discovery-report-design.md`

---

## File Structure

| Action | Path | Responsibility |
|--------|------|---------------|
| Create | `reporting/Export-HtmlReport.ps1` | Main script — reads discovery dir, builds HTML, writes file |

This is a single-file deliverable. The HTML/CSS/JS are all embedded as heredoc strings inside the PowerShell script. No templates, no partials, no build step.

---

## Task 1: Script Skeleton with HTML Shell

**Files:**
- Create: `reporting/Export-HtmlReport.ps1`

- [ ] **Step 1: Create the script with CmdletBinding, parameters, and HTML shell**

Create `reporting/Export-HtmlReport.ps1` with the parameter block, summary.json loading, and the HTML document skeleton (head, CSS variables, body open/close). No sections yet — just a valid HTML page with the dark theme CSS and a title.

```powershell
<#
.SYNOPSIS
    Generates a self-contained HTML report from discovery output.

.DESCRIPTION
    Reads a discovery report directory (produced by Invoke-TenantDiscovery.ps1)
    and generates a single HTML file with an executive dashboard, charts,
    data tables, and recommendations. No external dependencies — works offline.

.PARAMETER ReportDir
    Path to the discovery report directory.

.PARAMETER OutputPath
    Path for the HTML file. Default: {ReportDir}/discovery-report.html

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
$ReportDir = (Resolve-Path $ReportDir).Path

if (-not $OutputPath) {
    $OutputPath = Join-Path $ReportDir "discovery-report.html"
}

# ── Load summary ─────────────────────────────────────────────────────────────

$summaryFile = Join-Path $ReportDir "summary.json"
if (-not (Test-Path $summaryFile)) {
    Write-Error "summary.json not found in $ReportDir. Run Invoke-TenantDiscovery.ps1 first."
    return
}
$summary = Get-Content $summaryFile -Raw | ConvertFrom-Json
Write-Output "[INFO] Loaded summary: $($summary.RunDate)"

# ── Helper: Load CSV safely ──────────────────────────────────────────────────

function Import-OptionalCsv {
    param([string]$Path)
    if (Test-Path $Path) {
        $data = Import-Csv -Path $Path
        return $data
    }
    return @()
}

# ── Load all data ────────────────────────────────────────────────────────────

$inventory       = Import-OptionalCsv "$ReportDir/queries/01-full-resource-inventory.csv"
$untagged        = Import-OptionalCsv "$ReportDir/queries/02-untagged-resources.csv"
$emptyRGs        = Import-OptionalCsv "$ReportDir/queries/03-empty-resource-groups.csv"
$stoppedVMs      = Import-OptionalCsv "$ReportDir/queries/04-stopped-deallocated-vms.csv"
$unusedNSGs      = Import-OptionalCsv "$ReportDir/queries/07-unused-nsgs.csv"
$ageSummary      = Import-OptionalCsv "$ReportDir/queries/09-resource-age-summary.csv"
$subOverview     = Import-OptionalCsv "$ReportDir/queries/10-subscription-overview.csv"
$emptyAppPlans   = Import-OptionalCsv "$ReportDir/queries/12-empty-app-service-plans.csv"
$orphanedNICs    = Import-OptionalCsv "$ReportDir/queries/13-orphaned-nics.csv"
$emptyLBs        = Import-OptionalCsv "$ReportDir/queries/18-empty-load-balancers.csv"
$costByRG        = Import-OptionalCsv "$ReportDir/cost-by-resource-group.csv"
$topCostRGs      = Import-OptionalCsv "$ReportDir/top-20-cost-resource-groups.csv"
$rgActivity      = Import-OptionalCsv "$ReportDir/resource-group-activity.csv"
$lastTouch       = Import-OptionalCsv "$ReportDir/resource-last-touch.csv"

Write-Output "[INFO] Loaded $($inventory.Count) resources, $($costByRG.Count) cost records"

# ── Compute derived metrics ──────────────────────────────────────────────────

$totalResources = $inventory.Count
$totalCost = if ($summary.TotalCost) { $summary.TotalCost } else { 0 }
$costDays = if ($summary.CostLookbackDays) { $summary.CostLookbackDays } else { 30 }
$cleanupCandidates = $stoppedVMs.Count + $emptyRGs.Count + $emptyAppPlans.Count +
                     $unusedNSGs.Count + $orphanedNICs.Count + $emptyLBs.Count
$untaggedCount = $untagged.Count

# ── HTML Builder ─────────────────────────────────────────────────────────────

$html = [System.Text.StringBuilder]::new()

# Helper to append and keep code readable
function Add-Html {
    param([string]$Content)
    [void]$script:html.AppendLine($Content)
}

# ── Begin HTML Document ──────────────────────────────────────────────────────

# The full HTML document is built below, section by section.
# Each section is added via Add-Html calls.
# CSS, SVG charts, and JS are all inline.

Add-Html @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Azure Tenant Discovery Report</title>
<style>
/* ── CSS will be added in Task 2 ── */
</style>
</head>
<body>
<!-- Sections will be added in Tasks 3-9 -->
</body>
</html>
"@

# ── Write Output ─────────────────────────────────────────────────────────────

$html.ToString() | Set-Content -Path $OutputPath -Encoding UTF8
Write-Output "[INFO] HTML report: $OutputPath"
```

- [ ] **Step 2: Verify script parses and runs**

Run:
```bash
pwsh -NoProfile -Command "& './reporting/Export-HtmlReport.ps1' -ReportDir './reports/2026-04-02-153244'"
```
Expected: `[INFO] HTML report: ...discovery-report.html` — a valid (empty) HTML file.

- [ ] **Step 3: Commit**

```bash
git add reporting/Export-HtmlReport.ps1
git commit -m "feat(html-report): Add script skeleton with data loading"
```

---

## Task 2: Full CSS Theme

**Files:**
- Modify: `reporting/Export-HtmlReport.ps1`

- [ ] **Step 1: Replace the CSS placeholder with the full dark theme**

Replace the `/* ── CSS will be added in Task 2 ── */` comment with the complete CSS. The CSS must include:

- Dark theme variables and base styles (background `#0a0a1a`, text `#ccd6f6`, cards `#112240`)
- KPI card grid (4 columns, responsive to 2 on tablet, 1 on mobile)
- Sticky navigation sidebar (left side, 220px, collapses to top bar on mobile)
- Main content area with left margin for nav
- Section styles (padding, spacing, anchor offset for sticky nav)
- Table styles (striped rows, hover, sortable header indicators)
- SVG chart container styles
- Priority badges (HIGH = red, MEDIUM = amber, LOW = teal)
- Responsive breakpoints at 1024px and 768px
- Print styles (light background override)
- Scrollbar styling for dark theme
- Tag pills for resource tags display
- Search/filter input styling

The CSS is large (~200 lines) but entirely self-contained in the `<style>` block.

- [ ] **Step 2: Verify the styled page renders**

Run the script, open the HTML in a browser. Should show a dark page with the title. No content sections yet but the styling infrastructure is in place.

- [ ] **Step 3: Commit**

```bash
git add reporting/Export-HtmlReport.ps1
git commit -m "feat(html-report): Add full dark theme CSS"
```

---

## Task 3: Sticky Navigation + Header

**Files:**
- Modify: `reporting/Export-HtmlReport.ps1`

- [ ] **Step 1: Add the navigation sidebar and report header**

Replace `<!-- Sections will be added in Tasks 3-9 -->` with the navigation HTML and the report header. The nav lists all 8 sections with anchor links. The header shows the report title, generation date, subscriptions scanned, and scan duration.

Navigation section IDs: `overview`, `cost`, `candidates`, `governance`, `inventory`, `activity`, `recommendations`.

Use `$summary.RunDate`, `$summary.Subscriptions`, `$summary.ElapsedMinutes` for header values.

- [ ] **Step 2: Add the scroll-spy JavaScript**

Before `</body>`, add a `<script>` block with:
- Intersection Observer that highlights the current nav item on scroll
- Smooth scroll for nav link clicks
- Mobile hamburger toggle for nav

Keep the JS minimal — under 60 lines.

- [ ] **Step 3: Verify nav renders and scroll-spy works**

Open in browser. Nav should be on the left, section links should scroll smoothly, active section should highlight.

- [ ] **Step 4: Commit**

```bash
git add reporting/Export-HtmlReport.ps1
git commit -m "feat(html-report): Add sticky nav and report header"
```

---

## Task 4: KPI Cards Section

**Files:**
- Modify: `reporting/Export-HtmlReport.ps1`

- [ ] **Step 1: Add the KPI cards row after the header**

Four cards in a CSS grid:

| Card | Value | Subtitle | Accent |
|------|-------|----------|--------|
| Total Resources | `$totalResources` | `"$($subOverview.Count) subscriptions"` | `#64ffda` (teal) |
| Monthly Cost | `"$($totalCost.ToString('N2'))"` | `"${costDays}-day spend"` | `#f59e0b` (amber) |
| Cleanup Candidates | `$cleanupCandidates` | `"across 6 categories"` | `#ef4444` (red) |
| Untagged | `$untaggedCount` | `"missing governance"` | `#8b5cf6` (purple) |

Each card: accent left border, uppercase label, large number, subtitle.

- [ ] **Step 2: Verify cards render with real data**

Open in browser. Should see 4 cards in a row with the actual numbers from the discovery run.

- [ ] **Step 3: Commit**

```bash
git add reporting/Export-HtmlReport.ps1
git commit -m "feat(html-report): Add KPI cards section"
```

---

## Task 5: Tenant Overview Section (with SVG charts)

**Files:**
- Modify: `reporting/Export-HtmlReport.ps1`

- [ ] **Step 1: Add the Tenant Overview section**

Section contains:
1. **Subscription table** — from `$subOverview`. Columns: Subscription Name, Total Resources, Resource Types, Resource Groups, Locations.
2. **Resource type distribution** — horizontal bar chart (SVG). Group `$inventory` by `type`, take top 15 by count, render as horizontal bars. Each bar labeled with type name and count. Max bar width = 100% of chart width, others proportional.
3. **Resource age histogram** — vertical bar chart (SVG). Group `$ageSummary` by `age_bracket`, sum `count_` per bracket. Bars for each age bracket.

For the SVG charts, build them in PowerShell by calculating bar widths/heights from data and emitting SVG `<rect>` and `<text>` elements. Chart dimensions: 700px wide, 300px tall. Use the accent colors.

- [ ] **Step 2: Verify charts render with real data**

Open in browser. Should see subscription table, horizontal bar chart of resource types, and age histogram.

- [ ] **Step 3: Commit**

```bash
git add reporting/Export-HtmlReport.ps1
git commit -m "feat(html-report): Add tenant overview with SVG charts"
```

---

## Task 6: Cost Analysis Section

**Files:**
- Modify: `reporting/Export-HtmlReport.ps1`

- [ ] **Step 1: Add Cost Analysis section**

Section contains:
1. **Cost summary** — total spend, cost period, zero-cost RG count as stat cards.
2. **Top 20 RGs by cost** — horizontal bar chart (SVG) from `$topCostRGs`. Bar width proportional to `TotalCost`. Color gradient from amber to red for expensive RGs.
3. **Top 20 cost table** — table with columns: Resource Group, Subscription, Total Cost, Currency. Cost column right-aligned, formatted with dollar sign and 2 decimals.

- [ ] **Step 2: Verify cost section renders**

Open in browser. Should see cost chart and table with real dollar amounts.

- [ ] **Step 3: Commit**

```bash
git add reporting/Export-HtmlReport.ps1
git commit -m "feat(html-report): Add cost analysis section"
```

---

## Task 7: Cleanup Candidates Section

**Files:**
- Modify: `reporting/Export-HtmlReport.ps1`

- [ ] **Step 1: Add Cleanup Candidates section**

Section contains:
1. **Candidate breakdown donut chart** — SVG donut showing count per category. Categories: Stopped VMs, Empty RGs, Empty App Plans, Unused NSGs, Orphaned NICs, Empty LBs. Use distinct colors per category.
2. **Priority-sorted subsections** — one collapsible `<details>` block per category:
   - **Stopped VMs** (HIGH) — table: Name, RG, Location, VM Size, Age (days), Tags. From `$stoppedVMs` columns: `name`, `resourceGroup`, `location`, `vmSize`, `age_days`, `tags`.
   - **Empty App Service Plans** (HIGH/LOW based on `skuTier`) — table: Name, RG, SKU Tier, SKU Name, Sites. From `$emptyAppPlans`.
   - **Orphaned NICs** (LOW) — table: Name, RG, Private IP, Has Public IP, Managed By. From `$orphanedNICs`.
   - **Empty Resource Groups** (LOW) — table: Name, Subscription, Location. From `$emptyRGs`.
   - **Unused NSGs** (LOW) — table from `$unusedNSGs`.
   - **Empty Load Balancers** (MEDIUM) — table from `$emptyLBs`.

Each subsection header shows the count and priority badge.

- [ ] **Step 2: Verify candidate tables render**

Open in browser. Donut chart should show proportions. Each `<details>` should expand to show the data table.

- [ ] **Step 3: Commit**

```bash
git add reporting/Export-HtmlReport.ps1
git commit -m "feat(html-report): Add cleanup candidates section with donut chart"
```

---

## Task 8: Governance Gaps Section

**Files:**
- Modify: `reporting/Export-HtmlReport.ps1`

- [ ] **Step 1: Add Governance Gaps section**

Section contains:
1. **Tag coverage bar** — SVG progress bar. Percentage = `($totalResources - $untaggedCount) / $totalResources * 100`. Green fill for tagged portion, red for untagged.
2. **Untagged resources by type** — group `$untagged` by `type`, show counts. Horizontal bar chart or simple table.
3. **Untagged resources table** — sortable table. Columns: Type, Subscription, Count. From `$untagged` grouped by `type` and `subscriptionId`.

- [ ] **Step 2: Verify governance section renders**

Open in browser. Tag coverage bar should show percentage. Untagged breakdown visible.

- [ ] **Step 3: Commit**

```bash
git add reporting/Export-HtmlReport.ps1
git commit -m "feat(html-report): Add governance gaps section"
```

---

## Task 9: Resource Inventory Section (searchable table)

**Files:**
- Modify: `reporting/Export-HtmlReport.ps1`

- [ ] **Step 1: Add Resource Inventory section**

Full table of all `$inventory` resources. Columns: Name, Type, Resource Group, Location, Age (days), Tags.

Add a text input above the table for client-side filtering. The JS (added in Task 3) needs a filter function that hides rows not matching the search text.

For performance with 1,294 rows: render all rows but use `display:none` toggling for filtering rather than DOM manipulation. Add the filter JS function to the existing `<script>` block.

Table headers should be clickable for sorting. Add `data-sort` attribute to `<th>` elements. Sort JS toggles ascending/descending on click.

Limit the inventory table to the first 500 rows with a "Show all" button to prevent the HTML from being excessively large if inventories grow beyond 2000+ rows.

- [ ] **Step 2: Verify inventory table renders and search works**

Open in browser. Should see all resources in a table. Typing in the search box should filter rows. Clicking column headers should sort.

- [ ] **Step 3: Commit**

```bash
git add reporting/Export-HtmlReport.ps1
git commit -m "feat(html-report): Add searchable resource inventory table"
```

---

## Task 10: Activity Analysis Section

**Files:**
- Modify: `reporting/Export-HtmlReport.ps1`

- [ ] **Step 1: Add Activity Analysis section**

Section contains:
1. **RG activity table** — from `$rgActivity`. Columns: Resource Group, Subscription, Last Activity, Last Caller, Days Since Active. Sorted by `DaysSinceActive` descending. Rows with 60+ days get a warning highlight.
2. **Dormant count** — stat showing how many RGs have 60+ days inactivity.
3. **Last-touch summary** — if `$lastTouch` has data, show count of resources with last touch data and the dormant count.

Skip this section entirely if both `$rgActivity` and `$lastTouch` are empty (Activity Log was skipped).

- [ ] **Step 2: Verify activity section renders or skips gracefully**

Test with the current report (which has activity data). Should show the table with highlighted dormant rows.

- [ ] **Step 3: Commit**

```bash
git add reporting/Export-HtmlReport.ps1
git commit -m "feat(html-report): Add activity analysis section"
```

---

## Task 11: Recommendations Section + Final Polish

**Files:**
- Modify: `reporting/Export-HtmlReport.ps1`

- [ ] **Step 1: Add auto-generated Recommendations section**

Build recommendations dynamically from the data:

```powershell
$recommendations = @()

if ($emptyRGs.Count -gt 0) {
    $recommendations += @{
        Priority = "Quick Win"
        Icon     = "🗑"  # only in HTML, not in PS source
        Title    = "Delete $($emptyRGs.Count) empty resource groups"
        Detail   = "Zero resources, zero cost. Run: Remove-EmptyResourceGroups.ps1 -WhatIf"
    }
}
if ($stoppedVMs.Count -gt 0) {
    $recommendations += @{
        Priority = "Cost Savings"
        Icon     = "💰"
        Title    = "Review $($stoppedVMs.Count) stopped VMs — disks still billing"
        Detail   = "Deallocated VMs incur disk charges. Run: Remove-StoppedVMs.ps1 -WhatIf"
    }
}
if ($untaggedCount -gt 0) {
    $recommendations += @{
        Priority = "Governance"
        Icon     = "🏷"
        Title    = "$untaggedCount resources lack mandatory tags"
        Detail   = "Deploy require-tags.json policy in Audit mode. Run: Tag-CleanupCandidates.ps1"
    }
}
# ... additional recommendations for orphaned NICs, empty app plans, etc.
```

Render each recommendation as a card with priority badge, title, and detail text.

Add a final "Next Steps" block: "Run the full cleanup dry-run: `Invoke-CleanupDryRun.ps1`"

- [ ] **Step 2: Add the report footer**

Footer with: generation timestamp, script version, link to project repo.

- [ ] **Step 3: End-to-end test**

Run the full script against the fresh discovery data:
```bash
pwsh -NoProfile -Command "& './reporting/Export-HtmlReport.ps1' -ReportDir './reports/2026-04-02-153244'"
```

Open the HTML file in a browser. Verify:
- All 8 sections render with real data
- KPI cards show correct numbers
- Charts are proportional and readable
- Tables are sortable and filterable
- Sticky nav highlights on scroll
- File works offline (no external requests)
- Responsive at tablet width

- [ ] **Step 4: Commit**

```bash
git add reporting/Export-HtmlReport.ps1
git commit -m "feat(html-report): Add recommendations section and final polish"
```

---

## Task 12: Integration + Push

**Files:**
- Modify: `reporting/Export-HtmlReport.ps1` (if any fixes from testing)
- Modify: `.gitignore` (add `*.html` in reports output)

- [ ] **Step 1: Add generated HTML to gitignore**

Add to `.gitignore`:
```
# Generated HTML reports
discovery-report.html
```

- [ ] **Step 2: Update .gitignore and commit**

```bash
git add .gitignore
git commit -m "chore: Ignore generated HTML reports"
```

- [ ] **Step 3: Push all commits**

```bash
git push
```

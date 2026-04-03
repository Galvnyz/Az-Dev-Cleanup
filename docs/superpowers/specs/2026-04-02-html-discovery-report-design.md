# HTML Discovery Report — Design Spec

## Purpose

A single self-contained HTML file that presents Azure tenant discovery data as a dark-themed, multi-audience report. Executives see KPI cards and a summary at the top; team leads scroll into cleanup candidates and cost analysis; technical staff get full searchable inventory tables at the bottom.

## Audience

- **Management/stakeholders** — KPI cards, cost headline, cleanup candidate count
- **Technical team leads** — cleanup candidate tables, cost breakdown, governance gaps
- **Operational self-reference** — full inventory, activity analysis, recommendations

## Input

A discovery report directory produced by `Invoke-TenantDiscovery.ps1`, containing:
- `summary.json` — aggregate metrics
- `queries/*.csv` — individual KQL query results (16+ CSVs)
- `cost-by-resource-group.csv` — cost data per RG
- `top-20-cost-resource-groups.csv` — top spenders
- `resource-group-activity.csv` — last activity per RG
- `resource-last-touch.csv` — per-resource last touch

## Output

**New script:** `reporting/Export-HtmlReport.ps1`

Parameters:
- `-ReportDir` (mandatory) — path to discovery output directory
- `-OutputPath` (optional) — defaults to `{ReportDir}/discovery-report.html`

Generates a single `.html` file with:
- All CSS inline (no external stylesheets)
- All charts as inline SVG (no JavaScript charting libraries)
- Minimal JS only for: sticky nav highlighting, table sort/filter, collapsible sections
- No CDN links, no external dependencies — works offline, can be emailed as an attachment

## Visual Style

- **Dark professional** theme — dark navy background (`#0a0a1a`), light text (`#ccd6f6`), card backgrounds (`#112240`)
- Accent colors: teal (`#64ffda`) for primary, amber (`#f59e0b`) for cost, red (`#ef4444`) for cleanup, purple (`#8b5cf6`) for governance
- Clean typography: Segoe UI / system-ui font stack
- Responsive: readable on both desktop and tablet

## Report Structure

### Header
- Report title: "Azure Tenant Discovery Report"
- Generated timestamp, subscription names, scan duration

### Section 1: KPI Cards (top bar)
Four cards in a row:
| Card | Value Source | Accent Color |
|------|------------|--------------|
| Total Resources | `summary.json → QueryResultCounts["01-full-resource-inventory"]` | Teal |
| Monthly Cost | `summary.json → TotalCost` | Amber |
| Cleanup Candidates | Sum of: empty RGs + stopped VMs + empty app plans + unused NSGs + orphaned NICs + empty LBs | Red |
| Untagged Resources | `summary.json → QueryResultCounts["02-untagged-resources"]` | Purple |

### Section 2: Tenant Overview
- Subscription breakdown table (from `10-subscription-overview.csv`)
- Resource type distribution — horizontal bar chart (top 15 types from `01-full-resource-inventory.csv`, grouped by `type`)
- Resource age histogram — buckets: <30d, 30-90d, 90-180d, 180-365d, 1-2yr, 2yr+ (from `09-resource-age-summary.csv`)

### Section 3: Cost Analysis
- Top 20 resource groups by cost — horizontal bar chart + table (from `top-20-cost-resource-groups.csv`)
- Zero-cost resource groups count (from `summary.json → ZeroCostResourceGroups`)
- Cost distribution narrative

### Section 4: Cleanup Candidates
Priority-sorted tables for each category:
- Stopped/deallocated VMs (from `04-stopped-deallocated-vms.csv`) — HIGH priority
- Empty App Service Plans (from `12-empty-app-service-plans.csv`) — HIGH if paid tier
- Orphaned NICs (from `13-orphaned-nics.csv`) — LOW priority
- Empty Resource Groups (from `03-empty-resource-groups.csv`) — LOW priority
- Unused NSGs (from `07-unused-nsgs.csv`) — LOW priority
- Empty Load Balancers (from `18-empty-load-balancers.csv`) — MEDIUM if Standard SKU
- Candidate breakdown donut/ring chart by category

### Section 5: Governance Gaps
- Untagged resources table (from `02-untagged-resources.csv`)
- Tag coverage percentage bar (tagged vs total)
- Resources missing `owner`, `project`, `environment` tags

### Section 6: Resource Inventory
- Full searchable/sortable table of all resources (from `01-full-resource-inventory.csv`)
- Client-side text filter (JS) and column sort
- Columns: Name, Type, Resource Group, Subscription, Location, Age (days), Tags

### Section 7: Activity Analysis
- Resource group activity table sorted by days-since-active (from `resource-group-activity.csv`)
- Dormant resource groups highlighted (60+ days inactive)
- Per-resource last-touch data (from `resource-last-touch.csv`) if available

### Section 8: Recommendations
Auto-generated based on findings:
- Quick wins: "Delete N empty resource groups" (if count > 0)
- Cost: "Review N stopped VMs — disks still billing" (if stopped VMs > 0)
- Governance: "N resources lack mandatory tags" (if untagged > 0)
- Next steps: "Run cleanup dry-run", "Deploy tag policies in audit mode"

### Sticky Navigation
- Left sidebar (desktop) or top bar (mobile) with section anchors
- Highlights current section on scroll
- Collapses to hamburger on narrow viewports

## Charts (Inline SVG)

All charts rendered as inline SVG elements — no canvas, no charting libraries.

| Chart | Type | Data Source |
|-------|------|-------------|
| Resource type distribution | Horizontal bar | `01-full-resource-inventory.csv` grouped by type |
| Resource age histogram | Vertical bar | `09-resource-age-summary.csv` |
| Cost by RG (top 20) | Horizontal bar | `top-20-cost-resource-groups.csv` |
| Cleanup candidate breakdown | Donut/ring | Counts from candidate CSVs |
| Tag coverage | Progress bar | `02-untagged-resources.csv` count vs total |

## Implementation Pattern

Follow the same structure as `Export-DiscoveryReport.ps1`:
- `[CmdletBinding()]` with comment-based help
- Load CSVs conditionally (skip sections if CSV is missing)
- Build HTML as a `StringBuilder` or array of strings
- Write to file at the end
- `Write-Output` progress messages matching existing `[INFO]` format

## Existing Patterns to Reuse

- `reporting/Export-DiscoveryReport.ps1` — same input format, same CSV loading pattern, same worksheet map for friendly names
- `discovery/Invoke-TenantDiscovery.ps1` — summary JSON schema, query result naming convention

## Testing

- Run against `reports/2026-04-02-153244/` (fresh discovery data)
- Open generated HTML in browser — verify all sections render
- Verify file works when double-clicked (offline, no server needed)
- Verify tables are sortable and filterable
- Check responsive behavior at tablet width

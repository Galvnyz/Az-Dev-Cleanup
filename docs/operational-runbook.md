# Operational Runbook

Step-by-step guide for executing the full cleanup lifecycle: discovery, dry-run, stakeholder review, execution, and impact measurement.

## Prerequisites

- Azure PowerShell modules installed (see [prerequisites.md](prerequisites.md))
- Authenticated to Azure (`Connect-AzAccount`)
- Reader role for discovery, Contributor for cleanup
- Microsoft Graph permissions for orphan detection (`User.Read.All`)

## Workflow Overview

```
Discovery → Dry Run → Cost Projection → Stakeholder Review → Baseline → Execute → Compare
```

---

## Step 1: Run Discovery

Generate a full tenant inventory with cross-referenced data.

```powershell
# Full discovery across all subscriptions
./discovery/Invoke-TenantDiscovery.ps1

# Quick mode (KQL only, skip Activity Log and Cost)
./discovery/Invoke-TenantDiscovery.ps1 -SkipActivityLog -SkipCostData

# Scoped to one subscription
./discovery/Invoke-TenantDiscovery.ps1 -SubscriptionId "xxxx-xxxx"
```

**Output:** `./reports/{timestamp}/` with CSVs, REPORT.md, and summary.json.

### Optional: Generate Excel Workbook

```powershell
./reporting/Export-DiscoveryReport.ps1 -ReportDir ./reports/{latest-timestamp}

# Include external cost CSV from Azure portal
./reporting/Export-DiscoveryReport.ps1 -ReportDir ./reports/{latest-timestamp} -CostCsv ./reports/cost-analysis.csv
```

---

## Step 2: Run Dry Run

Execute all cleanup scripts in WhatIf mode to see what *would* be cleaned up.

```powershell
# Full dry run
./cleanup/Invoke-CleanupDryRun.ps1

# Exclude specific scripts
./cleanup/Invoke-CleanupDryRun.ps1 -ExcludeScripts 'Tag-CleanupCandidates','Get-OrphanedResources'

# Scoped to one subscription
./cleanup/Invoke-CleanupDryRun.ps1 -SubscriptionId "xxxx-xxxx"
```

**Output:** `./cleanup-dryrun-{timestamp}/` with:
- `cleanup-dryrun.csv` — consolidated candidate list
- `dryrun.log` — execution log
- `orphaned-resources.csv` — if orphan detection ran

---

## Step 3: Project Cost Savings

Estimate monthly savings from the cleanup candidates.

```powershell
# With cost data from Azure portal export
./reporting/Get-CostSavingsProjection.ps1 `
  -DryRunCsv ./cleanup-dryrun-{timestamp}/cleanup-dryrun.csv `
  -CostCsv ./reports/cost-analysis.csv

# Rate-card only (no cost CSV required)
./reporting/Get-CostSavingsProjection.ps1 `
  -DryRunCsv ./cleanup-dryrun-{timestamp}/cleanup-dryrun.csv
```

**Output:** Per-category savings summary table and CSV.

---

## Step 4: Stakeholder Review

Share the dry-run report and cost savings projection with team leads for approval.

**Key artifacts to share:**
- `cleanup-dryrun.csv` — the complete candidate list
- `cost-savings-summary.csv` — projected savings by category
- `orphaned-resources.csv` — resources with deleted/disabled creators

**Decision points:**
- Which scripts to include/exclude in the actual run?
- Any resources that should be tagged `keep` or `do-not-delete` before execution?
- Are the grace periods appropriate (default 30 days for tagging)?

---

## Step 5: Capture Baseline

Snapshot the tenant state before cleanup for before/after comparison.

```powershell
# Quick baseline (resource counts only)
./reporting/Save-TenantBaseline.ps1 -OutputPath ./baseline-before.json

# Full baseline with cost data
./reporting/Save-TenantBaseline.ps1 -OutputPath ./baseline-before.json -IncludeCost
```

**Output:** `baseline-before.json` with resource counts, RG counts, per-type breakdown.

---

## Step 6: Execute Cleanup

Run the actual cleanup with safety gates.

```powershell
# Interactive mode (prompts for confirmation)
./cleanup/Invoke-CleanupExecution.ps1

# Unattended mode (for CI/CD)
./cleanup/Invoke-CleanupExecution.ps1 -Force

# Exclude specific scripts
./cleanup/Invoke-CleanupExecution.ps1 -Force -ExcludeScripts 'Tag-CleanupCandidates'
```

**Safety features:**
- Runs a dry-run first and displays the plan
- Requires typing `YES` to confirm (or `-Force` for CI/CD)
- Captures before/after baselines automatically
- Per-script error isolation

**Output:** `./cleanup-execution-{timestamp}/` with:
- `cleanup-execution.csv` — per-resource action log
- `baseline-before.json` / `baseline-after.json`
- `comparison.csv` — before/after delta
- `execution.log` — full execution trace

---

## Step 7: Review Results

Compare before/after state and archive results.

```powershell
# If baselines were captured manually
./reporting/Compare-TenantState.ps1 -BeforePath ./baseline-before.json -AfterPath ./baseline-after.json

# Compare baseline against current live state
./reporting/Compare-TenantState.ps1 -BeforePath ./baseline-before.json -Current
```

---

## Automated Execution (GitHub Actions)

The `scheduled-cleanup.yml` workflow supports three modes via `workflow_dispatch`:

| Action | What it does |
|--------|-------------|
| `discovery-only` | Runs full discovery and uploads report artifacts |
| `cleanup-dry-run` | Runs all cleanup scripts in WhatIf mode + cost projection |
| `cleanup-execute` | Executes cleanup (requires `production` environment approval) |

### Webhook Notifications

Set the `NOTIFICATION_WEBHOOK_URL` secret to receive Slack/Teams notifications after each run. The webhook receives a JSON payload with run results and a link to the Actions run.

### Environment Protection

The `cleanup-execute` job uses the `production` environment, which supports:
- Required reviewers (1+ approvals before execution)
- Wait timers (delay before execution starts)
- Deployment branches (restrict to specific branches)

Configure these in **Settings → Environments → production**.

---

## Script Reference

| Script | Location | Purpose |
|--------|----------|---------|
| `Invoke-TenantDiscovery.ps1` | `discovery/` | Full tenant inventory with KQL, Activity Log, Cost, Entra ID |
| `Get-ResourceMetrics.ps1` | `discovery/` | Metric-based staleness detection via Azure Monitor |
| `Invoke-CleanupDryRun.ps1` | `cleanup/` | Orchestrate all cleanup scripts in WhatIf mode |
| `Invoke-CleanupExecution.ps1` | `cleanup/` | Orchestrate all cleanup scripts for real execution |
| `Remove-EmptyResourceGroups.ps1` | `cleanup/` | Delete empty resource groups |
| `Remove-UnattachedDisks.ps1` | `cleanup/` | Delete unattached managed disks |
| `Remove-UnusedPublicIPs.ps1` | `cleanup/` | Delete unassigned public IPs |
| `Remove-UnusedNSGs.ps1` | `cleanup/` | Delete NSGs with no associations |
| `Remove-StoppedVMs.ps1` | `cleanup/` | Delete deallocated VMs past retention |
| `Remove-OldSnapshots.ps1` | `cleanup/` | Delete snapshots past retention |
| `Get-OrphanedResources.ps1` | `cleanup/` | Identify resources with deleted/disabled creators |
| `Tag-CleanupCandidates.ps1` | `cleanup/` | Tag resources for cleanup with grace period |
| `Remove-ExpiredResources.ps1` | `automation/` | Auto-delete resources past expiry/cleanup date |
| `Export-DiscoveryReport.ps1` | `reporting/` | Generate Excel workbook from discovery results |
| `Get-CostSavingsProjection.ps1` | `reporting/` | Estimate savings from cleanup candidates |
| `Save-TenantBaseline.ps1` | `reporting/` | Capture tenant state snapshot |
| `Compare-TenantState.ps1` | `reporting/` | Diff two baselines for impact measurement |
| `Test-Prerequisites.ps1` | `automation/` | Validate required modules and permissions |

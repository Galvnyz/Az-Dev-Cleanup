# Azure Dev Tenant Cleanup

Tooling and strategy for safely cleaning up a long-lived Azure dev tenant with years of accumulated, unmanaged resources.

## Problem

- Tenant has been active for 10+ years
- Many resources are orphaned (creators no longer with the company)
- No consistent tagging or ownership metadata
- Some old resources are still actively used
- Manual review is impractical at scale

## Approach

### Phase 1: Discovery & Inventory
Automated queries to build a complete picture of what exists, who created it, when it was last touched, and what it costs.

**Tools:** Azure Resource Graph (KQL), Activity Logs, Cost Management

### Phase 2: Classification
Categorize every resource into actionable buckets: dead, dormant, orphaned, active-unmanaged, or active-managed.

**Tools:** PowerShell scripts cross-referencing Resource Graph, Entra ID, and Activity Logs

### Phase 3: Governance
Put guardrails in place so the problem doesn't recur. Enforce tagging, budgets, and expiry policies.

**Tools:** Azure Policy definitions, budget alerts

### Phase 4: Safe Cleanup
Staged deletion with grace periods, notifications, and export-before-delete safeguards.

**Tools:** PowerShell cleanup scripts, Azure Automation / Logic Apps

## Repository Structure

```
discovery/       # 20 KQL queries + orchestration scripts for tenant inventory
cleanup/         # 10 PowerShell scripts for safe resource cleanup + orchestration
reporting/       # Cost projection, baselines, Excel export, comparison tools
policies/        # Azure Policy definitions (JSON) for governance
automation/      # GitHub Actions workflows + pre-flight validation
tests/           # Pester test suites (8 test files, 27+ tests)
docs/            # Strategy, prerequisites, troubleshooting, operational runbook
```

## Quick Start

For the full step-by-step operational workflow, see the **[Operational Runbook](docs/operational-runbook.md)**.

### 1. Run Discovery

```powershell
./discovery/Invoke-TenantDiscovery.ps1
```

### 2. Dry Run (see what would be cleaned up)

```powershell
./cleanup/Invoke-CleanupDryRun.ps1
```

### 3. Project Cost Savings

```powershell
./reporting/Get-CostSavingsProjection.ps1 -DryRunCsv ./cleanup-dryrun-{timestamp}/cleanup-dryrun.csv
```

### 4. Execute Cleanup (with safety gates)

```powershell
./cleanup/Invoke-CleanupExecution.ps1
```

## Prerequisites

- PowerShell 7.x with Az modules (see [docs/prerequisites.md](docs/prerequisites.md))
- Permissions: Reader across all subscriptions for discovery, Contributor for cleanup
- Access to Entra ID (Azure AD) for owner cross-referencing

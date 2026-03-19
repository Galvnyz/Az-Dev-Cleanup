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
discovery/       # KQL queries for Resource Graph and Log Analytics
cleanup/         # PowerShell scripts for safe resource cleanup
policies/        # Azure Policy definitions (JSON) for governance
automation/      # Pipeline and runbook scaffolding
docs/            # Strategy documents and decision records
```

## Quick Start

### 1. Run Discovery Queries

Open the [Azure Resource Graph Explorer](https://portal.azure.com/#blade/HubsExtension/ArgQueryBlade) and run the queries in `discovery/`.

### 2. Review the Inventory

Export query results to CSV and review with stakeholders.

### 3. Apply Governance Policies

Deploy policies from `policies/` in **audit mode** first to understand impact before enforcing.

### 4. Run Cleanup Scripts

Use scripts in `cleanup/` to safely remove confirmed-dead resources. All scripts support `-WhatIf` for dry runs.

## Prerequisites

- Azure PowerShell module (`Az`) or Azure CLI
- Permissions: Reader across all subscriptions for discovery, Contributor for cleanup
- Access to Entra ID (Azure AD) for owner cross-referencing

# Azure Dev Tenant Cleanup Strategy

## Background

The Azure dev tenant has accumulated resources over 10+ years. Many resources are orphaned (creators have left), untagged, and potentially unused. Manual review is impractical.

## Guiding Principles

1. **Do no harm** — Never delete anything without a grace period and notification
2. **Automate first** — Minimize manual review hours
3. **Audit everything** — Log every action for accountability
4. **Prevent recurrence** — Governance before cleanup
5. **Start safe** — Begin with obviously-dead resources, escalate gradually

## Resource Classification

| Category | Definition | Criteria | Action |
|----------|-----------|----------|--------|
| Dead | No activity, no owner, no value | 12+ months idle, creator gone, no tags | Tag → Grace period → Delete |
| Dormant | Possibly unused but uncertain | 6-12 months idle, may have an owner | Notify owner → Review → Decide |
| Orphaned | Owner left the company | Creator disabled/deleted in Entra ID | Reassign or delete |
| Active Unmanaged | In use but not governed | Has activity but no tags/owner | Tag and bring under management |
| Active Managed | In use and properly governed | Tagged, owned, monitored | Leave alone |

## Phased Approach

### Phase 1: Discovery (Week 1-2)
- Run all KQL queries in `discovery/` to inventory the tenant
- Export results to CSV for stakeholder review
- Run `Get-OrphanedResources.ps1` to cross-reference with Entra ID
- Generate a summary report with counts by category

### Phase 2: Quick Wins (Week 2-3)
- Run consolidated dry-run: `Invoke-CleanupDryRun.ps1` (all 8 scripts in WhatIf)
- Review consolidated report and cost savings projection with stakeholders
- Capture baseline: `Save-TenantBaseline.ps1`
- Execute cleanup: `Invoke-CleanupExecution.ps1` (includes before/after comparison)
- Individual scripts also available for targeted cleanup:
  - `Remove-EmptyResourceGroups.ps1`, `Remove-UnattachedDisks.ps1`
  - `Remove-UnusedPublicIPs.ps1`, `Remove-OldSnapshots.ps1`
  - `Remove-StoppedVMs.ps1`, `Remove-UnusedNSGs.ps1`

### Phase 3: Governance (Week 3-4)
- Deploy tag policies in **Audit** mode (`policies/require-tags.json`)
- Deploy denied resource types policy (`policies/deny-unused-resource-types.json`)
- Set up budget alerts per subscription
- Communicate new tagging requirements to teams

### Phase 4: Orphan Cleanup (Month 2)
- Review orphaned resource report with stakeholders
- Tag orphaned resources as cleanup candidates (`Tag-CleanupCandidates.ps1`)
- Send notifications to subscription owners
- 30-day grace period

### Phase 5: Ongoing Automation (Month 2-3)
- Deploy scheduled cleanup workflow (`automation/scheduled-cleanup.yml`) with:
  - Consolidated dry-run and execution via orchestrators
  - Cost savings projection in workflow artifacts
  - GITHUB_STEP_SUMMARY reporting and webhook notifications
  - `production` environment approval gate for destructive operations
- Switch tag policies from Audit to Deny
- Set up automated expiry enforcement (`Remove-ExpiredResources.ps1`)
- Monthly discovery report generation with before/after tracking

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Deleting something still in use | Grace periods, `-WhatIf` dry runs, resource locks on critical resources |
| Angering teams by deleting their resources | Notification workflow, tagging before deletion, 30-60 day grace periods |
| Missing resources in discovery | Multiple discovery angles (Resource Graph, Activity Logs, Cost Management) |
| Breaking dependencies | Check for cross-resource dependencies before deletion (NICs, VNets, etc.) |
| Losing important data | Snapshot before delete option for disks, export storage accounts |

## Success Metrics

- % of resources with mandatory tags (owner, project, environment)
- Number of orphaned resources eliminated
- Monthly cost reduction from cleanup
- Number of empty resource groups removed
- Time to identify resource owner (should decrease)

## Escalation Path

1. Run discovery queries
2. Review results with team leads
3. Quick wins (safe deletions) — no approval needed
4. Orphaned resources — team lead approval
5. Active but unmanaged — individual owner notification
6. Anything unclear — escalate to management

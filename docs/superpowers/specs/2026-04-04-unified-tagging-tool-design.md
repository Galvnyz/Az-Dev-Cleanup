# Unified Tagging Tool — `Set-ResourceTags.ps1`

**Date:** 2026-04-04
**Status:** Proposed
**Location:** `cleanup/Set-ResourceTags.ps1`

## Context

The Az-Dev-Cleanup tenant has thousands of resources accumulated over 10+ years.
Discovery identifies untagged and orphaned resources, but the only tagging tool
(`Tag-CleanupCandidates.ps1`) is narrowly scoped — it applies three cleanup-specific
tags to orphaned resources from a CSV. There is no general-purpose tool to assign
governance tags (`owner`, `project`, `environment`) or arbitrary tags at scale using
filters and conditional rules.

**Goal:** A single PowerShell script that can apply any combination of tags to any
set of Azure resources, selected via CSV input, pipeline, or live query filters,
with optional rule-based conditional tag mapping.

## Script Interface

### Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-Tags` | `hashtable` | No* | — | Explicit tag key-value pairs to apply |
| `-InputCsv` | `string` | No* | — | Path to CSV with `ResourceId` column |
| `-ResourceId` | `string[]` | No* | — | Pipeline input — individual resource IDs |
| `-ResourceType` | `string` | No | — | Filter: Azure resource type (supports wildcards) |
| `-ResourceGroup` | `string` | No | — | Filter: resource group name (supports wildcards) |
| `-Subscription` | `string` | No | — | Filter: subscription name or ID |
| `-Location` | `string` | No | — | Filter: Azure region (supports wildcards) |
| `-TagFilter` | `hashtable` | No | — | Filter: match resources by existing tag values |
| `-Untagged` | `switch` | No | — | Filter: select only resources with zero tags |
| `-MissingTags` | `string[]` | No | — | Filter: resources missing specific tag keys |
| `-MinAgeDays` | `int` | No | — | Filter: resources older than N days |
| `-RulesFile` | `string` | No | — | Path to JSON rules file for conditional mapping |
| `-BatchSize` | `int` | No | 50 | Process N resources per batch; pause between batches |
| `-SummaryOnly` | `switch` | No | — | Count matches grouped by type/sub/tag gap; no tagging |
| `-Force` | `switch` | No | — | Skip batch pause confirmations |
| `-WhatIf` | built-in | No | — | Preview mode — show diff, export CSV, apply nothing |
| `-Confirm` | built-in | No | — | Prompt before each tag operation |

*At least one **input source** required: `-InputCsv`, `-ResourceId`, or a live filter.
*At least one **tag source** required: `-Tags` and/or `-RulesFile` (unless `-SummaryOnly`).

### Parameter Sets

- **CsvInput:** `-InputCsv` + optional filters + tag source
- **PipelineInput:** `-ResourceId` (pipeline) + tag source
- **LiveQuery:** One or more filters (`-ResourceType`, `-ResourceGroup`, `-Subscription`,
  `-Location`, `-TagFilter`, `-Untagged`, `-MissingTags`, `-MinAgeDays`) + tag source

All sets support `-RulesFile`, `-Tags`, `-BatchSize`, `-SummaryOnly`, `-Force`, `-WhatIf`.

## Rules File Format

Optional JSON file for conditional tag mapping. Rules are evaluated in order;
first match per tag key wins.

### Structure

```json
{
  "rules": [
    {
      "name": "Production resources by RG pattern",
      "matchMode": "all",
      "match": {
        "resourceGroup": "*-prod-*",
        "location": "eastus"
      },
      "tags": {
        "environment": "production",
        "owner": "platform-team@contoso.com"
      }
    },
    {
      "name": "Multi-team dev resources",
      "matchMode": "any",
      "match": {
        "resourceGroup": "regex:^(alpha|beta)-dev-",
        "tagEquals": { "environment": "dev" }
      },
      "tags": {
        "owner": "dev-leads@contoso.com",
        "expiry-date": "+90d"
      }
    },
    {
      "name": "Unowned fallback",
      "match": {
        "missingTags": ["owner"]
      },
      "tags": {
        "owner": "unassigned"
      }
    }
  ],
  "defaults": {
    "project": "unknown",
    "environment": "dev"
  }
}
```

### Match Conditions

All conditions within a rule use AND logic by default (`"matchMode": "all"`).
Set `"matchMode": "any"` for OR logic.

| Condition | Type | Description |
|-----------|------|-------------|
| `resourceGroup` | string | Wildcard or `regex:` prefixed pattern |
| `resourceType` | string | Wildcard or `regex:` prefixed pattern |
| `subscription` | string | Name or ID, wildcard supported |
| `location` | string | Azure region, wildcard supported |
| `hasTag` | string | Resource has this tag key (any value) |
| `missingTags` | string[] | Resource is missing one or more of these tag keys |
| `tagEquals` | hashtable | Existing tag key matches exact value |
| `createdBy` | string | Wildcard or regex on creator UPN (Activity Log) |

### Special Tag Values

| Syntax | Resolves To |
|--------|-------------|
| `+30d` | Today + 30 days, formatted `yyyy-MM-dd` |
| `{createdBy}` | Resource creator's UPN (from Activity Log) |
| `{resourceGroup}` | Resource group name |
| `{subscription}` | Subscription name |
| `{today}` | Today's date, formatted `yyyy-MM-dd` |

### Evaluation Priority (highest to lowest)

1. **Explicit `-Tags` parameter** — always wins
2. **Rules** — first matching rule per tag key
3. **Defaults** — fills in any remaining unset tag keys

## Execution Flow

```
1. COLLECT TARGETS
   ├── CSV input → parse ResourceId column
   ├── Pipeline → collect ResourceId values
   └── Live filters → Search-AzGraph KQL query
   Combine all sources, deduplicate by ResourceId

2. SUMMARY-ONLY CHECK
   If -SummaryOnly: count by type/subscription/tag gap → display → exit

3. LOAD RULES (if -RulesFile)
   Parse JSON, validate schema, report rule count

4. RESOLVE TAGS PER RESOURCE (in batches of -BatchSize)
   For each resource:
     a. Read existing tags (Get-AzResource)
     b. Evaluate rules top-to-bottom (first match per key)
     c. Apply defaults (fill gaps)
     d. Apply explicit -Tags (override)
     e. Merge with existing tags
     f. Compute diff (new keys only — merge never overwrites)

5. PREVIEW / APPLY
   -WhatIf → color-coded diff table + export tagging-preview CSV
   Live → Set-AzResource -Tag per resource, log results
   Between batches: pause for confirmation (unless -Force)

6. SUMMARY
   Tagged: X | Skipped (no changes): Y | Failed: Z
```

## Tag Merge Behavior

**Merge-only — never overwrites or removes existing tag values.**

- If a resource already has `owner=TeamAlpha` and the tool resolves `owner=TeamBeta`,
  the existing value is preserved and the tag is skipped (logged as "skipped — existing value").
- New tag keys are always added.
- To change an existing tag value, the user must first remove it manually (or via
  `Update-AzTag -Operation Delete`) and then re-run the tool.

## Output

### Console

- Progress bar with resource count and batch indicator
- Per-resource line: `[Tagged] /subscriptions/.../myVM — +3 tags (owner, project, environment)`
- Skipped resources: `[Skip] /subscriptions/.../myDB — no new tags to apply`
- Final summary: `Tagged: 142 | Skipped: 38 | Failed: 2`

### File Output

| Mode | File | Columns |
|------|------|---------|
| `-WhatIf` | `tagging-preview-{timestamp}.csv` | ResourceId, TagKey, CurrentValue, NewValue, Source |
| Live | `tagging-results-{timestamp}.csv` | ResourceId, TagKey, Value, Source, Status, Error |

`Source` column values: rule name, `explicit`, or `default`.

### SummaryOnly Output

Table showing: ResourceType, Subscription, Count, MissingTags (comma-separated keys).

## Live Query Implementation

When using filter parameters without CSV/pipeline input, resources are queried
via `Search-AzGraph` (Azure Resource Graph). The script builds a KQL query from
the filter parameters:

```kql
resources
| where type =~ "Microsoft.Compute/virtualMachines"   // -ResourceType
| where resourceGroup matches regex ".*-prod-.*"       // -ResourceGroup
| where location == "eastus"                           // -Location
| where isnull(tags) or tags == "{}"                   // -Untagged
| project id, name, type, resourceGroup, subscriptionId, location, tags
```

`-MinAgeDays` uses Activity Log (`Get-AzActivityLog`) to filter by creation date
when Resource Graph `createdTime` is unavailable.

## Integration with Existing Pipeline

- **Replaces `Tag-CleanupCandidates.ps1` for complex tagging** — the existing script
  remains for simple orphan-only tagging, but `Set-ResourceTags.ps1` can do the same
  job with `-InputCsv orphaned-resources.csv -Tags @{cleanup-status='candidate'; cleanup-date='+30d'; cleanup-tagged-on='{today}'}`
- **Consumes discovery output** — any CSV with a `ResourceId` column works
- **Fits in `Invoke-CleanupDryRun.ps1`** — can be called with `-WhatIf` from orchestrator
- **Rules files live in `policies/`** — alongside existing policy definitions, version-controlled

## File Locations

| File | Path |
|------|------|
| Script | `cleanup/Set-ResourceTags.ps1` |
| Tests | `tests/Set-ResourceTags.Tests.ps1` |
| Example rules | `policies/tagging-rules-example.json` |

## Verification Plan

1. **Unit tests** (Pester) — parameter validation, rule evaluation, tag merge logic, special value interpolation
2. **WhatIf dry run** — run against real tenant with `-WhatIf`, verify preview CSV accuracy
3. **Small batch test** — tag 5 resources in a test RG, verify merge behavior
4. **Rules file test** — create rules matching known RG patterns, verify correct tag assignment
5. **Integration test** — feed discovery CSV into the tool, verify end-to-end flow

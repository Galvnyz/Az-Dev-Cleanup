# Prerequisites

## Runtime Requirements

| Requirement | Minimum Version | Check Command |
|-------------|----------------|---------------|
| PowerShell | 7.x (Core) | `$PSVersionTable.PSVersion` |
| Az.Accounts | 2.x | `Get-Module Az.Accounts -ListAvailable` |
| Az.Monitor | 4.x | `Get-Module Az.Monitor -ListAvailable` |
| Az.ResourceGraph | 0.13+ | `Get-Module Az.ResourceGraph -ListAvailable` |
| ImportExcel | 7.x (optional) | `Get-Module ImportExcel -ListAvailable` |
| Pester | 5.x (optional, for tests) | `Get-Module Pester -ListAvailable` |

### Install Modules

```powershell
Install-Module Az -Scope CurrentUser -Force
Install-Module ImportExcel -Scope CurrentUser  # For XLSX reports
Install-Module Pester -Scope CurrentUser       # For running tests
```

## Required Permissions

### Per-Script Permission Matrix

| Script | Azure RBAC Role | Scope | Notes |
|--------|----------------|-------|-------|
| **Discovery** | | | |
| `Invoke-TenantDiscovery.ps1` | Reader | Subscription | Activity Log access included |
| `Get-OrphanedResources.ps1` | Reader | Subscription | Also needs Graph permissions (below) |
| **Cleanup** | | | |
| `Remove-EmptyResourceGroups.ps1` | Contributor | Subscription | Deletes empty RGs |
| `Remove-UnattachedDisks.ps1` | Contributor | Subscription | Snapshot Contributor if using `-SnapshotBeforeDelete` |
| `Remove-UnusedPublicIPs.ps1` | Contributor | Subscription | Deletes public IPs |
| `Remove-ExpiredResources.ps1` | Contributor | Subscription | Deletes any tagged resource |
| `Tag-CleanupCandidates.ps1` | Tag Contributor | Subscription | Only modifies tags |
| **Cost** | | | |
| Phase 3 (Cost Management API) | Cost Management Reader | Subscription | Or Billing Reader |
| **Reporting** | | | |
| `Export-DiscoveryReport.ps1` | None | Local | Reads CSV files only |

### Entra ID / Microsoft Graph Permissions

Required for Phase 4 (orphan detection) and `Get-OrphanedResources.ps1`:

| Permission | Type | Why |
|-----------|------|-----|
| `User.Read.All` | Application or Delegated | Read `AccountEnabled` property for orphan detection |
| `Directory.Read.All` | Application or Delegated | Enumerate all users in the tenant |

**Without these permissions**, Phase 4 skips automatically with a warning. All other phases work normally.

### Connecting with Required Scopes

```powershell
# Interactive login — basic discovery + cleanup
Connect-AzAccount -Tenant yourtenant.com

# With Graph scope — enables Entra ID orphan detection
Connect-AzAccount -Tenant yourtenant.com -AuthScope 'https://graph.microsoft.com/.default'
```

### Service Principal for CI/CD

```powershell
# Create SP with Contributor role
$sp = New-AzADServicePrincipal -DisplayName "Az-Dev-Cleanup-CI" -Role "Contributor" -Scope "/subscriptions/<sub-id>"

# Add Cost Management Reader
New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName "Cost Management Reader" -Scope "/subscriptions/<sub-id>"
```

Store in GitHub Actions secrets:
- `AZURE_CLIENT_ID` — Application (client) ID
- `AZURE_TENANT_ID` — Directory (tenant) ID
- `AZURE_SUBSCRIPTION_ID` — Default subscription
- `AZURE_CLIENT_SECRET` — Client secret (or use OIDC federated credentials)

## Pre-flight Validation

Run `automation/Test-Prerequisites.ps1` to verify all prerequisites:

```powershell
.\automation\Test-Prerequisites.ps1
```

Output:
```
[PASS] Az.Accounts module installed v2.19.0
[PASS] Az.Monitor module installed v5.2.1
[PASS] Azure context authenticated as user@tenant.com
[PASS] Subscriptions accessible 2 enabled subscription(s)
[PASS] Az.ResourceGraph module installed v0.13.0
[PASS] ImportExcel module (optional) v7.8.10
[PASS] Pester module (optional) v5.7.1

[RESULT] All pre-flight checks passed
```

## GitHub Actions Setup

1. Create a service principal (see above)
2. Configure OIDC federated credentials (recommended over client secrets)
3. Add secrets to the repository
4. The `preflight` job in both workflows validates connectivity before running

# Troubleshooting Guide

## Common Issues

### Authentication

**"Your Azure credentials have not been set up or have expired"**
```powershell
Connect-AzAccount -Tenant yourtenant.com
```

**"Authentication failed against tenant"** (MFA required)
```powershell
Connect-AzAccount -Tenant yourtenant.com -UseDeviceAuthentication
```

**Phase 4 shows "0 active" users**
Your token lacks Graph permissions. The script skips orphan detection automatically.
```powershell
Connect-AzAccount -AuthScope 'https://graph.microsoft.com/.default'
```

### Cost Data

**"Operation returned an invalid status code 'BadRequest'"**
The Consumption API doesn't support your subscription type. The toolkit uses the Cost Management Query API instead, which works on most types. If it still fails, export cost data from the Azure Portal and use `-CostCsv`:
```powershell
.\reporting\Export-DiscoveryReport.ps1 -ReportDir .\reports\latest -CostCsv .\cost-export.csv
```

**"Unauthorized" on cost queries**
Assign yourself **Cost Management Reader** role on the subscription.

### Activity Log

**Phase 2 returns 0 records or very few**
The Activity Log API is inconsistent. The toolkit degrades gracefully — cost data and KQL queries provide the primary staleness signals. Use `-SkipActivityLog` to skip Phase 2 entirely:
```powershell
.\Invoke-TenantDiscovery.ps1 -SkipActivityLog
```

**Phase 2 takes 60+ seconds**
Normal for active subscriptions. Use `-SkipActivityLog` for faster scans when activity data isn't needed.

### Resource Graph Queries

**"Query is invalid" errors**
Usually a KQL syntax issue. Check that the query file hasn't been corrupted. Re-download from the repository if needed.

**Query returns 0 results unexpectedly**
Verify you have **Reader** role on the target subscriptions. Some resource types require specific permissions to enumerate.

### XLSX Report

**"Excel found a problem with formula references"**
Regenerate the report — this was caused by an older version with inline charts. Update to the latest `Export-DiscoveryReport.ps1`.

**Report file locked**
Close the XLSX in Excel before regenerating. Or use `-OutputPath` to write to a different filename.

### Cleanup Scripts

**"The process cannot access the file"**
Another process has a lock on the output CSV. Close Excel or other applications that may have the file open.

**Resource deletion fails with 409 Conflict**
The resource has a lock. The script should skip it automatically with a "locked" message. If not, check for locks:
```powershell
Get-AzResourceLock -ResourceGroupName <rg-name>
```

**Partial deletion failure**
If a cleanup run fails mid-way, re-run the same script — it's idempotent. Already-deleted resources will be skipped. Check the audit log CSV for what was processed.

## Recovery Procedures

### Accidental Deletion
1. Check Azure Activity Log for what was deleted (Portal → Activity Log)
2. For resource groups: cannot be recovered — recreate manually
3. For resources with snapshots: restore from the cleanup snapshot
4. For Key Vaults with soft-delete: recover within the retention period
   ```powershell
   Undo-AzKeyVaultRemoval -VaultName <name> -ResourceGroupName <rg> -Location <location>
   ```

### Snapshot Cost Management
Safety snapshots created by `-SnapshotBeforeDelete` incur storage costs:
- Standard HDD: ~$0.05/GB/month
- A 128GB snapshot costs ~$6.40/month

**Recommendation**: Review and delete cleanup snapshots after 30 days:
```powershell
Get-AzSnapshot | Where-Object { $_.Name -like "cleanup-*" -and $_.TimeCreated -lt (Get-Date).AddDays(-30) }
```

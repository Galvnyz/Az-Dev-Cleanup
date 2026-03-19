<#
.SYNOPSIS
    Removes unattached managed disks across all subscriptions.

.DESCRIPTION
    Finds managed disks in "Unattached" state and removes them.
    Optionally creates snapshots before deletion as a safety net.

.PARAMETER SubscriptionId
    Optional. Limit to a specific subscription.

.PARAMETER SnapshotBeforeDelete
    Create a snapshot of each disk before deleting it.

.PARAMETER MinAgeDays
    Only target disks unattached for at least this many days. Default: 30.

.EXAMPLE
    # Dry run — see what would be deleted
    .\Remove-UnattachedDisks.ps1 -WhatIf

    # Delete with safety snapshots
    .\Remove-UnattachedDisks.ps1 -SnapshotBeforeDelete
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [switch]$SnapshotBeforeDelete,

    [Parameter()]
    [int]$MinAgeDays = 30
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$timestamp] [$Level] $Message"
}

# ── Main ─────────────────────────────────────────────────────────────────────

Write-Log "Starting unattached disk cleanup (min age: $MinAgeDays days)"

if ($SubscriptionId) {
    $subscriptions = @(Get-AzSubscription -SubscriptionId $SubscriptionId)
} else {
    $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
}

$cutoffDate = (Get-Date).AddDays(-$MinAgeDays)
$totalRemoved = 0
$results = @()

foreach ($sub in $subscriptions) {
    Write-Log "Scanning subscription: $($sub.Name)"
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    $disks = Get-AzDisk | Where-Object {
        $_.DiskState -eq "Unattached" -and
        $_.TimeCreated -lt $cutoffDate
    }

    Write-Log "Found $($disks.Count) unattached disk(s) older than $MinAgeDays days"

    foreach ($disk in $disks) {
        $ageDays = ((Get-Date) - $disk.TimeCreated).Days

        $result = [PSCustomObject]@{
            Subscription  = $sub.Name
            ResourceGroup = $disk.ResourceGroupName
            DiskName      = $disk.Name
            SizeGB        = $disk.DiskSizeGB
            AgeDays       = $ageDays
            Action        = "Pending"
        }

        if ($PSCmdlet.ShouldProcess("$($disk.Name) ($($disk.DiskSizeGB) GB, $ageDays days old)", "Remove unattached disk")) {

            # Optional: snapshot before delete
            if ($SnapshotBeforeDelete) {
                try {
                    $snapshotName = "cleanup-$($disk.Name)-$(Get-Date -Format 'yyyyMMdd')"
                    $snapshotConfig = New-AzSnapshotConfig -SourceUri $disk.Id -Location $disk.Location -CreateOption Copy
                    New-AzSnapshot -ResourceGroupName $disk.ResourceGroupName -SnapshotName $snapshotName -Snapshot $snapshotConfig | Out-Null
                    Write-Log "Created safety snapshot: $snapshotName" -Level "SNAPSHOT"
                } catch {
                    Write-Log "Failed to snapshot $($disk.Name), skipping deletion: $_" -Level "ERROR"
                    $result.Action = "Snapshot failed, skipped"
                    $results += $result
                    continue
                }
            }

            try {
                Remove-AzDisk -ResourceGroupName $disk.ResourceGroupName -DiskName $disk.Name -Force -ErrorAction Stop
                Write-Log "Removed: $($disk.Name)" -Level "DELETE"
                $result.Action = "Removed"
                $totalRemoved++
            } catch {
                Write-Log "Failed to remove $($disk.Name): $_" -Level "ERROR"
                $result.Action = "Failed"
            }
        } else {
            $result.Action = "WhatIf"
        }

        $results += $result
    }
}

Write-Log "Cleanup complete. Removed: $totalRemoved disks"

if ($results.Count -gt 0) {
    $results | Format-Table -AutoSize
}

return $results

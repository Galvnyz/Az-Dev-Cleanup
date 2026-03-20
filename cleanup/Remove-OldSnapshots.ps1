<#
.SYNOPSIS
    Removes disk snapshots older than a specified number of days.

.DESCRIPTION
    Finds disk snapshots past their retention period and removes them.
    Verifies source disk status before deletion — if the source disk
    was deleted, the snapshot may be the only remaining copy.

.PARAMETER SubscriptionId
    Optional. Limit to a specific subscription.

.PARAMETER MinAgeDays
    Only target snapshots older than this many days. Default: 90.

.PARAMETER SkipOrphaned
    Skip snapshots whose source disk no longer exists (safety measure).

.EXAMPLE
    .\Remove-OldSnapshots.ps1 -WhatIf
    .\Remove-OldSnapshots.ps1 -MinAgeDays 180
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$MinAgeDays = 90,

    [Parameter()]
    [switch]$SkipOrphaned
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$timestamp] [$Level] $Message"
}

function Test-ResourceLocked {
    param([string]$ResourceId)
    $locks = Get-AzResourceLock -ResourceId $ResourceId -ErrorAction SilentlyContinue
    return ($null -ne $locks -and $locks.Count -gt 0)
}

# ── Main ─────────────────────────────────────────────────────────────────────

Write-Log "Starting old snapshot cleanup (min age: $MinAgeDays days)"

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
    Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null

    $snapshots = Get-AzSnapshot | Where-Object { $_.TimeCreated -lt $cutoffDate }

    Write-Log "Found $($snapshots.Count) snapshot(s) older than $MinAgeDays days"

    foreach ($snap in $snapshots) {
        $ageDays = ((Get-Date) - $snap.TimeCreated).Days
        $sourceDiskExists = $false

        # Check if source disk still exists
        if ($snap.CreationData.SourceResourceId) {
            $sourceDisk = Get-AzResource -ResourceId $snap.CreationData.SourceResourceId -ErrorAction SilentlyContinue
            $sourceDiskExists = $null -ne $sourceDisk
        }

        $result = [PSCustomObject]@{
            Subscription     = $sub.Name
            ResourceGroup    = $snap.ResourceGroupName
            SnapshotName     = $snap.Name
            SizeGB           = $snap.DiskSizeGB
            AgeDays          = $ageDays
            SourceDiskExists = $sourceDiskExists
            Action           = "Pending"
        }

        # Safety: skip if source disk is deleted and SkipOrphaned is set
        if ($SkipOrphaned -and -not $sourceDiskExists) {
            Write-Log "Skipping orphaned snapshot (source disk deleted): $($snap.Name)" -Level "SKIP"
            $result.Action = "Skipped (orphaned, source disk deleted)"
            $results += $result
            continue
        }

        if (Test-ResourceLocked -ResourceId $snap.Id) {
            Write-Log "Skipping locked snapshot: $($snap.Name)" -Level "SKIP"
            $result.Action = "Skipped (locked)"
            $results += $result
            continue
        }

        if ($PSCmdlet.ShouldProcess("$($snap.Name) ($($snap.DiskSizeGB) GB, $ageDays days old)", "Remove old snapshot")) {
            try {
                Remove-AzSnapshot -ResourceGroupName $snap.ResourceGroupName -SnapshotName $snap.Name -Force -ErrorAction Stop
                Write-Log "Removed: $($snap.Name)" -Level "DELETE"
                $result.Action = "Removed"
                $totalRemoved++
            } catch {
                Write-Log "Failed to remove $($snap.Name): $_" -Level "ERROR"
                $result.Action = "Failed"
            }
        } else {
            $result.Action = "WhatIf"
        }

        $results += $result
    }
}

Write-Log "Cleanup complete. Removed: $totalRemoved snapshots"

if ($results.Count -gt 0) {
    $results | Format-Table -AutoSize
}

return $results

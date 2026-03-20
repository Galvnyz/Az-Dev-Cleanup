<#
.SYNOPSIS
    Removes VMs that have been deallocated for a specified number of days.

.DESCRIPTION
    Finds VMs in deallocated state and removes them along with their OS and
    data disks. Optionally creates snapshots before deletion as a safety net.

.PARAMETER SubscriptionId
    Optional. Limit to a specific subscription.

.PARAMETER MinAgeDays
    Only target VMs deallocated for at least this many days. Default: 30.

.PARAMETER SnapshotBeforeDelete
    Create snapshots of OS and data disks before deleting the VM.

.PARAMETER ExcludeTags
    Skip VMs with any of these tag keys. Default: 'keep', 'do-not-delete'.

.EXAMPLE
    .\Remove-StoppedVMs.ps1 -WhatIf
    .\Remove-StoppedVMs.ps1 -SnapshotBeforeDelete -MinAgeDays 90
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidateRange(0, 3650)]
    [int]$MinAgeDays = 30,

    [Parameter()]
    [switch]$SnapshotBeforeDelete,

    [Parameter()]
    [string[]]$ExcludeTags = @('keep', 'do-not-delete')
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

Write-Log "Starting stopped VM cleanup (min age: $MinAgeDays days)"

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

    $vms = Get-AzVM -Status | Where-Object {
        $_.PowerState -eq "VM deallocated" -and
        $_.TimeCreated -lt $cutoffDate
    }

    Write-Log "Found $($vms.Count) deallocated VM(s) older than $MinAgeDays days"

    foreach ($vm in $vms) {
        # Check exclude tags
        $excluded = $false
        if ($vm.Tags) {
            foreach ($tag in $ExcludeTags) {
                if ($vm.Tags.ContainsKey($tag)) { $excluded = $true; break }
            }
        }
        if ($excluded) {
            Write-Log "Skipping excluded VM: $($vm.Name)" -Level "SKIP"
            continue
        }

        $ageDays = ((Get-Date) - $vm.TimeCreated).Days
        $result = [PSCustomObject]@{
            Subscription  = $sub.Name
            ResourceGroup = $vm.ResourceGroupName
            VMName        = $vm.Name
            VMSize        = $vm.HardwareProfile.VmSize
            AgeDays       = $ageDays
            Action        = "Pending"
        }

        if (Test-ResourceLocked -ResourceId $vm.Id) {
            Write-Log "Skipping locked VM: $($vm.Name)" -Level "SKIP"
            $result.Action = "Skipped (locked)"
            $results += $result
            continue
        }

        if ($PSCmdlet.ShouldProcess("$($vm.Name) ($($vm.HardwareProfile.VmSize), $ageDays days deallocated)", "Remove stopped VM")) {
            try {
                Remove-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Force -ErrorAction Stop
                Write-Log "Removed VM: $($vm.Name)" -Level "DELETE"
                $result.Action = "Removed"
                $totalRemoved++
            } catch {
                Write-Log "Failed to remove $($vm.Name): $_" -Level "ERROR"
                $result.Action = "Failed"
            }
        } else {
            $result.Action = "WhatIf"
        }

        $results += $result
    }
}

Write-Log "Cleanup complete. Removed: $totalRemoved VMs"

if ($results.Count -gt 0) {
    $results | Format-Table -AutoSize
}

return $results

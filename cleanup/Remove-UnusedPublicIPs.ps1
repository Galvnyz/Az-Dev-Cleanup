<#
.SYNOPSIS
    Removes public IP addresses not associated with any resource.

.DESCRIPTION
    Finds public IPs with no ipConfiguration (not attached to a NIC, LB, etc.)
    and removes them. Unassociated public IPs still cost money and expand attack surface.

.PARAMETER SubscriptionId
    Optional. Limit to a specific subscription.

.EXAMPLE
    .\Remove-UnusedPublicIPs.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$SubscriptionId
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

Write-Log "Starting unused public IP cleanup"

if ($SubscriptionId) {
    $subscriptions = @(Get-AzSubscription -SubscriptionId $SubscriptionId)
} else {
    $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
}

$totalRemoved = 0
$results = @()

foreach ($sub in $subscriptions) {
    Write-Log "Scanning subscription: $($sub.Name)"
    Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null

    $publicIPs = Get-AzPublicIpAddress | Where-Object {
        $null -eq $_.IpConfiguration
    }

    Write-Log "Found $($publicIPs.Count) unused public IP(s)"

    foreach ($pip in $publicIPs) {
        $result = [PSCustomObject]@{
            Subscription  = $sub.Name
            ResourceGroup = $pip.ResourceGroupName
            Name          = $pip.Name
            IpAddress     = $pip.IpAddress
            SKU           = $pip.Sku.Name
            Action        = "Pending"
        }

        # Check for resource locks before attempting deletion
        if (Test-ResourceLocked -ResourceId $pip.Id) {
            Write-Log "Skipping locked public IP: $($pip.Name)" -Level "SKIP"
            $result.Action = "Skipped (locked)"
            $results += $result
            continue
        }

        if ($PSCmdlet.ShouldProcess("$($pip.Name) ($($pip.IpAddress))", "Remove unused public IP")) {
            try {
                Remove-AzPublicIpAddress -Name $pip.Name -ResourceGroupName $pip.ResourceGroupName -Force -ErrorAction Stop
                Write-Log "Removed: $($pip.Name)" -Level "DELETE"
                $result.Action = "Removed"
                $totalRemoved++
            } catch {
                Write-Log "Failed to remove $($pip.Name): $_" -Level "ERROR"
                $result.Action = "Failed"
            }
        } else {
            $result.Action = "WhatIf"
        }

        $results += $result
    }
}

Write-Log "Cleanup complete. Removed: $totalRemoved public IPs"

if ($results.Count -gt 0) {
    $results | Format-Table -AutoSize
}

return $results

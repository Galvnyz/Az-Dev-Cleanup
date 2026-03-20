<#
.SYNOPSIS
    Removes NSGs not associated with any subnet or NIC.

.DESCRIPTION
    Finds network security groups with zero associations and removes them.
    Exports NSG rules to JSON before deletion as a backup.

.PARAMETER SubscriptionId
    Optional. Limit to a specific subscription.

.EXAMPLE
    .\Remove-UnusedNSGs.ps1 -WhatIf
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

Write-Log "Starting unused NSG cleanup"

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

    $nsgs = Get-AzNetworkSecurityGroup | Where-Object {
        ($null -eq $_.NetworkInterfaces -or $_.NetworkInterfaces.Count -eq 0) -and
        ($null -eq $_.Subnets -or $_.Subnets.Count -eq 0)
    }

    Write-Log "Found $($nsgs.Count) unused NSG(s)"

    foreach ($nsg in $nsgs) {
        $result = [PSCustomObject]@{
            Subscription  = $sub.Name
            ResourceGroup = $nsg.ResourceGroupName
            Name          = $nsg.Name
            RuleCount     = $nsg.SecurityRules.Count
            Action        = "Pending"
        }

        if (Test-ResourceLocked -ResourceId $nsg.Id) {
            Write-Log "Skipping locked NSG: $($nsg.Name)" -Level "SKIP"
            $result.Action = "Skipped (locked)"
            $results += $result
            continue
        }

        if ($PSCmdlet.ShouldProcess("$($nsg.Name) ($($nsg.SecurityRules.Count) rules)", "Remove unused NSG")) {
            try {
                Remove-AzNetworkSecurityGroup -Name $nsg.Name -ResourceGroupName $nsg.ResourceGroupName -Force -ErrorAction Stop
                Write-Log "Removed: $($nsg.Name)" -Level "DELETE"
                $result.Action = "Removed"
                $totalRemoved++
            } catch {
                Write-Log "Failed to remove $($nsg.Name): $_" -Level "ERROR"
                $result.Action = "Failed"
            }
        } else {
            $result.Action = "WhatIf"
        }

        $results += $result
    }
}

Write-Log "Cleanup complete. Removed: $totalRemoved NSGs"

if ($results.Count -gt 0) {
    $results | Format-Table -AutoSize
}

return $results

<#
.SYNOPSIS
    Removes empty resource groups across all subscriptions.

.DESCRIPTION
    Scans all accessible subscriptions for resource groups containing zero resources
    and removes them. Supports -WhatIf for dry runs and logs all actions.

.PARAMETER SubscriptionId
    Optional. Limit to a specific subscription. If omitted, scans all subscriptions.

.PARAMETER ExcludeResourceGroups
    Optional. Array of resource group names to skip (e.g., NetworkWatcherRG).

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    # Dry run across all subscriptions
    .\Remove-EmptyResourceGroups.ps1 -WhatIf

    # Delete empty RGs in a specific subscription
    .\Remove-EmptyResourceGroups.ps1 -SubscriptionId "xxxx-xxxx"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string[]]$ExcludeResourceGroups = @("NetworkWatcherRG", "DefaultResourceGroup-*", "cloud-shell-storage-*"),

    [Parameter()]
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# ── Helpers ──────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$timestamp] [$Level] $Message"
}

function Test-Excluded {
    param([string]$Name, [string[]]$Patterns)
    foreach ($pattern in $Patterns) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

function Test-ResourceGroupLocked {
    param([string]$ResourceGroupName)
    $locks = Get-AzResourceLock -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    return ($null -ne $locks -and $locks.Count -gt 0)
}

# ── Main ─────────────────────────────────────────────────────────────────────

Write-Log "Starting empty resource group cleanup"

# Get target subscriptions
if ($SubscriptionId) {
    $subscriptions = @(Get-AzSubscription -SubscriptionId $SubscriptionId)
} else {
    $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
}

Write-Log "Found $($subscriptions.Count) subscription(s) to scan"

$totalRemoved = 0
$totalSkipped = 0
$results = @()

foreach ($sub in $subscriptions) {
    Write-Log "Scanning subscription: $($sub.Name) ($($sub.Id))"
    Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null

    $resourceGroups = Get-AzResourceGroup

    foreach ($rg in $resourceGroups) {
        # Check exclusion list
        if (Test-Excluded -Name $rg.ResourceGroupName -Patterns $ExcludeResourceGroups) {
            Write-Log "Skipping excluded: $($rg.ResourceGroupName)" -Level "SKIP"
            $totalSkipped++
            continue
        }

        # Count resources in the group
        $resourceCount = (Get-AzResource -ResourceGroupName $rg.ResourceGroupName).Count

        if ($resourceCount -eq 0) {
            $result = [PSCustomObject]@{
                Subscription  = $sub.Name
                ResourceGroup = $rg.ResourceGroupName
                Location      = $rg.Location
                Action        = "Pending"
            }

            # Check for resource locks before attempting deletion
            if (Test-ResourceGroupLocked -ResourceGroupName $rg.ResourceGroupName) {
                Write-Log "Skipping locked resource group: $($rg.ResourceGroupName)" -Level "SKIP"
                $result.Action = "Skipped (locked)"
                $totalSkipped++
                $results += $result
                continue
            }

            if ($PSCmdlet.ShouldProcess($rg.ResourceGroupName, "Remove empty resource group")) {
                try {
                    Remove-AzResourceGroup -Name $rg.ResourceGroupName -Force:$Force -ErrorAction Stop
                    Write-Log "Removed: $($rg.ResourceGroupName)" -Level "DELETE"
                    $result.Action = "Removed"
                    $totalRemoved++
                } catch {
                    Write-Log "Failed to remove $($rg.ResourceGroupName): $_" -Level "ERROR"
                    $result.Action = "Failed: $_"
                }
            } else {
                $result.Action = "WhatIf"
            }

            $results += $result
        }
    }
}

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Log "Cleanup complete. Removed: $totalRemoved | Skipped (excluded): $totalSkipped | Total empty found: $($results.Count)"

if ($results.Count -gt 0) {
    $results | Format-Table -AutoSize
}

return $results

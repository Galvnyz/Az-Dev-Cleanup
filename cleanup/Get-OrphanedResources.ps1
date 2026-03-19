<#
.SYNOPSIS
    Identifies resources whose creators are no longer in Entra ID (Azure AD).

.DESCRIPTION
    Cross-references Activity Log resource creation events with Entra ID user status
    to find resources created by users who have been deleted or disabled.
    These are "orphaned" resources with no active owner.

.PARAMETER SubscriptionId
    Optional. Limit to a specific subscription.

.PARAMETER LookbackDays
    How far back to search Activity Logs. Default: 365 (max for Activity Log).

.PARAMETER OutputPath
    Path to export CSV results. Default: ./orphaned-resources.csv

.EXAMPLE
    # Find orphaned resources and export to CSV
    .\Get-OrphanedResources.ps1 -OutputPath ./report.csv
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [int]$LookbackDays = 365,

    [Parameter()]
    [string]$OutputPath = "./orphaned-resources.csv"
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$timestamp] [$Level] $Message"
}

# ── Main ─────────────────────────────────────────────────────────────────────

Write-Log "Starting orphaned resource detection"

if ($SubscriptionId) {
    $subscriptions = @(Get-AzSubscription -SubscriptionId $SubscriptionId)
} else {
    $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
}

$startDate = (Get-Date).AddDays(-$LookbackDays)
$results = @()

# Build a cache of known Entra ID users
Write-Log "Loading Entra ID user directory..."
try {
    $allUsers = Get-AzADUser -First 10000
    $activeUPNs = $allUsers | Where-Object { $_.AccountEnabled -eq $true } | ForEach-Object { $_.UserPrincipalName }
    $disabledUPNs = $allUsers | Where-Object { $_.AccountEnabled -eq $false } | ForEach-Object { $_.UserPrincipalName }
    Write-Log "Loaded $($allUsers.Count) users ($($activeUPNs.Count) active, $($disabledUPNs.Count) disabled)"
} catch {
    Write-Log "Could not load Entra ID users. Ensure you have Directory.Read.All permissions: $_" -Level "ERROR"
    return
}

foreach ($sub in $subscriptions) {
    Write-Log "Scanning subscription: $($sub.Name)"
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    # Get resource creation events from Activity Log
    $logs = Get-AzActivityLog -StartTime $startDate -EndTime (Get-Date) `
        -Status "Succeeded" -MaxRecord 10000 |
        Where-Object { $_.OperationName.Value -match "/write$" -and $_.Caller -match "@" }

    # Group by resource to find the creator
    $resourceCreators = @{}
    foreach ($log in $logs) {
        $resourceId = $log.ResourceId
        if (-not $resourceCreators.ContainsKey($resourceId)) {
            $resourceCreators[$resourceId] = $log.Caller
        }
    }

    Write-Log "Found $($resourceCreators.Count) resources with identified creators"

    foreach ($resourceId in $resourceCreators.Keys) {
        $creator = $resourceCreators[$resourceId]
        $status = "Unknown"

        if ($activeUPNs -contains $creator) {
            $status = "Active"
        } elseif ($disabledUPNs -contains $creator) {
            $status = "Disabled"
        } else {
            $status = "Deleted"
        }

        if ($status -ne "Active") {
            # Verify the resource still exists
            $resource = Get-AzResource -ResourceId $resourceId -ErrorAction SilentlyContinue
            if ($resource) {
                $results += [PSCustomObject]@{
                    Subscription  = $sub.Name
                    ResourceGroup = $resource.ResourceGroupName
                    ResourceName  = $resource.Name
                    ResourceType  = $resource.ResourceType
                    Creator       = $creator
                    CreatorStatus = $status
                    Location      = $resource.Location
                    Tags          = ($resource.Tags | ConvertTo-Json -Compress)
                }
            }
        }
    }
}

Write-Log "Found $($results.Count) orphaned resources"

if ($results.Count -gt 0) {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation
    Write-Log "Results exported to: $OutputPath"
    $results | Format-Table -AutoSize -Property ResourceName, ResourceType, Creator, CreatorStatus
}

return $results

<#
.SYNOPSIS
    Automated cleanup of resources past their expiry date.

.DESCRIPTION
    Designed to run on a schedule (Azure Automation, GitHub Actions, etc.).
    Finds resources tagged with "expiry-date" that have passed their date,
    and resources tagged "cleanup-status=candidate" past their "cleanup-date".

    Safety features:
    - Only deletes resources explicitly tagged for cleanup
    - Logs every action for audit trail
    - Supports -WhatIf for dry runs
    - Skips resources with active resource locks

.PARAMETER DryRun
    Report what would be deleted without actually deleting.

.PARAMETER OutputPath
    Path to write the action log CSV. Default: ./cleanup-log-{date}.csv

.EXAMPLE
    # See what would be cleaned up
    .\Remove-ExpiredResources.ps1 -DryRun

    # Run for real
    .\Remove-ExpiredResources.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [string]$OutputPath = "./cleanup-log-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
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

$today = Get-Date -Format "yyyy-MM-dd"
Write-Log "Starting automated expired resource cleanup for date: $today"

$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
$results = @()
$totalDeleted = 0
$totalSkipped = 0

foreach ($sub in $subscriptions) {
    Write-Log "Processing subscription: $($sub.Name)"
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    # Find resources with expired expiry-date tag
    $expiredByTag = Get-AzResource -TagName "expiry-date" | Where-Object {
        try {
            $expiryDate = [datetime]::ParseExact($_.Tags["expiry-date"], "yyyy-MM-dd", $null)
            return $expiryDate -lt (Get-Date)
        } catch {
            return $false
        }
    }

    # Find resources tagged as cleanup candidates past their cleanup date
    $expiredCandidates = Get-AzResource -TagName "cleanup-status" | Where-Object {
        $_.Tags["cleanup-status"] -eq "candidate" -and
        $_.Tags.ContainsKey("cleanup-date") -and
        (
            try {
                $cleanupDate = [datetime]::ParseExact($_.Tags["cleanup-date"], "yyyy-MM-dd", $null)
                $cleanupDate -lt (Get-Date)
            } catch {
                $false
            }
        )
    }

    $allExpired = @($expiredByTag) + @($expiredCandidates) | Sort-Object -Property Id -Unique

    Write-Log "Found $($allExpired.Count) expired resource(s) in $($sub.Name)"

    foreach ($resource in $allExpired) {
        $result = [PSCustomObject]@{
            Timestamp     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Subscription  = $sub.Name
            ResourceGroup = $resource.ResourceGroupName
            ResourceName  = $resource.Name
            ResourceType  = $resource.ResourceType
            ExpiryDate    = $resource.Tags["expiry-date"]
            CleanupDate   = $resource.Tags["cleanup-date"]
            Action        = "Pending"
            Reason        = ""
        }

        # Check for locks
        if (Test-ResourceLocked -ResourceId $resource.Id) {
            Write-Log "Skipping locked resource: $($resource.Name)" -Level "SKIP"
            $result.Action = "Skipped"
            $result.Reason = "Resource is locked"
            $totalSkipped++
            $results += $result
            continue
        }

        if ($DryRun) {
            Write-Log "[DRY RUN] Would delete: $($resource.Name) ($($resource.ResourceType))" -Level "DRYRUN"
            $result.Action = "WouldDelete"
            $results += $result
            continue
        }

        if ($PSCmdlet.ShouldProcess($resource.Name, "Delete expired resource")) {
            try {
                Remove-AzResource -ResourceId $resource.Id -Force -ErrorAction Stop
                Write-Log "Deleted: $($resource.Name)" -Level "DELETE"
                $result.Action = "Deleted"
                $totalDeleted++
            } catch {
                Write-Log "Failed to delete $($resource.Name): $_" -Level "ERROR"
                $result.Action = "Failed"
                $result.Reason = $_.ToString()
            }
        }

        $results += $result
    }
}

# ── Summary & Export ─────────────────────────────────────────────────────────

Write-Log "Cleanup complete. Deleted: $totalDeleted | Skipped: $totalSkipped | Total processed: $($results.Count)"

if ($results.Count -gt 0) {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation
    Write-Log "Audit log written to: $OutputPath"
    $results | Format-Table -AutoSize -Property ResourceName, ResourceType, Action, Reason
}

return $results

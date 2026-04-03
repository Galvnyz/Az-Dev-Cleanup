<#
.SYNOPSIS
    Orchestrates all cleanup scripts in WhatIf mode and produces a consolidated report.

.DESCRIPTION
    Runs each cleanup script with -WhatIf, captures results, normalizes them into a
    common CSV format, and prints a summary table. Designed for stakeholder review
    before actual cleanup execution.

    Execution order (dependency-aware):
      1. Get-OrphanedResources      (discovery only — identifies orphans)
      2. Tag-CleanupCandidates       (tagging pass — marks candidates)
      3. Remove-StoppedVMs           (VMs first — may free disks/NICs)
      4. Remove-OldSnapshots         (snapshots before disks)
      5. Remove-UnattachedDisks      (freed by VM removal)
      6. Remove-UnusedPublicIPs      (freed by VM/NIC removal)
      7. Remove-UnusedNSGs           (freed by NIC removal)
      8. Remove-EmptyResourceGroups  (last — other removals may empty RGs)

.PARAMETER SubscriptionId
    Optional. Limit scope to a specific subscription (passed through to child scripts).

.PARAMETER OutputDir
    Directory for the consolidated dry-run report. Default: ./cleanup-dryrun-{timestamp}

.PARAMETER ExcludeScripts
    Array of script base names to skip (e.g., 'Remove-StoppedVMs', 'Tag-CleanupCandidates').

.EXAMPLE
    # Run all scripts in dry-run mode
    .\Invoke-CleanupDryRun.ps1

    # Exclude specific scripts
    .\Invoke-CleanupDryRun.ps1 -ExcludeScripts 'Tag-CleanupCandidates','Remove-OldSnapshots'

    # Scope to one subscription
    .\Invoke-CleanupDryRun.ps1 -SubscriptionId "xxxx-xxxx"
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$OutputDir = "./cleanup-dryrun-$(Get-Date -Format 'yyyy-MM-dd-HHmmss')",

    [Parameter()]
    [ValidateSet(
        'Get-OrphanedResources',
        'Tag-CleanupCandidates',
        'Remove-StoppedVMs',
        'Remove-OldSnapshots',
        'Remove-UnattachedDisks',
        'Remove-UnusedPublicIPs',
        'Remove-UnusedNSGs',
        'Remove-EmptyResourceGroups'
    )]
    [string[]]$ExcludeScripts = @()
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Write-Output $line
    if ($script:logFile) { $line | Out-File -Append -FilePath $script:logFile }
}

# ── Script Registry ─────────────────────────────────────────────────────────
# Each entry defines how to invoke the script and how to map its results
# into the common CSV schema: Script, ResourceType, ResourceName,
# ResourceGroup, Subscription, Action

$scriptRegistry = [ordered]@{
    'Get-OrphanedResources' = @{
        Path        = "$scriptRoot/Get-OrphanedResources.ps1"
        Description = "Identify resources with deleted/disabled creators"
        UsesWhatIf  = $false
        MapResult   = {
            param($r)
            [PSCustomObject]@{
                Script        = "Get-OrphanedResources"
                ResourceType  = $r.ResourceType
                ResourceName  = $r.ResourceName
                ResourceGroup = $r.ResourceGroup
                Subscription  = $r.Subscription
                Action        = "Orphan ($($r.CreatorStatus))"
            }
        }
    }
    'Tag-CleanupCandidates' = @{
        Path        = "$scriptRoot/Tag-CleanupCandidates.ps1"
        Description = "Tag orphaned resources as cleanup candidates"
        UsesWhatIf  = $true
        DependsOn   = 'Get-OrphanedResources'
        MapResult   = {
            param($r)
            # Tag-CleanupCandidates doesn't return structured results in WhatIf,
            # so we report the orphaned resources that would be tagged
            $null
        }
    }
    'Remove-StoppedVMs' = @{
        Path        = "$scriptRoot/Remove-StoppedVMs.ps1"
        Description = "Remove VMs deallocated beyond retention threshold"
        UsesWhatIf  = $true
        MapResult   = {
            param($r)
            [PSCustomObject]@{
                Script        = "Remove-StoppedVMs"
                ResourceType  = "Microsoft.Compute/virtualMachines"
                ResourceName  = $r.VMName
                ResourceGroup = $r.ResourceGroup
                Subscription  = $r.Subscription
                Action        = $r.Action
            }
        }
    }
    'Remove-OldSnapshots' = @{
        Path        = "$scriptRoot/Remove-OldSnapshots.ps1"
        Description = "Remove disk snapshots past retention period"
        UsesWhatIf  = $true
        MapResult   = {
            param($r)
            [PSCustomObject]@{
                Script        = "Remove-OldSnapshots"
                ResourceType  = "Microsoft.Compute/snapshots"
                ResourceName  = $r.SnapshotName
                ResourceGroup = $r.ResourceGroup
                Subscription  = $r.Subscription
                Action        = $r.Action
            }
        }
    }
    'Remove-UnattachedDisks' = @{
        Path        = "$scriptRoot/Remove-UnattachedDisks.ps1"
        Description = "Remove managed disks not attached to any VM"
        UsesWhatIf  = $true
        MapResult   = {
            param($r)
            [PSCustomObject]@{
                Script        = "Remove-UnattachedDisks"
                ResourceType  = "Microsoft.Compute/disks"
                ResourceName  = $r.DiskName
                ResourceGroup = $r.ResourceGroup
                Subscription  = $r.Subscription
                Action        = $r.Action
            }
        }
    }
    'Remove-UnusedPublicIPs' = @{
        Path        = "$scriptRoot/Remove-UnusedPublicIPs.ps1"
        Description = "Remove public IPs not associated with any resource"
        UsesWhatIf  = $true
        MapResult   = {
            param($r)
            [PSCustomObject]@{
                Script        = "Remove-UnusedPublicIPs"
                ResourceType  = "Microsoft.Network/publicIPAddresses"
                ResourceName  = $r.Name
                ResourceGroup = $r.ResourceGroup
                Subscription  = $r.Subscription
                Action        = $r.Action
            }
        }
    }
    'Remove-UnusedNSGs' = @{
        Path        = "$scriptRoot/Remove-UnusedNSGs.ps1"
        Description = "Remove network security groups with no associations"
        UsesWhatIf  = $true
        MapResult   = {
            param($r)
            [PSCustomObject]@{
                Script        = "Remove-UnusedNSGs"
                ResourceType  = "Microsoft.Network/networkSecurityGroups"
                ResourceName  = $r.Name
                ResourceGroup = $r.ResourceGroup
                Subscription  = $r.Subscription
                Action        = $r.Action
            }
        }
    }
    'Remove-EmptyResourceGroups' = @{
        Path        = "$scriptRoot/Remove-EmptyResourceGroups.ps1"
        Description = "Remove resource groups containing zero resources"
        UsesWhatIf  = $true
        MapResult   = {
            param($r)
            [PSCustomObject]@{
                Script        = "Remove-EmptyResourceGroups"
                ResourceType  = "Microsoft.Resources/resourceGroups"
                ResourceName  = $r.ResourceGroup
                ResourceGroup = $r.ResourceGroup
                Subscription  = $r.Subscription
                Action        = $r.Action
            }
        }
    }
}

# ── Setup ────────────────────────────────────────────────────────────────────

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$script:logFile = Join-Path $OutputDir "dryrun.log"
$csvPath = Join-Path $OutputDir "cleanup-dryrun.csv"
$orphanCsvPath = Join-Path $OutputDir "orphaned-resources.csv"

Write-Log "=== Cleanup Dry-Run Started ==="
Write-Log "Output directory: $OutputDir"
if ($SubscriptionId) { Write-Log "Subscription scope: $SubscriptionId" }
if ($ExcludeScripts.Count -gt 0) { Write-Log "Excluded scripts: $($ExcludeScripts -join ', ')" }

# ── Execute Scripts ──────────────────────────────────────────────────────────

$allResults = @()
$summary = @()
$orphanResults = $null

foreach ($scriptName in $scriptRegistry.Keys) {
    if ($ExcludeScripts -contains $scriptName) {
        Write-Log "Skipping excluded: $scriptName" -Level "SKIP"
        $summary += [PSCustomObject]@{
            Script      = $scriptName
            Candidates  = 0
            Status      = "Excluded"
            ElapsedSec  = 0
        }
        continue
    }

    $entry = $scriptRegistry[$scriptName]
    $scriptPath = $entry.Path

    if (-not (Test-Path $scriptPath)) {
        Write-Log "Script not found: $scriptPath" -Level "ERROR"
        $summary += [PSCustomObject]@{
            Script      = $scriptName
            Candidates  = 0
            Status      = "Not Found"
            ElapsedSec  = 0
        }
        continue
    }

    Write-Log "--- Running: $scriptName ---"
    Write-Log $entry.Description
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # Build parameters for the child script
        $params = @{}
        if ($SubscriptionId -and $scriptName -ne 'Tag-CleanupCandidates') {
            $params['SubscriptionId'] = $SubscriptionId
        }

        # Special handling per script type
        switch ($scriptName) {
            'Get-OrphanedResources' {
                $params['OutputPath'] = $orphanCsvPath
                $scriptResults = & $scriptPath @params
                $orphanResults = $scriptResults
            }
            'Tag-CleanupCandidates' {
                # Only run if orphan detection found results and produced a CSV
                if ($orphanResults -and (Test-Path $orphanCsvPath)) {
                    $params['InputCsv'] = $orphanCsvPath
                    $scriptResults = & $scriptPath @params -WhatIf
                } else {
                    Write-Log "Skipping Tag-CleanupCandidates — no orphan results to tag" -Level "SKIP"
                    $scriptResults = @()
                }
            }
            default {
                if ($entry.UsesWhatIf) {
                    $scriptResults = & $scriptPath @params -WhatIf
                } else {
                    $scriptResults = & $scriptPath @params
                }
            }
        }

        $stopwatch.Stop()

        # Normalize results using the mapping function
        $mapped = @()
        if ($scriptResults) {
            foreach ($r in $scriptResults) {
                $normalized = & $entry.MapResult $r
                if ($normalized) { $mapped += $normalized }
            }
        }

        $allResults += $mapped

        $candidateCount = $mapped.Count
        Write-Log "Completed: $scriptName — $candidateCount candidate(s) found ($([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s)"

        $summary += [PSCustomObject]@{
            Script      = $scriptName
            Candidates  = $candidateCount
            Status      = "OK"
            ElapsedSec  = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        }
    } catch {
        $stopwatch.Stop()
        Write-Log "FAILED: $scriptName — $_" -Level "ERROR"
        $summary += [PSCustomObject]@{
            Script      = $scriptName
            Candidates  = 0
            Status      = "Failed: $($_.Exception.Message)"
            ElapsedSec  = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        }
    }
}

# ── Export & Summary ─────────────────────────────────────────────────────────

if ($allResults.Count -gt 0) {
    $allResults | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Log "Consolidated dry-run CSV: $csvPath ($($allResults.Count) rows)"
}

Write-Log ""
Write-Log "=== Dry-Run Summary ==="
$summary | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_ }

$totalCandidates = ($summary | Measure-Object -Property Candidates -Sum).Sum
$failedScripts = ($summary | Where-Object { $_.Status -like "Failed*" }).Count

Write-Log "Total cleanup candidates: $totalCandidates"
if ($failedScripts -gt 0) {
    Write-Log "$failedScripts script(s) failed — review errors above" -Level "WARN"
}
Write-Log "=== Dry-Run Complete ==="

return $allResults

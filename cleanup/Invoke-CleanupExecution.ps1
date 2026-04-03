<#
.SYNOPSIS
    Orchestrates all cleanup scripts for real execution with safety gates.

.DESCRIPTION
    Mirrors Invoke-CleanupDryRun.ps1 but executes destructive operations.
    Safety features:
    - Requires -Force or interactive confirmation before proceeding
    - Runs a dry-run first and displays the plan for review
    - Captures a tenant baseline before and after execution
    - Compares state to show impact
    - Per-script error isolation (one failure does not halt the run)
    - Full audit log as CSV

    Execution order (same as dry-run):
      1. Get-OrphanedResources → 2. Tag-CleanupCandidates →
      3. Remove-StoppedVMs → 4. Remove-OldSnapshots →
      5. Remove-UnattachedDisks → 6. Remove-UnusedPublicIPs →
      7. Remove-UnusedNSGs → 8. Remove-EmptyResourceGroups

.PARAMETER SubscriptionId
    Optional. Limit scope to a specific subscription.

.PARAMETER OutputDir
    Directory for execution logs and baselines.
    Default: ./cleanup-execution-{timestamp}

.PARAMETER ExcludeScripts
    Array of script base names to skip.

.PARAMETER Force
    Skip the interactive confirmation prompt. Required for unattended execution.

.PARAMETER SkipBaseline
    Skip the before/after baseline capture (faster, less audit trail).

.EXAMPLE
    # Interactive execution with confirmation prompt
    .\Invoke-CleanupExecution.ps1

    # Unattended execution (CI/CD)
    .\Invoke-CleanupExecution.ps1 -Force

    # Skip specific scripts
    .\Invoke-CleanupExecution.ps1 -Force -ExcludeScripts 'Tag-CleanupCandidates'
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$OutputDir = "./cleanup-execution-$(Get-Date -Format 'yyyy-MM-dd-HHmmss')",

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
    [string[]]$ExcludeScripts = @(),

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$SkipBaseline
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot
$reportingRoot = Join-Path (Split-Path $scriptRoot -Parent) "reporting"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Write-Output $line
    if ($script:logFile) { $line | Out-File -Append -FilePath $script:logFile }
}

# ── Setup ────────────────────────────────────────────────────────────────────

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$script:logFile = Join-Path $OutputDir "execution.log"
$csvPath = Join-Path $OutputDir "cleanup-execution.csv"

Write-Log "=== Cleanup Execution Started ==="
Write-Log "Output directory: $OutputDir"

# ── Step 1: Dry-Run Preview ─────────────────────────────────────────────────

Write-Log "--- Step 1: Running dry-run preview ---"
$dryRunDir = Join-Path $OutputDir "dryrun-preview"
$dryRunParams = @{ OutputDir = $dryRunDir }
if ($SubscriptionId) { $dryRunParams['SubscriptionId'] = $SubscriptionId }
if ($ExcludeScripts.Count -gt 0) { $dryRunParams['ExcludeScripts'] = $ExcludeScripts }

$dryRunScript = Join-Path $scriptRoot "Invoke-CleanupDryRun.ps1"
$dryRunResults = & $dryRunScript @dryRunParams

$candidateCount = if ($dryRunResults) { $dryRunResults.Count } else { 0 }

if ($candidateCount -eq 0) {
    Write-Log "No cleanup candidates found. Nothing to do."
    Write-Log "=== Execution Complete (no changes) ==="
    return @()
}

Write-Log "Dry-run identified $candidateCount candidate(s) for cleanup"

# ── Step 2: Confirmation Gate ────────────────────────────────────────────────

if (-not $Force) {
    Write-Log ""
    Write-Log "*** CONFIRMATION REQUIRED ***" -Level "WARN"
    Write-Log "The above dry-run shows what will be deleted/modified."
    Write-Log "This action is DESTRUCTIVE and cannot be undone."
    Write-Log ""

    $confirm = Read-Host "Type 'YES' to proceed with cleanup, or anything else to abort"
    if ($confirm -ne 'YES') {
        Write-Log "Aborted by user." -Level "WARN"
        Write-Log "=== Execution Aborted ==="
        return @()
    }
}

# ── Step 3: Before Baseline ─────────────────────────────────────────────────

$beforeBaseline = $null
if (-not $SkipBaseline) {
    Write-Log "--- Step 3: Capturing before baseline ---"
    $beforePath = Join-Path $OutputDir "baseline-before.json"
    $baselineScript = Join-Path $reportingRoot "Save-TenantBaseline.ps1"

    if (Test-Path $baselineScript) {
        $baselineParams = @{ OutputPath = $beforePath }
        if ($SubscriptionId) { $baselineParams['SubscriptionId'] = $SubscriptionId }
        & $baselineScript @baselineParams | Out-Null
        $beforeBaseline = $beforePath
        Write-Log "Before baseline saved: $beforePath"
    } else {
        Write-Log "Save-TenantBaseline.ps1 not found — skipping baseline" -Level "WARN"
    }
}

# ── Step 4: Execute Cleanup Scripts ──────────────────────────────────────────

Write-Log "--- Step 4: Executing cleanup ---"

# Script execution order (same as dry-run)
$scriptOrder = @(
    @{ Name = 'Get-OrphanedResources';     Path = "$scriptRoot/Get-OrphanedResources.ps1" }
    @{ Name = 'Tag-CleanupCandidates';     Path = "$scriptRoot/Tag-CleanupCandidates.ps1" }
    @{ Name = 'Remove-StoppedVMs';         Path = "$scriptRoot/Remove-StoppedVMs.ps1" }
    @{ Name = 'Remove-OldSnapshots';       Path = "$scriptRoot/Remove-OldSnapshots.ps1" }
    @{ Name = 'Remove-UnattachedDisks';    Path = "$scriptRoot/Remove-UnattachedDisks.ps1" }
    @{ Name = 'Remove-UnusedPublicIPs';    Path = "$scriptRoot/Remove-UnusedPublicIPs.ps1" }
    @{ Name = 'Remove-UnusedNSGs';         Path = "$scriptRoot/Remove-UnusedNSGs.ps1" }
    @{ Name = 'Remove-EmptyResourceGroups'; Path = "$scriptRoot/Remove-EmptyResourceGroups.ps1" }
)

$allResults = @()
$summary = @()
$orphanCsvPath = Join-Path $OutputDir "orphaned-resources.csv"
$overallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($entry in $scriptOrder) {
    $scriptName = $entry.Name

    if ($ExcludeScripts -contains $scriptName) {
        Write-Log "Skipping excluded: $scriptName" -Level "SKIP"
        $summary += [PSCustomObject]@{
            Script     = $scriptName
            Processed  = 0
            Succeeded  = 0
            Failed     = 0
            Status     = "Excluded"
            ElapsedSec = 0
        }
        continue
    }

    if (-not (Test-Path $entry.Path)) {
        Write-Log "Script not found: $($entry.Path)" -Level "ERROR"
        $summary += [PSCustomObject]@{
            Script     = $scriptName
            Processed  = 0
            Succeeded  = 0
            Failed     = 0
            Status     = "Not Found"
            ElapsedSec = 0
        }
        continue
    }

    Write-Log "--- Executing: $scriptName ---"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $params = @{}
        if ($SubscriptionId -and $scriptName -ne 'Tag-CleanupCandidates') {
            $params['SubscriptionId'] = $SubscriptionId
        }

        switch ($scriptName) {
            'Get-OrphanedResources' {
                $params['OutputPath'] = $orphanCsvPath
                $scriptResults = & $entry.Path @params
            }
            'Tag-CleanupCandidates' {
                if (Test-Path $orphanCsvPath) {
                    $params['InputCsv'] = $orphanCsvPath
                    $scriptResults = & $entry.Path @params
                } else {
                    Write-Log "Skipping — no orphan results to tag" -Level "SKIP"
                    $scriptResults = @()
                }
            }
            default {
                # Real execution — no -WhatIf
                $scriptResults = & $entry.Path @params
            }
        }

        $stopwatch.Stop()

        # Count outcomes from results
        $processed = if ($scriptResults) { @($scriptResults).Count } else { 0 }
        $succeeded = if ($scriptResults) {
            @($scriptResults | Where-Object {
                $_.Action -in @("Removed", "Tagged", "Deleted") -or
                $_.Action -like "Removed*" -or
                $_.CreatorStatus  # Get-OrphanedResources returns creator status, not Action
            }).Count
        } else { 0 }
        $failed = if ($scriptResults) {
            @($scriptResults | Where-Object { $_.Action -like "Failed*" }).Count
        } else { 0 }

        # Log individual results
        if ($scriptResults) {
            foreach ($r in $scriptResults) {
                $allResults += [PSCustomObject]@{
                    Timestamp     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    Script        = $scriptName
                    ResourceName  = ($r.ResourceName, $r.VMName, $r.DiskName, $r.SnapshotName, $r.Name, $r.ResourceGroup | Where-Object { $_ } | Select-Object -First 1)
                    ResourceGroup = ($r.ResourceGroup, $r.ResourceGroupName | Where-Object { $_ } | Select-Object -First 1)
                    Subscription  = $r.Subscription
                    Action        = ($r.Action, $r.CreatorStatus | Where-Object { $_ } | Select-Object -First 1)
                    Error         = ""
                }
            }
        }

        Write-Log "Completed: $scriptName — $succeeded succeeded, $failed failed ($([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s)"

        $summary += [PSCustomObject]@{
            Script     = $scriptName
            Processed  = $processed
            Succeeded  = $succeeded
            Failed     = $failed
            Status     = if ($failed -gt 0) { "Partial" } else { "OK" }
            ElapsedSec = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        }
    } catch {
        $stopwatch.Stop()
        Write-Log "FAILED: $scriptName — $_" -Level "ERROR"

        $allResults += [PSCustomObject]@{
            Timestamp     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Script        = $scriptName
            ResourceName  = ""
            ResourceGroup = ""
            Subscription  = ""
            Action        = "Script Failed"
            Error         = $_.Exception.Message
        }

        $summary += [PSCustomObject]@{
            Script     = $scriptName
            Processed  = 0
            Succeeded  = 0
            Failed     = 1
            Status     = "Failed"
            ElapsedSec = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        }
    }
}

$overallStopwatch.Stop()

# ── Step 5: After Baseline & Comparison ──────────────────────────────────────

if (-not $SkipBaseline -and $beforeBaseline) {
    Write-Log "--- Step 5: Capturing after baseline ---"
    $afterPath = Join-Path $OutputDir "baseline-after.json"
    $baselineParams = @{ OutputPath = $afterPath }
    if ($SubscriptionId) { $baselineParams['SubscriptionId'] = $SubscriptionId }

    $baselineScript = Join-Path $reportingRoot "Save-TenantBaseline.ps1"
    & $baselineScript @baselineParams | Out-Null

    $compareScript = Join-Path $reportingRoot "Compare-TenantState.ps1"
    if (Test-Path $compareScript) {
        Write-Log "--- Before/After Comparison ---"
        $comparisonPath = Join-Path $OutputDir "comparison.csv"
        & $compareScript -BeforePath $beforeBaseline -AfterPath $afterPath -OutputPath $comparisonPath
    }
}

# ── Export & Summary ─────────────────────────────────────────────────────────

if ($allResults.Count -gt 0) {
    $allResults | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Log "Execution log: $csvPath ($($allResults.Count) rows)"
}

Write-Log ""
Write-Log "=== Execution Summary ==="
$summary | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_ }

$totalProcessed = ($summary | Measure-Object -Property Processed -Sum).Sum
$totalSucceeded = ($summary | Measure-Object -Property Succeeded -Sum).Sum
$totalFailed = ($summary | Measure-Object -Property Failed -Sum).Sum
$elapsed = [math]::Round($overallStopwatch.Elapsed.TotalMinutes, 1)

Write-Log "Total: $totalProcessed processed, $totalSucceeded succeeded, $totalFailed failed"
Write-Log "Elapsed: $elapsed minutes"
if ($totalFailed -gt 0) {
    Write-Log "$totalFailed action(s) failed — review execution log for details" -Level "WARN"
}
Write-Log "=== Execution Complete ==="

return $allResults

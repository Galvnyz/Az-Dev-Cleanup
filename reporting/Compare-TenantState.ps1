<#
.SYNOPSIS
    Compares two tenant baselines and reports the delta.

.DESCRIPTION
    Takes two baseline JSON files (from Save-TenantBaseline.ps1) and produces
    a summary comparison table showing what changed. Useful for proving cleanup
    impact to stakeholders.

    Supports comparing two saved baselines or comparing a baseline against the
    current live tenant state.

.PARAMETER BeforePath
    Path to the "before" baseline JSON file.

.PARAMETER AfterPath
    Path to the "after" baseline JSON file. Mutually exclusive with -Current.

.PARAMETER Current
    Compare the before baseline against the current live tenant state
    (runs Save-TenantBaseline internally). Mutually exclusive with -AfterPath.

.PARAMETER IncludeCost
    When using -Current, also capture cost data for the live baseline.

.PARAMETER OutputPath
    Path for the comparison detail CSV. Default: ./comparison-{timestamp}.csv

.EXAMPLE
    # Compare two saved baselines
    .\Compare-TenantState.ps1 -BeforePath ./baseline-before.json -AfterPath ./baseline-after.json

    # Compare baseline against live state
    .\Compare-TenantState.ps1 -BeforePath ./baseline-before.json -Current
#>

[CmdletBinding(DefaultParameterSetName = "File")]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$BeforePath,

    [Parameter(Mandatory, ParameterSetName = "File")]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$AfterPath,

    [Parameter(Mandatory, ParameterSetName = "Live")]
    [switch]$Current,

    [Parameter(ParameterSetName = "Live")]
    [switch]$IncludeCost,

    [Parameter()]
    [string]$OutputPath = "./comparison-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$timestamp] [$Level] $Message"
}

# ── Load Baselines ───────────────────────────────────────────────────────────

Write-Log "Loading before baseline: $BeforePath"
$before = Get-Content -Path $BeforePath -Raw | ConvertFrom-Json

if ($Current) {
    Write-Log "Capturing current live state..."
    $saveParams = @{}
    if ($IncludeCost) { $saveParams['IncludeCost'] = $true }

    $afterFile = "./baseline-current-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').json"
    $saveScript = Join-Path $PSScriptRoot "Save-TenantBaseline.ps1"
    & $saveScript -OutputPath $afterFile @saveParams | Out-Null
    $after = Get-Content -Path $afterFile -Raw | ConvertFrom-Json
    Write-Log "Live baseline saved: $afterFile"
} else {
    Write-Log "Loading after baseline: $AfterPath"
    $after = Get-Content -Path $AfterPath -Raw | ConvertFrom-Json
}

# ── Aggregate Comparison ─────────────────────────────────────────────────────

$metrics = @(
    @{ Name = "Total Resources";      Before = $before.resourceCount;       After = $after.resourceCount }
    @{ Name = "Resource Groups";       Before = $before.rgCount;             After = $after.rgCount }
    @{ Name = "Stopped VMs";           Before = $before.stoppedVMs;          After = $after.stoppedVMs }
    @{ Name = "Empty Resource Groups"; Before = $before.emptyResourceGroups; After = $after.emptyResourceGroups }
)

# Add cost if both baselines have it
if ($null -ne $before.estimatedMonthlyCost -and $null -ne $after.estimatedMonthlyCost) {
    $metrics += @{
        Name   = "Est. Monthly Cost"
        Before = $before.estimatedMonthlyCost
        After  = $after.estimatedMonthlyCost
    }
}

$summaryTable = $metrics | ForEach-Object {
    $delta = $_.After - $_.Before
    $deltaStr = if ($delta -gt 0) { "+$delta" } elseif ($delta -lt 0) { "$delta" } else { "0" }
    [PSCustomObject]@{
        Metric = $_.Name
        Before = $_.Before
        After  = $_.After
        Delta  = $deltaStr
    }
}

Write-Log ""
Write-Log "=== Tenant State Comparison ==="
Write-Log "Before: $($before.timestamp)"
Write-Log "After:  $($after.timestamp)"
Write-Log ""
$summaryTable | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_ }

# ── Per-Type Comparison ──────────────────────────────────────────────────────

$allTypes = @()
$beforeTypes = @{}
$afterTypes = @{}

# Convert PSObject properties to hashtable
if ($before.byType -is [System.Management.Automation.PSCustomObject]) {
    $before.byType.PSObject.Properties | ForEach-Object { $beforeTypes[$_.Name] = [int]$_.Value }
} elseif ($before.byType -is [hashtable]) {
    $beforeTypes = $before.byType
}

if ($after.byType -is [System.Management.Automation.PSCustomObject]) {
    $after.byType.PSObject.Properties | ForEach-Object { $afterTypes[$_.Name] = [int]$_.Value }
} elseif ($after.byType -is [hashtable]) {
    $afterTypes = $after.byType
}

$allTypeNames = ($beforeTypes.Keys + $afterTypes.Keys) | Sort-Object -Unique

$typeComparison = $allTypeNames | ForEach-Object {
    $typeName = $_
    $bCount = if ($beforeTypes.ContainsKey($typeName)) { $beforeTypes[$typeName] } else { 0 }
    $aCount = if ($afterTypes.ContainsKey($typeName)) { $afterTypes[$typeName] } else { 0 }
    $delta = $aCount - $bCount

    [PSCustomObject]@{
        ResourceType = $typeName
        Before       = $bCount
        After        = $aCount
        Delta        = $delta
    }
} | Where-Object { $_.Delta -ne 0 } | Sort-Object Delta

if ($typeComparison.Count -gt 0) {
    Write-Log "--- Changes by Resource Type ---"
    $typeComparison | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_ }

    # Export detail
    $typeComparison | Export-Csv -Path $OutputPath -NoTypeInformation
    Write-Log "Type-level detail CSV: $OutputPath"
} else {
    Write-Log "No per-type changes detected."
}

# ── Net Summary ──────────────────────────────────────────────────────────────

$netResources = $after.resourceCount - $before.resourceCount
$netRGs = $after.rgCount - $before.rgCount

Write-Log ""
if ($netResources -lt 0) {
    Write-Log "Net change: $netResources resources, $netRGs resource groups removed" -Level "INFO"
} elseif ($netResources -gt 0) {
    Write-Log "Net change: +$netResources resources added since baseline" -Level "WARN"
} else {
    Write-Log "No net resource count change."
}

if ($null -ne $before.estimatedMonthlyCost -and $null -ne $after.estimatedMonthlyCost) {
    $costDelta = $after.estimatedMonthlyCost - $before.estimatedMonthlyCost
    if ($costDelta -lt 0) {
        Write-Log "Estimated monthly savings: `$$([math]::Abs($costDelta))"
    } elseif ($costDelta -gt 0) {
        Write-Log "Estimated monthly cost increase: `$$costDelta" -Level "WARN"
    }
}

Write-Log "=== Comparison Complete ==="

return $summaryTable

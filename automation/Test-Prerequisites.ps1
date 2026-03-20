<#
.SYNOPSIS
    Pre-flight validation for discovery and cleanup workflows.

.DESCRIPTION
    Verifies that all prerequisites are met before running discovery or cleanup:
    - Az module is installed and importable
    - Azure context is authenticated
    - Target subscriptions are accessible
    - Required module versions are available

    Designed to run as the first step in GitHub Actions workflows.
    Returns exit code 1 if any check fails.

.EXAMPLE
    .\Test-Prerequisites.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$failed = 0

function Write-Check {
    param([string]$Name, [bool]$Passed, [string]$Detail = "")
    if ($Passed) {
        Write-Output "[PASS] $Name $Detail"
    } else {
        Write-Output "[FAIL] $Name $Detail"
        $script:failed++
    }
}

# ── Az Module ────────────────────────────────────────────────────────────────

$azModule = Get-Module Az.Accounts -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
Write-Check "Az.Accounts module installed" ($null -ne $azModule) $(if ($azModule) { "v$($azModule.Version)" })

$azMonitor = Get-Module Az.Monitor -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
Write-Check "Az.Monitor module installed" ($null -ne $azMonitor) $(if ($azMonitor) { "v$($azMonitor.Version)" })

# ── Azure Context ────────────────────────────────────────────────────────────

try {
    $context = Get-AzContext -ErrorAction Stop
    $hasContext = $null -ne $context -and $null -ne $context.Account
    Write-Check "Azure context authenticated" $hasContext $(if ($hasContext) { "as $($context.Account.Id)" })
} catch {
    Write-Check "Azure context authenticated" $false "Run Connect-AzAccount first"
}

# ── Subscription Access ──────────────────────────────────────────────────────

if ($hasContext) {
    try {
        $subs = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
        Write-Check "Subscriptions accessible" ($subs.Count -gt 0) "$($subs.Count) enabled subscription(s)"

        foreach ($sub in $subs) {
            Write-Output "       - $($sub.Name) ($($sub.Id))"
        }
    } catch {
        Write-Check "Subscriptions accessible" $false $_.ToString()
    }
}

# ── Resource Graph ───────────────────────────────────────────────────────────

$argModule = Get-Module Az.ResourceGraph -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
Write-Check "Az.ResourceGraph module installed" ($null -ne $argModule) $(if ($argModule) { "v$($argModule.Version)" })

# ── ImportExcel (optional) ───────────────────────────────────────────────────

$excelModule = Get-Module ImportExcel -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if ($excelModule) {
    Write-Check "ImportExcel module (optional)" $true "v$($excelModule.Version)"
} else {
    Write-Output "[SKIP] ImportExcel module not installed — XLSX reports will be skipped"
}

# ── Pester (optional) ────────────────────────────────────────────────────────

$pester = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if ($pester) {
    Write-Check "Pester module (optional)" $true "v$($pester.Version)"
} else {
    Write-Output "[SKIP] Pester module not installed — tests will be skipped"
}

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Output ""
if ($failed -gt 0) {
    Write-Output "[RESULT] $failed pre-flight check(s) FAILED"
    exit 1
} else {
    Write-Output "[RESULT] All pre-flight checks passed"
}

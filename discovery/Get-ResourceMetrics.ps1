<#
.SYNOPSIS
    Checks Azure Monitor metrics to identify unused resources.

.DESCRIPTION
    Queries Azure Monitor for utilization metrics on high-cost resource types.
    Resources with zero or near-zero usage over the check period are flagged
    as potentially stale. This catches resources that exist and run but are
    never actually used — the most expensive form of waste.

    Supported resource types:
    - Virtual Machines (CPU percentage)
    - App Service Plans (CPU percentage)
    - SQL Databases (connection count)
    - Storage Accounts (transaction count)
    - Key Vaults (API hits)

.PARAMETER SubscriptionId
    Optional. Limit to a specific subscription.

.PARAMETER CheckDays
    Number of days to check metrics over. Default: 14.

.PARAMETER OutputPath
    Path to export CSV results. Default: ./metric-staleness.csv

.PARAMETER ResourceTypes
    Which resource types to check. Default: all supported types.

.EXAMPLE
    # Check all supported types over 14 days
    .\Get-ResourceMetrics.ps1

    # Quick check — VMs only, last 7 days
    .\Get-ResourceMetrics.ps1 -ResourceTypes @('VirtualMachines') -CheckDays 7
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidateRange(1, 90)]
    [int]$CheckDays = 14,

    [Parameter()]
    [string]$OutputPath = "./metric-staleness.csv",

    [Parameter()]
    [ValidateSet('VirtualMachines', 'AppServicePlans', 'SqlDatabases', 'StorageAccounts', 'KeyVaults')]
    [string[]]$ResourceTypes = @('VirtualMachines', 'AppServicePlans', 'SqlDatabases', 'StorageAccounts', 'KeyVaults')
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$timestamp] [$Level] $Message"
}

# ── Metric definitions per resource type ──────────────────────────────────────

$metricChecks = @{
    VirtualMachines = @{
        ResourceType = 'Microsoft.Compute/virtualMachines'
        MetricName   = 'Percentage CPU'
        Aggregation  = 'Average'
        IdleThreshold = 5       # Avg CPU < 5% = likely idle
        Label        = 'Avg CPU %'
    }
    AppServicePlans = @{
        ResourceType = 'Microsoft.Web/serverFarms'
        MetricName   = 'CpuPercentage'
        Aggregation  = 'Average'
        IdleThreshold = 2       # Avg CPU < 2% = likely idle
        Label        = 'Avg CPU %'
    }
    SqlDatabases = @{
        ResourceType = 'Microsoft.Sql/servers/databases'
        MetricName   = 'connection_successful'
        Aggregation  = 'Total'
        IdleThreshold = 1       # 0 connections = unused
        Label        = 'Total Connections'
    }
    StorageAccounts = @{
        ResourceType = 'Microsoft.Storage/storageAccounts'
        MetricName   = 'Transactions'
        Aggregation  = 'Total'
        IdleThreshold = 10      # < 10 transactions over period = effectively unused
        Label        = 'Total Transactions'
    }
    KeyVaults = @{
        ResourceType = 'Microsoft.KeyVault/vaults'
        MetricName   = 'ServiceApiHit'
        Aggregation  = 'Total'
        IdleThreshold = 1       # 0 API hits = unused
        Label        = 'Total API Hits'
    }
}

# ── Main ──────────────────────────────────────────────────────────────────────

Write-Log "Starting metric-based staleness check ($CheckDays-day window)"

if ($SubscriptionId) {
    $subscriptions = @(Get-AzSubscription -SubscriptionId $SubscriptionId)
} else {
    $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
}

$startTime = (Get-Date).AddDays(-$CheckDays)
$endTime = Get-Date
$results = @()
$totalChecked = 0
$totalIdle = 0

foreach ($sub in $subscriptions) {
    Write-Log "Scanning subscription: $($sub.Name)"
    Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null

    foreach ($typeName in $ResourceTypes) {
        $check = $metricChecks[$typeName]
        if (-not $check) { continue }

        Write-Log "  Checking $typeName ($($check.MetricName))..."

        try {
            $resources = Get-AzResource -ResourceType $check.ResourceType -ErrorAction Stop
        } catch {
            Write-Log "  Failed to list $typeName`: $_" -Level "ERROR"
            continue
        }

        if ($resources.Count -eq 0) {
            Write-Log "  No $typeName found"
            continue
        }

        $idle = 0
        foreach ($resource in $resources) {
            $totalChecked++

            try {
                $metric = Get-AzMetric -ResourceId $resource.Id `
                    -MetricName $check.MetricName `
                    -StartTime $startTime -EndTime $endTime `
                    -AggregationType $check.Aggregation `
                    -TimeGrain ([TimeSpan]::FromDays(1)) `
                    -WarningAction SilentlyContinue -ErrorAction Stop

                $dataPoints = $metric.Data | Where-Object {
                    $null -ne $_.($check.Aggregation)
                }

                $metricValue = if ($check.Aggregation -eq 'Average') {
                    if ($dataPoints.Count -gt 0) {
                        [math]::Round(($dataPoints | Measure-Object -Property Average -Average).Average, 2)
                    } else { 0 }
                } else {
                    if ($dataPoints.Count -gt 0) {
                        [math]::Round(($dataPoints | Measure-Object -Property Total -Sum).Sum, 0)
                    } else { 0 }
                }

                $isIdle = $metricValue -lt $check.IdleThreshold

                $results += [PSCustomObject]@{
                    Subscription   = $sub.Name
                    ResourceGroup  = $resource.ResourceGroupName
                    ResourceName   = $resource.Name
                    ResourceType   = $check.ResourceType
                    MetricName     = $check.MetricName
                    MetricValue    = $metricValue
                    MetricLabel    = $check.Label
                    Threshold      = $check.IdleThreshold
                    IsIdle         = $isIdle
                    CheckDays      = $CheckDays
                    Tags           = ($resource.Tags | ConvertTo-Json -Compress -ErrorAction SilentlyContinue)
                }

                if ($isIdle) { $idle++ }
            } catch {
                # Some resources don't support metrics (e.g., master DB)
                continue
            }
        }

        Write-Log "  $typeName`: $($resources.Count) checked, $idle idle (below $($check.Label) threshold of $($check.IdleThreshold))"
        $totalIdle += $idle
    }
}

Write-Log "Metric check complete. Checked: $totalChecked | Idle: $totalIdle"

if ($results.Count -gt 0) {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation
    Write-Log "Results exported to: $OutputPath"

    $idleResults = $results | Where-Object { $_.IsIdle }
    if ($idleResults.Count -gt 0) {
        Write-Log "Idle resources:"
        $idleResults | Format-Table -AutoSize -Property ResourceName, ResourceType, MetricLabel, MetricValue, Threshold
    }
}

return $results

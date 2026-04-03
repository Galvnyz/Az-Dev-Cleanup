<#
.SYNOPSIS
    Captures a lightweight tenant state snapshot for before/after comparison.

.DESCRIPTION
    Queries Azure Resource Graph for aggregate resource metrics and saves them
    as a versioned JSON baseline. Designed to be run before and after cleanup
    to measure impact.

    Captures: resource count, resource group count, per-type resource counts,
    per-subscription breakdown, and optionally estimated monthly cost.

.PARAMETER OutputPath
    Path for the baseline JSON file. Default: ./baseline-{timestamp}.json

.PARAMETER SubscriptionId
    Optional. Limit to a specific subscription.

.PARAMETER IncludeCost
    Query Azure Cost Management for estimated monthly cost. Requires
    Cost Management Reader role. Slower but provides cost baseline.

.EXAMPLE
    # Quick baseline (no cost data)
    .\Save-TenantBaseline.ps1

    # Full baseline with cost
    .\Save-TenantBaseline.ps1 -IncludeCost

    # Scoped to one subscription
    .\Save-TenantBaseline.ps1 -SubscriptionId "xxxx-xxxx"
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath = "./baseline-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').json",

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [switch]$IncludeCost
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$timestamp] [$Level] $Message"
}

# ── Main ─────────────────────────────────────────────────────────────────────

Write-Log "Capturing tenant baseline..."

# Get target subscriptions
if ($SubscriptionId) {
    $subscriptions = @(Get-AzSubscription -SubscriptionId $SubscriptionId)
} else {
    $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
}

$subIds = $subscriptions | ForEach-Object { $_.Id }
Write-Log "Scanning $($subscriptions.Count) subscription(s)"

# ── Resource counts via Resource Graph ───────────────────────────────────────

# Total resource count
$totalQuery = "resources | summarize count()"
$totalResult = Search-AzGraph -Query $totalQuery -Subscription $subIds
$resourceCount = $totalResult.count_

# Resource group count
$rgQuery = "resourcecontainers | where type == 'microsoft.resources/subscriptions/resourcegroups' | summarize count()"
$rgResult = Search-AzGraph -Query $rgQuery -Subscription $subIds
$rgCount = $rgResult.count_

# Per-type breakdown
$typeQuery = "resources | summarize count() by type | order by count_ desc"
$typeResults = Search-AzGraph -Query $typeQuery -Subscription $subIds -First 1000
$byType = @{}
foreach ($row in $typeResults) {
    $byType[$row.type] = $row.count_
}

# Per-subscription breakdown
$subQuery = "resources | summarize count() by subscriptionId | order by count_ desc"
$subResults = Search-AzGraph -Query $subQuery -Subscription $subIds
$bySubscription = @{}
foreach ($row in $subResults) {
    $subName = ($subscriptions | Where-Object { $_.Id -eq $row.subscriptionId }).Name
    $key = if ($subName) { $subName } else { $row.subscriptionId }
    $bySubscription[$key] = $row.count_
}

# Key resource type counts for quick comparison
$stoppedVmQuery = "resources | where type == 'microsoft.compute/virtualmachines' | where properties.extended.instanceView.powerState.code == 'PowerState/deallocated' | summarize count()"
$stoppedVmResult = Search-AzGraph -Query $stoppedVmQuery -Subscription $subIds
$stoppedVMs = $stoppedVmResult.count_

$emptyRgQuery = "resourcecontainers | where type == 'microsoft.resources/subscriptions/resourcegroups' | where properties.provisioningState == 'Succeeded' | project name, id | join kind=leftanti (resources | project rgId = tolower(strcat('/subscriptions/', subscriptionId, '/resourcegroups/', resourceGroup))) on `$left.id == `$right.rgId | summarize count()"
$emptyRgResult = Search-AzGraph -Query $emptyRgQuery -Subscription $subIds
$emptyRGs = $emptyRgResult.count_

Write-Log "Resources: $resourceCount | RGs: $rgCount | Stopped VMs: $stoppedVMs | Empty RGs: $emptyRGs"

# ── Optional cost data ───────────────────────────────────────────────────────

$estimatedMonthlyCost = $null
if ($IncludeCost) {
    Write-Log "Querying cost data (last 30 days)..."
    try {
        $endDate = Get-Date
        $startDate = $endDate.AddDays(-30)

        $totalCost = 0
        foreach ($sub in $subscriptions) {
            Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
            $scope = "/subscriptions/$($sub.Id)"

            $costQuery = @{
                type = "ActualCost"
                timeframe = "Custom"
                timePeriod = @{
                    from = $startDate.ToString("yyyy-MM-ddT00:00:00Z")
                    to   = $endDate.ToString("yyyy-MM-ddT00:00:00Z")
                }
                dataset = @{
                    granularity = "None"
                    aggregation = @{
                        totalCost = @{ name = "Cost"; function = "Sum" }
                    }
                }
            }

            $result = Invoke-AzCostManagementQuery -Scope $scope -QueryBody $costQuery -ErrorAction Stop
            if ($result.Row) {
                $totalCost += [decimal]$result.Row[0][0]
            }
        }
        $estimatedMonthlyCost = [math]::Round($totalCost, 2)
        Write-Log "Estimated monthly cost: `$$estimatedMonthlyCost"
    } catch {
        Write-Log "Cost query failed (continuing without cost data): $_" -Level "WARN"
    }
}

# ── Build Baseline Object ────────────────────────────────────────────────────

$baseline = [ordered]@{
    schemaVersion       = 1
    timestamp           = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    subscriptions       = ($subscriptions | ForEach-Object { $_.Name }) -join "; "
    subscriptionCount   = $subscriptions.Count
    resourceCount       = $resourceCount
    rgCount             = $rgCount
    stoppedVMs          = $stoppedVMs
    emptyResourceGroups = $emptyRGs
    estimatedMonthlyCost = $estimatedMonthlyCost
    byType              = $byType
    bySubscription      = $bySubscription
}

# ── Save ─────────────────────────────────────────────────────────────────────

$baseline | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputPath -Encoding UTF8
Write-Log "Baseline saved: $OutputPath"

return $baseline

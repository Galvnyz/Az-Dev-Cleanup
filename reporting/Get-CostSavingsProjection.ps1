<#
.SYNOPSIS
    Estimates monthly cost savings from cleanup candidates.

.DESCRIPTION
    Cross-references a dry-run CSV (from Invoke-CleanupDryRun.ps1) with Azure
    Cost Management data to project dollar savings per category. For resources
    without direct cost data, uses built-in rate-card estimates.

    Output: per-category savings summary (CSV + console table).

.PARAMETER DryRunCsv
    Path to the consolidated dry-run CSV from Invoke-CleanupDryRun.ps1.

.PARAMETER CostCsv
    Path to an Azure Cost Management export CSV.
    Expected columns: UsageDate, ResourceId, ResourceType, ResourceLocation,
    ResourceGroupName, ServiceName, Meter, CostUSD

.PARAMETER RateCard
    Hashtable of fallback monthly cost estimates by resource type pattern.
    Used when a resource has no matching cost data. Defaults provided for
    common resource types.

.PARAMETER OutputPath
    Path for the savings summary CSV. Default: ./cost-savings-{timestamp}.csv

.EXAMPLE
    # Project savings from a dry-run
    .\Get-CostSavingsProjection.ps1 -DryRunCsv ./cleanup-dryrun-2026-04-02/cleanup-dryrun.csv `
                                     -CostCsv ./reports/cost-analysis.csv

    # Use custom rate card overrides
    .\Get-CostSavingsProjection.ps1 -DryRunCsv ./dryrun.csv -RateCard @{
        "Microsoft.Compute/disks" = 5.00
        "Microsoft.Network/publicIPAddresses" = 3.65
    }
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$DryRunCsv,

    [Parameter()]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CostCsv,

    [Parameter()]
    [hashtable]$RateCard,

    [Parameter()]
    [string]$OutputPath = "./cost-savings-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$timestamp] [$Level] $Message"
}

# ── Default Rate Card ────────────────────────────────────────────────────────
# Fallback monthly estimates when no cost data is available.
# Sources: Azure pricing calculator (East US, pay-as-you-go, April 2026)

$defaultRateCard = @{
    "Microsoft.Network/publicIPAddresses"    = 3.65   # Basic static IP
    "Microsoft.Compute/disks/Standard_LRS"   = 1.54   # per 32 GB S4
    "Microsoft.Compute/disks/StandardSSD_LRS"= 2.40   # per 32 GB E4
    "Microsoft.Compute/disks/Premium_LRS"    = 5.28   # per 32 GB P4
    "Microsoft.Compute/disks"                = 3.00   # generic disk average
    "Microsoft.Compute/snapshots"            = 0.05   # per GB/month
    "Microsoft.Network/networkSecurityGroups" = 0.00  # free
    "Microsoft.Resources/resourceGroups"     = 0.00   # free
    "Microsoft.Network/loadBalancers/Basic"  = 0.00   # free
    "Microsoft.Network/loadBalancers/Standard"= 18.25 # ~$0.025/hr
    "Microsoft.Network/loadBalancers"        = 9.00   # average
    "Microsoft.Web/serverFarms/Free"         = 0.00   # free tier
    "Microsoft.Web/serverFarms/Basic"        = 54.75  # B1
    "Microsoft.Web/serverFarms/Standard"     = 73.00  # S1
    "Microsoft.Web/serverFarms"              = 30.00  # generic average
}

# Merge user overrides
if ($RateCard) {
    foreach ($key in $RateCard.Keys) {
        $defaultRateCard[$key] = $RateCard[$key]
    }
}

# ── Load Data ────────────────────────────────────────────────────────────────

Write-Log "Loading dry-run candidates from: $DryRunCsv"
$candidates = Import-Csv -Path $DryRunCsv

# Filter to actionable candidates (exclude discovery-only entries like orphan detection)
$actionable = $candidates | Where-Object {
    $_.Action -notin @("Excluded", "Skipped") -and
    $_.Script -ne "Get-OrphanedResources"
}

Write-Log "Loaded $($candidates.Count) candidates ($($actionable.Count) actionable)"

$costLookup = @{}
$costDays = 30
if ($CostCsv) {
    Write-Log "Loading cost data from: $CostCsv"
    $costData = Import-Csv -Path $CostCsv

    # Determine date range for monthly normalization
    $dates = $costData | ForEach-Object {
        try { [datetime]$_.UsageDate } catch { $null }
    } | Where-Object { $_ } | Sort-Object
    if ($dates.Count -ge 2) {
        $costDays = [math]::Max(1, ($dates[-1] - $dates[0]).Days)
    }
    $monthFactor = 30.44 / $costDays

    Write-Log "Cost data spans $costDays days ($($costData.Count) records)"

    # Build lookup: ResourceId (lowercase) → total cost over period
    foreach ($row in $costData) {
        $rid = $row.ResourceId.ToLower()
        $cost = try { [decimal]$row.CostUSD } catch { 0 }
        if ($costLookup.ContainsKey($rid)) {
            $costLookup[$rid] += $cost
        } else {
            $costLookup[$rid] = $cost
        }
    }

    # Normalize to monthly
    $keys = @($costLookup.Keys)
    foreach ($key in $keys) {
        $costLookup[$key] = [math]::Round($costLookup[$key] * $monthFactor, 2)
    }

    Write-Log "Built cost lookup for $($costLookup.Count) unique resources"
} else {
    Write-Log "No cost CSV provided — using rate-card estimates only" -Level "WARN"
}

# ── Calculate Savings ────────────────────────────────────────────────────────

$detailResults = @()

foreach ($candidate in $actionable) {
    $resourceType = $candidate.ResourceType
    $resourceName = $candidate.ResourceName
    $script = $candidate.Script
    $monthlySavings = 0
    $source = "none"

    # Try direct cost lookup by constructing a partial resource ID match
    $matched = $false
    if ($costLookup.Count -gt 0) {
        # Find cost entries matching this resource name + resource group
        $matchKeys = $costLookup.Keys | Where-Object {
            $_ -like "*/$($candidate.ResourceGroup.ToLower())/*" -and
            $_ -like "*/$($resourceName.ToLower())"
        }
        if ($matchKeys) {
            $monthlySavings = ($matchKeys | ForEach-Object { $costLookup[$_] } | Measure-Object -Sum).Sum
            $source = "cost-data"
            $matched = $true
        }
    }

    # Fall back to rate card
    if (-not $matched) {
        $rateKey = $null
        # Try exact resource type match first, then fallback to base type
        foreach ($key in $defaultRateCard.Keys | Sort-Object { $_.Length } -Descending) {
            if ($resourceType -like "$key*" -or $resourceType -eq $key) {
                $rateKey = $key
                break
            }
        }
        if ($rateKey) {
            $monthlySavings = $defaultRateCard[$rateKey]
            $source = "rate-card ($rateKey)"
        }
    }

    $detailResults += [PSCustomObject]@{
        Script        = $script
        ResourceType  = $resourceType
        ResourceName  = $resourceName
        ResourceGroup = $candidate.ResourceGroup
        Subscription  = $candidate.Subscription
        MonthlySavings = [math]::Round($monthlySavings, 2)
        Source        = $source
    }
}

# ── Category Summary ─────────────────────────────────────────────────────────

# Map scripts to user-friendly category names
$categoryMap = @{
    "Remove-StoppedVMs"        = "Stopped VMs (disk costs)"
    "Remove-OldSnapshots"      = "Old Snapshots"
    "Remove-UnattachedDisks"   = "Unattached Disks"
    "Remove-UnusedPublicIPs"   = "Unused Public IPs"
    "Remove-UnusedNSGs"        = "Unused NSGs"
    "Remove-EmptyResourceGroups" = "Empty Resource Groups"
    "Tag-CleanupCandidates"    = "Tagged for Cleanup"
}

$categorySummary = $detailResults |
    Group-Object Script |
    ForEach-Object {
        $scriptName = $_.Name
        $items = $_.Group
        $totalSavings = ($items | Measure-Object -Property MonthlySavings -Sum).Sum
        $fromCost = ($items | Where-Object { $_.Source -eq "cost-data" }).Count
        $fromRate = ($items | Where-Object { $_.Source -like "rate-card*" }).Count

        [PSCustomObject]@{
            Category        = if ($categoryMap[$scriptName]) { $categoryMap[$scriptName] } else { $scriptName }
            Count           = $items.Count
            EstMonthlySavings = [math]::Round($totalSavings, 2)
            FromCostData    = $fromCost
            FromRateCard    = $fromRate
            Notes           = if ($totalSavings -eq 0) { "Governance clutter only" } else { "" }
        }
    } |
    Sort-Object EstMonthlySavings -Descending

# Add total row
$totalSavings = ($categorySummary | Measure-Object -Property EstMonthlySavings -Sum).Sum
$totalCount = ($categorySummary | Measure-Object -Property Count -Sum).Sum

$categorySummary += [PSCustomObject]@{
    Category        = "TOTAL"
    Count           = $totalCount
    EstMonthlySavings = [math]::Round($totalSavings, 2)
    FromCostData    = ($categorySummary | Measure-Object -Property FromCostData -Sum).Sum
    FromRateCard    = ($categorySummary | Measure-Object -Property FromRateCard -Sum).Sum
    Notes           = "Estimated monthly savings"
}

# ── Output ───────────────────────────────────────────────────────────────────

Write-Log ""
Write-Log "=== Cost Savings Projection ==="
$categorySummary | Format-Table -AutoSize -Property Category, Count,
    @{N="Est. Monthly Savings";E={"`${0:N2}" -f $_.EstMonthlySavings}},
    FromCostData, FromRateCard, Notes |
    Out-String | ForEach-Object { Write-Log $_ }

# Export detail CSV
if ($detailResults.Count -gt 0) {
    $detailResults | Export-Csv -Path $OutputPath -NoTypeInformation
    Write-Log "Detail CSV: $OutputPath ($($detailResults.Count) rows)"
}

# Export summary CSV alongside the detail
$summaryPath = $OutputPath -replace '\.csv$', '-summary.csv'
$categorySummary | Export-Csv -Path $summaryPath -NoTypeInformation
Write-Log "Summary CSV: $summaryPath"

Write-Log "=== Projection Complete ==="

return $categorySummary

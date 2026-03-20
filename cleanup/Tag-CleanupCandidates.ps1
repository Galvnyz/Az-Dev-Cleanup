<#
.SYNOPSIS
    Tags resources as cleanup candidates with a future deletion date.

.DESCRIPTION
    Takes a CSV of resource IDs (from discovery scripts) and applies
    cleanup-candidate tags with a configurable grace period.
    This enables a "tag and notify" workflow before deletion.

.PARAMETER InputCsv
    Path to CSV file with a 'ResourceId' column (or pipe from other scripts).

.PARAMETER GracePeriodDays
    Number of days before the resource is eligible for deletion. Default: 30.

.PARAMETER Tag
    Tag name to apply. Default: "cleanup-status".

.EXAMPLE
    # Tag resources from a discovery export
    .\Tag-CleanupCandidates.ps1 -InputCsv ./orphaned-resources.csv -GracePeriodDays 60

    # Pipe from another script
    Get-OrphanedResources | .\Tag-CleanupCandidates.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [string]$ResourceId,

    [Parameter()]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$InputCsv,

    [Parameter()]
    [ValidateRange(1, 365)]
    [int]$GracePeriodDays = 30
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$timestamp] [$Level] $Message"
}

# ── Main ─────────────────────────────────────────────────────────────────────

$deletionDate = (Get-Date).AddDays($GracePeriodDays).ToString("yyyy-MM-dd")

# Collect resource IDs from CSV or pipeline
$resourceIds = @()
if ($InputCsv) {
    $csv = Import-Csv -Path $InputCsv
    # Support multiple possible column names
    $idColumn = ($csv[0].PSObject.Properties.Name | Where-Object { $_ -match "ResourceId|Id|resourceId" })[0]
    $resourceIds = $csv | ForEach-Object { $_.$idColumn }
} elseif ($ResourceId) {
    $resourceIds = @($ResourceId)
}

if ($resourceIds.Count -eq 0) {
    Write-Log "No resource IDs provided. Use -InputCsv or pipe ResourceId values." -Level "WARN"
    return
}

Write-Log "Tagging $($resourceIds.Count) resource(s) as cleanup candidates (deletion date: $deletionDate)"

$tagged = 0
foreach ($rid in $resourceIds) {
    if ([string]::IsNullOrWhiteSpace($rid)) { continue }

    if ($PSCmdlet.ShouldProcess($rid, "Apply cleanup tags")) {
        try {
            $resource = Get-AzResource -ResourceId $rid -ErrorAction Stop
            $tags = $resource.Tags
            if ($null -eq $tags) { $tags = @{} }

            $tags["cleanup-status"] = "candidate"
            $tags["cleanup-date"] = $deletionDate
            $tags["cleanup-tagged-on"] = (Get-Date).ToString("yyyy-MM-dd")

            Set-AzResource -ResourceId $rid -Tag $tags -Force -ErrorAction Stop
            Write-Log "Tagged: $($resource.Name) (delete after $deletionDate)" -Level "TAG"
            $tagged++
        } catch {
            Write-Log "Failed to tag $rid : $_" -Level "ERROR"
        }
    }
}

Write-Log "Tagging complete. Tagged: $tagged / $($resourceIds.Count)"

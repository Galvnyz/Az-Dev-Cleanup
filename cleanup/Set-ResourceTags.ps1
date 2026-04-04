<#
.SYNOPSIS
    Applies tags to Azure resources using filters, CSV input, and optional rule-based mapping.

.DESCRIPTION
    A unified tagging tool that can apply any combination of tags to Azure resources
    selected via CSV input, pipeline, or live query filters. Supports an optional JSON
    rules file for conditional tag mapping based on resource properties.

    Tags are always merged — existing tag values are never overwritten or removed.

.PARAMETER Tags
    Hashtable of explicit tag key-value pairs to apply. These take highest priority,
    overriding rules and defaults.

.PARAMETER InputCsv
    Path to CSV file with a 'ResourceId' column (from discovery scripts).

.PARAMETER ResourceId
    Pipeline input — one or more Azure resource IDs.

.PARAMETER ResourceType
    Filter by Azure resource type (e.g., 'Microsoft.Compute/virtualMachines').
    Supports wildcards.

.PARAMETER ResourceGroup
    Filter by resource group name. Supports wildcards.

.PARAMETER Subscription
    Filter by subscription name or ID.

.PARAMETER Location
    Filter by Azure region. Supports wildcards.

.PARAMETER TagFilter
    Filter by existing tag values (e.g., @{environment='dev'}).

.PARAMETER Untagged
    Select only resources with zero tags.

.PARAMETER MissingTags
    Select resources missing one or more specific tag keys.

.PARAMETER MinAgeDays
    Select resources older than N days (based on createdTime property).

.PARAMETER RulesFile
    Path to JSON rules file for conditional tag mapping.

.PARAMETER BatchSize
    Number of resources to process per batch. Pauses between batches for
    confirmation unless -Force is specified. Default: 50.

.PARAMETER SummaryOnly
    Count matching resources grouped by type, subscription, and missing tags.
    No tagging is performed.

.PARAMETER Force
    Skip batch pause confirmations.

.EXAMPLE
    # Tag all untagged resources with owner and project
    .\Set-ResourceTags.ps1 -Untagged -Tags @{owner='platform-team'; project='infra'} -WhatIf

.EXAMPLE
    # Apply rules-based tagging to resources missing the owner tag
    .\Set-ResourceTags.ps1 -MissingTags 'owner' -RulesFile ../policies/tagging-rules.json

.EXAMPLE
    # Tag resources from a discovery CSV
    .\Set-ResourceTags.ps1 -InputCsv ./orphaned-resources.csv -Tags @{cleanup-status='candidate'; cleanup-date='+30d'}

.EXAMPLE
    # Summary of untagged resources without applying anything
    .\Set-ResourceTags.ps1 -Untagged -SummaryOnly

.EXAMPLE
    # Pipeline input from another script
    Get-OrphanedResources | .\Set-ResourceTags.ps1 -RulesFile ../policies/tagging-rules.json -Force
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'LiveQuery')]
param(
    [Parameter()]
    [hashtable]$Tags,

    [Parameter(Mandatory, ParameterSetName = 'CsvInput')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$InputCsv,

    [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName, ParameterSetName = 'PipelineInput')]
    [string[]]$ResourceId,

    [Parameter(ParameterSetName = 'LiveQuery')]
    [string]$ResourceType,

    [Parameter(ParameterSetName = 'LiveQuery')]
    [string]$ResourceGroup,

    [Parameter(ParameterSetName = 'LiveQuery')]
    [string]$Subscription,

    [Parameter(ParameterSetName = 'LiveQuery')]
    [string]$Location,

    [Parameter(ParameterSetName = 'LiveQuery')]
    [hashtable]$TagFilter,

    [Parameter(ParameterSetName = 'LiveQuery')]
    [switch]$Untagged,

    [Parameter(ParameterSetName = 'LiveQuery')]
    [string[]]$MissingTags,

    [Parameter(ParameterSetName = 'LiveQuery')]
    [ValidateRange(1, 3650)]
    [int]$MinAgeDays,

    [Parameter()]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$RulesFile,

    [Parameter()]
    [ValidateRange(1, 1000)]
    [int]$BatchSize = 50,

    [Parameter()]
    [switch]$SummaryOnly,

    [Parameter()]
    [switch]$Force
)

begin {
    $ErrorActionPreference = "Stop"
    $pipelineIds = [System.Collections.Generic.List[string]]::new()

    # ── Logging ──────────────────────────────────────────────────────────────

    function Write-Log {
        param([string]$Message, [string]$Level = "INFO")
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $color = switch ($Level) {
            "TAG"   { "Green"  }
            "SKIP"  { "DarkGray" }
            "WARN"  { "Yellow" }
            "ERROR" { "Red"    }
            default { "White"  }
        }
        Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
    }

    # ── Rules Engine ─────────────────────────────────────────────────────────

    function Import-TagRules {
        param([string]$Path)

        $content = Get-Content -Path $Path -Raw | ConvertFrom-Json -AsHashtable
        if (-not $content.ContainsKey('rules') -or $content['rules'] -isnot [System.Collections.IList]) {
            throw "Rules file must contain a 'rules' array: $Path"
        }
        foreach ($rule in $content['rules']) {
            if (-not $rule.ContainsKey('name'))  { throw "Each rule must have a 'name' property" }
            if (-not $rule.ContainsKey('match')) { throw "Rule '$($rule['name'])' must have a 'match' property" }
            if (-not $rule.ContainsKey('tags'))  { throw "Rule '$($rule['name'])' must have a 'tags' property" }
        }
        return $content
    }

    function Test-PatternMatch {
        param([string]$Value, [string]$Pattern)

        if ($Pattern.StartsWith('regex:')) {
            $regexPattern = $Pattern.Substring(6)
            return $Value -match $regexPattern
        }
        return $Value -like $Pattern
    }

    function Test-RuleMatch {
        param([hashtable]$Rule, [hashtable]$Resource)

        $matchBlock = $Rule['match']
        $matchMode  = if ($Rule.ContainsKey('matchMode')) { $Rule['matchMode'] } else { 'all' }
        $results    = [System.Collections.Generic.List[bool]]::new()

        if ($matchBlock.ContainsKey('resourceGroup')) {
            $results.Add((Test-PatternMatch -Value $Resource['resourceGroup'] -Pattern $matchBlock['resourceGroup']))
        }
        if ($matchBlock.ContainsKey('resourceType')) {
            $results.Add((Test-PatternMatch -Value $Resource['type'] -Pattern $matchBlock['resourceType']))
        }
        if ($matchBlock.ContainsKey('subscription')) {
            $results.Add((Test-PatternMatch -Value $Resource['subscriptionName'] -Pattern $matchBlock['subscription']))
        }
        if ($matchBlock.ContainsKey('location')) {
            $results.Add((Test-PatternMatch -Value $Resource['location'] -Pattern $matchBlock['location']))
        }
        if ($matchBlock.ContainsKey('hasTag')) {
            $tagKey = $matchBlock['hasTag']
            $hasTags = $Resource['tags'] -is [hashtable] -and $Resource['tags'].ContainsKey($tagKey)
            $results.Add($hasTags)
        }
        if ($matchBlock.ContainsKey('missingTags')) {
            $missing = $matchBlock['missingTags']
            $resourceTags = if ($Resource['tags'] -is [hashtable]) { $Resource['tags'] } else { @{} }
            $anyMissing = $false
            foreach ($key in $missing) {
                if (-not $resourceTags.ContainsKey($key)) { $anyMissing = $true; break }
            }
            $results.Add($anyMissing)
        }
        if ($matchBlock.ContainsKey('tagEquals')) {
            $tagEquals = $matchBlock['tagEquals']
            $resourceTags = if ($Resource['tags'] -is [hashtable]) { $Resource['tags'] } else { @{} }
            $allEqual = $true
            foreach ($key in $tagEquals.Keys) {
                if (-not $resourceTags.ContainsKey($key) -or $resourceTags[$key] -ne $tagEquals[$key]) {
                    $allEqual = $false; break
                }
            }
            $results.Add($allEqual)
        }
        if ($matchBlock.ContainsKey('createdBy')) {
            $createdBy = if ($Resource.ContainsKey('createdBy')) { $Resource['createdBy'] } else { '' }
            $results.Add((Test-PatternMatch -Value $createdBy -Pattern $matchBlock['createdBy']))
        }

        if ($results.Count -eq 0) { return $false }

        if ($matchMode -eq 'any') {
            return ($results -contains $true)
        }
        return ($results -notcontains $false)
    }

    function Resolve-SpecialValue {
        param([string]$Value, [hashtable]$Resource)

        if ($Value -match '^\+(\d+)d$') {
            return (Get-Date).AddDays([int]$Matches[1]).ToString("yyyy-MM-dd")
        }

        $resolved = $Value
        $resolved = $resolved -creplace '\{today\}',         (Get-Date).ToString("yyyy-MM-dd")
        $resolved = $resolved -creplace '\{createdBy\}',      ($Resource['createdBy'] ?? 'unknown')
        $resolved = $resolved -creplace '\{resourceGroup\}',  ($Resource['resourceGroup'] ?? '')
        $resolved = $resolved -creplace '\{subscription\}',   ($Resource['subscriptionName'] ?? '')

        return $resolved
    }

    function Resolve-ResourceTags {
        param(
            [hashtable]$Resource,
            [hashtable]$RulesConfig,
            [hashtable]$ExplicitTags
        )

        $existingTags = if ($Resource['tags'] -is [hashtable]) {
            [hashtable]$Resource['tags'].Clone()
        } else { @{} }

        $newTags = @{}

        # 1. Evaluate rules (first match per key wins)
        if ($null -ne $RulesConfig -and $RulesConfig.ContainsKey('rules')) {
            foreach ($rule in $RulesConfig['rules']) {
                if (Test-RuleMatch -Rule $rule -Resource $Resource) {
                    foreach ($key in $rule['tags'].Keys) {
                        if (-not $newTags.ContainsKey($key)) {
                            $newTags[$key] = @{
                                Value  = Resolve-SpecialValue -Value $rule['tags'][$key] -Resource $Resource
                                Source = $rule['name']
                            }
                        }
                    }
                }
            }
        }

        # 2. Apply defaults (fill unset keys)
        if ($null -ne $RulesConfig -and $RulesConfig.ContainsKey('defaults')) {
            foreach ($key in $RulesConfig['defaults'].Keys) {
                if (-not $newTags.ContainsKey($key)) {
                    $newTags[$key] = @{
                        Value  = Resolve-SpecialValue -Value $RulesConfig['defaults'][$key] -Resource $Resource
                        Source = 'default'
                    }
                }
            }
        }

        # 3. Apply explicit tags (override rules and defaults)
        if ($null -ne $ExplicitTags) {
            foreach ($key in $ExplicitTags.Keys) {
                $newTags[$key] = @{
                    Value  = Resolve-SpecialValue -Value ([string]$ExplicitTags[$key]) -Resource $Resource
                    Source = 'explicit'
                }
            }
        }

        # 4. Compute diff — merge-only: skip keys that already exist
        $diff = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($key in $newTags.Keys) {
            if ($existingTags.ContainsKey($key)) {
                $diff.Add(@{
                    TagKey       = $key
                    CurrentValue = $existingTags[$key]
                    NewValue     = $newTags[$key].Value
                    Source       = $newTags[$key].Source
                    Action       = 'Skip'
                })
            } else {
                $diff.Add(@{
                    TagKey       = $key
                    CurrentValue = $null
                    NewValue     = $newTags[$key].Value
                    Source       = $newTags[$key].Source
                    Action       = 'Add'
                })
            }
        }

        return , $diff
    }

    # ── Live Query Builder ───────────────────────────────────────────────────

    function Build-ResourceGraphQuery {
        $clauses = [System.Collections.Generic.List[string]]::new()
        $clauses.Add("resources")

        if ($ResourceType) {
            if ($ResourceType.Contains('*') -or $ResourceType.StartsWith('regex:')) {
                $clauses.Add("| where type matches regex '(?i)$($ResourceType -replace '\*','.*')'")
            } else {
                $clauses.Add("| where type =~ '$ResourceType'")
            }
        }
        if ($ResourceGroup) {
            if ($ResourceGroup.Contains('*') -or $ResourceGroup.StartsWith('regex:')) {
                $clauses.Add("| where resourceGroup matches regex '(?i)$($ResourceGroup -replace '\*','.*')'")
            } else {
                $clauses.Add("| where resourceGroup =~ '$ResourceGroup'")
            }
        }
        if ($Location) {
            if ($Location.Contains('*')) {
                $clauses.Add("| where location matches regex '(?i)$($Location -replace '\*','.*')'")
            } else {
                $clauses.Add("| where location =~ '$Location'")
            }
        }
        if ($Untagged) {
            $clauses.Add("| where isnull(tags) or tags == '{}' or array_length(bag_keys(tags)) == 0")
        }
        if ($MissingTags) {
            foreach ($tagKey in $MissingTags) {
                $clauses.Add("| where not(tags contains '$tagKey')")
            }
        }
        if ($TagFilter) {
            foreach ($key in $TagFilter.Keys) {
                $clauses.Add("| where tostring(tags['$key']) == '$($TagFilter[$key])'")
            }
        }
        if ($MinAgeDays) {
            $cutoffDate = (Get-Date).AddDays(-$MinAgeDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
            $clauses.Add("| where properties.createdTime < datetime('$cutoffDate')")
        }

        $clauses.Add("| project id, name, type, resourceGroup, subscriptionId, location, tags")

        return ($clauses -join "`n")
    }
}

process {
    if ($PSCmdlet.ParameterSetName -eq 'PipelineInput' -and $ResourceId) {
        foreach ($rid in $ResourceId) {
            if (-not [string]::IsNullOrWhiteSpace($rid)) {
                $pipelineIds.Add($rid)
            }
        }
    }
}

end {
    # ── Validate Inputs ──────────────────────────────────────────────────────

    $hasInputSource = $false
    $allResourceIds = [System.Collections.Generic.List[string]]::new()

    # CSV Input
    if ($InputCsv) {
        $csv = Import-Csv -Path $InputCsv
        $idColumn = ($csv[0].PSObject.Properties.Name | Where-Object { $_ -match '^(ResourceId|Id|resourceId)$' })[0]
        if (-not $idColumn) {
            Write-Log "CSV file must contain a 'ResourceId' or 'Id' column." -Level "ERROR"
            return
        }
        foreach ($row in $csv) {
            $rid = $row.$idColumn
            if (-not [string]::IsNullOrWhiteSpace($rid)) { $allResourceIds.Add($rid) }
        }
        $hasInputSource = $true
        Write-Log "Loaded $($allResourceIds.Count) resource(s) from CSV: $InputCsv"
    }

    # Pipeline Input
    if ($pipelineIds.Count -gt 0) {
        foreach ($rid in $pipelineIds) { $allResourceIds.Add($rid) }
        $hasInputSource = $true
        Write-Log "Received $($pipelineIds.Count) resource(s) from pipeline"
    }

    # Live Query
    if ($PSCmdlet.ParameterSetName -eq 'LiveQuery') {
        $hasFilter = $ResourceType -or $ResourceGroup -or $Subscription -or $Location -or
                     $Untagged -or $MissingTags -or $TagFilter -or $MinAgeDays
        if ($hasFilter) {
            $kql = Build-ResourceGraphQuery
            Write-Log "Querying Azure Resource Graph..."

            $graphParams = @{ Query = $kql; First = 1000 }
            if ($Subscription) {
                $sub = Get-AzSubscription -SubscriptionName $Subscription -ErrorAction SilentlyContinue
                if ($sub) { $graphParams['Subscription'] = $sub.Id }
            }

            $results = Search-AzGraph @graphParams
            foreach ($r in $results) {
                if (-not [string]::IsNullOrWhiteSpace($r.id)) { $allResourceIds.Add($r.id) }
            }
            $hasInputSource = $true
            Write-Log "Resource Graph returned $($results.Count) resource(s)"
        }
    }

    if (-not $hasInputSource -or $allResourceIds.Count -eq 0) {
        Write-Log "No resources found. Provide -InputCsv, pipe ResourceId values, or specify filters." -Level "WARN"
        return
    }

    # Deduplicate
    $allResourceIds = [System.Collections.Generic.List[string]]($allResourceIds | Select-Object -Unique)
    Write-Log "Total unique targets: $($allResourceIds.Count)"

    # ── Summary Only Mode ────────────────────────────────────────────────────

    if ($SummaryOnly) {
        Write-Log "Summary mode — collecting resource metadata..."
        $governanceTags = @('owner', 'project', 'environment', 'expiry-date')
        $summaryData = [System.Collections.Generic.List[hashtable]]::new()

        foreach ($rid in $allResourceIds) {
            try {
                $resource = Get-AzResource -ResourceId $rid -ErrorAction Stop
                $existingTags = if ($null -ne $resource.Tags) { $resource.Tags } else { @{} }
                $missing = $governanceTags | Where-Object { -not $existingTags.ContainsKey($_) }

                $summaryData.Add(@{
                    ResourceType = $resource.ResourceType
                    Subscription = (($rid -split '/')[2])
                    MissingTags  = ($missing -join ', ')
                })
            } catch {
                Write-Log "Could not read resource: $rid — $_" -Level "WARN"
            }
        }

        $grouped = $summaryData | Group-Object -Property ResourceType, Subscription
        Write-Host ""
        Write-Host "Resource Type                                  | Subscription                         | Count | Missing Tags" -ForegroundColor Cyan
        Write-Host ("-" * 120) -ForegroundColor DarkGray
        foreach ($group in $grouped) {
            $parts = $group.Name -split ', '
            $missingList = ($group.Group | ForEach-Object { $_.MissingTags } | Select-Object -Unique) -join '; '
            Write-Host ("{0,-46} | {1,-36} | {2,5} | {3}" -f $parts[0], $parts[1], $group.Count, $missingList)
        }
        Write-Host ""
        Write-Log "Summary complete. Total resources: $($allResourceIds.Count)"
        return
    }

    # ── Validate Tag Source ──────────────────────────────────────────────────

    if (-not $Tags -and -not $RulesFile) {
        Write-Log "No tag source specified. Provide -Tags and/or -RulesFile." -Level "ERROR"
        return
    }

    # ── Load Rules ───────────────────────────────────────────────────────────

    $rulesConfig = $null
    if ($RulesFile) {
        $rulesConfig = Import-TagRules -Path $RulesFile
        $ruleCount = $rulesConfig['rules'].Count
        $defaultCount = if ($rulesConfig.ContainsKey('defaults')) { $rulesConfig['defaults'].Count } else { 0 }
        Write-Log "Loaded $ruleCount rule(s) and $defaultCount default(s) from: $RulesFile"
    }

    # ── Process in Batches ───────────────────────────────────────────────────

    $totalTagged  = 0
    $totalSkipped = 0
    $totalFailed  = 0
    $outputRows   = [System.Collections.Generic.List[hashtable]]::new()
    $batchCount   = [math]::Ceiling($allResourceIds.Count / $BatchSize)
    $isWhatIf     = $WhatIfPreference

    for ($batchIndex = 0; $batchIndex -lt $batchCount; $batchIndex++) {
        $start = $batchIndex * $BatchSize
        $end   = [math]::Min($start + $BatchSize, $allResourceIds.Count)
        $batch = $allResourceIds[$start..($end - 1)]

        Write-Log "Processing batch $($batchIndex + 1) of $batchCount ($($batch.Count) resources)..."

        foreach ($rid in $batch) {
            try {
                $resource = Get-AzResource -ResourceId $rid -ErrorAction Stop
                $resourceData = @{
                    id               = $resource.ResourceId
                    name             = $resource.Name
                    type             = $resource.ResourceType
                    resourceGroup    = $resource.ResourceGroupName
                    location         = $resource.Location
                    subscriptionName = (($rid -split '/')[2])
                    tags             = if ($null -ne $resource.Tags) { $resource.Tags } else { @{} }
                    createdBy        = ''
                }

                $diff = Resolve-ResourceTags -Resource $resourceData -RulesConfig $rulesConfig -ExplicitTags $Tags

                $addTags = $diff | Where-Object { $_.Action -eq 'Add' }
                if ($addTags.Count -eq 0) {
                    Write-Log "[Skip] $($resource.Name) — no new tags to apply" -Level "SKIP"
                    $totalSkipped++
                    foreach ($d in $diff) {
                        $outputRows.Add(@{
                            ResourceId   = $rid
                            ResourceName = $resource.Name
                            TagKey       = $d.TagKey
                            CurrentValue = $d.CurrentValue
                            NewValue     = $d.NewValue
                            Source       = $d.Source
                            Status       = 'Skipped'
                            Error        = ''
                        })
                    }
                    continue
                }

                $tagsToMerge = @{}
                foreach ($d in $addTags) { $tagsToMerge[$d.TagKey] = $d.NewValue }
                $tagNames = ($addTags | ForEach-Object { $_.TagKey }) -join ', '

                if ($PSCmdlet.ShouldProcess($rid, "Add tags: $tagNames")) {
                    Update-AzTag -ResourceId $rid -Tag $tagsToMerge -Operation Merge -ErrorAction Stop | Out-Null
                    Write-Log "[Tagged] $($resource.Name) — +$($addTags.Count) tags ($tagNames)" -Level "TAG"
                    $totalTagged++
                    $status = 'Tagged'
                } else {
                    Write-Log "[WhatIf] $($resource.Name) — would add $($addTags.Count) tags ($tagNames)" -Level "TAG"
                    $totalTagged++
                    $status = 'WhatIf'
                }

                foreach ($d in $diff) {
                    $outputRows.Add(@{
                        ResourceId   = $rid
                        ResourceName = $resource.Name
                        TagKey       = $d.TagKey
                        CurrentValue = $d.CurrentValue
                        NewValue     = $d.NewValue
                        Source       = $d.Source
                        Status       = if ($d.Action -eq 'Add') { $status } else { 'Skipped' }
                        Error        = ''
                    })
                }
            } catch {
                Write-Log "[Failed] $rid — $_" -Level "ERROR"
                $totalFailed++
                $outputRows.Add(@{
                    ResourceId   = $rid
                    ResourceName = ''
                    TagKey       = ''
                    CurrentValue = ''
                    NewValue     = ''
                    Source       = ''
                    Status       = 'Failed'
                    Error        = $_.ToString()
                })
            }
        }

        # Batch pause (unless last batch, Force, or WhatIf)
        if ($batchIndex -lt ($batchCount - 1) -and -not $Force -and -not $isWhatIf) {
            $remaining = $allResourceIds.Count - $end
            Write-Host ""
            $response = Read-Host "Batch $($batchIndex + 1) complete. $remaining resources remaining. Continue? (Y/n)"
            if ($response -and $response -notmatch '^[Yy]') {
                Write-Log "User cancelled after batch $($batchIndex + 1)." -Level "WARN"
                break
            }
        }
    }

    # ── Export Results ────────────────────────────────────────────────────────

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $prefix = if ($isWhatIf) { "tagging-preview" } else { "tagging-results" }
    $outputPath = Join-Path -Path (Get-Location) -ChildPath "$prefix-$timestamp.csv"

    if ($outputRows.Count -gt 0) {
        $outputRows | ForEach-Object { [PSCustomObject]$_ } |
            Select-Object ResourceId, ResourceName, TagKey, CurrentValue, NewValue, Source, Status, Error |
            Export-Csv -Path $outputPath -NoTypeInformation
        Write-Log "Results exported to: $outputPath"
    }

    # ── Summary ──────────────────────────────────────────────────────────────

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Tagged: $totalTagged | Skipped: $totalSkipped | Failed: $totalFailed" -ForegroundColor White
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

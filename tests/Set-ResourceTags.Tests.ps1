BeforeAll {
    # Stub Az cmdlets so the script can be dot-sourced
    function Get-AzResource { }
    function Update-AzTag { }
    function Search-AzGraph { }
    function Get-AzSubscription { }

    # Extract internal functions from the script using AST parsing
    $scriptPath = "$PSScriptRoot/../cleanup/Set-ResourceTags.ps1"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)

    $functionsToExtract = @(
        'Import-TagRules',
        'Test-PatternMatch',
        'Test-RuleMatch',
        'Resolve-SpecialValue',
        'Resolve-ResourceTags'
    )

    $functionDefs = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -in $functionsToExtract
    }, $true)

    foreach ($funcDef in $functionDefs) {
        Invoke-Expression $funcDef.Extent.Text
    }
}

# ── Parameter Validation ─────────────────────────────────────────────────────

Describe 'Set-ResourceTags — Parameter Validation' {
    It 'should reject non-existent CSV path' {
        { & "$PSScriptRoot/../cleanup/Set-ResourceTags.ps1" -InputCsv '/nonexistent/path.csv' -Tags @{owner='test'} -WhatIf } |
            Should -Throw
    }

    It 'should reject non-existent rules file path' {
        { & "$PSScriptRoot/../cleanup/Set-ResourceTags.ps1" -Untagged -RulesFile '/nonexistent/rules.json' -WhatIf } |
            Should -Throw
    }

    It 'should reject BatchSize less than 1' {
        { & "$PSScriptRoot/../cleanup/Set-ResourceTags.ps1" -Untagged -Tags @{owner='test'} -BatchSize 0 -WhatIf } |
            Should -Throw
    }

    It 'should reject BatchSize over 1000' {
        { & "$PSScriptRoot/../cleanup/Set-ResourceTags.ps1" -Untagged -Tags @{owner='test'} -BatchSize 1001 -WhatIf } |
            Should -Throw
    }

    It 'should reject MinAgeDays less than 1' {
        { & "$PSScriptRoot/../cleanup/Set-ResourceTags.ps1" -MinAgeDays 0 -Tags @{owner='test'} -WhatIf } |
            Should -Throw
    }
}

# ── Test-PatternMatch ────────────────────────────────────────────────────────

Describe 'Test-PatternMatch' {
    It 'should match simple wildcard' {
        Test-PatternMatch -Value 'rg-prod-eastus' -Pattern '*-prod-*' | Should -BeTrue
    }

    It 'should not match non-matching wildcard' {
        Test-PatternMatch -Value 'rg-dev-eastus' -Pattern '*-prod-*' | Should -BeFalse
    }

    It 'should match regex pattern' {
        Test-PatternMatch -Value 'alpha-staging-01' -Pattern 'regex:^(alpha|beta)-staging-' | Should -BeTrue
    }

    It 'should not match non-matching regex' {
        Test-PatternMatch -Value 'gamma-staging-01' -Pattern 'regex:^(alpha|beta)-staging-' | Should -BeFalse
    }

    It 'should match exact string with no wildcards' {
        Test-PatternMatch -Value 'eastus' -Pattern 'eastus' | Should -BeTrue
    }
}

# ── Test-RuleMatch ───────────────────────────────────────────────────────────

Describe 'Test-RuleMatch' {
    BeforeAll {
        $testResource = @{
            id               = '/subscriptions/sub-1/resourceGroups/rg-prod-eastus/providers/Microsoft.Compute/virtualMachines/vm1'
            name             = 'vm1'
            type             = 'Microsoft.Compute/virtualMachines'
            resourceGroup    = 'rg-prod-eastus'
            location         = 'eastus'
            subscriptionName = 'sub-1'
            tags             = @{ environment = 'production' }
            createdBy        = 'user@contoso.com'
        }
    }

    It 'should match with AND logic (all conditions true)' {
        $rule = @{
            name  = 'test'
            matchMode = 'all'
            match = @{
                resourceGroup = '*-prod-*'
                location      = 'eastus'
            }
            tags  = @{ owner = 'test' }
        }
        Test-RuleMatch -Rule $rule -Resource $testResource | Should -BeTrue
    }

    It 'should not match AND logic when one condition fails' {
        $rule = @{
            name  = 'test'
            matchMode = 'all'
            match = @{
                resourceGroup = '*-prod-*'
                location      = 'westus'
            }
            tags  = @{ owner = 'test' }
        }
        Test-RuleMatch -Rule $rule -Resource $testResource | Should -BeFalse
    }

    It 'should match with OR logic when one condition is true' {
        $rule = @{
            name  = 'test'
            matchMode = 'any'
            match = @{
                resourceGroup = '*-dev-*'
                location      = 'eastus'
            }
            tags  = @{ owner = 'test' }
        }
        Test-RuleMatch -Rule $rule -Resource $testResource | Should -BeTrue
    }

    It 'should not match OR logic when all conditions fail' {
        $rule = @{
            name  = 'test'
            matchMode = 'any'
            match = @{
                resourceGroup = '*-dev-*'
                location      = 'westus'
            }
            tags  = @{ owner = 'test' }
        }
        Test-RuleMatch -Rule $rule -Resource $testResource | Should -BeFalse
    }

    It 'should default to AND matchMode when not specified' {
        $rule = @{
            name  = 'test'
            match = @{
                resourceGroup = '*-prod-*'
                location      = 'westus'
            }
            tags  = @{ owner = 'test' }
        }
        Test-RuleMatch -Rule $rule -Resource $testResource | Should -BeFalse
    }

    It 'should match missingTags condition' {
        $rule = @{
            name  = 'test'
            match = @{ missingTags = @('owner', 'project') }
            tags  = @{ owner = 'test' }
        }
        Test-RuleMatch -Rule $rule -Resource $testResource | Should -BeTrue
    }

    It 'should not match missingTags when all tags present' {
        $rule = @{
            name  = 'test'
            match = @{ missingTags = @('environment') }
            tags  = @{ owner = 'test' }
        }
        Test-RuleMatch -Rule $rule -Resource $testResource | Should -BeFalse
    }

    It 'should match hasTag condition' {
        $rule = @{
            name  = 'test'
            match = @{ hasTag = 'environment' }
            tags  = @{ owner = 'test' }
        }
        Test-RuleMatch -Rule $rule -Resource $testResource | Should -BeTrue
    }

    It 'should match tagEquals condition' {
        $rule = @{
            name  = 'test'
            match = @{ tagEquals = @{ environment = 'production' } }
            tags  = @{ owner = 'test' }
        }
        Test-RuleMatch -Rule $rule -Resource $testResource | Should -BeTrue
    }

    It 'should not match tagEquals with wrong value' {
        $rule = @{
            name  = 'test'
            match = @{ tagEquals = @{ environment = 'dev' } }
            tags  = @{ owner = 'test' }
        }
        Test-RuleMatch -Rule $rule -Resource $testResource | Should -BeFalse
    }

    It 'should match createdBy condition' {
        $rule = @{
            name  = 'test'
            match = @{ createdBy = '*@contoso.com' }
            tags  = @{ owner = 'test' }
        }
        Test-RuleMatch -Rule $rule -Resource $testResource | Should -BeTrue
    }

    It 'should match resourceType condition' {
        $rule = @{
            name  = 'test'
            match = @{ resourceType = 'Microsoft.Compute/*' }
            tags  = @{ owner = 'test' }
        }
        Test-RuleMatch -Rule $rule -Resource $testResource | Should -BeTrue
    }

    It 'should return false when match block is empty' {
        $rule = @{
            name  = 'test'
            match = @{}
            tags  = @{ owner = 'test' }
        }
        Test-RuleMatch -Rule $rule -Resource $testResource | Should -BeFalse
    }
}

# ── Resolve-SpecialValue ────────────────────────────────────────────────────

Describe 'Resolve-SpecialValue' {
    BeforeAll {
        $testResource = @{
            createdBy        = 'alice@contoso.com'
            resourceGroup    = 'rg-prod-01'
            subscriptionName = 'Production'
        }
    }

    It 'should resolve relative date +30d' {
        $result = Resolve-SpecialValue -Value '+30d' -Resource $testResource
        $expected = (Get-Date).AddDays(30).ToString("yyyy-MM-dd")
        $result | Should -Be $expected
    }

    It 'should resolve relative date +90d' {
        $result = Resolve-SpecialValue -Value '+90d' -Resource $testResource
        $expected = (Get-Date).AddDays(90).ToString("yyyy-MM-dd")
        $result | Should -Be $expected
    }

    It 'should resolve {today} placeholder' {
        $result = Resolve-SpecialValue -Value '{today}' -Resource $testResource
        $expected = (Get-Date).ToString("yyyy-MM-dd")
        $result | Should -Be $expected
    }

    It 'should resolve {createdBy} placeholder' {
        $result = Resolve-SpecialValue -Value '{createdBy}' -Resource $testResource
        $result | Should -Be 'alice@contoso.com'
    }

    It 'should resolve {resourceGroup} placeholder' {
        $result = Resolve-SpecialValue -Value '{resourceGroup}' -Resource $testResource
        $result | Should -Be 'rg-prod-01'
    }

    It 'should resolve {subscription} placeholder' {
        $result = Resolve-SpecialValue -Value '{subscription}' -Resource $testResource
        $result | Should -Be 'Production'
    }

    It 'should return plain strings unchanged' {
        $result = Resolve-SpecialValue -Value 'platform-team@contoso.com' -Resource $testResource
        $result | Should -Be 'platform-team@contoso.com'
    }

    It 'should default createdBy to unknown when missing' {
        $resource = @{ resourceGroup = 'rg1'; subscriptionName = 'sub1' }
        $result = Resolve-SpecialValue -Value '{createdBy}' -Resource $resource
        $result | Should -Be 'unknown'
    }
}

# ── Resolve-ResourceTags ────────────────────────────────────────────────────

Describe 'Resolve-ResourceTags' {
    It 'should apply explicit tags' {
        $resource = @{
            type          = 'Microsoft.Compute/virtualMachines'
            resourceGroup = 'rg-test'
            location      = 'eastus'
            tags          = @{}
        }
        $diff = Resolve-ResourceTags -Resource $resource -RulesConfig $null -ExplicitTags @{ owner = 'alice' }
        $diff.Count | Should -Be 1
        $diff[0].TagKey | Should -Be 'owner'
        $diff[0].NewValue | Should -Be 'alice'
        $diff[0].Source | Should -Be 'explicit'
        $diff[0].Action | Should -Be 'Add'
    }

    It 'should skip tags that already exist (merge-only)' {
        $resource = @{
            type          = 'Microsoft.Compute/virtualMachines'
            resourceGroup = 'rg-test'
            location      = 'eastus'
            tags          = @{ owner = 'existing-owner' }
        }
        $diff = Resolve-ResourceTags -Resource $resource -RulesConfig $null -ExplicitTags @{ owner = 'new-owner' }
        $diff.Count | Should -Be 1
        $diff[0].Action | Should -Be 'Skip'
        $diff[0].CurrentValue | Should -Be 'existing-owner'
    }

    It 'should apply rules when no explicit tags given' {
        $resource = @{
            type          = 'Microsoft.Compute/virtualMachines'
            resourceGroup = 'rg-prod-eastus'
            location      = 'eastus'
            tags          = @{}
        }
        $rulesConfig = @{
            rules = @(
                @{
                    name  = 'prod-rule'
                    match = @{ resourceGroup = '*-prod-*' }
                    tags  = @{ environment = 'production' }
                }
            )
        }
        $diff = Resolve-ResourceTags -Resource $resource -RulesConfig $rulesConfig -ExplicitTags $null
        $match = $diff | Where-Object { $_.TagKey -eq 'environment' }
        $match.NewValue | Should -Be 'production'
        $match.Source | Should -Be 'prod-rule'
    }

    It 'should apply defaults for unset keys' {
        $resource = @{
            type          = 'Microsoft.Compute/virtualMachines'
            resourceGroup = 'rg-test'
            location      = 'eastus'
            tags          = @{}
        }
        $rulesConfig = @{
            rules    = @()
            defaults = @{ project = 'unknown'; environment = 'dev' }
        }
        $diff = Resolve-ResourceTags -Resource $resource -RulesConfig $rulesConfig -ExplicitTags $null
        $diff.Count | Should -Be 2
        ($diff | Where-Object { $_.TagKey -eq 'project' }).Source | Should -Be 'default'
    }

    It 'should prioritize explicit over rules over defaults' {
        $resource = @{
            type          = 'Microsoft.Compute/virtualMachines'
            resourceGroup = 'rg-prod-eastus'
            location      = 'eastus'
            tags          = @{}
        }
        $rulesConfig = @{
            rules = @(
                @{
                    name  = 'prod-rule'
                    match = @{ resourceGroup = '*-prod-*' }
                    tags  = @{ owner = 'rule-owner' }
                }
            )
            defaults = @{ owner = 'default-owner' }
        }
        $diff = Resolve-ResourceTags -Resource $resource -RulesConfig $rulesConfig -ExplicitTags @{ owner = 'explicit-owner' }
        $match = $diff | Where-Object { $_.TagKey -eq 'owner' }
        $match.NewValue | Should -Be 'explicit-owner'
        $match.Source | Should -Be 'explicit'
    }

    It 'first matching rule per key wins' {
        $resource = @{
            type          = 'Microsoft.Compute/virtualMachines'
            resourceGroup = 'rg-prod-eastus'
            location      = 'eastus'
            tags          = @{}
        }
        $rulesConfig = @{
            rules = @(
                @{
                    name  = 'rule-1'
                    match = @{ resourceGroup = '*-prod-*' }
                    tags  = @{ owner = 'first-owner' }
                },
                @{
                    name  = 'rule-2'
                    match = @{ location = 'eastus' }
                    tags  = @{ owner = 'second-owner' }
                }
            )
        }
        $diff = Resolve-ResourceTags -Resource $resource -RulesConfig $rulesConfig -ExplicitTags $null
        $match = $diff | Where-Object { $_.TagKey -eq 'owner' }
        $match.NewValue | Should -Be 'first-owner'
        $match.Source | Should -Be 'rule-1'
    }
}

# ── Import-TagRules Validation ───────────────────────────────────────────────

Describe 'Import-TagRules — Validation' {
    It 'should reject rules file without rules array' {
        $tmpFile = [System.IO.Path]::GetTempFileName()
        '{"defaults": {}}' | Set-Content -Path $tmpFile
        { Import-TagRules -Path $tmpFile } | Should -Throw "*'rules' array*"
        Remove-Item -Path $tmpFile
    }

    It 'should reject rule without name' {
        $tmpFile = [System.IO.Path]::GetTempFileName()
        '{"rules": [{"match": {}, "tags": {}}]}' | Set-Content -Path $tmpFile
        { Import-TagRules -Path $tmpFile } | Should -Throw "*'name'*"
        Remove-Item -Path $tmpFile
    }

    It 'should reject rule without match' {
        $tmpFile = [System.IO.Path]::GetTempFileName()
        '{"rules": [{"name": "test", "tags": {}}]}' | Set-Content -Path $tmpFile
        { Import-TagRules -Path $tmpFile } | Should -Throw "*'match'*"
        Remove-Item -Path $tmpFile
    }

    It 'should reject rule without tags' {
        $tmpFile = [System.IO.Path]::GetTempFileName()
        '{"rules": [{"name": "test", "match": {}}]}' | Set-Content -Path $tmpFile
        { Import-TagRules -Path $tmpFile } | Should -Throw "*'tags'*"
        Remove-Item -Path $tmpFile
    }

    It 'should load valid rules file' {
        $tmpFile = [System.IO.Path]::GetTempFileName()
        $json = @{
            rules = @(
                @{ name = 'test'; match = @{ resourceGroup = '*' }; tags = @{ owner = 'test' } }
            )
            defaults = @{ project = 'unknown' }
        } | ConvertTo-Json -Depth 5
        $json | Set-Content -Path $tmpFile
        $result = Import-TagRules -Path $tmpFile
        $result['rules'].Count | Should -Be 1
        $result['defaults']['project'] | Should -Be 'unknown'
        Remove-Item -Path $tmpFile
    }
}

BeforeAll {
    # Dot-source is not possible since scripts use top-level params.
    # Instead, test by invoking the script with mocked Az commands.

    # Mock all Az module commands used by the cleanup scripts
    function Get-AzSubscription { }
    function Set-AzContext { }
    function Get-AzResourceGroup { }
    function Get-AzResource { }
    function Get-AzResourceLock { }
    function Remove-AzResourceGroup { }
}

Describe 'Remove-EmptyResourceGroups' {
    BeforeEach {
        # Default mocks
        Mock Get-AzSubscription {
            @([PSCustomObject]@{ Id = 'sub-1'; Name = 'Test Sub'; State = 'Enabled' })
        }
        Mock Set-AzContext { }
        Mock Get-AzResourceLock { $null }
        Mock Remove-AzResourceGroup { }
    }

    It 'should skip excluded resource groups' {
        Mock Get-AzResourceGroup {
            @(
                [PSCustomObject]@{ ResourceGroupName = 'NetworkWatcherRG'; Location = 'eastus' },
                [PSCustomObject]@{ ResourceGroupName = 'cloud-shell-storage-westus'; Location = 'westus' },
                [PSCustomObject]@{ ResourceGroupName = 'my-test-rg'; Location = 'eastus' }
            )
        }
        Mock Get-AzResource { @() }  # All RGs are empty

        $results = & "$PSScriptRoot/../cleanup/Remove-EmptyResourceGroups.ps1" -WhatIf *>&1 |
            Where-Object { $_ -match 'SKIP|WhatIf' }

        # NetworkWatcherRG and cloud-shell-storage-* should be skipped
        $results | Should -Not -BeNullOrEmpty
        ($results | Where-Object { $_ -match 'NetworkWatcherRG' }).Count | Should -BeGreaterThan 0
    }

    It 'should not delete resource groups that contain resources' {
        Mock Get-AzResourceGroup {
            @([PSCustomObject]@{ ResourceGroupName = 'rg-with-stuff'; Location = 'eastus' })
        }
        Mock Get-AzResource {
            @([PSCustomObject]@{ Name = 'some-resource'; ResourceType = 'Microsoft.Storage/storageAccounts' })
        }

        & "$PSScriptRoot/../cleanup/Remove-EmptyResourceGroups.ps1" -WhatIf *>&1 | Out-Null

        Should -Invoke Remove-AzResourceGroup -Times 0
    }

    It 'should skip locked resource groups' {
        Mock Get-AzResourceGroup {
            @([PSCustomObject]@{ ResourceGroupName = 'locked-rg'; Location = 'eastus' })
        }
        Mock Get-AzResource { @() }  # Empty
        Mock Get-AzResourceLock {
            @([PSCustomObject]@{ Name = 'DoNotDelete'; Properties = @{ Level = 'CanNotDelete' } })
        }

        $output = & "$PSScriptRoot/../cleanup/Remove-EmptyResourceGroups.ps1" -WhatIf *>&1

        Should -Invoke Remove-AzResourceGroup -Times 0
        $output | Where-Object { $_ -match 'locked' } | Should -Not -BeNullOrEmpty
    }
}

BeforeAll {
    function Get-AzSubscription { }
    function Set-AzContext { param($SubscriptionId, $ErrorAction) }
    function Get-AzResource { param($TagName, $ResourceId) }
    function Get-AzResourceLock { param($ResourceId, $ErrorAction) }
    function Remove-AzResource { param($ResourceId, [switch]$Force, $ErrorAction) }
}

Describe 'Remove-ExpiredResources' {
    BeforeEach {
        Mock Get-AzSubscription {
            @([PSCustomObject]@{ Id = 'sub-1'; Name = 'Test Sub'; State = 'Enabled' })
        }
        Mock Set-AzContext { }
        Mock Get-AzResourceLock { $null }
        Mock Remove-AzResource { }
    }

    It 'should not have a -DryRun parameter (standardized to -WhatIf)' {
        $cmd = Get-Command "$PSScriptRoot/../automation/Remove-ExpiredResources.ps1"
        $cmd.Parameters.Keys | Should -Not -Contain 'DryRun'
        $cmd.Parameters.Keys | Should -Contain 'WhatIf'
    }

    It 'should skip locked resources' {
        # Return one expired resource regardless of which TagName is queried
        Mock Get-AzResource {
            if ($TagName -eq 'expiry-date') {
                @([PSCustomObject]@{
                    Id                = '/subscriptions/sub-1/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
                    Name              = 'vm1'
                    ResourceGroupName = 'rg'
                    ResourceType      = 'Microsoft.Compute/virtualMachines'
                    Tags              = @{ 'expiry-date' = '2025-01-01' }
                })
            } else { @() }
        }

        Mock Get-AzResourceLock {
            @([PSCustomObject]@{ Name = 'CanNotDelete' })
        }

        $output = & "$PSScriptRoot/../automation/Remove-ExpiredResources.ps1" -WhatIf *>&1

        Should -Invoke Remove-AzResource -Times 0
        $output | Where-Object { $_ -match 'locked' } | Should -Not -BeNullOrEmpty
    }

    It 'should only process resources with expired dates' {
        Mock Get-AzResource {
            if ($TagName -eq 'expiry-date') {
                @(
                    [PSCustomObject]@{
                        Id = '/sub/rg/providers/type/expired-resource'
                        Name = 'expired-resource'
                        ResourceGroupName = 'rg'
                        ResourceType = 'Microsoft.Storage/storageAccounts'
                        Tags = @{ 'expiry-date' = '2025-01-01' }
                    },
                    [PSCustomObject]@{
                        Id = '/sub/rg/providers/type/future-resource'
                        Name = 'future-resource'
                        ResourceGroupName = 'rg'
                        ResourceType = 'Microsoft.Storage/storageAccounts'
                        Tags = @{ 'expiry-date' = '2099-12-31' }
                    }
                )
            } else { @() }
        }

        $results = & "$PSScriptRoot/../automation/Remove-ExpiredResources.ps1" -WhatIf *>&1

        # Expired resource should be processed, future resource should not
        $results | Where-Object { $_ -match 'expired-resource' } | Should -Not -BeNullOrEmpty
        $results | Where-Object { $_ -match 'future-resource' } | Should -BeNullOrEmpty
    }
}

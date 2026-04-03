BeforeAll {
    function Get-AzSubscription { }
    function Set-AzContext { }
    function Get-AzNetworkSecurityGroup { }
    function Get-AzResourceLock { }
    function Remove-AzNetworkSecurityGroup { }
}

Describe 'Remove-UnusedNSGs' {
    BeforeEach {
        Mock Get-AzSubscription {
            @([PSCustomObject]@{ Id = 'sub-1'; Name = 'Test Sub'; State = 'Enabled' })
        }
        Mock Set-AzContext { }
        Mock Get-AzResourceLock { $null }
        Mock Remove-AzNetworkSecurityGroup { }
    }

    It 'should only target NSGs with no subnet and no NIC associations' {
        Mock Get-AzNetworkSecurityGroup {
            @(
                [PSCustomObject]@{
                    Name              = 'nsg-attached'
                    ResourceGroupName = 'rg-test'
                    Id                = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Network/networkSecurityGroups/nsg-attached'
                    SecurityRules     = @(@{ Name = 'Allow-SSH' })
                    NetworkInterfaces = @(@{ Id = 'nic-1' })
                    Subnets           = @()
                },
                [PSCustomObject]@{
                    Name              = 'nsg-unused'
                    ResourceGroupName = 'rg-test'
                    Id                = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Network/networkSecurityGroups/nsg-unused'
                    SecurityRules     = @(@{ Name = 'Allow-HTTP' }, @{ Name = 'Allow-HTTPS' })
                    NetworkInterfaces = @()
                    Subnets           = @()
                }
            )
        }

        $output = & "$PSScriptRoot/../cleanup/Remove-UnusedNSGs.ps1" -WhatIf *>&1

        # Should only process nsg-unused, not nsg-attached
        $output | Where-Object { $_ -match 'nsg-attached' -and $_ -match 'Remove' } | Should -BeNullOrEmpty
    }

    It 'should skip locked NSGs' {
        Mock Get-AzNetworkSecurityGroup {
            @(
                [PSCustomObject]@{
                    Name              = 'nsg-locked'
                    ResourceGroupName = 'rg-test'
                    Id                = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Network/networkSecurityGroups/nsg-locked'
                    SecurityRules     = @()
                    NetworkInterfaces = @()
                    Subnets           = @()
                }
            )
        }
        Mock Get-AzResourceLock {
            @([PSCustomObject]@{ Name = 'DoNotDelete' })
        }

        $output = & "$PSScriptRoot/../cleanup/Remove-UnusedNSGs.ps1" -WhatIf *>&1

        Should -Invoke Remove-AzNetworkSecurityGroup -Times 0
        $output | Where-Object { $_ -match 'locked' } | Should -Not -BeNullOrEmpty
    }

    It 'should not call Remove-AzNetworkSecurityGroup in WhatIf mode' {
        Mock Get-AzNetworkSecurityGroup {
            @(
                [PSCustomObject]@{
                    Name              = 'nsg-unused'
                    ResourceGroupName = 'rg-test'
                    Id                = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Network/networkSecurityGroups/nsg-unused'
                    SecurityRules     = @(@{ Name = 'Rule1' })
                    NetworkInterfaces = $null
                    Subnets           = $null
                }
            )
        }

        & "$PSScriptRoot/../cleanup/Remove-UnusedNSGs.ps1" -WhatIf *>&1 | Out-Null

        Should -Invoke Remove-AzNetworkSecurityGroup -Times 0
    }
}

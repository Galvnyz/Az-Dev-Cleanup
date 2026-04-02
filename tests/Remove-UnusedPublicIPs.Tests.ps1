BeforeAll {
    function Get-AzSubscription { }
    function Set-AzContext { }
    function Get-AzPublicIpAddress { }
    function Get-AzResourceLock { }
    function Remove-AzPublicIpAddress { }
}

Describe 'Remove-UnusedPublicIPs' {
    BeforeEach {
        Mock Get-AzSubscription {
            @([PSCustomObject]@{ Id = 'sub-1'; Name = 'Test Sub'; State = 'Enabled' })
        }
        Mock Set-AzContext { }
        Mock Get-AzResourceLock { $null }
        Mock Remove-AzPublicIpAddress { }
    }

    It 'should only target IPs with null ipConfiguration' {
        Mock Get-AzPublicIpAddress {
            @(
                [PSCustomObject]@{
                    Name              = 'pip-attached'
                    ResourceGroupName = 'rg-test'
                    Id                = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Network/publicIPAddresses/pip-attached'
                    IpAddress         = '10.0.0.1'
                    IpConfiguration   = @{ Id = 'some-config' }
                    Sku               = @{ Name = 'Basic' }
                },
                [PSCustomObject]@{
                    Name              = 'pip-unused'
                    ResourceGroupName = 'rg-test'
                    Id                = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Network/publicIPAddresses/pip-unused'
                    IpAddress         = '10.0.0.2'
                    IpConfiguration   = $null
                    Sku               = @{ Name = 'Basic' }
                }
            )
        }

        $output = & "$PSScriptRoot/../cleanup/Remove-UnusedPublicIPs.ps1" -WhatIf *>&1

        # Should only process the unused one, not the attached one
        $output | Where-Object { $_ -match 'pip-attached' -and $_ -match 'Remove' } | Should -BeNullOrEmpty
    }

    It 'should skip locked public IPs' {
        Mock Get-AzPublicIpAddress {
            @(
                [PSCustomObject]@{
                    Name              = 'pip-locked'
                    ResourceGroupName = 'rg-test'
                    Id                = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Network/publicIPAddresses/pip-locked'
                    IpAddress         = '10.0.0.3'
                    IpConfiguration   = $null
                    Sku               = @{ Name = 'Standard' }
                }
            )
        }
        Mock Get-AzResourceLock {
            @([PSCustomObject]@{ Name = 'DoNotDelete' })
        }

        $output = & "$PSScriptRoot/../cleanup/Remove-UnusedPublicIPs.ps1" -WhatIf *>&1

        Should -Invoke Remove-AzPublicIpAddress -Times 0
        $output | Where-Object { $_ -match 'locked' } | Should -Not -BeNullOrEmpty
    }

    It 'should not call Remove-AzPublicIpAddress in WhatIf mode' {
        Mock Get-AzPublicIpAddress {
            @(
                [PSCustomObject]@{
                    Name              = 'pip-unused'
                    ResourceGroupName = 'rg-test'
                    Id                = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Network/publicIPAddresses/pip-unused'
                    IpAddress         = '10.0.0.4'
                    IpConfiguration   = $null
                    Sku               = @{ Name = 'Basic' }
                }
            )
        }

        & "$PSScriptRoot/../cleanup/Remove-UnusedPublicIPs.ps1" -WhatIf *>&1 | Out-Null

        Should -Invoke Remove-AzPublicIpAddress -Times 0
    }
}

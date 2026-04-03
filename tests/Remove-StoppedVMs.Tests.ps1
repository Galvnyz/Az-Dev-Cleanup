BeforeAll {
    # Mock all Az module commands used by the script
    function Get-AzSubscription { }
    function Set-AzContext { }
    function Get-AzVM { }
    function Get-AzResourceLock { }
    function Remove-AzVM { }
    function New-AzSnapshotConfig { }
    function New-AzSnapshot { }
}

Describe 'Remove-StoppedVMs' {
    BeforeEach {
        Mock Get-AzSubscription {
            @([PSCustomObject]@{ Id = 'sub-1'; Name = 'Test Sub'; State = 'Enabled' })
        }
        Mock Set-AzContext { }
        Mock Get-AzResourceLock { $null }
        Mock Remove-AzVM { }
    }

    It 'should skip VMs with exclude tags' {
        Mock Get-AzVM {
            @(
                [PSCustomObject]@{
                    Name              = 'vm-keep'
                    ResourceGroupName = 'rg-test'
                    Id                = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Compute/virtualMachines/vm-keep'
                    PowerState        = 'VM deallocated'
                    TimeCreated       = (Get-Date).AddDays(-60)
                    Tags              = @{ 'keep' = 'true' }
                    HardwareProfile   = @{ VmSize = 'Standard_B2s' }
                }
            )
        }

        & "$PSScriptRoot/../cleanup/Remove-StoppedVMs.ps1" -WhatIf *>&1 | Out-Null

        Should -Invoke Remove-AzVM -Times 0
    }

    It 'should skip VMs newer than MinAgeDays' {
        Mock Get-AzVM {
            @(
                [PSCustomObject]@{
                    Name              = 'vm-new'
                    ResourceGroupName = 'rg-test'
                    Id                = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Compute/virtualMachines/vm-new'
                    PowerState        = 'VM deallocated'
                    TimeCreated       = (Get-Date).AddDays(-5)
                    Tags              = @{}
                    HardwareProfile   = @{ VmSize = 'Standard_B2s' }
                }
            )
        }

        & "$PSScriptRoot/../cleanup/Remove-StoppedVMs.ps1" -MinAgeDays 30 -WhatIf *>&1 | Out-Null

        Should -Invoke Remove-AzVM -Times 0
    }

    It 'should skip locked VMs' {
        Mock Get-AzVM {
            @(
                [PSCustomObject]@{
                    Name              = 'vm-locked'
                    ResourceGroupName = 'rg-test'
                    Id                = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Compute/virtualMachines/vm-locked'
                    PowerState        = 'VM deallocated'
                    TimeCreated       = (Get-Date).AddDays(-60)
                    Tags              = @{}
                    HardwareProfile   = @{ VmSize = 'Standard_B2s' }
                }
            )
        }
        Mock Get-AzResourceLock {
            @([PSCustomObject]@{ Name = 'DoNotDelete' })
        }

        $output = & "$PSScriptRoot/../cleanup/Remove-StoppedVMs.ps1" -WhatIf *>&1

        Should -Invoke Remove-AzVM -Times 0
        $output | Where-Object { $_ -match 'locked' } | Should -Not -BeNullOrEmpty
    }

    It 'should not call Remove-AzVM in WhatIf mode' {
        Mock Get-AzVM {
            @(
                [PSCustomObject]@{
                    Name              = 'vm-old'
                    ResourceGroupName = 'rg-test'
                    Id                = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Compute/virtualMachines/vm-old'
                    PowerState        = 'VM deallocated'
                    TimeCreated       = (Get-Date).AddDays(-60)
                    Tags              = @{}
                    HardwareProfile   = @{ VmSize = 'Standard_B2s' }
                }
            )
        }

        & "$PSScriptRoot/../cleanup/Remove-StoppedVMs.ps1" -WhatIf *>&1 | Out-Null

        Should -Invoke Remove-AzVM -Times 0
    }
}

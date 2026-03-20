BeforeAll {
    function Get-AzSubscription { }
    function Set-AzContext { }
    function Get-AzDisk { }
    function Get-AzResourceLock { }
    function Remove-AzDisk { }
    function New-AzSnapshotConfig { }
    function New-AzSnapshot { }
}

Describe 'Remove-UnattachedDisks' {
    BeforeEach {
        Mock Get-AzSubscription {
            @([PSCustomObject]@{ Id = 'sub-1'; Name = 'Test Sub'; State = 'Enabled' })
        }
        Mock Set-AzContext { }
        Mock Get-AzResourceLock { $null }
        Mock Remove-AzDisk { }
    }

    It 'should reject negative MinAgeDays' {
        { & "$PSScriptRoot/../cleanup/Remove-UnattachedDisks.ps1" -MinAgeDays -5 -WhatIf } |
            Should -Throw
    }

    It 'should reject MinAgeDays over 3650' {
        { & "$PSScriptRoot/../cleanup/Remove-UnattachedDisks.ps1" -MinAgeDays 5000 -WhatIf } |
            Should -Throw
    }

    It 'should skip disks newer than MinAgeDays' {
        Mock Get-AzDisk {
            @([PSCustomObject]@{
                Name              = 'new-disk'
                DiskState         = 'Unattached'
                TimeCreated       = (Get-Date).AddDays(-5)  # Only 5 days old
                DiskSizeGB        = 128
                ResourceGroupName = 'rg-test'
                Id                = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Compute/disks/new-disk'
                Location          = 'eastus'
            })
        }

        & "$PSScriptRoot/../cleanup/Remove-UnattachedDisks.ps1" -MinAgeDays 30 -WhatIf *>&1 | Out-Null

        Should -Invoke Remove-AzDisk -Times 0
    }

    It 'should skip locked disks' {
        Mock Get-AzDisk {
            @([PSCustomObject]@{
                Name              = 'locked-disk'
                DiskState         = 'Unattached'
                TimeCreated       = (Get-Date).AddDays(-60)
                DiskSizeGB        = 128
                ResourceGroupName = 'rg-test'
                Id                = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Compute/disks/locked-disk'
                Location          = 'eastus'
            })
        }
        Mock Get-AzResourceLock {
            @([PSCustomObject]@{ Name = 'DoNotDelete' })
        }

        $output = & "$PSScriptRoot/../cleanup/Remove-UnattachedDisks.ps1" -WhatIf *>&1

        Should -Invoke Remove-AzDisk -Times 0
        $output | Where-Object { $_ -match 'locked' } | Should -Not -BeNullOrEmpty
    }
}

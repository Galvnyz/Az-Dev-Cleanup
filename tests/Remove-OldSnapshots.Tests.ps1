BeforeAll {
    function Get-AzSubscription { }
    function Set-AzContext { }
    function Get-AzSnapshot { }
    function Get-AzResource { }
    function Get-AzResourceLock { }
    function Remove-AzSnapshot { }
}

Describe 'Remove-OldSnapshots' {
    BeforeEach {
        Mock Get-AzSubscription {
            @([PSCustomObject]@{ Id = 'sub-1'; Name = 'Test Sub'; State = 'Enabled' })
        }
        Mock Set-AzContext { }
        Mock Get-AzResourceLock { $null }
        Mock Remove-AzSnapshot { }
        Mock Get-AzResource { [PSCustomObject]@{ Name = 'source-disk' } }
    }

    It 'should skip snapshots newer than threshold' {
        Mock Get-AzSnapshot {
            @(
                [PSCustomObject]@{
                    Name              = 'snap-new'
                    ResourceGroupName = 'rg-test'
                    Id                = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Compute/snapshots/snap-new'
                    TimeCreated       = (Get-Date).AddDays(-10)
                    DiskSizeGB        = 128
                    CreationData      = @{ SourceResourceId = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Compute/disks/disk-1' }
                }
            )
        }

        & "$PSScriptRoot/../cleanup/Remove-OldSnapshots.ps1" -MinAgeDays 90 -WhatIf *>&1 | Out-Null

        Should -Invoke Remove-AzSnapshot -Times 0
    }

    It 'should skip locked snapshots' {
        Mock Get-AzSnapshot {
            @(
                [PSCustomObject]@{
                    Name              = 'snap-locked'
                    ResourceGroupName = 'rg-test'
                    Id                = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Compute/snapshots/snap-locked'
                    TimeCreated       = (Get-Date).AddDays(-120)
                    DiskSizeGB        = 64
                    CreationData      = @{ SourceResourceId = $null }
                }
            )
        }
        Mock Get-AzResourceLock {
            @([PSCustomObject]@{ Name = 'DoNotDelete' })
        }

        $output = & "$PSScriptRoot/../cleanup/Remove-OldSnapshots.ps1" -WhatIf *>&1

        Should -Invoke Remove-AzSnapshot -Times 0
        $output | Where-Object { $_ -match 'locked' } | Should -Not -BeNullOrEmpty
    }

    It 'should skip orphaned snapshots when SkipOrphaned is set' {
        Mock Get-AzSnapshot {
            @(
                [PSCustomObject]@{
                    Name              = 'snap-orphaned'
                    ResourceGroupName = 'rg-test'
                    Id                = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Compute/snapshots/snap-orphaned'
                    TimeCreated       = (Get-Date).AddDays(-120)
                    DiskSizeGB        = 32
                    CreationData      = @{ SourceResourceId = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Compute/disks/deleted-disk' }
                }
            )
        }
        Mock Get-AzResource { $null }  # Source disk no longer exists

        $output = & "$PSScriptRoot/../cleanup/Remove-OldSnapshots.ps1" -SkipOrphaned -WhatIf *>&1

        Should -Invoke Remove-AzSnapshot -Times 0
        $output | Where-Object { $_ -match 'orphaned' } | Should -Not -BeNullOrEmpty
    }

    It 'should not call Remove-AzSnapshot in WhatIf mode' {
        Mock Get-AzSnapshot {
            @(
                [PSCustomObject]@{
                    Name              = 'snap-old'
                    ResourceGroupName = 'rg-test'
                    Id                = '/subscriptions/sub-1/resourceGroups/rg-test/providers/Microsoft.Compute/snapshots/snap-old'
                    TimeCreated       = (Get-Date).AddDays(-120)
                    DiskSizeGB        = 128
                    CreationData      = @{ SourceResourceId = $null }
                }
            )
        }

        & "$PSScriptRoot/../cleanup/Remove-OldSnapshots.ps1" -WhatIf *>&1 | Out-Null

        Should -Invoke Remove-AzSnapshot -Times 0
    }
}

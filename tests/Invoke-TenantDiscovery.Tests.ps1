BeforeAll {
    # Stub filesystem and Az cmdlets so the script body can run without side effects
    function New-Item { }
    function Out-File { }
    function Set-Content { }
    function ConvertTo-Json { '{}' }
    function Get-AzSubscription { }
    function Get-AzContext { }
    function Connect-AzAccount { }
    function Search-AzGraph { [PSCustomObject]@{ Data = @(); SkipToken = $null } }
    function Get-ChildItem { @() }   # no KQL files → Phase 1 loop is a no-op
}

Describe 'Invoke-TenantDiscovery — auth check' {
    BeforeEach {
        Mock New-Item { }
        Mock Out-File { }
        Mock Set-Content { }
        Mock ConvertTo-Json { '{}' }
        Mock Search-AzGraph { [PSCustomObject]@{ Data = @(); SkipToken = $null } }
        Mock Get-ChildItem { @() }
        Mock Get-AzSubscription {
            @([PSCustomObject]@{ Id = 'sub-1'; Name = 'Test Sub'; State = 'Enabled' })
        }
        Mock Get-AzContext { $null }
        Mock Connect-AzAccount { }
        $script:contextCallCount = 0
    }

    It 'proceeds silently when a context already exists' {
        Mock Get-AzContext {
            [PSCustomObject]@{ Account = [PSCustomObject]@{ Id = 'user@test.com' } }
        }
        Mock Connect-AzAccount { }

        { & "$PSScriptRoot/../discovery/Invoke-TenantDiscovery.ps1" `
              -SkipActivityLog -SkipCostData -SkipEntraId `
              -OutputDir 'TestDrive:\reports' *>&1 | Out-Null
        } | Should -Not -Throw

        Should -Invoke Connect-AzAccount -Times 0
    }

    It 'calls Connect-AzAccount when no context exists and -SkipConnect is not set' {
        Mock Get-AzContext {
            $script:contextCallCount++
            if ($script:contextCallCount -eq 1) { return $null }
            return [PSCustomObject]@{ Account = [PSCustomObject]@{ Id = 'user@test.com' } }
        }
        Mock Connect-AzAccount { }

        { & "$PSScriptRoot/../discovery/Invoke-TenantDiscovery.ps1" `
              -SkipActivityLog -SkipCostData -SkipEntraId `
              -OutputDir 'TestDrive:\reports' *>&1 | Out-Null
        } | Should -Not -Throw

        Should -Invoke Connect-AzAccount -Times 1
    }

    It 'throws if Connect-AzAccount completes but context is still null (user cancelled browser)' {
        Mock Get-AzContext { $null }
        Mock Connect-AzAccount { }

        { & "$PSScriptRoot/../discovery/Invoke-TenantDiscovery.ps1" `
              -SkipActivityLog -SkipCostData -SkipEntraId `
              -OutputDir 'TestDrive:\reports' *>&1 | Out-Null
        } | Should -Throw '*Connection was not completed*'
    }

    It 'throws immediately with an actionable message when -SkipConnect is set and no context exists' {
        Mock Get-AzContext { $null }
        Mock Connect-AzAccount { }

        { & "$PSScriptRoot/../discovery/Invoke-TenantDiscovery.ps1" `
              -SkipConnect `
              -SkipActivityLog -SkipCostData -SkipEntraId `
              -OutputDir 'TestDrive:\reports' *>&1 | Out-Null
        } | Should -Throw '*No active Azure session*'

        Should -Invoke Connect-AzAccount -Times 0
    }

    It 'does not call Connect-AzAccount when -SkipConnect is set and context exists' {
        Mock Get-AzContext {
            [PSCustomObject]@{ Account = [PSCustomObject]@{ Id = 'user@test.com' } }
        }
        Mock Connect-AzAccount { }

        { & "$PSScriptRoot/../discovery/Invoke-TenantDiscovery.ps1" `
              -SkipConnect `
              -SkipActivityLog -SkipCostData -SkipEntraId `
              -OutputDir 'TestDrive:\reports' *>&1 | Out-Null
        } | Should -Not -Throw

        Should -Invoke Connect-AzAccount -Times 0
    }
}

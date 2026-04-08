# Auto-Connect to Azure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an automatic Azure login prompt to `Invoke-TenantDiscovery.ps1` so users with no active session get connected via browser before discovery runs, with a `-SkipConnect` flag for pipeline use.

**Architecture:** Insert an auth check block immediately before subscription resolution in the existing script. Use `Get-AzContext` to detect session state, `Connect-AzAccount` to connect interactively, and `throw` to exit cleanly on failure — consistent with `$ErrorActionPreference = "Stop"` already set in the script.

**Tech Stack:** PowerShell 7, Az.Accounts module, Pester 5 (test framework already used in repo)

---

### Task 1: Write failing Pester tests

**Files:**
- Create: `tests/Invoke-TenantDiscovery.Tests.ps1`

The test file mocks all Az cmdlets and filesystem operations so the script can be dot-invoked without real Azure calls or disk I/O. All tests pass `-SkipActivityLog -SkipCostData -SkipEntraId` and mock `Get-ChildItem` to return no KQL files, isolating the auth check behaviour.

- [ ] **Step 1: Create the test file**

```powershell
# tests/Invoke-TenantDiscovery.Tests.ps1

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
        $script:contextCallCount = 0
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
```

- [ ] **Step 2: Run the tests — confirm they all fail**

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Invoke-TenantDiscovery.Tests.ps1 -Output Detailed"
```

Expected: all 5 tests fail. The `Get-AzContext` / `Connect-AzAccount` mocks aren't hooked to any auth check logic yet, so the script proceeds without checking and the mock-invocation assertions fail.

---

### Task 2: Add `-SkipConnect` parameter and update comment-based help

**Files:**
- Modify: `discovery/Invoke-TenantDiscovery.ps1:15-48` (comment-based help)
- Modify: `discovery/Invoke-TenantDiscovery.ps1:50-78` (param block)

- [ ] **Step 1: Add `.PARAMETER SkipConnect` to comment-based help**

In `discovery/Invoke-TenantDiscovery.ps1`, after the existing `.PARAMETER PageSize` block (line ~37) and before `.EXAMPLE` (line ~39), insert:

```powershell
.PARAMETER SkipConnect
    Skip the automatic Azure login prompt. Use in pipelines where Connect-AzAccount
    is managed externally. Without this flag the script calls Connect-AzAccount if
    no active session is detected.
```

- [ ] **Step 2: Add a `-SkipConnect` usage example**

In the `.EXAMPLE` section, after the existing examples, add:

```powershell
    # Pipeline use — manage auth externally, suppress auto-connect
    .\Invoke-TenantDiscovery.ps1 -SkipConnect
```

- [ ] **Step 3: Add `$SkipConnect` to the param block**

In the `param()` block of `discovery/Invoke-TenantDiscovery.ps1`, after the `$SkipEntraId` switch (line ~65) and before `$LookbackDays` (line ~68), insert:

```powershell
    [Parameter()]
    [switch]$SkipConnect,
```

- [ ] **Step 4: Run the tests — still failing (implementation not added yet)**

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Invoke-TenantDiscovery.Tests.ps1 -Output Detailed"
```

Expected: same failures as before. No logic yet.

- [ ] **Step 5: Commit**

```bash
git add discovery/Invoke-TenantDiscovery.ps1
git commit -m "feat: add -SkipConnect parameter to Invoke-TenantDiscovery"
```

---

### Task 3: Implement the auth check block

**Files:**
- Modify: `discovery/Invoke-TenantDiscovery.ps1:99-101` (after output-dir log line, before subscription resolution)

- [ ] **Step 1: Insert the auth check block**

In `discovery/Invoke-TenantDiscovery.ps1`, after the line:
```powershell
Write-Log "Output directory: $OutputDir"
```
and immediately before:
```powershell
# Resolve subscriptions
```
insert:

```powershell
# ── Azure auth check ─────────────────────────────────────────────────────────

$azContext = Get-AzContext -ErrorAction SilentlyContinue
if (-not ($azContext -and $azContext.Account)) {
    if ($SkipConnect) {
        throw (
            "No active Azure session. Run the following then re-run discovery:`n" +
            "        Connect-AzAccount`n" +
            "        Connect-AzAccount -TenantId 'your-tenant-id'   # to target a specific tenant"
        )
    }

    Write-Log "No active Azure session found. Launching Connect-AzAccount..."
    Connect-AzAccount

    $azContext = Get-AzContext -ErrorAction SilentlyContinue
    if (-not ($azContext -and $azContext.Account)) {
        throw "Connection was not completed. Re-run the script to try again."
    }

    Write-Log "Connected as $($azContext.Account.Id)"
}

```

- [ ] **Step 2: Run the tests — all 5 should now pass**

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Invoke-TenantDiscovery.Tests.ps1 -Output Detailed"
```

Expected output:
```
Describing Invoke-TenantDiscovery — auth check
  [+] proceeds silently when a context already exists
  [+] calls Connect-AzAccount when no context exists and -SkipConnect is not set
  [+] throws if Connect-AzAccount completes but context is still null (user cancelled browser)
  [+] throws immediately with an actionable message when -SkipConnect is set and no context exists
  [+] does not call Connect-AzAccount when -SkipConnect is set and context exists
Tests completed in Xms
Passed: 5, Failed: 0
```

- [ ] **Step 3: Commit**

```bash
git add discovery/Invoke-TenantDiscovery.ps1 tests/Invoke-TenantDiscovery.Tests.ps1
git commit -m "feat: auto-connect to Azure if no session detected in Invoke-TenantDiscovery"
```

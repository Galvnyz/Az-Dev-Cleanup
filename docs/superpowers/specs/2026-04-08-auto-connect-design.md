# Design: Auto-Connect to Azure in Invoke-TenantDiscovery

**Date:** 2026-04-08
**Status:** Approved

## Problem

`Invoke-TenantDiscovery.ps1` calls `Get-AzSubscription` immediately with no auth check. If the user hasn't run `Connect-AzAccount` first, the script fails with a cryptic error. There is no guidance in the script itself on how to fix it.

## Goal

Detect a missing or inactive Azure session at startup and connect the user automatically via interactive browser login — with a clean escape hatch (`-SkipConnect`) for pipeline use.

## Scope

Single file: `discovery/Invoke-TenantDiscovery.ps1`. No new scripts or wrappers.

---

## Design

### New Parameter

```powershell
[Parameter()]
[switch]$SkipConnect
```

Added to the existing `param()` block alongside the other `Skip*` switches. Also documented in comment-based help (`.PARAMETER SkipConnect` and `.EXAMPLE`).

### Auth Check Logic

Inserted immediately after the `Write-Log "Output directory..."` line and before the `Get-AzSubscription` call — the earliest point where a failure would occur.

```
Get-AzContext
├─ context exists AND account is not null
│   └─ proceed normally
├─ no context AND -SkipConnect is set
│   └─ Write-Log ERROR with exact Connect-AzAccount command
│      exit 1
└─ no context AND -SkipConnect is NOT set
    └─ Write-Log INFO "No active Azure session. Connecting..."
       Connect-AzAccount
       Get-AzContext again to verify
       ├─ context now exists → proceed
       └─ still no context (user cancelled browser)
           └─ Write-Log ERROR "Connection was not completed."
              exit 1
```

### `-SkipConnect` exit message

The error message shown when `-SkipConnect` suppresses auto-connect must be actionable:

```
[ERROR] No active Azure session. Run the following then re-run discovery:
        Connect-AzAccount
        Connect-AzAccount -TenantId 'your-tenant-id'   # to target a specific tenant
```

### Post-connect verification

After `Connect-AzAccount` returns, immediately call `Get-AzContext` to confirm the session was established. `Connect-AzAccount` can return without error even if the user closed the browser window — the context check catches that case and exits cleanly rather than proceeding into `Get-AzSubscription` with no session.

---

## What Is Not In Scope

- Tenant ID prompting — `Connect-AzAccount` with no arguments handles tenant selection through the browser.
- Service principal / certificate auth — out of scope; pipelines use `-SkipConnect` and manage auth externally.
- Expired session refresh — if a context exists (`Get-AzContext` returns non-null), the script proceeds as today. Token refresh is handled by the Az module itself when API calls are made.
- Changes to any other script — each script is responsible for its own concerns; the other cleanup scripts are not changed.

---

## Verification

1. Run `Invoke-TenantDiscovery.ps1` with no active session — browser should open, then discovery proceeds after login.
2. Cancel the browser login mid-flow — script should exit with a clear error, not proceed.
3. Run with `-SkipConnect` and no active session — script should exit immediately with an actionable error message.
4. Run with an active session — auth check passes silently, no change in behavior.
5. Run with `-SkipConnect` and an active session — passes through silently (no connect attempt).

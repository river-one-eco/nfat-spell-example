# Sky-Core Dependencies

What must already be true on the Sky-core (PauseProxy) side before these payloads can cast.
The payloads run as a star SubProxy, which cannot do any of this itself; the fork tests stand
in for each missing piece.

## 1. Beacon registration (PauseProxy-only)

`PAUInit.init` syncs integration ids from the canonical Beacon
(`0x829dC2b7E94B1954F0764E573f2E0d45Afa28199`). An unregistered id reverts the cast with
`IntegrationNotFound`, and every dispatch call the payload makes must be in that integration's
wire set. The ids below are just what these examples use: the rule is that whatever facet a
spell dispatches through must be registered on the canonical Beacon, with the wires it calls.

What each payload syncs, and the dispatch calls it makes through the Controller:

| Integration (synced by) | Dispatch calls in the payload |
| --- | --- |
| `NFAT_HALO_FACET` (Halo) | `nfatHalo_setMaxAnnualGrowthRate`, `nfatHalo_get{Issue,RepayPrincipal,RepayInterest}RateLimitKey` |
| `PSM_FACET` (Halo) | `psm_usdcToUSDSSwapRateLimitKey`, `psm_usdsToUSDCSwapRateLimitKey` |
| `TRANSFER_ASSET_FACET` (Halo) | `transferAsset_getTransferRateLimitKey` |
| `NFAT_PRIME_FACET` (Prime) | `nfatPrime_get{Subscribe,Withdraw,Collect}RateLimitKey` |
| `USDS_FACET` (Prime) | `usds_setVault`, `usds_mintRateLimitKey`, `usds_burnRateLimitKey` |

The table is only the cast-time surface. The relayers' day-to-day calls after onboarding
(`nfatHalo_issue`, `nfatPrime_subscribe`, `usds_mint`, `usds_burn`, `psm_swap*`,
`transferAsset_transfer`, ...) dispatch through the same integrations, so the registered wire
sets must cover those selectors too.

## 2. LitePSM kiss (PauseProxy-only)

The LitePSM is whitelist-gated: the Halo ALMProxy must be `kiss`ed before `psm_swap*` works.
This does not block the cast - the payload only sets the swap rate limits - but the swap leg
is dead until the kiss lands.

## 3. SubProxy privileges (must pre-exist)

Each init call checks or requires authority the SubProxy must already hold; any missing one
reverts the cast:

- Both payloads, each on its own stack: `DEFAULT_ADMIN_ROLE` on the stack's AccessControls,
  ALMProxy and RateLimits (checked by `PAUInit.init`), and sole admin of the inert
  AdministeredAgent (checked by `AdministeredAgentInit.init`).
- Halo: ward of the NFATFacility (`NFATInit.init` files the recipient, kisses the ALMProxy
  and adds freezers under `auth`).
- Prime: ward on the AllocatorVault and AllocatorBuffer (`vault.rely(almProxy)` and
  `buffer.approve(...)` are ward-gated).

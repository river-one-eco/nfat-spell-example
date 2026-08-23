# nfat-spell-example

**Illustrative** governance spells that onboard the two sides of ONE NFAT deal across TWO PAU
stacks — the **Halo** payload onboards the facility-operator (borrower) side, the **Prime**
payload onboards the subscriber (investor) side — plus mainnet-fork tests that cast them the way
Sky governance does and run the full deal lifecycle crossing between the stacks, including
**real USDS minting** from the Interval allocator vault and **real LitePSM swaps**.

The deal shape: the Halo star operates the facility (its ALMProxy is the recipient — issued
principal flows to it, repayments flow from it); the Prime star invests into that facility (its
ALMProxy subscribes, holds the issued NFAT, and collects). The facility is initialized by the
**Halo** payload — the Prime side never inits a facility that isn't its own.

## Who executes what

The example separates the three authorities the way mainnet does:

| Leg | Executor | Actions |
| --- | -------- | ------- |
| Deploy | deployer EOA | both PAU stacks + agents via canonical factories, the deal facility + facet impls from source — everything handed to the SubProxy |
| **Sky core** | MCD PauseProxy | `Beacon.setIntegration` for the NFAT facets (the Beacon admin IS the PauseProxy) and `LitePSM.kiss` of the Halo ALMProxy (the PSM is whitelist-gated) |
| **Deal payloads** | **Interval SubProxy** (`0x56a9…f5B`) | everything deal-scoped — init libraries, agent roles, vault wiring, rate limits |

*Simplification: both stacks are owned and cast by the same Interval SubProxy; in production the
Prime and Halo sides would typically be different stars, each with its own SubProxy + StarGuard.
The payloads are written per-side, so splitting executors changes nothing in them.*

Facet registration is deliberately **not** in the payloads: a SubProxy is not the Beacon admin.
In the tests the Sky-core leg is pranked in `SpellRunner._setUpWorld` (standing in for the pending
Sky-core registration spell); the payloads are cast through the **real Interval StarGuard**
(`0xB36e…B28`): the PauseProxy `plot`s the payload (address + codehash), `exec()` has the SubProxy
delegatecall its `execute()` — byte-for-byte the pattern-spells / obex-gov-relay activation path.
Payloads inherit `NFATPayloadBase` (`execute()` / `isExecutable()` / `_execute()`), the same
payload shape those repos use.

## The two payloads

**`src/NFATHaloOnboardingPayload.sol`** — the **facility-operator (borrower) side**:

1. `PAUInit.init` — its stack's Controller roles + `[NFAT_HALO_FACET]`;
2. `PAUInit.addAllocator` + `AdministeredAgentInit.init` — agent as allocator, relayer as actor;
3. `NFATInit.init` — **the deal facility**, wired with recipient + bud = the HALO ALMProxy (the
   facility belongs to this side; the facet issues/repays through it). Chainlog registration was
   removed from `NFATInit` entirely: the Sky chainlog is PauseProxy-writable only — verified
   on-chain, `chainlog.wards(INTERVAL_SUBPROXY) == 0` — and stars track addresses in their own
   registry, as pattern-spells / spark-spells do;
4. `nfatHalo_setMaxAnnualGrowthRate` — 20% APR deal risk parameter;
5. **rate limits** — issue (keyed per subscriber: the Prime star's ALMProxy) / repayPrincipal /
   repayInterest + the PSM USDC<->USDS swap limits + the **TransferAsset offramp limit** (USDC →
   the deal's borrower/custodian destination — the only rate-limited exit from the proxy; the
   subscriber side stays USDS-only).

**`src/NFATPrimeOnboardingPayload.sol`** — the **subscriber (investor) side**. No `NFATInit` —
the facility is not this star's:

1. `PAUInit.init` — its stack's Controller roles + `[NFAT_PRIME_FACET, USDS_FACET]` (no PSM —
   this side only mints and deploys USDS);
2. `PAUInit.addAllocator` + `AdministeredAgentInit.init` — agent as allocator, relayer as actor;
3. **USDS mint wiring** — `usds_setVault(ALLOCATOR_INTERVAL_A_VAULT)`, `vault.rely(almProxy)`,
   `buffer.approve(usds, almProxy, ∞)` (the SubProxy owns the Interval vault `0xDD3b…2720` and
   buffer `0x67Ac…8AfD` — same wiring as spark's `initAlmSystem`);
4. **rate limits** — subscribe / withdraw / collect on the deal facility + USDS mint.

All rate limits use the Sky ALM convention **`slope = cap / 1 day`** (a consumed limit recharges
linearly back to its cap over a day) and both payloads copy the audited init libraries verbatim
(`src/dependencies/`) — exactly what a real spell does.

## What the tests prove (`test/OnboardingSpell.t.sol`)

- **`test_onboarding_wiresBothSides`**: casts both payloads and asserts each side's wiring — the
  facility's recipient + bud are the HALO ALMProxy (and NOT the Prime one), each stack's
  Controller roles, agents, and rate limits.
- **`test_fullDealLifecycle`** — one deal crossing both stacks:
  Prime **mints 1M USDS for real** (Interval vault draw → buffer → ALMProxy; mint limit drains to
  0) → Prime subscribes 2M into the facility → **Halo issues a 1M NFAT** (NFT to the PRIME
  ALMProxy, principal to the HALO ALMProxy) → Prime withdraws its unissued 1M → Halo **swaps
  100k of the received principal USDS→USDC through the LitePSM and offramps it to the borrower
  via the TransferAsset facet** (the rate-limited exit door) → 180 days accrue at
  the 20% APR cap (~98,630 USDS interest, read via `nfatHalo_getCurrentMaxOutstandingInterest`) →
  Halo repays interest then full principal → Prime collects, ending with its full 2M back plus
  the earned interest. Limit consumption and slope recharge asserted throughout.

```bash
cp .env.example .env   # set MAINNET_RPC_URL
forge test -vv
```

## TEMPORARY pieces (delete when live)

- **Facet registration + facet deployments**: at the current mainnet block the canonical Beacon
  (`PAUFactory 0x69A5…` → Beacon `0x829d…`) has 25 integrations — `USDS_FACET`, `PSM_FACET`, … —
  but **not** `NFAT_PRIME_FACET` / `NFAT_HALO_FACET`. The harness deploys them from diamond-pau
  source and registers them in the Sky-core leg (`test/FacetRegistration.sol` holds the wire
  configs, mirroring diamond-pau's canonical `_wireNFAT*Facet`). Once registered for real, delete
  that leg, `FacetRegistration.sol`, and the facet deployments — the payloads don't change.
- **`LitePSM.kiss(almProxy)`**: also Sky-core; on mainnet it lands in the same Sky-core spell as
  the facet registration.

## Fidelity notes

- **Not production spells; structure inspired by spark-spells**: `SpellRunner` owns *how to cast*,
  tests own *what to assert*; thin `*Like` interfaces (`test/Interfaces.sol`) instead of protocol
  source imports. A production spell would live as a dated proposal in `grove-labs/grove-spells`
  (which already ships `CommonPauTestBase` / `CommonPauSpellTests` for PAU) with an address
  registry instead of constructor-injected addresses.
- Deal parameters are `immutable`/`constant` (baked into the payload's code) so they survive the
  delegatecall — a delegatecall runs against the *executor's* storage.
- The init libraries under `src/dependencies/` are **vendored copies** of the audited originals
  (`diamond-pau/deploy/PAUInit.sol`, `pau-administered-agent/deploy/AdministeredAgentInit.sol`,
  `nfat/deploy/NFATInit.sol`) — a real spell copies them the same way, pinned to the audited tag.

// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { NFATFacility } from "../lib/nfat/src/NFATFacility.sol";

import { NFATPrimeFacet } from "../lib/diamond-pau/src/facets/nfat-prime/NFATPrimeFacet.sol";
import { NFATHaloFacet }  from "../lib/diamond-pau/src/facets/nfat-halo/NFATHaloFacet.sol";

import { IEnumerableIntegrations } from "../lib/diamond-pau/src/interfaces/IEnumerableIntegrations.sol";

import { PAUDeploy, PAUDeployParams } from "./dependencies/PAUDeploy.sol";
import {
    AdministeredAgentDeploy,
    AdministeredAgentDeployParams
} from "./dependencies/AdministeredAgentDeploy.sol";

import { PAUInstance } from "../src/dependencies/PAUInit.sol";

import { FacetRegistration } from "./FacetRegistration.sol";

import { IChainlogLike, IStarGuardLike, IPAUFactoryLike } from "./Interfaces.sol";

interface IBeaconAdminLike {
    function setIntegration(bytes32 id, IEnumerableIntegrations.Config calldata config) external;
}

interface IPSMLike {
    function kiss(address usr) external;
}

/**
 * @notice Minimal analogue of spark-spells' / pattern-spells' `test-harness/SpellRunner`. The
 *         world models one NFAT deal between TWO PAU stacks:
 *
 *         - the **Halo stack** operates the deal facility (issues NFATs, repays through its
 *           ALMProxy — the facility's recipient);
 *         - the **Prime stack** invests into it (mints USDS, subscribes, holds the NFAT,
 *           collects).
 *
 *         Three legs:
 *
 *         1. **Deploy** — a deployer stands up both PAU stacks + agents, the deal facility, and
 *            (for now) the NFAT facet implementations, handing everything to the SubProxy;
 *         2. **Sky core** — the Beacon admin (MCD PauseProxy) registers the NFAT facets on the
 *            canonical Beacon and kisses the Halo ALMProxy on the LitePSM (both PauseProxy-only
 *            actions; deal payloads deliberately do NOT do this);
 *         3. **Cast** — the payloads execute as the SubProxy via the real **StarGuard**
 *            (`plot(payload, codehash)` by the PauseProxy, then `exec()`), the exact activation
 *            path pattern-spells / obex-gov-relay use.
 *
 * @dev    Simplification: both stacks are owned and cast by the same Interval SubProxy. In
 *         production the Prime and Halo sides would typically be different stars, each with its
 *         own SubProxy + StarGuard — the payloads are already written per-side, so splitting
 *         executors changes nothing in them.
 */
abstract contract SpellRunner is Test {

    address internal constant CHAINLOG      = 0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F;
    address internal constant PAU_FACTORY   = 0x69A5d548830AC2A4Ba90A44a2C75BDA71f97fc66;
    address internal constant AGENT_FACTORY = 0x2968c3b5478cF93B70aB1e24255d4EDBBd27a089;

    // The Interval star: its SubProxy owns the PAU stacks, allocator vault, and the facility.
    address internal constant INTERVAL_SUBPROXY  = 0x56a9bA5FE133EF4Ab1131E8ac7c4312a52284f5B;
    address internal constant INTERVAL_STARGUARD = 0xB36e88c02E4619Ef34C0Db76C5BCb6655747FB28;

    address internal executor = INTERVAL_SUBPROXY; // delegatecalls the deal payloads
    address internal skyCore;                      // MCD PauseProxy: Beacon admin, plots payloads

    address internal deployer        = makeAddr("deployer");
    address internal relayerPrime    = makeAddr("relayerPrime"); // subscriber-side operator
    address internal relayerHalo     = makeAddr("relayerHalo");  // facility-side operator
    address internal borrower        = makeAddr("borrower");     // deal custodian / offramp destination
    address internal revokerHalo     = makeAddr("revokerHalo");  // incident response: revoke the relayer
    address internal facilityFreezer = makeAddr("facilityFreezer"); // incident response: stop the facility

    PAUInstance internal pauPrime;
    PAUInstance internal pauHalo;
    address     internal agentPrime;
    address     internal agentHalo;
    address     internal usds;

    address internal facility; // ONE deal facility: operated by Halo, subscribed by Prime
    address internal primeFacet;
    address internal haloFacet;

    /// @notice Legs 1 + 2: deploy the world for the SubProxy, then do the Sky-core actions.
    function _setUpWorld() internal {
        skyCore = IChainlogLike(CHAINLOG).getAddress("MCD_PAUSE_PROXY");
        usds    = IChainlogLike(CHAINLOG).getAddress("USDS");

        // --- Leg 1: deploy, handing sole admin/ward to the SubProxy ---
        vm.startPrank(deployer);

        pauPrime = _deployStack();
        pauHalo  = _deployStack();

        agentPrime = AdministeredAgentDeploy.deploy(
            AdministeredAgentDeployParams({ agentFactory: AGENT_FACTORY, owner: executor })
        );
        agentHalo = AdministeredAgentDeploy.deploy(
            AdministeredAgentDeployParams({ agentFactory: AGENT_FACTORY, owner: executor })
        );

        // NFAT facet implementations (stateless): deployed from diamond-pau source because they
        // are not yet registered on the canonical Beacon. Delete once they are.
        primeFacet = address(new NFATPrimeFacet());
        haloFacet  = address(new NFATHaloFacet());

        // The deal facility (name/symbol must match the Halo payload's constants — NFATInit
        // sanity-checks them). Sole ward is handed to the SubProxy.
        facility = address(new NFATFacility(usds, "NFAT Example Deal", "NFAT-EX"));
        NFATFacility(facility).rely(executor);
        NFATFacility(facility).deny(deployer);

        vm.stopPrank();

        // --- Leg 2: Sky core (PauseProxy) actions — stand-in for the pending Sky-core spell;
        //     NOT deal-payload actions. ---
        vm.startPrank(skyCore);
        IBeaconAdminLike(pauPrime.beacon).setIntegration(
            "NFAT_PRIME_FACET", FacetRegistration.primeFacetConfig(primeFacet)
        );
        IBeaconAdminLike(pauPrime.beacon).setIntegration(
            "NFAT_HALO_FACET", FacetRegistration.haloFacetConfig(haloFacet)
        );
        // The LitePSM is whitelist-gated: the Halo ALMProxy must be kissed to swap (the facility
        // operator converts between deployment/repayment currencies; the Prime side stays USDS).
        IPSMLike(IChainlogLike(CHAINLOG).getAddress("MCD_LITE_PSM_USDC_A")).kiss(pauHalo.almProxy);
        vm.stopPrank();
    }

    function _deployStack() internal returns (PAUInstance memory pau) {
        (pau.accessControls, pau.almProxy, pau.rateLimits, pau.controller) =
            PAUDeploy.deploy(PAUDeployParams({ pauFactory: PAU_FACTORY, owner: executor }));
        pau.beacon = IPAUFactoryLike(PAU_FACTORY).beacon();
    }

    /// @notice Leg 3: cast — Sky core plots the payload on the StarGuard (address + codehash),
    ///         then exec() has the SubProxy delegatecall its `execute()` — the pattern-spells /
    ///         obex-gov-relay activation path, against the real INTERVAL_STARGUARD.
    function _executePayload(address payload) internal {
        vm.prank(skyCore);
        IStarGuardLike(INTERVAL_STARGUARD).plot(payload, payload.codehash);

        address executed = IStarGuardLike(INTERVAL_STARGUARD).exec();
        require(executed == payload, "SpellRunner/starguard-exec-mismatch");
    }

}

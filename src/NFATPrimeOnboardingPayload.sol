// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { PAUInit, PAUInstance } from "./dependencies/PAUInit.sol";
import {
    AdministeredAgentInit,
    AdministeredAgentInitParams
} from "./dependencies/AdministeredAgentInit.sol";

import { NFATPayloadBase } from "./NFATPayloadBase.sol";

import { IControllerDispatchLike } from "./interfaces/IControllerDispatchLike.sol";

interface IRateLimitsLike {
    function setRateLimitData(bytes32 key, uint256 maxAmount, uint256 slope) external;
}

interface IVaultLike {
    function rely(address usr) external;
}

interface IBufferLike {
    function approve(address asset, address spender, uint256 amount) external;
}

/**
 * @title  NFATPrimeOnboardingPayload (example)
 * @notice Onboards the **subscriber / investor side** of an NFAT deal. The Prime PAU invests
 *         INTO a facility operated by another star (the Halo side): it mints USDS, subscribes,
 *         holds the issued NFAT in its ALMProxy, and collects repayments. The facility is NOT
 *         this star's — it is initialized by the Halo payload, never here.
 *
 *         1. PAUInit.init — this stack's Controller roles + [NFAT_PRIME, USDS] integrations
 *            (facet registration on the Beacon is a Sky-core action);
 *         2. PAUInit.addAllocator + AdministeredAgentInit.init — agent routing for the relayer;
 *         3. USDS mint wiring — the USDS facet draws from the Interval allocator vault:
 *            `usds_setVault`, `vault.rely(almProxy)`, `buffer.approve(usds, almProxy)`;
 *         4. rate limits — subscribe / withdraw / collect on the deal facility and the USDS
 *            mint limit, slope = cap / 1 day (Sky ALM convention). No PSM here: this side only
 *            mints and deploys USDS — swaps live on the Halo (facility-operator) side.
 */
contract NFATPrimeOnboardingPayload is NFATPayloadBase {

    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;

    // Interval allocation system (owned by the SubProxy executing this payload).
    address internal constant ALLOCATOR_INTERVAL_A_VAULT  = 0xDD3bE7650589E6A6171d454b026C4AD1a2C02720;
    address internal constant ALLOCATOR_INTERVAL_A_BUFFER = 0x67Ac5c8FbFDAc5265c995e9B2ACd830496438AfD;

    // Deal rate limits (example values). Slope = cap / 1 day: a fully-consumed limit recharges
    // linearly back to the cap over a day — the convention used across Sky ALM spells.
    uint256 internal constant SUBSCRIBE_LIMIT = 5_000_000e18;
    uint256 internal constant SUBSCRIBE_SLOPE = SUBSCRIBE_LIMIT / 1 days;
    uint256 internal constant WITHDRAW_LIMIT  = 5_000_000e18;
    uint256 internal constant WITHDRAW_SLOPE  = WITHDRAW_LIMIT / 1 days;
    uint256 internal constant COLLECT_LIMIT   = 2_000_000e18;
    uint256 internal constant COLLECT_SLOPE   = COLLECT_LIMIT / 1 days;
    uint256 internal constant USDS_MINT_LIMIT = 1_000_000e18;
    uint256 internal constant USDS_MINT_SLOPE = USDS_MINT_LIMIT / 1 days;

    address public immutable accessControls;
    address public immutable almProxy;
    address public immutable beacon;
    address public immutable controller;
    address public immutable rateLimits;
    address public immutable agent;
    address public immutable facility; // the Halo star's facility this PAU subscribes into
    address public immutable relayer;

    constructor(PAUInstance memory pau, address agent_, address facility_, address relayer_) {
        accessControls = pau.accessControls;
        almProxy       = pau.almProxy;
        beacon         = pau.beacon;
        controller     = pau.controller;
        rateLimits     = pau.rateLimits;
        agent          = agent_;
        facility       = facility_;
        relayer        = relayer_;
    }

    function _execute() internal override {
        PAUInstance memory pau = PAUInstance({
            accessControls: accessControls,
            almProxy:       almProxy,
            beacon:         beacon,
            controller:     controller,
            rateLimits:     rateLimits
        });

        // 1. PAU: this stack's Controller roles + this side's integrations.
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = "NFAT_PRIME_FACET";
        ids[1] = "USDS_FACET";
        PAUInit.init(pau, ids);

        // 2. Agent: allocator role + relayer as actor.
        PAUInit.addAllocator(pau, agent);

        address[] memory actors = new address[](1);
        actors[0] = relayer;
        AdministeredAgentInit.init(agent, AdministeredAgentInitParams({
            admins:   new address[](0), //Note: Add extra admins such as PAS if applicable
            actors:   actors,
            grantors: new address[](0), //Note: Add grantors if applicable
            revokers: new address[](0)  //Note: Add revokers if applicable
        }));

        // 3. USDS mint wiring: the USDS facet mints by drawing from the Interval allocator vault
        //    into its buffer, then pulling into the ALMProxy — the same wiring as
        //    spark-alm-controller's initAlmSystem. This SubProxy owns the vault and buffer.
        IControllerDispatchLike c = IControllerDispatchLike(controller);

        c.usds_setVault(ALLOCATOR_INTERVAL_A_VAULT);
        IVaultLike(ALLOCATOR_INTERVAL_A_VAULT).rely(almProxy);
        IBufferLike(ALLOCATOR_INTERVAL_A_BUFFER).approve(USDS, almProxy, type(uint256).max);

        // 4. Rate limits: deal-specific caps + slopes (inlined spell calls — deliberately not
        //    init-library surface; the values are deal parameters).
        IRateLimitsLike(rateLimits).setRateLimitData(
            c.nfatPrime_getSubscribeRateLimitKey(facility, USDS), SUBSCRIBE_LIMIT, SUBSCRIBE_SLOPE
        );
        IRateLimitsLike(rateLimits).setRateLimitData(
            c.nfatPrime_getWithdrawRateLimitKey(facility), WITHDRAW_LIMIT, WITHDRAW_SLOPE
        );
        IRateLimitsLike(rateLimits).setRateLimitData(
            c.nfatPrime_getCollectRateLimitKey(facility), COLLECT_LIMIT, COLLECT_SLOPE
        );
        IRateLimitsLike(rateLimits).setRateLimitData(
            c.usds_mintRateLimitKey(), USDS_MINT_LIMIT, USDS_MINT_SLOPE
        );
    }

}

// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { DssInstance, MCD } from "dss-test/MCD.sol";

import { PAUInit, PAUInstance } from "./dependencies/PAUInit.sol";
import {
    AdministeredAgentInit,
    AdministeredAgentInitParams
} from "./dependencies/AdministeredAgentInit.sol";
import { NFATInit, NFATConfig } from "./dependencies/NFATInit.sol";

import { NFATPayloadBase } from "./NFATPayloadBase.sol";

import { IControllerDispatchLike } from "./interfaces/IControllerDispatchLike.sol";

interface IRateLimitsLike {
    function setRateLimitData(bytes32 key, uint256 maxAmount, uint256 slope) external;
}

/**
 * @title  NFATHaloOnboardingPayload (example)
 * @notice Onboards the **borrower / facility-operator side** of an NFAT deal. The Halo PAU runs
 *         the facility: it issues NFATs against subscriptions and repays principal + interest
 *         through its ALMProxy. Because the facility belongs to THIS star, the facility
 *         initialization (`NFATInit`) lives here — never in the Prime (subscriber-side) payload.
 *
 *         1. PAUInit.init — this stack's Controller roles + [NFAT_HALO_FACET] integration
 *            (facet registration on the Beacon is a Sky-core action, NOT done here);
 *         2. PAUInit.addAllocator + AdministeredAgentInit.init — agent routing for the relayer,
 *            plus a revoker for incident response (can cut off a compromised relayer);
 *         3. NFATInit.init — the deal facility, wired with recipient + bud = THIS stack's
 *            ALMProxy (issued principal flows here; repayments flow back out of here), plus a
 *            freezer for incident response (can stop() the facility);
 *         4. nfatHalo_setMaxAnnualGrowthRate — deal risk parameter;
 *         5. rate limits — issue (keyed per subscriber — the Prime star's ALMProxy) /
 *            repayPrincipal / repayInterest, plus the PSM USDC<->USDS swap limits (this side
 *            converts between deployment/repayment currencies; the LitePSM needs no extra
 *            wiring — tin = tout = 0 — but the ALMProxy must be kissed on it, a Sky-core
 *            action), and the TransferAsset offramp limit (USDC -> the deal's custodian /
 *            borrower destination — how deployed principal actually leaves the proxy),
 *            slope = cap / 1 day (Sky ALM convention).
 */
contract NFATHaloOnboardingPayload is NFATPayloadBase {

    address internal constant CHAINLOG = 0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F;
    address internal constant USDS     = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address internal constant USDC     = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    string internal constant FACILITY_NAME   = "NFAT Example Deal";
    string internal constant FACILITY_SYMBOL = "NFAT-EX";

    // Deal parameters (example values). Slope = cap / 1 day.
    uint256 internal constant MAX_ANNUAL_GROWTH_RATE = 0.20e18; // 20% APR cap
    uint256 internal constant ISSUE_LIMIT            = 5_000_000e18;
    uint256 internal constant ISSUE_SLOPE            = ISSUE_LIMIT / 1 days;
    uint256 internal constant REPAY_PRINCIPAL_LIMIT  = 5_000_000e18;
    uint256 internal constant REPAY_PRINCIPAL_SLOPE  = REPAY_PRINCIPAL_LIMIT / 1 days;
    uint256 internal constant REPAY_INTEREST_LIMIT   = 1_000_000e18;
    uint256 internal constant REPAY_INTEREST_SLOPE   = REPAY_INTEREST_LIMIT / 1 days;
    uint256 internal constant PSM_SWAP_LIMIT         = 2_000_000e6; // USDC precision
    uint256 internal constant PSM_SWAP_SLOPE         = PSM_SWAP_LIMIT / 1 days;
    uint256 internal constant OFFRAMP_LIMIT          = 2_000_000e6; // USDC precision
    uint256 internal constant OFFRAMP_SLOPE          = OFFRAMP_LIMIT / 1 days;

    address public immutable accessControls;
    address public immutable almProxy;
    address public immutable beacon;
    address public immutable controller;
    address public immutable rateLimits;
    address public immutable agent;
    address public immutable facility;
    address public immutable relayer;
    address public immutable subscriber; // the Prime star's ALMProxy (issue limits key on it)
    address public immutable offramp;    // deal custodian / borrower destination for deployed USDC
    address public immutable revoker;    // incident response: can revoke the relayer (agent actor)
    address public immutable freezer;    // incident response: can stop() the facility

    constructor(
        PAUInstance memory pau,
        address agent_,
        address facility_,
        address relayer_,
        address subscriber_,
        address offramp_,
        address revoker_,
        address freezer_
    ) {
        accessControls = pau.accessControls;
        almProxy       = pau.almProxy;
        beacon         = pau.beacon;
        controller     = pau.controller;
        rateLimits     = pau.rateLimits;
        agent          = agent_;
        facility       = facility_;
        relayer        = relayer_;
        subscriber     = subscriber_;
        offramp        = offramp_;
        revoker        = revoker_;
        freezer        = freezer_;
    }

    function _execute() internal override {
        DssInstance memory dss = MCD.loadFromChainlog(CHAINLOG);

        PAUInstance memory pau = PAUInstance({
            accessControls: accessControls,
            almProxy:       almProxy,
            beacon:         beacon,
            controller:     controller,
            rateLimits:     rateLimits
        });

        // 1. PAU: this stack's Controller roles + the Halo integration.
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = "NFAT_HALO_FACET";
        ids[1] = "PSM_FACET";
        ids[2] = "TRANSFER_ASSET_FACET";
        PAUInit.init(pau, ids);

        // 2. Agent: allocator role + relayer as actor.
        PAUInit.addAllocator(pau, agent);

        address[] memory actors = new address[](1);
        actors[0] = relayer;
        // Incident response: a revoker can removeActor(relayer) to cut off a compromised operator
        // fast, without waiting on the governance path.
        address[] memory revokers = new address[](1);
        revokers[0] = revoker;
        AdministeredAgentInit.init(agent, AdministeredAgentInitParams({
            admins:   new address[](0), //Note: Add extra admins such as PAS if applicable
            actors:   actors,
            grantors: new address[](0), //Note: Add grantors if applicable
            revokers: revokers
        }));

        // 3. NFAT: the deal facility — recipient + bud = THIS stack's ALMProxy. The Halo facet
        //    issues and repays through it. No operators: issuance goes through the facet.
        //    (No chainlog registration: stars track addresses in their own registry.)
        // Incident response: a freezer (cop) can stop() the facility to halt issue / subscribe /
        // repay / collect immediately if something goes wrong with the deal.
        address[] memory freezers = new address[](1);
        freezers[0] = freezer;
        NFATInit.init(dss, facility, NFATConfig({
            name:            FACILITY_NAME,
            symbol:          FACILITY_SYMBOL,
            almProxy:        almProxy,
            identityNetwork: address(0),
            baseURI:         "",
            operators:       new address[](0),
            freezers:        freezers
        }));

        // 4. Deal risk parameter: interest growth cap.
        IControllerDispatchLike c = IControllerDispatchLike(controller);
        c.nfatHalo_setMaxAnnualGrowthRate(facility, MAX_ANNUAL_GROWTH_RATE);

        // 5. Rate limits (issue limits are keyed per subscriber — the Prime star's ALMProxy).
        IRateLimitsLike(rateLimits).setRateLimitData(
            c.nfatHalo_getIssueRateLimitKey(facility, subscriber), ISSUE_LIMIT, ISSUE_SLOPE
        );
        IRateLimitsLike(rateLimits).setRateLimitData(
            c.nfatHalo_getRepayPrincipalRateLimitKey(facility, USDS),
            REPAY_PRINCIPAL_LIMIT,
            REPAY_PRINCIPAL_SLOPE
        );
        IRateLimitsLike(rateLimits).setRateLimitData(
            c.nfatHalo_getRepayInterestRateLimitKey(facility, USDS),
            REPAY_INTEREST_LIMIT,
            REPAY_INTEREST_SLOPE
        );
        IRateLimitsLike(rateLimits).setRateLimitData(
            c.psm_usdcToUSDSSwapRateLimitKey(), PSM_SWAP_LIMIT, PSM_SWAP_SLOPE
        );
        IRateLimitsLike(rateLimits).setRateLimitData(
            c.psm_usdsToUSDCSwapRateLimitKey(), PSM_SWAP_LIMIT, PSM_SWAP_SLOPE
        );

        // Offramp: rate-limited per (asset, destination) — the ONLY door deployed USDC can
        // leave the ALMProxy through, and only to the reviewed destination.
        IRateLimitsLike(rateLimits).setRateLimitData(
            c.transferAsset_getTransferRateLimitKey(USDC, offramp), OFFRAMP_LIMIT, OFFRAMP_SLOPE
        );
    }

}

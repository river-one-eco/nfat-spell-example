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
 * @notice One prime subscriber of the deal and its issue rate limit.
 * @param  subscriber The Prime star's ALMProxy — the address NFATs are issued `to`, and the key
 *                    the Halo facet's issue rate limit is scoped on.
 * @param  maxAmount  The issue rate-limit cap for this subscriber (USDS, 18 decimals)
 * @param  slope      The issue rate-limit recharge slope (USDS per second).
 */
struct Subscriber {
    address subscriber;
    uint256 maxAmount;
    uint256 slope;
}

/**
 * @title  NFATHaloOnboardingPayload (example)
 * @notice Onboards the **borrower / facility-operator side** of an NFAT deal. The Halo PAU runs
 *         the facility: it issues NFATs against subscriptions and repays principal + interest
 *         through its ALMProxy. Because the facility belongs to THIS star, the facility
 *         initialization (`NFATInit`) lives here — never in the Prime (subscriber-side) payload.
 *
 *         1. PAUInit.init — this stack's Controller roles + [NFAT_HALO_FACET, PSM_FACET,
 *            TRANSFER_ASSET_FACET] integrations (facet registration on the Beacon is a Sky-core
 *            action, NOT done here);
 *         2. PAUInit.addAllocator + AdministeredAgentInit.init — agent routing for the relayer,
 *            plus a revoker for incident response (can cut off a compromised relayer);
 *         3. NFATInit.init — the deal facility, wired with recipient + bud = THIS stack's
 *            ALMProxy (issued principal flows here; repayments flow back out of here), plus a
 *            freezer for incident response (can stop() the facility);
 *         4. nfatHalo_setMaxAnnualGrowthRate — deal risk parameter;
 *         5. rate limits — one issue limit PER SUBSCRIBER (keyed on each Prime star's ALMProxy,
 *            with that subscriber's own cap + slope) / repayPrincipal / repayInterest, plus the PSM
 *            USDC<->USDS swap limits (this side
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

    // The deal's prime subscribers (example placeholders). In a real spell each one is that Prime
    // star's ALMProxy, declared `constant` with a trusted source (its address registry / the
    // approved forum post), per the star-spell reviewer checklist. See `_subscribers()`.
    address internal constant PRIME_A_ALM_PROXY = 0x1111111111111111111111111111111111111111;
    address internal constant PRIME_B_ALM_PROXY = 0x2222222222222222222222222222222222222222;

    address public immutable accessControls;
    address public immutable almProxy;
    address public immutable beacon;
    address public immutable controller;
    address public immutable rateLimits;
    address public immutable agent;
    address public immutable facility;
    address public immutable relayer;
    address public immutable offramp;    // deal custodian / borrower destination for deployed USDC
    address public immutable revoker;    // incident response: can revoke the relayer (agent actor)
    address public immutable freezer;    // incident response: can stop() the facility

    error NoSubscribers();
    error ZeroSubscriber(uint256 index);
    error ZeroMaxAmount(uint256 index);
    error ZeroSlope(uint256 index);
    error DuplicateSubscriber(uint256 index);

    constructor(
        PAUInstance memory pau,
        address agent_,
        address facility_,
        address relayer_,
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
        offramp        = offramp_;
        revoker        = revoker_;
        freezer        = freezer_;
    }

    /// @notice The deal's prime subscribers and their issue limits, as `_execute` will apply them.
    function subscribers() external view returns (Subscriber[] memory) {
        return _subscribers();
    }

    /**
     * @notice The deal's prime subscribers (each Prime star's ALMProxy + its issue limit).
     * @dev    Built from constants — the payload is DELEGATECALLed by the SubProxy, so it must hold
     *         no storage (every contract variable is `constant` or `immutable`, per the reviewer
     *         checklist). `virtual` so a test harness can substitute dynamically deployed stacks.
     */
    function _subscribers() internal view virtual returns (Subscriber[] memory subs) {
        subs = new Subscriber[](2);
        subs[0] = Subscriber({
            subscriber: PRIME_A_ALM_PROXY,
            maxAmount:  5_000_000e18,
            slope:      uint256(5_000_000e18) / 1 days
        });
        subs[1] = Subscriber({
            subscriber: PRIME_B_ALM_PROXY,
            maxAmount:  2_500_000e18,
            slope:      uint256(2_500_000e18) / 1 days
        });
    }

    /// @dev Rejects an empty list, zero addresses, zero caps / slopes (a limit that never
    ///      recharges) and duplicates (a later entry would silently overwrite an earlier one).
    function _validate(Subscriber[] memory subs) internal pure {
        if (subs.length == 0) revert NoSubscribers();

        for (uint256 i = 0; i < subs.length; ++i) {
            if (subs[i].subscriber == address(0)) revert ZeroSubscriber(i);
            if (subs[i].maxAmount == 0)           revert ZeroMaxAmount(i);
            if (subs[i].slope == 0)               revert ZeroSlope(i);
            for (uint256 j = 0; j < i; ++j) {
                if (subs[j].subscriber == subs[i].subscriber) revert DuplicateSubscriber(i);
            }
        }
    }

    function _execute() internal override {
        // Fail fast on a bad subscriber list, before any state is touched.
        Subscriber[] memory subs = _subscribers();
        _validate(subs);

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
            gemKey:          "USDS",
            name:            FACILITY_NAME,
            symbol:          FACILITY_SYMBOL,
            almProxy:        almProxy,
            identityNetwork: address(0),
            baseURI:         "",
            operators:       new address[](0),
            freezers:        freezers
        }));

        // 4. Deal risk parameter: interest growth cap (20% APR).
        IControllerDispatchLike c = IControllerDispatchLike(controller);
        c.nfatHalo_setMaxAnnualGrowthRate(facility, 0.20e18);

        // 5. Rate limits. Issue limits are keyed per subscriber (each Prime star's ALMProxy), each
        //    with its own cap + slope.
        for (uint256 i = 0; i < subs.length; ++i) {
            IRateLimitsLike(rateLimits).setRateLimitData(
                c.nfatHalo_getIssueRateLimitKey(facility, subs[i].subscriber),
                subs[i].maxAmount,
                subs[i].slope
            );
        }

        // NFAT Halo Rate Limits
        IRateLimitsLike(rateLimits).setRateLimitData(
            c.nfatHalo_getRepayPrincipalRateLimitKey(facility, USDS),
            5_000_000e18,
            uint256(5_000_000e18) / 1 days
        );
        IRateLimitsLike(rateLimits).setRateLimitData(
            c.nfatHalo_getRepayInterestRateLimitKey(facility, USDS),
            1_000_000e18,
            uint256(1_000_000e18) / 1 days
        );

        // PSM swaps (USDC precision eth-mainnet) Rate Limits
        IRateLimitsLike(rateLimits).setRateLimitData(
            c.psm_usdcToUSDSSwapRateLimitKey(), 2_000_000e6, uint256(2_000_000e6) / 1 days
        );
        IRateLimitsLike(rateLimits).setRateLimitData(
            c.psm_usdsToUSDCSwapRateLimitKey(), 2_000_000e6, uint256(2_000_000e6) / 1 days
        );

        // Offramp (USDC precision eth-mainnet) Rate Limits
        IRateLimitsLike(rateLimits).setRateLimitData(
            c.transferAsset_getTransferRateLimitKey(USDC, offramp),
            2_000_000e6,
            uint256(2_000_000e6) / 1 days
        );
    }

}

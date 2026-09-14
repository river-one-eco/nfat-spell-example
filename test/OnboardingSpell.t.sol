// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { SpellRunner } from "./SpellRunner.sol";

import { NFATPrimeOnboardingPayload }            from "../src/NFATPrimeOnboardingPayload.sol";
import { NFATHaloOnboardingPayload, Subscriber } from "../src/NFATHaloOnboardingPayload.sol";

import { NFATHaloOnboardingPayloadHarness } from "./NFATHaloOnboardingPayloadHarness.sol";

import { IControllerDispatchLike } from "../src/interfaces/IControllerDispatchLike.sol";

import {
    IAccessControlLike,
    IALMProxyLike,
    IRateLimitsLike,
    IAdministeredAgentLike,
    IERC20Like,
    INFATFacilityLike
} from "./Interfaces.sol";

interface IRateLimitsDataLike {
    struct RateLimitData {
        uint256 maxAmount;
        uint256 slope;
        uint256 lastAmount;
        uint256 lastUpdated;
    }
    function getRateLimitData(bytes32 key) external view returns (RateLimitData memory data);
}

/**
 * @notice End-to-end demonstration of one NFAT deal between two PAU stacks: the Halo payload
 *         onboards the facility-operator side, the Prime payload onboards the subscriber side,
 *         and the full lifecycle crosses between them — Prime mints + subscribes, Halo issues
 *         (NFT to the Prime ALMProxy, principal to the Halo ALMProxy), interest accrues, Halo
 *         repays, Prime collects. Cast via the real Interval StarGuard.
 */
contract OnboardingSpell_Fork_Test is SpellRunner {

    bytes32 internal constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // The Prime star's issue rate limit on the Halo side (cap = its deal commitment, slope = cap / day).
    uint256 internal constant PRIME_ISSUE_LIMIT = 5_000_000e18;

    IControllerDispatchLike internal cPrime;
    IControllerDispatchLike internal cHalo;

    function setUp() external {
        vm.createSelectFork("mainnet", 25807575);
        _setUpWorld();

        cPrime = IControllerDispatchLike(pauPrime.controller);
        cHalo  = IControllerDispatchLike(pauHalo.controller);
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _castPayloads() internal {
        Subscriber[] memory subs = new Subscriber[](1);
        subs[0] = _sub(pauPrime.almProxy, PRIME_ISSUE_LIMIT);
        _castPayloads(subs);
    }

    function _castPayloads(Subscriber[] memory subs) internal {
        // Facility side first (it initializes the facility), then the subscriber side.
        _executePayload(address(_newHaloPayload(subs)));
        _executePayload(address(new NFATPrimeOnboardingPayload(
            pauPrime, agentPrime, facility, relayerPrime
        )));
    }

    /// @dev The Halo payload lists its subscribers as constants; the harness overrides
    ///      `_subscribers()` so the test can point at the Prime stack it deployed at runtime.
    function _newHaloPayload(Subscriber[] memory subs) internal returns (NFATHaloOnboardingPayload) {
        return new NFATHaloOnboardingPayloadHarness(
            pauHalo, agentHalo, facility, relayerHalo, borrower, revokerHalo, facilityFreezer, subs
        );
    }

    /// @dev Subscriber with the Sky ALM convention slope = cap / 1 day.
    function _sub(address subscriber, uint256 maxAmount) internal pure returns (Subscriber memory) {
        return Subscriber({ subscriber: subscriber, maxAmount: maxAmount, slope: maxAmount / 1 days });
    }

    function _issueLimit(address subscriber) internal view returns (uint256) {
        return IRateLimitsLike(pauHalo.rateLimits).getCurrentRateLimit(
            cHalo.nfatHalo_getIssueRateLimitKey(facility, subscriber)
        );
    }

    function _primeCall(bytes memory data) internal {
        vm.prank(relayerPrime);
        IAdministeredAgentLike(agentPrime).call(pauPrime.controller, data);
    }

    function _haloCall(bytes memory data) internal {
        vm.prank(relayerHalo);
        IAdministeredAgentLike(agentHalo).call(pauHalo.controller, data);
    }

    /**********************************************************************************************/
    /*** Wiring                                                                                 ***/
    /**********************************************************************************************/

    function test_onboarding_wiresBothSides() external {
        // Preconditions: nothing configured yet.
        assertEq(INFATFacilityLike(facility).recipient(), address(0));

        _castPayloads();

        // Halo side: its Controller wired, its agent an allocator, relayer an actor, and the
        // facility's recipient + bud = the HALO ALMProxy (the facility belongs to this side).
        assertTrue(
            IAccessControlLike(pauHalo.almProxy).hasRole(
                IALMProxyLike(pauHalo.almProxy).CONTROLLER(), pauHalo.controller
            )
        );
        assertTrue(IAccessControlLike(pauHalo.accessControls).hasRole(ALLOCATOR_ROLE, agentHalo));
        assertTrue(IAdministeredAgentLike(agentHalo).getIsActor(relayerHalo));

        // Incident-response roles: a revoker on the agent (can cut off the relayer) and a freezer
        // (cop) on the facility (can stop() it).
        assertTrue(IAdministeredAgentLike(agentHalo).getIsRevoker(revokerHalo));
        assertEq(INFATFacilityLike(facility).cops(facilityFreezer), 1);

        assertEq(INFATFacilityLike(facility).recipient(),          pauHalo.almProxy);
        assertEq(INFATFacilityLike(facility).buds(pauHalo.almProxy), 1);

        // Prime side: its own stack wired; it holds NO facility role beyond being a subscriber.
        assertTrue(
            IAccessControlLike(pauPrime.almProxy).hasRole(
                IALMProxyLike(pauPrime.almProxy).CONTROLLER(), pauPrime.controller
            )
        );
        assertTrue(IAccessControlLike(pauPrime.accessControls).hasRole(ALLOCATOR_ROLE, agentPrime));
        assertTrue(IAdministeredAgentLike(agentPrime).getIsActor(relayerPrime));

        assertEq(INFATFacilityLike(facility).buds(pauPrime.almProxy), 0);

        // Rate limits landed on each side's own RateLimits.
        assertEq(
            IRateLimitsLike(pauPrime.rateLimits).getCurrentRateLimit(
                cPrime.nfatPrime_getSubscribeRateLimitKey(facility, usds)
            ),
            5_000_000e18
        );
        assertEq(_issueLimit(pauPrime.almProxy), PRIME_ISSUE_LIMIT);

        // The offramp (TransferAsset) limit: USDC can only leave the Halo proxy to the
        // reviewed borrower destination, rate-limited.
        assertEq(
            IRateLimitsLike(pauHalo.rateLimits).getCurrentRateLimit(
                cHalo.transferAsset_getTransferRateLimitKey(USDC, borrower)
            ),
            2_000_000e6
        );

        // PSM swap limits live on the HALO side only (it converts repayment currencies).
        assertEq(
            IRateLimitsLike(pauHalo.rateLimits).getCurrentRateLimit(
                cHalo.psm_usdsToUSDCSwapRateLimitKey()
            ),
            2_000_000e6
        );
        // The Prime controller doesn't even have the PSM facet integrated: dispatching a psm_*
        // selector through the Prime agent hits the Controller's fallback with no wired facet and
        // reverts with CallSelectorNotWired(psm_swapUSDSToUSDC).
        vm.prank(relayerPrime);
        vm.expectRevert(
            abi.encodeWithSignature(
                "CallSelectorNotWired(bytes4)", IControllerDispatchLike.psm_swapUSDSToUSDC.selector
            )
        );
        IAdministeredAgentLike(agentPrime).call(
            pauPrime.controller,
            abi.encodeWithSelector(IControllerDispatchLike.psm_swapUSDSToUSDC.selector, uint256(1))
        );

        // And its RateLimits holds nothing at the PSM key.
        assertEq(
            IRateLimitsLike(pauPrime.rateLimits).getCurrentRateLimit(
                cHalo.psm_usdsToUSDCSwapRateLimitKey()
            ),
            0
        );
    }

    /**********************************************************************************************/
    /*** Multiple subscribers                                                                   ***/
    /**********************************************************************************************/

    /// @notice An NFAT may have several prime subscribers, each with its own issue limit. The Halo
    ///         payload sets one issue limit per subscriber, with exactly the cap + slope given,
    ///         and leaves every other address with no issue limit at all.
    function test_onboarding_multipleSubscribers() external {
        address prime2 = makeAddr("prime2ALMProxy");
        address prime3 = makeAddr("prime3ALMProxy");

        Subscriber[] memory subs = new Subscriber[](3);
        subs[0] = _sub(pauPrime.almProxy, PRIME_ISSUE_LIMIT);
        subs[1] = _sub(prime2,            2_500_000e18);
        // Not the cap / 1 day convention: an explicit 1 USDS/sec recharge — the slope is taken as given.
        subs[2] = Subscriber({ subscriber: prime3, maxAmount: 750_000e18, slope: 1e18 });

        NFATHaloOnboardingPayload payload = _newHaloPayload(subs);

        // The payload exposes what it will apply.
        Subscriber[] memory listed = payload.subscribers();
        assertEq(listed.length, 3);
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(listed[i].subscriber, subs[i].subscriber);
            assertEq(listed[i].maxAmount,  subs[i].maxAmount);
            assertEq(listed[i].slope,      subs[i].slope);
        }

        _executePayload(address(payload));

        // One issue limit per subscriber with exactly the configured cap + slope.
        for (uint256 i = 0; i < 3; ++i) {
            IRateLimitsDataLike.RateLimitData memory d = IRateLimitsDataLike(pauHalo.rateLimits)
                .getRateLimitData(cHalo.nfatHalo_getIssueRateLimitKey(facility, subs[i].subscriber));
            assertEq(d.maxAmount, subs[i].maxAmount);
            assertEq(d.slope,     subs[i].slope);
            assertEq(_issueLimit(subs[i].subscriber), subs[i].maxAmount);
        }

        // A non-subscriber has no issue limit.
        assertEq(_issueLimit(makeAddr("notASubscriber")), 0);

        // The aggregate repay limits are unchanged by the number of subscribers.
        assertEq(
            IRateLimitsLike(pauHalo.rateLimits).getCurrentRateLimit(
                cHalo.nfatHalo_getRepayPrincipalRateLimitKey(facility, usds)
            ),
            5_000_000e18
        );
    }

    /// @notice Issuance is enforced per subscriber: a second prime can only be issued up to ITS
    ///         cap, regardless of headroom on the others.
    function test_issueLimit_isPerSubscriber() external {
        address prime2 = makeAddr("prime2ALMProxy");

        Subscriber[] memory subs = new Subscriber[](2);
        subs[0] = _sub(pauPrime.almProxy, PRIME_ISSUE_LIMIT);
        subs[1] = _sub(prime2,            1_000_000e18);
        _castPayloads(subs);

        // Both subscribe 2M so the facility holds enough deposit for either issue.
        uint256 depositAmount = 2_000_000e18;
        deal(usds, pauPrime.almProxy, depositAmount);
        _primeCall(abi.encodeWithSelector(
            IControllerDispatchLike.nfatPrime_subscribe.selector, facility, depositAmount, ""
        ));
        deal(usds, prime2, depositAmount);
        vm.startPrank(prime2);
        IERC20Like(usds).approve(facility, depositAmount);
        INFATFacilityLike(facility).subscribe(depositAmount, "");
        vm.stopPrank();

        // 1.5M to prime2 exceeds its 1M cap -> rate limited, even though the first prime has 5M
        // of headroom.
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        _haloCall(abi.encodeWithSelector(
            IControllerDispatchLike.nfatHalo_issue.selector, facility, prime2, 1, 1_500_000e18
        ));

        // 1M to prime2 is exactly its cap -> succeeds and drains its limit to 0.
        _haloCall(abi.encodeWithSelector(
            IControllerDispatchLike.nfatHalo_issue.selector, facility, prime2, 1, 1_000_000e18
        ));
        assertEq(INFATFacilityLike(facility).ownerOf(1), prime2);
        assertEq(_issueLimit(prime2),            0);
        assertEq(_issueLimit(pauPrime.almProxy), PRIME_ISSUE_LIMIT);

        // The first prime's limit is untouched: 1.5M to it goes through.
        _haloCall(abi.encodeWithSelector(
            IControllerDispatchLike.nfatHalo_issue.selector, facility, pauPrime.almProxy, 2, 1_500_000e18
        ));
        assertEq(INFATFacilityLike(facility).ownerOf(2), pauPrime.almProxy);
        assertEq(_issueLimit(pauPrime.almProxy), PRIME_ISSUE_LIMIT - 1_500_000e18);
    }

    /// @notice The subscriber list is validated first thing in `_execute`, before any state is
    ///         touched, so a bad list reverts the whole cast atomically. Exercised via a direct
    ///         `execute()` call: the validation runs before the first external call either way.
    function test_execute_validatesSubscribers() external {
        // Empty list.
        Subscriber[] memory none = new Subscriber[](0);
        NFATHaloOnboardingPayload p_none = _newHaloPayload(none);
        vm.expectRevert(NFATHaloOnboardingPayload.NoSubscribers.selector);
        p_none.execute();

        // Zero address.
        Subscriber[] memory zeroAddr = new Subscriber[](2);
        zeroAddr[0] = _sub(pauPrime.almProxy, 1e18);
        zeroAddr[1] = _sub(address(0),        1e18);
        NFATHaloOnboardingPayload p_zeroAddr = _newHaloPayload(zeroAddr);
        vm.expectRevert(abi.encodeWithSelector(NFATHaloOnboardingPayload.ZeroSubscriber.selector, 1));
        p_zeroAddr.execute();

        // Zero cap.
        Subscriber[] memory zeroMax = new Subscriber[](1);
        zeroMax[0] = Subscriber({ subscriber: pauPrime.almProxy, maxAmount: 0, slope: 1 });
        NFATHaloOnboardingPayload p_zeroMax = _newHaloPayload(zeroMax);
        vm.expectRevert(abi.encodeWithSelector(NFATHaloOnboardingPayload.ZeroMaxAmount.selector, 0));
        p_zeroMax.execute();

        // Zero slope (the limit would never recharge).
        Subscriber[] memory zeroSlope = new Subscriber[](1);
        zeroSlope[0] = Subscriber({ subscriber: pauPrime.almProxy, maxAmount: 1e18, slope: 0 });
        NFATHaloOnboardingPayload p_zeroSlope = _newHaloPayload(zeroSlope);
        vm.expectRevert(abi.encodeWithSelector(NFATHaloOnboardingPayload.ZeroSlope.selector, 0));
        p_zeroSlope.execute();

        // Duplicate subscriber (would silently overwrite the first limit).
        Subscriber[] memory dup = new Subscriber[](3);
        dup[0] = _sub(pauPrime.almProxy,          1e18);
        dup[1] = _sub(makeAddr("prime2ALMProxy"), 2e18);
        dup[2] = _sub(pauPrime.almProxy,          3e18);
        NFATHaloOnboardingPayload p_dup = _newHaloPayload(dup);
        vm.expectRevert(abi.encodeWithSelector(NFATHaloOnboardingPayload.DuplicateSubscriber.selector, 2));
        p_dup.execute();

        // Nothing on the Halo side was touched by the failed casts.
        assertEq(INFATFacilityLike(facility).recipient(), address(0));
    }

    /// @notice The test harness holds at most three immutable subscriber triples.
    function test_harness_rejectsMoreThanThreeSubscribers() external {
        Subscriber[] memory four = new Subscriber[](4);
        for (uint256 i = 0; i < 4; ++i) {
            four[i] = _sub(makeAddr(string(abi.encodePacked("prime", i))), 1e18);
        }
        vm.expectRevert(
            abi.encodeWithSelector(NFATHaloOnboardingPayloadHarness.TooManySubscribers.selector, 4, 3)
        );
        _newHaloPayload(four);
    }

    /// @notice The unmodified payload (no harness) casts with its constant subscriber list: one
    ///         issue limit per listed Prime ALMProxy, with exactly the constants' cap + slope.
    function test_onboarding_defaultSubscriberConstants() external {
        NFATHaloOnboardingPayload payload = new NFATHaloOnboardingPayload(
            pauHalo, agentHalo, facility, relayerHalo, borrower, revokerHalo, facilityFreezer
        );
        Subscriber[] memory subs = payload.subscribers();
        assertEq(subs.length, 2);
        assertEq(subs[0].subscriber, 0x1111111111111111111111111111111111111111);
        assertEq(subs[1].subscriber, 0x2222222222222222222222222222222222222222);

        _executePayload(address(payload));

        for (uint256 i = 0; i < subs.length; ++i) {
            IRateLimitsDataLike.RateLimitData memory d = IRateLimitsDataLike(pauHalo.rateLimits)
                .getRateLimitData(cHalo.nfatHalo_getIssueRateLimitKey(facility, subs[i].subscriber));
            assertEq(d.maxAmount, subs[i].maxAmount);
            assertEq(d.slope,     subs[i].slope);
        }
        assertEq(_issueLimit(subs[0].subscriber), 5_000_000e18);
        assertEq(_issueLimit(subs[1].subscriber), 2_500_000e18);
        assertEq(_issueLimit(pauPrime.almProxy),  0);
    }

    /**********************************************************************************************/
    /*** Full deal lifecycle across both stacks                                                 ***/
    /**********************************************************************************************/

    function test_fullDealLifecycle() external {
        _castPayloads();

        IRateLimitsLike rlPrime = IRateLimitsLike(pauPrime.rateLimits);

        uint256 mintAmount      = 1_000_000e18;
        uint256 subscribeAmount = 2_000_000e18;
        uint256 issueAmount     = 1_000_000e18;
        uint256 swapAmount      = 100_000e6; // USDC precision
        uint256 tokenId         = 1;

        // 1. Prime mints 1M USDS for real (Interval vault draw -> buffer -> Prime ALMProxy) and
        //    tops up a second million (stand-in for yield / other inflows).
        _primeCall(abi.encodeWithSelector(IControllerDispatchLike.usds_mint.selector, mintAmount));
        assertEq(IERC20Like(usds).balanceOf(pauPrime.almProxy),                mintAmount);
        assertEq(rlPrime.getCurrentRateLimit(cPrime.usds_mintRateLimitKey()), 0);

        deal(usds, pauPrime.almProxy, subscribeAmount);

        // 2. Prime subscribes 2M into the Halo star's facility.
        _primeCall(abi.encodeWithSelector(
            IControllerDispatchLike.nfatPrime_subscribe.selector, facility, subscribeAmount, ""
        ));
        assertEq(INFATFacilityLike(facility).deposits(pauPrime.almProxy), subscribeAmount);

        // 3. Halo issues a 1M NFAT against Prime's subscription: the NFT goes to the PRIME
        //    ALMProxy (the investor), the principal flows to the HALO ALMProxy (the recipient).
        _haloCall(abi.encodeWithSelector(
            IControllerDispatchLike.nfatHalo_issue.selector,
            facility, pauPrime.almProxy, tokenId, issueAmount
        ));

        assertEq(INFATFacilityLike(facility).ownerOf(tokenId),            pauPrime.almProxy);
        assertEq(INFATFacilityLike(facility).deposits(pauPrime.almProxy), subscribeAmount - issueAmount);
        assertEq(IERC20Like(usds).balanceOf(pauHalo.almProxy),            issueAmount);

        ( bool issued, uint256 outstandingPrincipal, , ) =
            cHalo.nfatHalo_getPosition(facility, tokenId);
        assertTrue(issued);
        assertEq(outstandingPrincipal, issueAmount);

        // 4. Prime withdraws its unissued 1M deposit.
        _primeCall(abi.encodeWithSelector(
            IControllerDispatchLike.nfatPrime_withdraw.selector,
            facility, subscribeAmount - issueAmount
        ));
        assertEq(INFATFacilityLike(facility).deposits(pauPrime.almProxy), 0);
        assertEq(IERC20Like(usds).balanceOf(pauPrime.almProxy),           subscribeAmount - issueAmount);

        // 5. Halo deploys the principal off-chain: converts USDS -> USDC through the LitePSM
        //    (tin = tout = 0), then OFFRAMPS the USDC to the deal's borrower destination via the
        //    TransferAsset facet — the only rate-limited exit from the proxy.
        _haloCall(abi.encodeWithSelector(
            IControllerDispatchLike.psm_swapUSDSToUSDC.selector, swapAmount
        ));
        assertEq(IERC20Like(USDC).balanceOf(pauHalo.almProxy), swapAmount);

        _haloCall(abi.encodeWithSelector(
            IControllerDispatchLike.transferAsset_transfer.selector, USDC, borrower, swapAmount
        ));
        assertEq(IERC20Like(USDC).balanceOf(pauHalo.almProxy), 0);
        assertEq(IERC20Like(USDC).balanceOf(borrower),         swapAmount);
        assertEq(
            IRateLimitsLike(pauHalo.rateLimits).getCurrentRateLimit(
                cHalo.transferAsset_getTransferRateLimitKey(USDC, borrower)
            ),
            2_000_000e6 - swapAmount
        );

        // 6. Interest accrues for 180 days at the Halo payload's 20% APR cap
        //    (~1M * 20% * 180/365 ≈ 98,630 USDS).
        vm.warp(block.timestamp + 180 days);

        uint256 interest = cHalo.nfatHalo_getCurrentMaxOutstandingInterest(facility, tokenId);
        assertApproxEqAbs(interest, 98_630e18, 1e18);

        // 7. Halo repays interest then full principal out of its ALMProxy (top up the interest
        //    portion — in production that liquidity comes from the deployed principal's yield).
        deal(usds, pauHalo.almProxy, issueAmount + interest);

        _haloCall(abi.encodeWithSelector(
            IControllerDispatchLike.nfatHalo_repayInterest.selector, facility, tokenId, interest
        ));
        _haloCall(abi.encodeWithSelector(
            IControllerDispatchLike.nfatHalo_repayPrincipal.selector, facility, tokenId, issueAmount
        ));

        ( , outstandingPrincipal, , ) = cHalo.nfatHalo_getPosition(facility, tokenId);
        assertEq(outstandingPrincipal, 0);
        assertEq(IERC20Like(usds).balanceOf(pauHalo.almProxy), 0);

        // 8. Prime collects principal + interest (the NFAT owner is its ALMProxy).
        assertEq(INFATFacilityLike(facility).collectable(tokenId), issueAmount + interest);

        _primeCall(abi.encodeWithSelector(
            IControllerDispatchLike.nfatPrime_collect.selector,
            facility, tokenId, issueAmount + interest
        ));

        // Prime ends with its full 2M back plus the earned interest.
        assertEq(IERC20Like(usds).balanceOf(pauPrime.almProxy), subscribeAmount + interest);
        assertEq(INFATFacilityLike(facility).collectable(tokenId), 0);

        // 9. Slope recharge: limits recover after ~a day.
        vm.warp(block.timestamp + 1 days + 1 hours);
        assertEq(rlPrime.getCurrentRateLimit(cPrime.usds_mintRateLimitKey()), 1_000_000e18);
        assertEq(
            rlPrime.getCurrentRateLimit(cPrime.nfatPrime_getSubscribeRateLimitKey(facility, usds)),
            5_000_000e18
        );
    }

    /**********************************************************************************************/
    /*** Incident response                                                                      ***/
    /**********************************************************************************************/

    /// @notice The three levers the onboarding wires for reacting to a compromised deal: a freezer
    ///         that stops the facility, a revoker that cuts off the relayer, and the governance
    ///         path that revokes the allocator.
    function test_incidentResponse() external {
        _castPayloads();

        // Set up a live position: Prime mints and subscribes into the Halo facility.
        uint256 amount = 1_000_000e18;
        _primeCall(abi.encodeWithSelector(IControllerDispatchLike.usds_mint.selector, amount));
        _primeCall(abi.encodeWithSelector(
            IControllerDispatchLike.nfatPrime_subscribe.selector, facility, amount, ""
        ));
        assertEq(INFATFacilityLike(facility).deposits(pauPrime.almProxy), amount);

        // 1. Freezer stops the facility — issue / subscribe / repay / collect all halt.
        assertFalse(INFATFacilityLike(facility).stopped());
        vm.prank(facilityFreezer);
        INFATFacilityLike(facility).stop();
        assertTrue(INFATFacilityLike(facility).stopped());

        // The Halo relayer can no longer issue against the subscription — the facility's
        // notStopped modifier reverts, bubbling up through the facet / controller / agent.
        vm.expectRevert("NFATFacility/stopped");
        _haloCall(abi.encodeWithSelector(
            IControllerDispatchLike.nfatHalo_issue.selector, facility, pauPrime.almProxy, 1, amount
        ));

        // 2. Revoker cuts off the Halo relayer (e.g. a compromised operator key).
        assertTrue(IAdministeredAgentLike(agentHalo).getIsActor(relayerHalo));
        vm.prank(revokerHalo);
        IAdministeredAgentLike(agentHalo).removeActor(relayerHalo);
        assertFalse(IAdministeredAgentLike(agentHalo).getIsActor(relayerHalo));

        // The revoked relayer can no longer route calls through the agent (NotActor()).
        vm.expectRevert(abi.encodeWithSignature("NotActor()"));
        _haloCall(abi.encodeWithSelector(
            IControllerDispatchLike.psm_swapUSDSToUSDC.selector, uint256(1)
        ));

        // 3. Governance (the SubProxy admin) revokes the allocator role from the agent. This
        //    example keeps allocator revocation on the governance path: AccessControls ships no
        //    built-in freezer module, so a custom module would be layered on for faster revocation.
        assertTrue(IAccessControlLike(pauHalo.accessControls).hasRole(ALLOCATOR_ROLE, agentHalo));
        vm.prank(executor);
        IAccessControlLike(pauHalo.accessControls).revokeRole(ALLOCATOR_ROLE, agentHalo);
        assertFalse(IAccessControlLike(pauHalo.accessControls).hasRole(ALLOCATOR_ROLE, agentHalo));
    }

}

// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { SpellRunner } from "./SpellRunner.sol";

import { NFATPrimeOnboardingPayload } from "../src/NFATPrimeOnboardingPayload.sol";
import { NFATHaloOnboardingPayload }  from "../src/NFATHaloOnboardingPayload.sol";

import { IControllerDispatchLike } from "../src/interfaces/IControllerDispatchLike.sol";

import {
    IAccessControlLike,
    IALMProxyLike,
    IRateLimitsLike,
    IAdministeredAgentLike,
    IERC20Like,
    INFATFacilityLike
} from "./Interfaces.sol";

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
        // Facility side first (it initializes the facility), then the subscriber side.
        _executePayload(address(new NFATHaloOnboardingPayload(
            pauHalo, agentHalo, facility, relayerHalo, pauPrime.almProxy, borrower, revokerHalo, facilityFreezer
        )));
        _executePayload(address(new NFATPrimeOnboardingPayload(
            pauPrime, agentPrime, facility, relayerPrime
        )));
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
        assertEq(
            IRateLimitsLike(pauHalo.rateLimits).getCurrentRateLimit(
                cHalo.nfatHalo_getIssueRateLimitKey(facility, pauPrime.almProxy)
            ),
            5_000_000e18
        );

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
        // The Prime controller doesn't even have the PSM facet integrated (dispatching
        // psm_* selectors on it reverts), and its RateLimits holds nothing at the PSM key.
        assertEq(
            IRateLimitsLike(pauPrime.rateLimits).getCurrentRateLimit(
                cHalo.psm_usdsToUSDCSwapRateLimitKey()
            ),
            0
        );
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

        // The Halo relayer can no longer issue against the subscription.
        vm.expectRevert();
        _haloCall(abi.encodeWithSelector(
            IControllerDispatchLike.nfatHalo_issue.selector, facility, pauPrime.almProxy, 1, amount
        ));

        // 2. Revoker cuts off the Halo relayer (e.g. a compromised operator key).
        assertTrue(IAdministeredAgentLike(agentHalo).getIsActor(relayerHalo));
        vm.prank(revokerHalo);
        IAdministeredAgentLike(agentHalo).removeActor(relayerHalo);
        assertFalse(IAdministeredAgentLike(agentHalo).getIsActor(relayerHalo));

        // The revoked relayer can no longer route calls through the agent.
        vm.expectRevert();
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

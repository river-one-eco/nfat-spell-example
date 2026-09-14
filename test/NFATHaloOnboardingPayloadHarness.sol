// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { PAUInstance } from "../src/dependencies/PAUInit.sol";

import { NFATHaloOnboardingPayload, Subscriber } from "../src/NFATHaloOnboardingPayload.sol";

/**
 * @notice Test-only subclass of the Halo payload: the real payload lists its subscribers as
 *         `constant`s (see `_subscribers()`), but the fork test deploys the Prime stacks at
 *         runtime, so this harness takes them in the constructor instead. It keeps the payload
 *         invariant — every contract variable `constant` or `immutable`, no storage — because
 *         the SubProxy DELEGATECALLs `execute()`: storage would be the SubProxy's, not ours.
 *         Up to three subscribers, each as an immutable (address, maxAmount, slope) triple.
 */
contract NFATHaloOnboardingPayloadHarness is NFATHaloOnboardingPayload {

    uint256 internal constant MAX_SUBSCRIBERS = 3;

    error TooManySubscribers(uint256 given, uint256 max);

    uint256 internal immutable count;

    address internal immutable subscriber0;
    uint256 internal immutable maxAmount0;
    uint256 internal immutable slope0;

    address internal immutable subscriber1;
    uint256 internal immutable maxAmount1;
    uint256 internal immutable slope1;

    address internal immutable subscriber2;
    uint256 internal immutable maxAmount2;
    uint256 internal immutable slope2;

    constructor(
        PAUInstance memory pau,
        address agent_,
        address facility_,
        address relayer_,
        address offramp_,
        address revoker_,
        address freezer_,
        Subscriber[] memory subs
    ) NFATHaloOnboardingPayload(pau, agent_, facility_, relayer_, offramp_, revoker_, freezer_) {
        if (subs.length > MAX_SUBSCRIBERS) revert TooManySubscribers(subs.length, MAX_SUBSCRIBERS);
        count = subs.length;

        Subscriber memory empty;
        Subscriber memory s0 = subs.length > 0 ? subs[0] : empty;
        Subscriber memory s1 = subs.length > 1 ? subs[1] : empty;
        Subscriber memory s2 = subs.length > 2 ? subs[2] : empty;

        subscriber0 = s0.subscriber; maxAmount0 = s0.maxAmount; slope0 = s0.slope;
        subscriber1 = s1.subscriber; maxAmount1 = s1.maxAmount; slope1 = s1.slope;
        subscriber2 = s2.subscriber; maxAmount2 = s2.maxAmount; slope2 = s2.slope;
    }

    function _subscribers() internal view override returns (Subscriber[] memory subs) {
        subs = new Subscriber[](count);
        if (count > 0) subs[0] = Subscriber(subscriber0, maxAmount0, slope0);
        if (count > 1) subs[1] = Subscriber(subscriber1, maxAmount1, slope1);
        if (count > 2) subs[2] = Subscriber(subscriber2, maxAmount2, slope2);
    }

}

// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IEnumerableIntegrations } from "../lib/diamond-pau/src/interfaces/IEnumerableIntegrations.sol";

import { IFacet }          from "../lib/diamond-pau/src/facets/IFacet.sol";
import { INFATPrimeFacet } from "../lib/diamond-pau/src/facets/nfat-prime/INFATPrimeFacet.sol";
import { INFATHaloFacet }  from "../lib/diamond-pau/src/facets/nfat-halo/INFATHaloFacet.sol";

import { IControllerDispatchLike } from "../src/interfaces/IControllerDispatchLike.sol";

/**
 * @notice Beacon wire configs for the NFAT facets, mirroring diamond-pau's canonical
 *         `_wireNFAT*Facet` registration. Registering a facet on the Beacon is a **Sky-core
 *         action** — the Beacon admin is the PauseProxy, NOT the star SubProxy that onboards
 *         deals — which is why this lives in the test harness (standing in for the pending
 *         Sky-core registration spell) and not in the deal payloads. Delete once the facets are
 *         registered on the canonical Beacon.
 */
library FacetRegistration {

    function primeFacetConfig(address facet)
        internal
        pure
        returns (IEnumerableIntegrations.Config memory config)
    {
        IEnumerableIntegrations.Wire[] memory wires = new IEnumerableIntegrations.Wire[](7);

        wires[0] = IEnumerableIntegrations.Wire(
            IControllerDispatchLike.nfatPrime_subscribe.selector,
            INFATPrimeFacet.subscribe.selector
        );
        wires[1] = IEnumerableIntegrations.Wire(
            IControllerDispatchLike.nfatPrime_withdraw.selector,
            INFATPrimeFacet.withdraw.selector
        );
        wires[2] = IEnumerableIntegrations.Wire(
            IControllerDispatchLike.nfatPrime_collect.selector,
            INFATPrimeFacet.collect.selector
        );
        wires[3] = IEnumerableIntegrations.Wire(
            IControllerDispatchLike.nfatPrime_getSubscribeRateLimitKey.selector,
            INFATPrimeFacet.getSubscribeRateLimitKey.selector
        );
        wires[4] = IEnumerableIntegrations.Wire(
            IControllerDispatchLike.nfatPrime_getCollectRateLimitKey.selector,
            INFATPrimeFacet.getCollectRateLimitKey.selector
        );
        wires[5] = IEnumerableIntegrations.Wire(
            IControllerDispatchLike.nfatPrime_getWithdrawRateLimitKey.selector,
            INFATPrimeFacet.getWithdrawRateLimitKey.selector
        );
        wires[6] = IEnumerableIntegrations.Wire(
            bytes4(keccak256("nfatPrime_VERSION()")),
            IFacet.VERSION.selector
        );

        config = IEnumerableIntegrations.Config({ facet: facet, wires: wires });
    }

    function haloFacetConfig(address facet)
        internal
        pure
        returns (IEnumerableIntegrations.Config memory config)
    {
        IEnumerableIntegrations.Wire[] memory wires = new IEnumerableIntegrations.Wire[](12);

        wires[0] = IEnumerableIntegrations.Wire(
            IControllerDispatchLike.nfatHalo_setMaxAnnualGrowthRate.selector,
            INFATHaloFacet.setMaxAnnualGrowthRate.selector
        );
        wires[1] = IEnumerableIntegrations.Wire(
            IControllerDispatchLike.nfatHalo_issue.selector,
            INFATHaloFacet.issue.selector
        );
        wires[2] = IEnumerableIntegrations.Wire(
            IControllerDispatchLike.nfatHalo_repayPrincipal.selector,
            INFATHaloFacet.repayPrincipal.selector
        );
        wires[3] = IEnumerableIntegrations.Wire(
            IControllerDispatchLike.nfatHalo_repayInterest.selector,
            INFATHaloFacet.repayInterest.selector
        );
        wires[4] = IEnumerableIntegrations.Wire(
            bytes4(keccak256("nfatHalo_getMaxAnnualGrowthRate(address)")),
            INFATHaloFacet.getMaxAnnualGrowthRate.selector
        );
        wires[5] = IEnumerableIntegrations.Wire(
            bytes4(keccak256("nfatHalo_getFacilityState(address)")),
            INFATHaloFacet.getFacilityState.selector
        );
        wires[6] = IEnumerableIntegrations.Wire(
            IControllerDispatchLike.nfatHalo_getPosition.selector,
            INFATHaloFacet.getPosition.selector
        );
        wires[7] = IEnumerableIntegrations.Wire(
            IControllerDispatchLike.nfatHalo_getCurrentMaxOutstandingInterest.selector,
            INFATHaloFacet.getCurrentMaxOutstandingInterest.selector
        );
        wires[8] = IEnumerableIntegrations.Wire(
            IControllerDispatchLike.nfatHalo_getIssueRateLimitKey.selector,
            INFATHaloFacet.getIssueRateLimitKey.selector
        );
        wires[9] = IEnumerableIntegrations.Wire(
            IControllerDispatchLike.nfatHalo_getRepayInterestRateLimitKey.selector,
            INFATHaloFacet.getRepayInterestRateLimitKey.selector
        );
        wires[10] = IEnumerableIntegrations.Wire(
            IControllerDispatchLike.nfatHalo_getRepayPrincipalRateLimitKey.selector,
            INFATHaloFacet.getRepayPrincipalRateLimitKey.selector
        );
        wires[11] = IEnumerableIntegrations.Wire(
            bytes4(keccak256("nfatHalo_VERSION()")),
            IFacet.VERSION.selector
        );

        config = IEnumerableIntegrations.Config({ facet: facet, wires: wires });
    }

}

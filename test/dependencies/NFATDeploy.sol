// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import "dss-interfaces/Interfaces.sol";
import { ScriptTools }  from "dss-test/ScriptTools.sol";
import { NFATFacility } from "../../lib/nfat/src/NFATFacility.sol";

/**
 * @title  NFATDeploy
 * @notice Deployment library for an NFAT facility, vendored from the nfat repo's `deploy/`
 *         scripts (adapted only in its `NFATFacility` import path). Deploys the facility against
 *         the chainlog-resolved gem and hands sole ward to `owner` via `ScriptTools.switchOwner`
 *         (rely(owner) + deny(deployer)), so the harness does not hand-roll the ownership swap.
 */
library NFATDeploy {

    function deploy(
        address deployer,
        address owner,
        bytes32 gemKey,
        string memory name,
        string memory symbol
    ) internal returns (address facility) {
        require(owner != address(0), "NFATDeploy/owner-zero-address");
        require(gemKey == "USDS" || gemKey == "SUSDS", "NFATDeploy/gem-not-usds-or-susds");

        ChainlogAbstract chainlog = ChainlogAbstract(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

        facility = address(new NFATFacility(chainlog.getAddress(gemKey), name, symbol));
        ScriptTools.switchOwner(facility, deployer, owner);
    }
}

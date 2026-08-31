// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

/**
 * @notice Base contract for Interval star payloads, mirroring the obex-gov-relay / pattern-spells
 *         payload shape (`PatternPayloadEthereum`): the StarGuard plots a payload by address +
 *         codehash, checks `isExecutable()`, and the SubProxy delegatecalls `execute()`.
 */
abstract contract NFATPayloadBase {

    function execute() external {
        _execute();
    }

    /**
     * @notice Checks if the star payload is executable in the current block
     * @dev    Required by the StarGuard; useful for implementing "earliest launch date" or
     *         "office hours" strategies.
     */
    function isExecutable() external pure returns (bool result) {
        result = true;
    }

    function _execute() internal virtual;

}

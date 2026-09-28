// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

// Inline `*Like` interfaces for the on-chain contracts the harness/tests touch — the same
// convention spark-spells / grove-spells use (they never import the deployed protocol source,
// only interact via thin interfaces).

interface IChainlogLike {
    function getAddress(bytes32 key) external view returns (address);
}

// The star's StarGuard: Sky core (PauseProxy) plots a payload by address + codehash, then anyone
// triggers `exec()`, which has the SubProxy delegatecall the payload's `execute()`. Same
// machinery as pattern-spells / obex-gov-relay.
interface IStarGuardLike {
    function plot(address addr_, bytes32 tag_) external;
    function exec() external returns (address addr);
}

interface IAccessControlLike {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function revokeRole(bytes32 role, address account) external;
}

interface IALMProxyLike {
    function CONTROLLER() external view returns (bytes32);
}

interface IRateLimitsLike {
    function CONTROLLER() external view returns (bytes32);
    function getCurrentRateLimit(bytes32 key) external view returns (uint256);
}

interface IPAUFactoryLike {
    function beacon() external view returns (address);
}

interface IAdministeredAgentLike {
    function getIsActor(address account) external view returns (bool);
    function getIsRevoker(address account) external view returns (bool);
    function removeActor(address account) external;
    function call(address target, bytes calldata data)
        external payable returns (bytes memory result);
}

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface INFATFacilityLike {
    function recipient() external view returns (address);
    function buds(address usr) external view returns (uint256);
    function wards(address usr) external view returns (uint256);
    function cops(address usr) external view returns (uint256);
    function stopped() external view returns (bool);
    function stop() external;
    function deposits(address depositor) external view returns (uint256);
    function collectable(uint256 tokenId) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function subscribe(uint256 amount, bytes calldata data) external;
    function issue(address to, uint256 tokenId, uint256 amount) external;
    function repay(uint256 tokenId, uint256 amount) external;
    function collect(uint256 tokenId, uint256 amount) external;
    function withdraw(uint256 amount) external;
}

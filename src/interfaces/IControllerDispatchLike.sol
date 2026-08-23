// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

// Dispatched (facet-routed) Controller surface used by the payloads and tests. Signatures must
// match the Beacon wire configs exactly — the Controller routes `nfatPrime_*` / `nfatHalo_*`
// selectors to the registered facet's implementation.
interface IControllerDispatchLike {

    // --- NFAT Prime facet ---

    function nfatPrime_subscribe(address facility, uint256 amount, bytes calldata data) external;

    function nfatPrime_withdraw(address facility, uint256 amount) external;

    function nfatPrime_collect(address facility, uint256 tokenId, uint256 amount) external;

    function nfatPrime_getSubscribeRateLimitKey(address facility, address gem)
        external pure returns (bytes32 key);

    function nfatPrime_getWithdrawRateLimitKey(address facility)
        external pure returns (bytes32 key);

    function nfatPrime_getCollectRateLimitKey(address facility)
        external pure returns (bytes32 key);

    // --- NFAT Halo facet ---

    function nfatHalo_setMaxAnnualGrowthRate(address facility, uint256 maxAnnualGrowthRate)
        external;

    function nfatHalo_issue(address facility, address to, uint256 tokenId, uint256 amount)
        external;

    function nfatHalo_repayPrincipal(address facility, uint256 tokenId, uint256 amount) external;

    function nfatHalo_repayInterest(address facility, uint256 tokenId, uint256 amount) external;

    function nfatHalo_getIssueRateLimitKey(address facility, address to)
        external pure returns (bytes32 key);

    function nfatHalo_getRepayInterestRateLimitKey(address facility, address gem)
        external pure returns (bytes32 key);

    function nfatHalo_getRepayPrincipalRateLimitKey(address facility, address gem)
        external pure returns (bytes32 key);

    function nfatHalo_getCurrentMaxOutstandingInterest(address facility, uint256 tokenId)
        external view returns (uint256 currentMaxOutstandingInterest);

    function nfatHalo_getPosition(address facility, uint256 tokenId)
        external view
        returns (
            bool    issued,
            uint256 outstandingPrincipal,
            uint256 maxOutstandingInterest,
            uint256 interestIndex
        );

    // --- USDS facet (live on the canonical Beacon) ---

    function usds_setVault(address vault) external;

    function usds_mint(uint256 usdsAmount) external;

    function usds_burn(uint256 usdsAmount) external;

    function usds_mintRateLimitKey() external pure returns (bytes32 key);

    // --- TransferAsset facet (live on the canonical Beacon) ---

    function transferAsset_transfer(address asset, address destination, uint256 amount) external;

    function transferAsset_getTransferRateLimitKey(address asset, address destination)
        external pure returns (bytes32 key);

    // --- PSM facet (live on the canonical Beacon) ---

    function psm_swapUSDSToUSDC(uint256 usdcAmount) external;

    function psm_swapUSDCToUSDS(uint256 usdcAmount) external;

    function psm_usdcToUSDSSwapRateLimitKey() external pure returns (bytes32 key);

    function psm_usdsToUSDCSwapRateLimitKey() external pure returns (bytes32 key);

}

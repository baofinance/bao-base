// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

import {IPriceOracleErrors} from "@bao/interfaces/IPriceOracleErrors.sol";

/// @notice A layer providing validated price information for underlying and wrapped assets.
/// @dev This validates prices from Chainlink feeds and ensures they meet quality standards.
interface IWrappedPriceOracle is IPriceOracleErrors {
    /// @notice Return the validated oracle price.
    /// @dev Checks and validates prices from the underlying feed, returning zero only if the price is valid.
    /// @return minUnderlyingPrice The validated min underlying price, always positive, returned as uint256 always 18 decimals
    /// @return maxUnderlyingPrice The validated max underlying price, always positive, returned as uint256 always 18 decimals
    /// @return minWrappedRate The min rate of the wrapped asset to the underlying asset, always 18 decimals
    /// @return maxWrappedRate The max rate of the wrapped asset to the underlying asset, always 18 decimals
    function latestAnswer()
        external
        view
        returns (
            uint256 minUnderlyingPrice,
            uint256 maxUnderlyingPrice,
            uint256 minWrappedRate,
            uint256 maxWrappedRate
        );
}

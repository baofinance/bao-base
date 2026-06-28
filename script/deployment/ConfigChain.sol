// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Read-only chain-level deployment config — values that vary per chain, not per peg / collateral /
///         market. Deployments are separated per chain, so each chain provides its own values here.
interface IChainConfig {
    /// @notice Symbol of the chain's native fee token — the denomination of `block.basefee`
    ///         (e.g. "ETH" on Ethereum and ETH-gas L2s, "POL" on Polygon, "BNB", "AVAX"). Used to build
    ///         gas-denominated oracle keys and to convert gas costs into peg units.
    function gasToken() external view returns (string memory);
}

/// @notice Chain-config mixin with Ethereum-mainnet defaults. A per-chain deploy overrides only what
///         differs (e.g. a Polygon deploy overrides `gasToken()` to "POL"). `FactoryDeployer` inherits this,
///         so every deploy stack exposes the chain config without threading it through call signatures.
abstract contract ConfigChain is IChainConfig {
    /// @inheritdoc IChainConfig
    function gasToken() public pure virtual returns (string memory) {
        return "ETH";
    }
}

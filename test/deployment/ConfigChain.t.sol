// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {ConfigChain, IChainConfig} from "@bao-script/deployment/ConfigChain.sol";

/// @notice Default chain config — Ethereum mainnet / ETH-gas chains (the `gasToken()` default).
contract DefaultChain is ConfigChain {}

/// @notice A non-ETH-gas chain overriding only the differing value.
contract PolygonChain is ConfigChain {
    function gasToken() public pure override returns (string memory) {
        return "POL";
    }
}

/// @notice Tests ConfigChain — the per-chain deployment config (gasToken for now).
contract ConfigChainTest is BaoTest {
    /// @notice The default gas token is ETH (correct for mainnet + every ETH-gas L2).
    function test_default_gasTokenIsETH() public {
        assertEq(new DefaultChain().gasToken(), "ETH");
    }

    /// @notice A per-chain config overrides only what differs (gas token).
    function test_override_changesGasToken() public {
        assertEq(new PolygonChain().gasToken(), "POL");
    }

    /// @notice The value is reachable through the read-only IChainConfig interface.
    function test_readableViaInterface() public {
        IChainConfig chain = new PolygonChain();
        assertEq(chain.gasToken(), "POL");
    }
}

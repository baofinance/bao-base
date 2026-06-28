// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice The single home for "::"-separated CREATE3 salt-key construction.
/// @dev Pure, stateless component joins — the one place the `::` separator is defined. Reachable from
///      anywhere (deployers, configs, libraries, tests) by import, with no inheritance coupling.
///      The campaign salt PREFIX is deploy-run state and is applied separately by the deployer
///      (`FactoryDeployer._saltString`); configs build unprefixed component keys here.
library SaltString {
    /// @dev The one definition of the salt-key separator.
    string internal constant SEPARATOR = "::";

    /// @notice A single-part key (identity).
    function key(string memory a) internal pure returns (string memory) {
        return a;
    }

    /// @notice Join two parts (e.g., "ETH::fxUSD").
    function key(string memory a, string memory b) internal pure returns (string memory) {
        return string.concat(a, SEPARATOR, b);
    }

    /// @notice Join three parts (e.g., "ETH::fxUSD::minter"). Chains the 2-part join so each overload keeps a
    ///         tiny stack footprint when inlined (a flat multi-arg string.concat blows the stack without via-IR).
    function key(string memory a, string memory b, string memory c) internal pure returns (string memory) {
        return key(key(a, b), c);
    }

    /// @notice Join four parts (e.g., "ETH::fxUSD::stabilityPoolCollateral::harvest").
    function key(
        string memory a,
        string memory b,
        string memory c,
        string memory d
    ) internal pure returns (string memory) {
        return key(key(a, b, c), d);
    }

    /// @notice Join five parts.
    function key(
        string memory a,
        string memory b,
        string memory c,
        string memory d,
        string memory e
    ) internal pure returns (string memory) {
        return key(key(a, b, c, d), e);
    }
}

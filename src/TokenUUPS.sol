// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {Token} from "@bao/Token.sol";
import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";

library TokenUUPS {
    /// @dev thrown when zero collateral is passed in or -1 is passed in and the balance is zero
    error NotUUPSUpgradeable(address addr);

    function ensureUUPSUpgradeable(address addr) internal view {
        Token.ensureContract(addr);
        // Must be ownable (Harbor owner()) ...
        if (!Token._hasNonMutatingFunction(addr, abi.encodeWithSelector(IHarborOwnable.owner.selector))) {
            revert NotUUPSUpgradeable(addr);
        }
        // ... and report the ERC-1967 implementation slot as its proxiable UUID. The call is
        // guarded: a contract without proxiableUUID() reverts, which must surface as the clean
        // NotUUPSUpgradeable error rather than an opaque low-level revert.
        try UUPSUpgradeable(addr).proxiableUUID() returns (bytes32 slot) {
            if (slot != bytes32(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)) {
                revert NotUUPSUpgradeable(addr);
            }
        } catch {
            revert NotUUPSUpgradeable(addr);
        }
    }
}

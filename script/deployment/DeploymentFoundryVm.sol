// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

/**
 * @title DeploymentFoundryVm
 * @notice Minimal mixin providing Foundry VM constant
 * @dev Declares Vm constant exactly once to avoid inheritance conflicts
 *      All Foundry-specific deployment code inherits from this
 */
abstract contract DeploymentFoundryVm {
    /// @notice Foundry VM for cheatcodes (file I/O, trace labels, pranks)
    Vm constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
}

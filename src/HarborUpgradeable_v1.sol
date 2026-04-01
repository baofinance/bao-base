// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {HarborFixedOwnable} from "./HarborFixedOwnable.sol";

/**
 * @title HarborUpgradeable
 * @author rootminus0x1
 * @notice Minimal UUPS-upgradeable contract with fixed Harbor multisig ownership.
 * @dev Base contract for small upgradeable contracts deployed via BaoFactory (CREATE3).
 *
 * Provides:
 * - UUPS upgradeability (owner-authorized)
 * - Fixed ownership to Harbor multisig (no constructor params for deterministic bytecode)
 * - IERC5313 owner interface
 *
 * Use cases:
 * - RewardAlias contracts
 * - Other small contracts that need predictable addresses and upgradeability
 *
 * Does NOT include a pause fallback — use HarborPauser_v1 for that.
 */
// solhint-disable-next-line contract-name-capwords
contract HarborUpgradeable_v1 is UUPSUpgradeable, HarborFixedOwnable, IERC5313 {
    /// @notice Harbor multisig address - hardcoded for deterministic deployment
    address private constant _OWNER = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() HarborFixedOwnable(address(0), _OWNER, 0) {
        _disableInitializers();
    }

    /// @inheritdoc IERC5313
    function owner() public view virtual override(HarborFixedOwnable, IERC5313) returns (address owner_) {
        owner_ = HarborFixedOwnable.owner();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC5313).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @notice Authorize upgrades — only owner can upgrade.
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks
}

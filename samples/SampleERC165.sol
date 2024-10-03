// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC165Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";

contract SampleUpgradeable is Initializable, ERC165Upgradeable {
    function initialize() external initializer {
        __ERC165_init();
    }

    /// @notice Returns true if a given interface is supported.
    /// @dev See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            // add your interfaces here
            // interfaceId == type(IOwnable).interfaceId ||
            // interfaceId == type(IERC20).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}

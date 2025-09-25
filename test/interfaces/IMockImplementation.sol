// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/**
 * @title IMockImplementation
 * @notice Common interface for all mock implementation contracts
 * @dev Only contains methods common to all implementations (value operations)
 * Ownership methods are intentionally excluded as different models implement them differently
 */
interface IMockImplementation {
    enum ImplementationType {
        MockImplementationWithState,
        MockImplementationWithState_v2,
        MockImplementationOZOwnable
    }

    function implementationType() external pure returns (uint256);

    function name() external view returns (string memory);

    function owner() external view returns (address);

    /**
     * @notice Get the current stored value
     * @return The stored value
     */
    function value() external view returns (uint256);

    /**
     * @notice Get the current stored value that can't change
     * @return The stored value
     */
    function stableValue() external view returns (uint256);

    /**
     * @notice Set the stored value
     * @param newValue The new value to set
     */
    function setValue(uint256 newValue) external;

    // /**
    //  * @notice Setup function called after an upgrade
    //  * @param newValue The value to set after upgrade
    //  */
    // function postUpgradeSetup(uint256 newValue) external;

    /**
     * @notice Increment the stored value by 1
     * @dev Common across MockImplementationWithState and MockImplementationWithState_v2
     */
    function incrementValue() external;

    function postUpgradeSetup(address newOwner, uint256 newValue) external;
}

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

abstract contract MockImplementationWithStateBase is UUPSUpgradeable, IMockImplementation {
    // Events
    event ValueChanged(uint256 oldValue, uint256 newValue);

    function name() external view virtual override returns (string memory) {
        uint256 implementationType = this.implementationType();
        if (implementationType == uint(IMockImplementation.ImplementationType.MockImplementationWithState)) {
            return "MockImplementationWithState";
        } else if (implementationType == uint(IMockImplementation.ImplementationType.MockImplementationWithState_v2)) {
            return "MockImplementationWithState_v2";
        } else if (implementationType == uint(IMockImplementation.ImplementationType.MockImplementationOZOwnable)) {
            return "MockImplementationOZOwnable";
        }
        return "MockImplementation!";
    }

    // all derived implementations must use compatible storage structure and the same slot for state to be upgradeable!
    // EIP-7201: Storage struct and slot
    struct StateStorage {
        uint256 value;
        uint256 stableValue; // to demonstrate state preservation
    }

    // keccak256("bao.mockimplementationwithstate.storage") - 1
    bytes32 private constant MOCKIMPLEMENTATIONWITHSTATE_STORAGE_SLOT =
        0x6e1b6c6e2e20e671e7e55ce49963cf343577b6c7d429f775d390d05f9b0a7b1b;

    // EIP-7201: Storage accessor (Proxy Pattern: EIP-7201)
    function _getStateStorage() internal pure returns (StateStorage storage $) {
        assembly {
            $.slot := MOCKIMPLEMENTATIONWITHSTATE_STORAGE_SLOT
        }
    }

    function value() external view returns (uint256) {
        return _getStateStorage().value;
    }

    function stableValue() external view returns (uint256) {
        return _getStateStorage().stableValue;
    }

    function _setValue(uint256 newValue) internal {
        StateStorage storage $ = _getStateStorage();
        emit ValueChanged($.value, newValue);
        $.value = newValue;
    }

    function _incrementValue() internal {
        StateStorage storage $ = _getStateStorage();
        $.value += 1;
        emit ValueChanged($.value - 1, $.value);
    }

    function upgradeToAndCall(address newImplementation, bytes memory data) public payable virtual override {
        // console2.log("MockImplementation.upgradeToAndCall called with newImplementation: %s", newImplementation);

        super.upgradeToAndCall(newImplementation, data);

        // console2.log("MockImplementation.upgradeToAndCall completed.");
    }

    // modifier log(string memory funcname) {
    //     console2.log("->", this.name(), funcname, "...");
    //     _;
    //     console2.log("<-", this.name(), funcname, ".");
    // }

    bytes32 private constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    function $_getInitializableStorage() private pure returns (InitializableStorage storage $) {
        assembly {
            $.slot := INITIALIZABLE_STORAGE
        }
    }
    modifier $reinitializer(uint64 version) {
        InitializableStorage storage $ = $_getInitializableStorage();

        // console2.log("MockImplementation.$reinitializer called with version: %s", version);
        // console2.log("_initializing=%s.", $._initializing);
        // console2.log("_initialized=%s.", $._initialized);

        if ($._initializing || $._initialized >= version) {
            revert InvalidInitialization();
        }
        $._initialized = version;
        $._initializing = true;
        _;
        $._initializing = false;
        emit Initialized(version);
        // console2.log("MockImplementation.$reinitializer completed.");
    }
}

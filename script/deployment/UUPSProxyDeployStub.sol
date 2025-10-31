// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Ownable} from "@solady/auth/Ownable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title UUPSProxyDeployStub
/// @notice Minimal UUPS-compatible bootstrap used as the first implementation for CREATE3 proxies.
/// @dev Keeps a single deployer address with Solady ownership for rotation.
contract UUPSProxyDeployStub is UUPSUpgradeable, Ownable {
    /// @dev Emitted whenever the active deployer is updated.
    event DeployerUpdated(address indexed deployer);

    /// @dev ERC-7201 style namespace for the deployer slot.
    bytes32 private constant _DEPLOYER_SLOT = keccak256("bao.stub.deployer");

    /// @dev Remember the stub's own address so delegatecall contexts can resolve back to storage.
    address private immutable _self;

    error StubDeployerQueryFailed();

    constructor(address owner_) {
        require(owner_ != address(0), "owner zero");
        _self = address(this);
        _initializeOwner(owner_);
        _setDeployer(msg.sender);
    }

    /// @notice Return the address allowed to perform upgrades.
    function deployer() external view returns (address) {
        return _getDeployer();
    }

    /// @notice Surface the Solady ownership handover window (in seconds).
    function handoverTimeout() external view returns (uint64) {
        return _ownershipHandoverValidFor();
    }

    /// @notice Rotate the deployer before running an upgrade.
    function setDeployer(address newDeployer) external onlyOwner {
        require(newDeployer != address(0), "deployer zero");
        _setDeployer(newDeployer);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == _getDeployer(), "not deployer");
    }

    function _getDeployer() internal view returns (address deployer_) {
        if (address(this) == _self) {
            deployer_ = _loadDeployerSlot();
        } else {
            deployer_ = _loadDeployerFromStub();
        }
    }

    function _loadDeployerSlot() private view returns (address deployer_) {
        bytes32 slot = _DEPLOYER_SLOT;
        assembly {
            deployer_ := sload(slot)
        }
    }

    function _loadDeployerFromStub() private view returns (address deployer_) {
        (bool success, bytes memory data) = _self.staticcall(
            abi.encodeWithSelector(UUPSProxyDeployStub.deployer.selector)
        );
        if (!success || data.length != 32) revert StubDeployerQueryFailed();
        deployer_ = abi.decode(data, (address));
    }

    function _setDeployer(address deployer_) private {
        bytes32 slot = _DEPLOYER_SLOT;
        assembly {
            sstore(slot, deployer_)
        }
        emit DeployerUpdated(deployer_);
    }
}

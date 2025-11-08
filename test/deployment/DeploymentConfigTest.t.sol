// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {DeploymentConfig} from "@bao-script/deployment/DeploymentConfig.sol";

contract DeploymentConfigTest is Test {
    DeploymentConfig.SourceJson private config;

    function setUp() public {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/test/fixtures/deployment/config-basic.json");
        string memory text;
        try vm.readFile(path) returns (string memory contents) {
            text = contents;
        } catch {
            path = string.concat(root, "/lib/bao-base/test/fixtures/deployment/config-basic.json");
            text = vm.readFile(path);
        }
        config = DeploymentConfig.fromJson(text);
    }

    function test_getAddress_prefersContractOverride() public view {
        address owner = DeploymentConfig.get(config, "pegged", "owner");
        assertEq(owner, vm.parseAddress("0x0000000000000000000000000000000000bbbb01"));
    }

    function test_getAddress_fallsBackToDefaultOwner() public view {
        address owner = DeploymentConfig.get(config, "stabilityPoolCollateral", "owner");
        assertEq(owner, vm.parseAddress("0x0000000000000000000000000000000000aaaa01"));
    }

    function test_getString_prefersContractOverride() public view {
        string memory symbol = DeploymentConfig.getString(config, "pegged", "params.symbol");
        assertEq(symbol, "cUSD");
    }

    function test_getString_fallsBackToContractDefaults() public view {
        string memory name = DeploymentConfig.getString(config, "pegged", "params.name");
        assertEq(name, "Bao USD");
    }

    function test_getUint_fallsBackToContractSpecificDefaults() public view {
        uint256 minDeposit = DeploymentConfig.getUint(config, "stabilityPoolCollateral", "params.minDeposit");
        assertEq(minDeposit, 1e18);
    }

    function test_getUint_prefersContractOverride() public view {
        uint256 feeBps = DeploymentConfig.getUint(config, "minter", "params.feeBps");
        assertEq(feeBps, 25);
    }

    function test_missingFieldReverts() public {
        vm.expectRevert(abi.encodeWithSelector(DeploymentConfig.ConfigValueMissing.selector, "unknown", "owner"));
        this._getOwner("unknown");
    }

    function test_conflictResolution_preferConfig() public view {
        DeploymentConfig.ConflictResolution resolution = DeploymentConfig.conflictResolution(config, "owner");
        assertEq(uint256(resolution), uint256(DeploymentConfig.ConflictResolution.PreferConfig));
    }

    function test_conflictResolution_preferLog() public view {
        DeploymentConfig.ConflictResolution resolution = DeploymentConfig.conflictResolution(config, "minter.owner");
        assertEq(uint256(resolution), uint256(DeploymentConfig.ConflictResolution.PreferLog));
    }

    function test_conflictResolution_unspecified() public view {
        DeploymentConfig.ConflictResolution resolution = DeploymentConfig.conflictResolution(config, "pegged.owner");
        assertEq(uint256(resolution), uint256(DeploymentConfig.ConflictResolution.Unspecified));
    }

    function _getOwner(string memory contractKey) external view returns (address) {
        return DeploymentConfig.get(config, contractKey, "owner");
    }
}

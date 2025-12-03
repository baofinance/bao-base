// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentMemoryTesting} from "@bao-script/deployment/DeploymentMemoryTesting.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";

contract DeploymentConfigParameterBagTestHarness is DeploymentMemoryTesting {
    constructor() {
        // Register all keys that will be used in the test
        // Register parent keys first
        addContract("contracts.pegged");
        addContract("contracts.collateral");
        addContract("contracts.minter");
        addContract("contracts.minter.bands");
        addContract("contracts.minter.ratios");

        // Then register nested keys
        addStringKey("contracts.pegged.name");
        addStringKey("contracts.pegged.symbol");
        addUintKey("contracts.pegged.decimals");
        addContract("contracts.collateral"); // collateral is actually a contract key
        addUintKey("contracts.minter.bands.0");
        addUintKey("contracts.minter.bands.1");
        addIntKey("contracts.minter.ratios.0");
        addUintKey("contracts.minter.ratios.1");
    }

    function populateTestData() external {
        // Populate test data after start() is called
        setString("contracts.pegged.name", "Bao USD");
        setString("contracts.pegged.symbol", "BAOUSD");
        setUint("contracts.pegged.decimals", 18);
        _set("contracts.collateral", 0x0000000000000000000000000000000000000002);
        setUint("contracts.minter.bands.0", 100);
        setUint("contracts.minter.bands.1", 200);
        setInt("contracts.minter.ratios.0", -1);
        setUint("contracts.minter.ratios.1", 2);
    }
}

contract DeploymentConfigParameterBagTest is BaoDeploymentTest {
    DeploymentConfigParameterBagTestHarness internal deployment;
    string constant OWNER_ADDRESS = "0x0000000000000000000000000000000000000001";
    string constant COLLATERAL_ADDRESS = "0x0000000000000000000000000000000000000002";

    function setUp() public override {
        super.setUp();
        deployment = new DeploymentConfigParameterBagTestHarness();
    }

    function test_FlattensNestedConfigIntoParameters() public {
        deployment.start("testnet", "test-salt", "");
        deployment.populateTestData();

        assertEq(deployment.getString("contracts.pegged.name"), "Bao USD");
        assertEq(deployment.getString("contracts.pegged.symbol"), "BAOUSD");
        assertEq(deployment.getUint("contracts.pegged.decimals"), 18);

        assertEq(
            deployment.getAddress("contracts.collateral.address"),
            address(0x0000000000000000000000000000000000000002)
        );

        assertEq(deployment.getUint("contracts.minter.bands.0"), 100);
        assertEq(deployment.getUint("contracts.minter.bands.1"), 200);
        assertEq(deployment.getInt("contracts.minter.ratios.0"), -1);
        assertEq(deployment.getUint("contracts.minter.ratios.1"), 2);

        vm.expectRevert(abi.encodeWithSelector(DeploymentDataMemory.ValueNotSet.selector, "owner"));
        deployment.getString("owner");
    }

    function _buildConfigJson() internal pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "{",
                    '"owner":"',
                    OWNER_ADDRESS,
                    '",',
                    '"version":"1.0.0",',
                    '"systemSaltString":"bag-demo",',
                    '"pegged":{"name":"Bao USD","symbol":"BAOUSD","decimals":18},',
                    '"collateral":{"address":"',
                    COLLATERAL_ADDRESS,
                    '"},',
                    '"minter":{"bands":[100,200],"ratios":[-1,2]},',
                    '"conflicts":{"owner":"prefer-config"}',
                    "}"
                )
            );
    }
}

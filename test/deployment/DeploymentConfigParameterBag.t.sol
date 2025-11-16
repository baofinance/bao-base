// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentFoundryTesting} from "./DeploymentFoundryTesting.sol";
import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";

contract DeploymentConfigParameterBagTest is BaoDeploymentTest {
    DeploymentFoundryTesting internal deployment;
    string constant OWNER_ADDRESS = "0x0000000000000000000000000000000000000001";
    string constant COLLATERAL_ADDRESS = "0x0000000000000000000000000000000000000002";

    function setUp() public override {
        super.setUp();
        deployment = new DeploymentFoundryTesting();
    }

    function test_FlattensNestedConfigIntoParameters() public {
        string memory configJson = _buildConfigJson();
        deployment.start(configJson, "testnet");

        assertEq(deployment.getString("pegged.name"), "Bao USD");
        assertEq(deployment.getString("pegged.symbol"), "BAOUSD");
        assertEq(deployment.getUint("pegged.decimals"), 18);

    assertEq(deployment.getString("collateral.address"), COLLATERAL_ADDRESS);

        assertEq(deployment.getUint("minter.bands.0"), 100);
        assertEq(deployment.getUint("minter.bands.1"), 200);
        assertEq(deployment.getInt("minter.ratios.0"), -1);
        assertEq(deployment.getUint("minter.ratios.1"), 2);

        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.ParameterNotFound.selector, "owner"));
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

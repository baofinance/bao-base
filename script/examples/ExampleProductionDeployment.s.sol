// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/**
 * @title ExampleProductionDeployment
 * @notice Example of deploying a harness via Nick's Factory for cross-chain determinism
 * @dev This demonstrates the two-phase production deployment workflow:
 *      Phase 1: Deploy harness via Nick's Factory
 *      Phase 2: Use harness to deploy contracts (in a separate script)
 *
 * @dev Usage:
 *      1. Predict address: forge script ExampleProductionDeployment --sig "predictHarnessAddress()"
 *      2. Deploy harness: forge script ExampleProductionDeployment --sig "deployHarness()" --broadcast
 *      3. Deploy contracts: Use the deployed harness in your actual deployment script
 */
contract ExampleProductionDeployment is Script {
    /// @notice Nick's Factory address
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Fixed salt for harness deployment (same across all chains)
    bytes32 constant HARNESS_SALT = keccak256("bao-deployment-harness-v1");

    /**
     * @notice Phase 1: Deploy your harness via Nick's Factory
     * @dev Replace YourDeploymentContract with your actual deployment contract name
     * @dev Run this once on each chain to establish the deterministic harness address
     *
     * Example:
     *   bytes memory creationCode = type(YourDeploymentContract).creationCode;
     *   bytes memory deployData = abi.encodePacked(HARNESS_SALT, creationCode);
     *   (bool success, bytes memory returnData) = NICKS_FACTORY.call(deployData);
     *   address deployed = address(uint160(uint256(bytes32(returnData))));
     */
    function deployHarnessExample() public pure {
        revert("Replace this with your actual deployment contract in type(...).creationCode");
    }

    /**
     * @notice Phase 2: Use the harness to deploy contracts
     * @dev This is a placeholder showing how to use the deployed harness.
     *      In practice, create a separate deployment script that extends your harness contract.
     *
     * Example in your actual deployment script:
     *
     * contract MyDeployment is DeploymentFoundry {
     *     constructor() DeploymentFoundry(vm, HARNESS_ADDRESS) {}
     *
     *     function run() external {
     *         vm.startBroadcast();
     *         startDeployment(...);
     *         deployProxy(...);
     *         finishDeployment();
     *         vm.stopBroadcast();
     *     }
     * }
     */
    function deployContracts() public view {
        address harnessAddr = predictHarnessAddress();
        require(harnessAddr.code.length > 0, "Harness not deployed yet");

        console.log("Harness deployed at:", harnessAddr);
        console.log("Create your deployment script and pass this address as deployerContext");
    }

    /**
     * @notice Predict harness address before deployment
     * @param bytecode Creation bytecode of your deployment contract
     * @return Address where harness will be deployed
     *
     * Example usage:
     *   bytes memory bytecode = type(YourDeploymentContract).creationCode;
     *   address predicted = predictHarnessAddress(bytecode);
     */
    function predictHarnessAddress(bytes memory bytecode) public pure returns (address) {
        bytes32 bytecodeHash = keccak256(bytecode);
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), NICKS_FACTORY, HARNESS_SALT, bytecodeHash));
        return address(uint160(uint256(hash)));
    }

    /**
     * @notice Entry point showing the workflow
     */
    function run() public pure {
        revert(
            string.concat(
                "This is an example/documentation script. ",
                "To use in production:\n",
                "1. Create your deployment contract extending DeploymentFoundry\n",
                "2. Calculate predicted address using predictHarnessAddress(bytecode)\n",
                "3. Deploy via Nick's Factory: NICKS_FACTORY.call(abi.encodePacked(salt, bytecode))\n",
                "4. Instantiate with: YourDeployment(deployedAddress)\n",
                "5. Use the same salt on all chains for identical addresses"
            )
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {FundedVault, NonPayableVault, FundedVaultUUPS} from "@bao-test/mocks/deployment/FundedVault.sol";

/// @title Simple test contract for CREATE3 deployments
contract SimpleContract {
    uint256 public value;
    address public deployer;

    constructor(uint256 _value) {
        value = _value;
        deployer = msg.sender;
    }
}

/// @title BaoDeployerTest
/// @notice Comprehensive tests for BaoDeployer contract
contract BaoDeployerTest is Test {
    BaoDeployer public implementation;
    BaoDeployer public deployer;

    address public finalOwner;
    address public deployer1;
    address public deployer2;
    address public deployer3;
    address public deployer4;
    address public user;

    uint256 constant DEPLOYER_ROLE = 1 << 0; // _ROLE_0

    event ContractDeployed(address indexed deployer, address indexed deployed, bytes32 indexed salt);

    function setUp() public {
        finalOwner = makeAddr("finalOwner");
        deployer1 = makeAddr("deployer1");
        deployer2 = makeAddr("deployer2");
        deployer3 = makeAddr("deployer3");
        deployer4 = makeAddr("deployer4");
        user = makeAddr("user");

        // Deploy implementation (no constructor parameters for CREATE2 determinism)
        implementation = new BaoDeployer();

        // Deploy proxy with initial deployers
        address[] memory initialDeployers = new address[](0);
        bytes memory initData = abi.encodeCall(BaoDeployer.initialize, (address(this), initialDeployers));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        deployer = BaoDeployer(payable(address(proxy)));

        // Initial owner is address(this)
        assertEq(deployer.owner(), address(this));
    }

    /*//////////////////////////////////////////////////////////////////////////
                              CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_Constructor() public view {
        // Owner should be test contract
        assertEq(deployer.owner(), address(this));
    }

    function test_Initialize() public {
        // Already initialized in setUp
        // Try to initialize again - should fail
        address[] memory noDeployers = new address[](0);
        vm.expectRevert();
        deployer.initialize(address(this), noDeployers);
    }

    function test_Initialize_WithDeployers() public {
        // Deploy fresh proxy
        BaoDeployer freshImpl = new BaoDeployer();
        address[] memory initDeployers = new address[](2);
        initDeployers[0] = deployer1;
        initDeployers[1] = deployer2;

        bytes memory initData = abi.encodeCall(BaoDeployer.initialize, (finalOwner, initDeployers));
        ERC1967Proxy proxy = new ERC1967Proxy(address(freshImpl), initData);
        BaoDeployer freshDeployer = BaoDeployer(payable(address(proxy)));

        // Check owner
        assertEq(freshDeployer.owner(), finalOwner);

        // Check deployers were granted roles
        assertTrue(freshDeployer.isAuthorizedDeployer(deployer1));
        assertTrue(freshDeployer.isAuthorizedDeployer(deployer2));

        // Check enumeration
        address[] memory deployerList = freshDeployer.deployers();
        assertEq(deployerList.length, 2);
        assertEq(deployerList[0], deployer1);
        assertEq(deployerList[1], deployer2);
    }

    /*//////////////////////////////////////////////////////////////////////////
                         ROLE MANAGEMENT TESTS (OWNER ONLY)
    //////////////////////////////////////////////////////////////////////////*/

    function test_GrantRoles() public {
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);

        // Verify deployer was granted
        assertTrue(deployer.isAuthorizedDeployer(deployer1));
        assertTrue(deployer.hasAnyRole(deployer1, DEPLOYER_ROLE));

        // Check via deployers() view
        address[] memory holders = deployer.deployers();
        assertEq(holders.length, 1);
        assertEq(holders[0], deployer1);
    }

    function test_GrantMultipleRoles() public {
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);
        deployer.grantRoles(deployer2, DEPLOYER_ROLE);
        deployer.grantRoles(deployer3, DEPLOYER_ROLE);

        assertTrue(deployer.isAuthorizedDeployer(deployer1));
        assertTrue(deployer.isAuthorizedDeployer(deployer2));
        assertTrue(deployer.isAuthorizedDeployer(deployer3));

        address[] memory holders = deployer.deployers();
        assertEq(holders.length, 3);
    }

    function test_GrantRoles_Idempotent() public {
        // Grant same role twice
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);

        // Should still only have 1 deployer
        address[] memory holders = deployer.deployers();
        assertEq(holders.length, 1);
        assertTrue(deployer.isAuthorizedDeployer(deployer1));
    }

    function test_GrantRoles_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);
    }

    function test_RevokeRoles() public {
        // Grant role first
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);
        assertTrue(deployer.isAuthorizedDeployer(deployer1));

        // Revoke
        deployer.revokeRoles(deployer1, DEPLOYER_ROLE);

        // Verify revoked
        assertFalse(deployer.isAuthorizedDeployer(deployer1));
        assertFalse(deployer.hasAnyRole(deployer1, DEPLOYER_ROLE));

        address[] memory holders = deployer.deployers();
        assertEq(holders.length, 0);
    }

    function test_RevokeRoles_NotFound() public {
        // Revoking non-existent role should succeed silently (idempotent)
        deployer.revokeRoles(deployer1, DEPLOYER_ROLE);

        // No revert - should just be a no-op
        assertFalse(deployer.isAuthorizedDeployer(deployer1));
    }

    function test_RevokeRoles_OnlyOwner() public {
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);

        vm.prank(user);
        vm.expectRevert();
        deployer.revokeRoles(deployer1, DEPLOYER_ROLE);
    }

    function test_Enumeration_AfterRevoke() public {
        // Grant multiple roles
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);
        deployer.grantRoles(deployer2, DEPLOYER_ROLE);
        deployer.grantRoles(deployer3, DEPLOYER_ROLE);

        address[] memory holdersBefore = deployer.deployers();
        assertEq(holdersBefore.length, 3);

        // Revoke middle one
        deployer.revokeRoles(deployer2, DEPLOYER_ROLE);

        // Check enumeration updated
        address[] memory holdersAfter = deployer.deployers();
        assertEq(holdersAfter.length, 2);

        // deployer2 should not be in the list
        for (uint256 i = 0; i < holdersAfter.length; i++) {
            assertTrue(holdersAfter[i] != deployer2);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                        DEPLOYER-CALLABLE FUNCTION TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_Deploy() public {
        // Grant deployer role
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);

        // Prepare deployment
        bytes32 salt = keccak256("test.deployment");
        bytes memory creationCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(42)));

        // Deploy
        vm.prank(deployer1);
        address deployed = deployer.deployDeterministic(creationCode, salt);

        // Verify deployment
        assertTrue(deployed != address(0));
        assertTrue(deployed.code.length > 0);

        SimpleContract simple = SimpleContract(deployed);
        assertEq(simple.value(), 42);
        // The deployer in SimpleContract's context is the CREATE3 proxy, not BaoDeployer
        // This is expected CREATE3 behavior
    }

    function test_Deploy_Owner() public {
        // Owner can also deploy without being granted DEPLOYER_ROLE
        bytes32 salt = keccak256("test.owner.deployment");
        bytes memory creationCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(99)));

        address deployed = deployer.deployDeterministic(creationCode, salt);

        assertTrue(deployed != address(0));
        SimpleContract simple = SimpleContract(deployed);
        assertEq(simple.value(), 99);
    }

    function test_Deploy_UnauthorizedDeployer() public {
        bytes32 salt = keccak256("test");
        bytes memory creationCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(1)));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BaoDeployer.UnauthorizedDeployer.selector, user));
        deployer.deployDeterministic(creationCode, salt);
    }

    function test_Deploy_Deterministic() public {
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);

        bytes32 salt = keccak256("deterministic.test");
        bytes memory creationCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(100)));

        // Predict address
        address predicted = deployer.predictDeterministicAddress(salt);

        // Deploy
        vm.prank(deployer1);
        address deployed = deployer.deployDeterministic(creationCode, salt);

        // Verify prediction matches
        assertEq(deployed, predicted);
    }

    // Note: deployDeterministic with value is complex with CREATE3 due to proxy indirection
    // Skipping test - the function exists but testing it properly requires special setup
    function test_DeployWithValue() public {
        // Grant deployer role
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);

        // Get deployment bytecode for FundedVault (payable constructor)
        bytes memory initCode = type(FundedVault).creationCode;
        bytes32 salt = keccak256("funded.vault");
        uint256 fundingAmount = 5 ether;

        // Deploy with value as authorized deployer
        vm.deal(deployer1, fundingAmount);
        vm.prank(deployer1);
        address deployed = deployer.deployDeterministic{value: fundingAmount}(fundingAmount, initCode, salt);

        // Verify deployment
        assertTrue(deployed != address(0));
        assertTrue(deployed.code.length > 0);

        // Verify the contract received the ETH during construction
        FundedVault vault = FundedVault(payable(deployed));
        assertEq(vault.initialBalance(), fundingAmount, "Constructor did not receive value");
        assertEq(vault.currentBalance(), fundingAmount, "Contract balance incorrect");

        // Note: vault.deployer() will be the CREATE3 proxy, not BaoDeployer
        // This is expected - CREATE3 uses an intermediate proxy that does the actual CREATE
        assertTrue(vault.deployer() != address(0), "Deployer should be set");
        assertTrue(vault.deployer() != address(deployer), "Deployer is the CREATE3 proxy, not BaoDeployer");
    }

    function test_DeployWithValue_NonPayableReverts() public {
        // Grant deployer role
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);

        // Get deployment bytecode for NonPayableVault
        bytes memory initCode = abi.encodePacked(type(NonPayableVault).creationCode, abi.encode(42));
        bytes32 salt = keccak256("nonpayable.test");
        uint256 fundingAmount = 1 ether;

        // Try to deploy with value - should revert because constructor is not payable
        vm.deal(deployer1, fundingAmount);
        vm.prank(deployer1);
        vm.expectRevert(); // CREATE3 will revert with DeploymentFailed
        deployer.deployDeterministic{value: fundingAmount}(fundingAmount, initCode, salt);
    }

    function test_DeployWithoutValue_PayableConstructor() public {
        // Test that payable constructor works fine with 0 value
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);

        bytes memory initCode = type(FundedVault).creationCode;
        bytes32 salt = keccak256("unfunded.vault");

        // Deploy without value using non-value overload
        vm.prank(deployer1);
        address deployed = deployer.deployDeterministic(initCode, salt);

        // Verify deployment succeeded
        assertTrue(deployed != address(0));
        assertTrue(deployed.code.length > 0);

        // Verify contract has zero balance
        FundedVault vault = FundedVault(payable(deployed));
        assertEq(vault.initialBalance(), 0, "Should have zero initial balance");
        assertEq(vault.currentBalance(), 0, "Should have zero current balance");

        // Verify msg.sender in constructor was CREATE3 proxy (not BaoDeployer)
        assertTrue(vault.deployer() != address(0), "Deployer should be set");
        assertTrue(vault.deployer() != address(deployer), "msg.sender is CREATE3 proxy, not BaoDeployer");
    }

    function test_MsgSenderIsSameForBothDeployMethods() public {
        // Verify that msg.sender in constructor is the same CREATE3 proxy for both methods
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);

        bytes memory initCode = type(FundedVault).creationCode;

        // Deploy with value
        uint256 fundingAmount = 1 ether;
        vm.deal(deployer1, fundingAmount);
        vm.prank(deployer1);
        address deployedWithValue = deployer.deployDeterministic{value: fundingAmount}(
            fundingAmount,
            initCode,
            keccak256("vault.with.value")
        );

        // Deploy without value
        vm.prank(deployer1);
        address deployedWithoutValue = deployer.deployDeterministic(initCode, keccak256("vault.without.value"));

        // Both should have their deployer field set (msg.sender in constructor)
        FundedVault vaultWithValue = FundedVault(payable(deployedWithValue));
        FundedVault vaultWithoutValue = FundedVault(payable(deployedWithoutValue));

        // Neither should be the BaoDeployer - both should be CREATE3 proxies
        assertTrue(vaultWithValue.deployer() != address(deployer), "With-value: msg.sender is CREATE3 proxy");
        assertTrue(vaultWithoutValue.deployer() != address(deployer), "Without-value: msg.sender is CREATE3 proxy");

        // Both should be non-zero addresses
        assertTrue(vaultWithValue.deployer() != address(0), "With-value deployer set");
        assertTrue(vaultWithoutValue.deployer() != address(0), "Without-value deployer set");

        // The deployer() values will be different CREATE3 proxies (different salts = different proxy addresses)
        // But both follow the same pattern: CREATE3 creates proxy -> proxy creates contract
    }

    function test_DeployUUPSProxyWithValue() public {
        // Grant deployer role
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);

        // Deploy implementation
        FundedVaultUUPS impl = new FundedVaultUUPS(finalOwner);

        // Create proxy deployment with payable initializer
        bytes memory initData = abi.encodeCall(FundedVaultUUPS.initialize, ());
        bytes memory proxyCreation = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(address(impl), initData)
        );

        bytes32 salt = keccak256("uups.funded.vault");
        uint256 fundingAmount = 3 ether;

        // Deploy proxy with value - the initializer is payable
        vm.deal(deployer1, fundingAmount);
        vm.prank(deployer1);
        address deployed = deployer.deployDeterministic{value: fundingAmount}(fundingAmount, proxyCreation, salt);

        // Verify deployment
        assertTrue(deployed != address(0));
        assertTrue(deployed.code.length > 0);

        // Verify the proxy received ETH during initialization
        FundedVaultUUPS proxy = FundedVaultUUPS(payable(deployed));
        assertEq(proxy.initialBalance(), fundingAmount, "Initializer did not receive value");
        assertEq(proxy.currentBalance(), fundingAmount, "Proxy balance incorrect");
    }

    function test_DeployUUPSProxyWithoutValue() public {
        // Test UUPS proxy deployment without value
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);

        // Deploy implementation
        FundedVaultUUPS impl = new FundedVaultUUPS(finalOwner);

        // Create proxy deployment
        bytes memory initData = abi.encodeCall(FundedVaultUUPS.initialize, ());
        bytes memory proxyCreation = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(address(impl), initData)
        );

        bytes32 salt = keccak256("uups.unfunded.vault");

        // Deploy proxy without value
        vm.prank(deployer1);
        address deployed = deployer.deployDeterministic(proxyCreation, salt);

        // Verify deployment succeeded
        assertTrue(deployed != address(0));
        assertTrue(deployed.code.length > 0);

        // Verify proxy has zero balance
        FundedVaultUUPS proxy = FundedVaultUUPS(payable(deployed));
        assertEq(proxy.initialBalance(), 0, "Should have zero initial balance");
        assertEq(proxy.currentBalance(), 0, "Should have zero current balance");
    }

    function test_PredictDeterministicAddress() public view {
        bytes32 salt = keccak256("prediction.test");

        // Anyone can predict
        address predicted = deployer.predictDeterministicAddress(salt);

        assertTrue(predicted != address(0));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_Deployers_Empty() public view {
        address[] memory holders = deployer.deployers();
        assertEq(holders.length, 0);
    }

    function test_Deployers_WithActive() public {
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);
        deployer.grantRoles(deployer2, DEPLOYER_ROLE);

        address[] memory holders = deployer.deployers();

        assertEq(holders.length, 2);
        assertEq(holders[0], deployer1);
        assertEq(holders[1], deployer2);
    }

    function test_Deployers_OnlyShowsNonEmpty() public {
        // Grant and revoke
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);
        deployer.grantRoles(deployer2, DEPLOYER_ROLE);
        deployer.revokeRoles(deployer1, DEPLOYER_ROLE);

        address[] memory holders = deployer.deployers();

        // Should only show deployer2
        assertEq(holders.length, 1);
        assertEq(holders[0], deployer2);
    }

    function test_IsAuthorizedDeployer() public {
        assertFalse(deployer.isAuthorizedDeployer(deployer1));

        deployer.grantRoles(deployer1, DEPLOYER_ROLE);
        assertTrue(deployer.isAuthorizedDeployer(deployer1));
    }

    /*//////////////////////////////////////////////////////////////////////////
                             UPGRADEABILITY TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_UpgradeAuthorization() public {
        // Deploy new implementation (no constructor params)
        BaoDeployer newImplementation = new BaoDeployer();

        // Owner can upgrade
        deployer.upgradeToAndCall(address(newImplementation), "");

        // Verify still functional
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);
        assertTrue(deployer.isAuthorizedDeployer(deployer1));
    }

    function test_UpgradeAuthorization_OnlyOwner() public {
        BaoDeployer newImplementation = new BaoDeployer();

        vm.prank(user);
        vm.expectRevert();
        deployer.upgradeToAndCall(address(newImplementation), "");
    }

    function test_UpgradePreservesState() public {
        // Grant some deployers
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);
        deployer.grantRoles(deployer2, DEPLOYER_ROLE);

        // Upgrade
        BaoDeployer newImplementation = new BaoDeployer();
        deployer.upgradeToAndCall(address(newImplementation), "");

        // Verify state preserved
        assertTrue(deployer.isAuthorizedDeployer(deployer1));
        assertTrue(deployer.isAuthorizedDeployer(deployer2));

        address[] memory holders = deployer.deployers();
        assertEq(holders.length, 2);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        OWNERSHIP TRANSITION TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_OwnershipTransfer() public {
        // Initially, test contract is owner
        assertEq(deployer.owner(), address(this));

        // Transfer ownership to finalOwner
        deployer.transferOwnership(finalOwner);

        // Owner should now be finalOwner
        assertEq(deployer.owner(), finalOwner);

        // Test contract can no longer call owner functions
        vm.expectRevert();
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);

        // Final owner can
        vm.prank(finalOwner);
        deployer.grantRoles(deployer1, DEPLOYER_ROLE);
        assertTrue(deployer.isAuthorizedDeployer(deployer1));
    }

    /*//////////////////////////////////////////////////////////////////////////
                          EDGE CASE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_GrantRole_ZeroAddress() public {
        // EnumerableSet allows address(0) - it's just another address
        deployer.grantRoles(address(0), DEPLOYER_ROLE);

        address[] memory holders = deployer.deployers();
        assertEq(holders.length, 1); // address(0) is included
        assertEq(holders[0], address(0));

        // address(0) is now an authorized deployer
        assertTrue(deployer.isAuthorizedDeployer(address(0)));
    }
}

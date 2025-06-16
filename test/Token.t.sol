// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Token} from "@bao/Token.sol";

import {console2} from "forge-std/console2.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock contract that is not an ERC20 token
contract MockNonERC20 {
    // Has some functions but not ERC20 functions
    function doSomething() external pure returns (bool) {
        return true;
    }

    // This function will revert
    function revertingFunction() external pure {
        revert("Always reverts");
    }
}

// Mock contract with specific test functions
contract MockFunctions {
    uint256 public stateValue;

    function noParamsNoReturn() external pure {}

    function noParamsWithReturn() external pure returns (uint256) {
        return 42;
    }

    function withParamsNoReturn(uint256 value) external {
        stateValue = value;
    }

    function withParamsWithReturn(uint256 value) external returns (uint256) {
        stateValue = value;
        return value * 2;
    }
}

/**
 * @title TokenLibraryWrapper
 * @dev Wrapper contract that converts all internal Token library functions to external functions
 * for testing purposes. This allows vm.expectRevert to properly capture reverts.
 */
contract TokenLibraryWrapper {
    /**
     * @dev External wrapper for Token.allOf
     */
    function allOf(address account, address token, uint256 tokenIn) external view returns (uint256) {
        return Token.allOf(account, token, tokenIn);
    }

    /**
     * @dev External wrapper for Token.ensureNonZeroAddress
     */
    function ensureNonZeroAddress(address addr) external pure {
        Token.ensureNonZeroAddress(addr);
    }

    /**
     * @dev External wrapper for Token.ensureContract
     */
    function ensureContract(address addr) external view {
        Token.ensureContract(addr);
    }

    /**
     * @dev External wrapper for Token.sanityCheckERC20Token
     */
    function sanityCheckERC20Token(address addr) external view {
        Token.sanityCheckERC20Token(addr);
    }

    /**
     * @dev External wrapper for Token.hasNonMutatingParameterlessFunction
     */
    function hasNonMutatingParameterlessFunction(
        address contractAddr,
        string memory funcName
    ) external view returns (bool) {
        return Token.hasNonMutatingParameterlessFunction(contractAddr, funcName);
    }

    /**
     * @dev External wrapper for Token.callFunction
     */
    function callFunction(
        address contractAddr,
        bytes4 selector,
        bytes memory calldataParams
    ) external returns (bool success, bytes memory returnData) {
        return Token.callFunction(contractAddr, selector, calldataParams);
    }
}

// Contract to test Token library functions
contract TokenLibraryTest is Test {
    TokenLibraryWrapper public tokenLibExt;

    address constant ZERO_ADDRESS = address(0);
    address constant NON_CONTRACT_ADDRESS = address(0x123);

    MockERC20 public token;
    MockNonERC20 public nonERC20;
    MockFunctions public testFunctions;

    address public user;

    function setUp() public {
        tokenLibExt = new TokenLibraryWrapper();

        // Create mock contracts
        token = new MockERC20("Test Token", "TEST", 18);
        nonERC20 = new MockNonERC20();
        testFunctions = new MockFunctions();

        // Setup user
        user = address(0xABCD);
        vm.deal(user, 100 ether);

        // Mint some tokens to user and this contract
        token.mint(user, 1000 ether);
        token.mint(address(this), 500 ether);
    }

    // --- allOf tests ---

    function test_allOf_specificAmount() public view {
        uint256 result = tokenLibExt.allOf(user, address(token), 100 ether);
        assertEq(result, 100 ether, "Should return the specific amount passed");
    }

    function test_allOf_maxValue() public view {
        uint256 result = tokenLibExt.allOf(user, address(token), type(uint256).max);
        assertEq(result, 1000 ether, "Should return the user's balance");
    }

    function test_allOf_zeroReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, address(token)));
        tokenLibExt.allOf(user, address(token), 0);
    }

    function test_allOf_maxValueWithZeroBalance() public {
        address emptyUser = address(0x1234);
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, address(token)));
        tokenLibExt.allOf(emptyUser, address(token), type(uint256).max);
    }

    // --- ensureNonZeroAddress tests ---

    function test_ensureNonZeroAddress() public view {
        // Should not revert with non-zero address
        tokenLibExt.ensureNonZeroAddress(address(token));
    }

    function test_ensureNonZeroAddress_zeroReverts() public {
        vm.expectRevert(Token.ZeroAddress.selector);
        tokenLibExt.ensureNonZeroAddress(ZERO_ADDRESS);
    }

    // --- ensureContract tests ---

    function test_ensureContract() public view {
        // Should not revert with contract address
        tokenLibExt.ensureContract(address(token));
    }

    function test_ensureContract_nonContractReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Token.NotContractAddress.selector, NON_CONTRACT_ADDRESS));
        tokenLibExt.ensureContract(NON_CONTRACT_ADDRESS);
    }

    function test_ensureContract_zeroAddressReverts() public {
        vm.expectRevert(Token.ZeroAddress.selector);
        tokenLibExt.ensureContract(ZERO_ADDRESS);
    }

    // --- sanityCheckERC20Token tests ---

    function test_sanityCheckERC20Token() public view {
        // Should not revert with valid ERC20
        tokenLibExt.sanityCheckERC20Token(address(token));
    }

    function test_sanityCheckERC20Token_nonERC20Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Token.NotERC20Token.selector, address(nonERC20)));
        tokenLibExt.sanityCheckERC20Token(address(nonERC20));
    }

    function test_sanityCheckERC20Token_nonContractReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Token.NotContractAddress.selector, NON_CONTRACT_ADDRESS));
        tokenLibExt.sanityCheckERC20Token(NON_CONTRACT_ADDRESS);
    }

    function test_sanityCheckERC20Token_zeroAddressReverts() public {
        vm.expectRevert(Token.ZeroAddress.selector);
        tokenLibExt.sanityCheckERC20Token(ZERO_ADDRESS);
    }

    // --- hasNonMutatingParameterlessFunction tests ---

    function test_hasNonMutatingParameterlessFunction_exists() public view {
        bool exists = tokenLibExt.hasNonMutatingParameterlessFunction(address(testFunctions), "noParamsNoReturn");
        assertTrue(exists, "Should return true for existing function");

        exists = tokenLibExt.hasNonMutatingParameterlessFunction(address(testFunctions), "noParamsWithReturn");
        assertTrue(exists, "Should return true for existing function with return");
    }

    function test_hasNonMutatingParameterlessFunction_notExists() public view {
        bool exists = tokenLibExt.hasNonMutatingParameterlessFunction(address(testFunctions), "nonExistentFunction");
        assertFalse(exists, "Should return false for non-existent function");
    }

    function test_hasNonMutatingParameterlessFunction_withParams() public view {
        // Functions with parameters will revert when called without parameters
        bool exists = tokenLibExt.hasNonMutatingParameterlessFunction(address(testFunctions), "withParamsNoReturn");
        assertFalse(exists, "Should return false for function with parameters");
    }

    // --- callFunction tests ---

    function test_callFunction_noParamsNoReturn() public {
        bytes4 selector = bytes4(keccak256("noParamsNoReturn()"));
        (bool success, bytes memory returnData) = tokenLibExt.callFunction(address(testFunctions), selector, "");

        assertTrue(success, "Function call should succeed");
        assertEq(returnData.length, 0, "No return data expected");
    }

    function test_callFunction_noParamsWithReturn() public {
        bytes4 selector = bytes4(keccak256("noParamsWithReturn()"));
        (bool success, bytes memory returnData) = tokenLibExt.callFunction(address(testFunctions), selector, "");

        assertTrue(success, "Function call should succeed");
        assertEq(abi.decode(returnData, (uint256)), 42, "Should return 42");
    }

    function test_callFunction_withParamsNoReturn() public {
        bytes4 selector = bytes4(keccak256("withParamsNoReturn(uint256)"));
        uint256 testValue = 123;
        (bool success, bytes memory returnData) = tokenLibExt.callFunction(
            address(testFunctions),
            selector,
            abi.encode(testValue)
        );

        assertTrue(success, "Function call should succeed");
        assertEq(returnData.length, 0, "No return data expected");
        assertEq(testFunctions.stateValue(), testValue, "State should be updated");
    }

    function test_callFunction_withParamsWithReturn() public {
        bytes4 selector = bytes4(keccak256("withParamsWithReturn(uint256)"));
        uint256 testValue = 123;
        (bool success, bytes memory returnData) = tokenLibExt.callFunction(
            address(testFunctions),
            selector,
            abi.encode(testValue)
        );

        assertTrue(success, "Function call should succeed");
        assertEq(abi.decode(returnData, (uint256)), testValue * 2, "Should return doubled value");
        assertEq(testFunctions.stateValue(), testValue, "State should be updated");
    }

    function test_callFunction_nonExistent() public {
        bytes4 selector = bytes4(keccak256("nonExistentFunction()"));
        (bool success, bytes memory returnData) = tokenLibExt.callFunction(address(testFunctions), selector, "");

        assertFalse(success, "Function call should fail");
        assertEq(returnData.length, 0, "No return data expected for failed call");
    }

    function test_callFunction_reverting() public {
        bytes4 selector = bytes4(keccak256("revertingFunction()"));
        (bool success, ) = tokenLibExt.callFunction(address(nonERC20), selector, "");

        assertFalse(success, "Function call should fail for reverting function");
    }
}

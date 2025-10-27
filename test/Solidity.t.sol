// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract TestSolidityInitialisation is Test {
    string public stateString;
    uint256 public stateUint;
    bool public stateBool;
    string[] public stateStringArray;
    uint256[] public stateUintArray;
    string[1] public stateStringArray1;
    uint256[1] public stateUintArray1;

    struct Variables {
        string structString;
        uint256 structUint;
        bool structBool;
        string[] structStringArray;
        uint256[] structUintArray;
        string[1] structStringArray1;
        uint256[1] structUintArray1;
    }

    function testState() public view {
        assertEq(stateString, "", "stateString");
        assertEq(stateUint, 0, "stateUint");
        assertEq(stateBool, false, "stateBool");
        assertEq(stateStringArray.length, 0, "stateStringArray");
        assertEq(stateUintArray.length, 0, "stateUintArray");
        assertEq(stateStringArray1[0], "", "stateStringArray1");
        assertEq(stateUintArray1[0], 0, "stateUintArray1");
    }

    function testStruct() public pure {
        Variables memory v;
        assertEq(v.structString, "", "structString");
        assertEq(v.structUint, 0, "structUint");
        assertEq(v.structBool, false, "structBool");
        assertEq(v.structStringArray.length, 0, "structStringArray");
        assertEq(v.structUintArray.length, 0, "structUintArray");
        assertEq(v.structStringArray1[0], "", "structStringArray1");
        assertEq(v.structUintArray1[0], 0, "structUintArray1");
    }

    function testMemory() public pure {
        string memory memString;
        uint256 memUint;
        bool memBool;
        string[] memory memStringArray;
        uint256[] memory memUintArray;
        string[1] memory memStringArray1;
        uint256[1] memory memUintArray1;

        assertEq(memString, "", "memString");
        assertEq(memUint, 0, "memUint");
        assertEq(memBool, false, "memBool");
        assertEq(memStringArray.length, 0, "memStringArray");
        assertEq(memUintArray.length, 0, "memUintArray");
        assertEq(memStringArray1[0], "", "memStringArray1");
        assertEq(memUintArray1[0], 0, "memUintArray1");
    }
}

contract ReturnGas {
    function doReturn(uint256 a, uint256 b, uint256 c) public pure returns (uint256) {
        return Math.mulDiv(a, b, c);
    }

    function doVariable(uint256 a, uint256 b, uint256 c) public pure returns (uint256 value) {
        value = Math.mulDiv(a, b, c);
    }
}

contract TestReturnGas is Test {
    ReturnGas public rg;

    function setUp() public {
        rg = new ReturnGas();
    }

    function testReturnGas() public {
        uint256 gasStart;

        uint256 snap = vm.snapshotState();

        gasStart = gasleft();
        uint256 resultReturn = rg.doReturn(1e18, 4e18, 2e18);
        uint256 gasUsedReturn = gasStart - gasleft();

        gasStart = gasleft();
        uint256 resultVariable = rg.doVariable(1e18, 4e18, 2e18);
        uint256 gasUsedVariable = gasStart - gasleft();

        assertEq(resultReturn, resultVariable, "results should be equal");

        vm.revertToState(snap);

        gasStart = gasleft();
        uint256 resultVariable1 = rg.doVariable(2e18, 8e18, 4e18);
        uint256 gasUsedVariable1 = gasStart - gasleft();

        gasStart = gasleft();
        uint256 resultReturn1 = rg.doReturn(2e18, 8e18, 4e18);
        uint256 gasUsedReturn1 = gasStart - gasleft();

        assertEq(resultReturn1, resultVariable1, "results should be equal");

        // emit log_named_uint("gasUsedReturn", gasUsedReturn);
        // emit log_named_uint("gasUsedVariable", gasUsedVariable);
        assertLt(gasUsedReturn, gasUsedVariable1, "return should use less gas (first use)");
        assertLt(gasUsedReturn1, gasUsedVariable, "return should use less gas (second use)");
    }
}

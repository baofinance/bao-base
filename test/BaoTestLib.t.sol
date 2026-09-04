// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {BaoTestLib} from "@bao-test/BaoTestLib.sol";

contract BaoTestLibTest is Test {
    function test_extractUInt256() public pure {
        bytes memory data = new bytes(100);
        assertEq(BaoTestLib.extractUInt256(data, 0), 0, "initialised to zero, right?");

        data[31] = 0x01;
        assertEq(BaoTestLib.extractUInt256(data, 0), 1, "little endian numbers for you");
        assertEq(BaoTestLib.extractUInt256(data, 1), 256, "offset by 1 byte is like a multiply by 2*8");

        data[30] = 0x01; // we now have
        assertEq(BaoTestLib.extractUInt256(data, 0), 257, "two byte number");
    }

    function test_toString_decimals() public pure {
        assertEq(BaoTestLib.toStringScaled(uint(0), 1), "0.0");
        assertEq(BaoTestLib.toStringScaled(uint(0), 2), "0.00");
        assertEq(BaoTestLib.toStringScaled(uint(1), 1), "0.1");
        assertEq(BaoTestLib.toStringScaled(uint(1), 2), "0.01");
        assertEq(BaoTestLib.toStringScaled(uint(10), 1), "1.0");
        assertEq(BaoTestLib.toStringScaled(uint(100), 2), "1.00");

        assertEq(BaoTestLib.toStringScaled(int(0), 1), "0.0");
        assertEq(BaoTestLib.toStringScaled(int(0), 2), "0.00");
        assertEq(BaoTestLib.toStringScaled(int(1), 1), "0.1");
        assertEq(BaoTestLib.toStringScaled(int(1), 2), "0.01");
        assertEq(BaoTestLib.toStringScaled(int(10), 1), "1.0");
        assertEq(BaoTestLib.toStringScaled(int(100), 2), "1.00");

        assertEq(BaoTestLib.toStringScaled(int(-0), 2), "0.00");
        assertEq(BaoTestLib.toStringScaled(int(-1), 1), "-0.1");
        assertEq(BaoTestLib.toStringScaled(int(-1), 2), "-0.01");
        assertEq(BaoTestLib.toStringScaled(int(-10), 1), "-1.0");
        assertEq(BaoTestLib.toStringScaled(int(-100), 2), "-1.00");
    }

    function test_toString_thousands() public pure {
        assertEq(BaoTestLib.toStringThousands(0, BaoTestLib.comma), "0");
        assertEq(BaoTestLib.toStringThousands(1, BaoTestLib.comma), "1");
        assertEq(BaoTestLib.toStringThousands(100, BaoTestLib.comma), "100");
        assertEq(BaoTestLib.toStringThousands(1000, BaoTestLib.comma), "1,000");
        assertEq(BaoTestLib.toStringThousands(10000, BaoTestLib.underscore), "10_000");
        assertEq(BaoTestLib.toStringThousands(100000, BaoTestLib.comma), "100,000");
        assertEq(BaoTestLib.toStringThousands(1000000, BaoTestLib.comma), "1,000,000");
        assertEq(BaoTestLib.toStringThousands(10000000, BaoTestLib.comma), "10,000,000");
        assertEq(BaoTestLib.toStringThousands(100000000, BaoTestLib.comma), "100,000,000");

        assertEq(BaoTestLib.toStringThousands(123456789, BaoTestLib.comma), "123,456,789");

        assertEq(BaoTestLib.toStringThousands(0, 0), "0");
        assertEq(BaoTestLib.toStringThousands(1, 0), "1");
        assertEq(BaoTestLib.toStringThousands(100, 0), "100");
        assertEq(BaoTestLib.toStringThousands(1000, 0), "1000");
        assertEq(BaoTestLib.toStringThousands(10000, 0), "10000");
        assertEq(BaoTestLib.toStringThousands(100000, 0), "100000");
        assertEq(BaoTestLib.toStringThousands(1000000, 0), "1000000");
    }

    function test_toUint256() public pure {
        assertEq(BaoTestLib.toUint256("", 0), 0, "empty");
        assertEq(BaoTestLib.toUint256("0", 0), 0, "zero");

        assertEq(BaoTestLib.toUint256("1", 0), 1, "one");
        assertEq(BaoTestLib.toUint256("1", 1), 10, "ten");
        assertEq(BaoTestLib.toUint256("1", 10), 10000000000, "gazillion");

        assertEq(BaoTestLib.toUint256("01", 0), 1, "one 2");
        assertEq(BaoTestLib.toUint256("10", 0), 10, "ten 2");
        assertEq(BaoTestLib.toUint256("10000000000", 0), 10000000000, "gazillion 2");

        assertEq(BaoTestLib.toUint256("1234567890", 0), 1234567890, "all digits");

        // point
        assertEq(BaoTestLib.toUint256("9876543210", 0), 9876543210, "all digits backwards");
        assertEq(BaoTestLib.toUint256("9876543210", 1), 98765432100, "all digits backwards * 10");

        assertEq(BaoTestLib.toUint256("987654321.0", 0), 987654321, ". @ 1");
        assertEq(BaoTestLib.toUint256("987654321.0", 1), 9876543210, ". @ 1 * 10");
        assertEq(BaoTestLib.toUint256("98765432.10", 0), 98765432, ". @ 2");
        assertEq(BaoTestLib.toUint256("98765432.10", 1), 987654321, ". @ 2 * 10");
        assertEq(BaoTestLib.toUint256("9876543.210", 0), 9876543, ". @ 3");
        assertEq(BaoTestLib.toUint256("9876543.210", 1), 98765432, ". @ 3 * 10");
        assertEq(BaoTestLib.toUint256(".9876543210", 0), 0, ".9");
        assertEq(BaoTestLib.toUint256(".9876543210", 1), 9, ".9 * 10");
        assertEq(BaoTestLib.toUint256("0.99", 1), 9, "0.99");

        // percent
        assertEq(BaoTestLib.toUint256("0.9", 4), 9000, "0.9");
        assertEq(BaoTestLib.toUint256("0.9%", 4), 90, "0.9%");

        assertEq(BaoTestLib.toUint256("9%", 4), 900, "9%");
    }

    function test_consistency() public pure {
        assertEq(BaoTestLib.toUint256(BaoTestLib.toStringScaled(uint(0), 1), 1), 0);
        assertEq(BaoTestLib.toUint256(BaoTestLib.toStringScaled(uint(0), 2), 2), 0);
        assertEq(BaoTestLib.toUint256(BaoTestLib.toStringScaled(uint(1), 1), 1), 1);
        assertEq(BaoTestLib.toUint256(BaoTestLib.toStringScaled(uint(1), 2), 2), 1);
        assertEq(BaoTestLib.toUint256(BaoTestLib.toStringScaled(uint(10), 1), 1), 10);
        assertEq(BaoTestLib.toUint256(BaoTestLib.toStringScaled(uint(100), 2), 2), 100);
    }

    /// `join` is the CSV row builder for the graph framework, so its separator placement matters at
    /// every arity: none for an empty or single-element list, and exactly one between each pair.
    function test_join_atEachArity() public pure {
        string[] memory none = new string[](0);
        assertEq(BaoTestLib.join(none, ","), "", "empty joins to empty");

        string[] memory one = new string[](1);
        one[0] = "a";
        assertEq(BaoTestLib.join(one, ","), "a", "single element carries no separator");

        string[] memory three = new string[](3);
        three[0] = "a";
        three[1] = "b";
        three[2] = "c";
        assertEq(BaoTestLib.join(three, ","), "a,b,c", "separator between each pair only");

        // An empty element is still an element: it must produce an empty field, not vanish.
        string[] memory withGap = new string[](3);
        withGap[0] = "a";
        withGap[1] = "";
        withGap[2] = "c";
        assertEq(BaoTestLib.join(withGap, ","), "a,,c", "empty field is preserved");

        assertEq(BaoTestLib.join(three, ""), "abc", "empty separator concatenates");
    }
}

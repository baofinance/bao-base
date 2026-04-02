// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {Array} from "@bao-script/utils/Array.sol";

contract ArrayTest is Test, Array {
    // ========== ua (uint[]) ==========

    function test_ua_0() public pure {
        uint[] memory r = ua();
        assertEq(r.length, 0);
    }

    function test_ua_1() public pure {
        uint[] memory r = ua(11);
        assertEq(r.length, 1);
        assertEq(r[0], 11);
    }

    function test_ua_2() public pure {
        uint[] memory r = ua(1, 2);
        assertEq(r.length, 2);
        assertEq(r[0], 1);
        assertEq(r[1], 2);
    }

    function test_ua_3() public pure {
        uint[] memory r = ua(1, 2, 3);
        assertEq(r.length, 3);
        assertEq(r[2], 3);
    }

    function test_ua_4() public pure {
        uint[] memory r = ua(1, 2, 3, 4);
        assertEq(r.length, 4);
        assertEq(r[3], 4);
    }

    function test_ua_5() public pure {
        uint[] memory r = ua(1, 2, 3, 4, 5);
        assertEq(r.length, 5);
        assertEq(r[4], 5);
    }

    function test_ua_6() public pure {
        uint[] memory r = ua(1, 2, 3, 4, 5, 6);
        assertEq(r.length, 6);
        assertEq(r[5], 6);
    }

    function test_ua_7() public pure {
        uint[] memory r = ua(1, 2, 3, 4, 5, 6, 7);
        assertEq(r.length, 7);
        assertEq(r[6], 7);
    }

    function test_ua_8() public pure {
        uint[] memory r = ua(1, 2, 3, 4, 5, 6, 7, 8);
        assertEq(r.length, 8);
        assertEq(r[7], 8);
    }

    function test_ua_9() public pure {
        uint[] memory r = ua(1, 2, 3, 4, 5, 6, 7, 8, 9);
        assertEq(r.length, 9);
        assertEq(r[8], 9);
    }

    function test_ua_10() public pure {
        uint[] memory r = ua(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
        assertEq(r.length, 10);
        assertEq(r[9], 10);
    }

    function test_ua_11() public pure {
        uint[] memory r = ua(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11);
        assertEq(r.length, 11);
        assertEq(r[10], 11);
    }

    function test_ua_12() public pure {
        uint[] memory r = ua(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12);
        assertEq(r.length, 12);
        assertEq(r[11], 12);
    }

    function test_ua_13() public pure {
        uint[] memory r = ua(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13);
        assertEq(r.length, 13);
        assertEq(r[0], 1);
        assertEq(r[12], 13);
    }

    // ========== ia (int[]) ==========

    function test_ia_0() public pure {
        int[] memory r = ia();
        assertEq(r.length, 0);
    }

    function test_ia_1() public pure {
        int[] memory r = ia(-5);
        assertEq(r.length, 1);
        assertEq(r[0], -5);
    }

    function test_ia_2() public pure {
        int[] memory r = ia(-1, 2);
        assertEq(r.length, 2);
        assertEq(r[0], -1);
        assertEq(r[1], 2);
    }

    function test_ia_3() public pure {
        int[] memory r = ia(1, 2, 3);
        assertEq(r.length, 3);
        assertEq(r[2], 3);
    }

    function test_ia_4() public pure {
        int[] memory r = ia(1, 2, 3, 4);
        assertEq(r.length, 4);
        assertEq(r[3], 4);
    }

    function test_ia_5() public pure {
        int[] memory r = ia(1, 2, 3, 4, 5);
        assertEq(r.length, 5);
        assertEq(r[4], 5);
    }

    function test_ia_6() public pure {
        int[] memory r = ia(1, 2, 3, 4, 5, 6);
        assertEq(r.length, 6);
        assertEq(r[5], 6);
    }

    function test_ia_7() public pure {
        int[] memory r = ia(1, 2, 3, 4, 5, 6, 7);
        assertEq(r.length, 7);
        assertEq(r[6], 7);
    }

    function test_ia_8() public pure {
        int[] memory r = ia(1, 2, 3, 4, 5, 6, 7, 8);
        assertEq(r.length, 8);
        assertEq(r[7], 8);
    }

    function test_ia_9() public pure {
        int[] memory r = ia(1, 2, 3, 4, 5, 6, 7, 8, 9);
        assertEq(r.length, 9);
        assertEq(r[8], 9);
    }

    function test_ia_10() public pure {
        int[] memory r = ia(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
        assertEq(r.length, 10);
        assertEq(r[0], 1);
        assertEq(r[9], 10);
    }

    // ========== aa (address[]) ==========

    function test_aa_0() public pure {
        address[] memory r = aa();
        assertEq(r.length, 0);
    }

    function test_aa_1() public pure {
        address[] memory r = aa(address(1));
        assertEq(r.length, 1);
        assertEq(r[0], address(1));
    }

    function test_aa_2() public pure {
        address[] memory r = aa(address(1), address(2));
        assertEq(r.length, 2);
        assertEq(r[1], address(2));
    }

    function test_aa_3() public pure {
        address[] memory r = aa(address(1), address(2), address(3));
        assertEq(r.length, 3);
        assertEq(r[2], address(3));
    }

    function test_aa_4() public pure {
        address[] memory r = aa(address(1), address(2), address(3), address(4));
        assertEq(r.length, 4);
        assertEq(r[3], address(4));
    }

    function test_aa_5() public pure {
        address[] memory r = aa(address(1), address(2), address(3), address(4), address(5));
        assertEq(r.length, 5);
        assertEq(r[4], address(5));
    }

    function test_aa_6() public pure {
        address[] memory r = aa(address(1), address(2), address(3), address(4), address(5), address(6));
        assertEq(r.length, 6);
        assertEq(r[0], address(1));
        assertEq(r[5], address(6));
    }

    // ========== sa (string[]) ==========

    function test_sa_0() public pure {
        string[] memory r = sa();
        assertEq(r.length, 0);
    }

    function test_sa_1() public pure {
        string[] memory r = sa("a");
        assertEq(r.length, 1);
        assertEq(r[0], "a");
    }

    function test_sa_2() public pure {
        string[] memory r = sa("a", "b");
        assertEq(r.length, 2);
        assertEq(r[1], "b");
    }

    function test_sa_3() public pure {
        string[] memory r = sa("a", "b", "c");
        assertEq(r.length, 3);
        assertEq(r[2], "c");
    }

    function test_sa_4() public pure {
        string[] memory r = sa("a", "b", "c", "d");
        assertEq(r.length, 4);
        assertEq(r[3], "d");
    }

    function test_sa_5() public pure {
        string[] memory r = sa("a", "b", "c", "d", "e");
        assertEq(r.length, 5);
        assertEq(r[4], "e");
    }

    function test_sa_6() public pure {
        string[] memory r = sa("a", "b", "c", "d", "e", "f");
        assertEq(r.length, 6);
        assertEq(r[5], "f");
    }

    function test_sa_7() public pure {
        string[] memory r = sa("a", "b", "c", "d", "e", "f", "g");
        assertEq(r.length, 7);
        assertEq(r[6], "g");
    }

    function test_sa_8() public pure {
        string[] memory r = sa("a", "b", "c", "d", "e", "f", "g", "h");
        assertEq(r.length, 8);
        assertEq(r[7], "h");
    }

    function test_sa_9() public pure {
        string[] memory r = sa("a", "b", "c", "d", "e", "f", "g", "h", "i");
        assertEq(r.length, 9);
        assertEq(r[8], "i");
    }

    function test_sa_10() public pure {
        string[] memory r = sa("a", "b", "c", "d", "e", "f", "g", "h", "i", "j");
        assertEq(r.length, 10);
        assertEq(r[9], "j");
    }

    function test_sa_11() public pure {
        string[] memory r = sa("a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k");
        assertEq(r.length, 11);
        assertEq(r[10], "k");
    }

    function test_sa_12() public pure {
        string[] memory r = sa("a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l");
        assertEq(r.length, 12);
        assertEq(r[11], "l");
    }

    function test_sa_13() public pure {
        string[] memory r = sa("a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m");
        assertEq(r.length, 13);
        assertEq(r[0], "a");
        assertEq(r[12], "m");
    }

    // ========== cons ==========

    function test_cons_uint() public pure {
        uint[] memory tail = ua(2, 3);
        uint[] memory r = cons(1, tail);
        assertEq(r.length, 3);
        assertEq(r[0], 1);
        assertEq(r[1], 2);
        assertEq(r[2], 3);
    }

    function test_cons_uint_empty() public pure {
        uint[] memory r = cons(42, ua());
        assertEq(r.length, 1);
        assertEq(r[0], 42);
    }

    function test_cons_int() public pure {
        int[] memory tail = ia(-2, -3);
        int[] memory r = cons(-1, tail);
        assertEq(r.length, 3);
        assertEq(r[0], -1);
        assertEq(r[1], -2);
        assertEq(r[2], -3);
    }

    function test_cons_address() public pure {
        address[] memory tail = aa(address(2), address(3));
        address[] memory r = cons(address(1), tail);
        assertEq(r.length, 3);
        assertEq(r[0], address(1));
        assertEq(r[1], address(2));
        assertEq(r[2], address(3));
    }

    // ========== ultimate / penultimate / initial / second ==========

    function test_ultimate_uint() public pure {
        assertEq(ultimate(ua(10, 20, 30)), 30);
    }

    function test_ultimate_int() public pure {
        assertEq(ultimate(ia(-1, -2, -3)), -3);
    }

    function test_ultimate_address() public pure {
        assertEq(ultimate(aa(address(1), address(2), address(3))), address(3));
    }

    function test_penultimate_uint() public pure {
        assertEq(penultimate(ua(10, 20, 30)), 20);
    }

    function test_penultimate_int() public pure {
        assertEq(penultimate(ia(-1, -2, -3)), -2);
    }

    function test_penultimate_address() public pure {
        assertEq(penultimate(aa(address(1), address(2), address(3))), address(2));
    }

    function test_initial_uint() public pure {
        assertEq(initial(ua(10, 20, 30)), 10);
    }

    function test_initial_int() public pure {
        assertEq(initial(ia(-1, -2, -3)), -1);
    }

    function test_initial_address() public pure {
        assertEq(initial(aa(address(1), address(2), address(3))), address(1));
    }

    function test_second_uint() public pure {
        assertEq(second(ua(10, 20, 30)), 20);
    }

    function test_second_int() public pure {
        assertEq(second(ia(-1, -2, -3)), -2);
    }

    function test_second_address() public pure {
        assertEq(second(aa(address(1), address(2), address(3))), address(2));
    }
}

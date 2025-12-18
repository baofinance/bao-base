// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// creates arrays of uint, int and address

contract Array {
    function ua() internal pure returns (uint[] memory result) {
        result = new uint[](0);
    }
    function ua(uint a_) internal pure returns (uint[] memory result) {
        result = new uint[](1);
        result[0] = a_;
    }
    function ua(uint a_, uint b) internal pure returns (uint[] memory result) {
        result = new uint[](2);
        result[0] = a_;
        result[1] = b;
    }
    function ua(uint a_, uint b, uint c) internal pure returns (uint[] memory result) {
        result = new uint[](3);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
    }
    function ua(uint a_, uint b, uint c, uint d) internal pure returns (uint[] memory result) {
        result = new uint[](4);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
    }
    function ua(uint a_, uint b, uint c, uint d, uint e) internal pure returns (uint[] memory result) {
        result = new uint[](5);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
    }
    function ua(uint a_, uint b, uint c, uint d, uint e, uint f) internal pure returns (uint[] memory result) {
        result = new uint[](6);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
    }
    function ua(uint a_, uint b, uint c, uint d, uint e, uint f, uint g) internal pure returns (uint[] memory result) {
        result = new uint[](7);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
    }
    function ua(
        uint a_,
        uint b,
        uint c,
        uint d,
        uint e,
        uint f,
        uint g,
        uint h
    ) internal pure returns (uint[] memory result) {
        result = new uint[](8);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
    }

    function ua(
        uint a_,
        uint b,
        uint c,
        uint d,
        uint e,
        uint f,
        uint g,
        uint h,
        uint i
    ) internal pure returns (uint[] memory result) {
        result = new uint[](9);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
    }

    function ua(
        uint a_,
        uint b,
        uint c,
        uint d,
        uint e,
        uint f,
        uint g,
        uint h,
        uint i,
        uint j
    ) internal pure returns (uint[] memory result) {
        result = new uint[](10);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
        result[9] = j;
    }

    function ua(
        uint a_,
        uint b,
        uint c,
        uint d,
        uint e,
        uint f,
        uint g,
        uint h,
        uint i,
        uint j,
        uint k
    ) internal pure returns (uint[] memory result) {
        result = new uint[](11);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
        result[9] = j;
        result[10] = k;
    }

    function ua(
        uint a_,
        uint b,
        uint c,
        uint d,
        uint e,
        uint f,
        uint g,
        uint h,
        uint i,
        uint j,
        uint k,
        uint l
    ) internal pure returns (uint[] memory result) {
        result = new uint[](12);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
        result[9] = j;
        result[10] = k;
        result[11] = l;
    }

    function ua(
        uint a_,
        uint b,
        uint c,
        uint d,
        uint e,
        uint f,
        uint g,
        uint h,
        uint i,
        uint j,
        uint k,
        uint l,
        uint m
    ) internal pure returns (uint[] memory result) {
        result = new uint[](13);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
        result[9] = j;
        result[10] = k;
        result[11] = l;
        result[12] = m;
    }

    function ia() internal pure returns (int[] memory result) {
        result = new int[](0);
    }

    function ia(int a_) internal pure returns (int[] memory result) {
        result = new int[](1);
        result[0] = a_;
    }

    function ia(int a_, int b) internal pure returns (int[] memory result) {
        result = new int[](2);
        result[0] = a_;
        result[1] = b;
    }

    function ia(int a_, int b, int c) internal pure returns (int[] memory result) {
        result = new int[](3);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
    }

    function ia(int a_, int b, int c, int d) internal pure returns (int[] memory result) {
        result = new int[](4);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
    }

    function ia(int a_, int b, int c, int d, int e) internal pure returns (int[] memory result) {
        result = new int[](5);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
    }

    function ia(int a_, int b, int c, int d, int e, int f) internal pure returns (int[] memory result) {
        result = new int[](6);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
    }

    function ia(int a_, int b, int c, int d, int e, int f, int g) internal pure returns (int[] memory result) {
        result = new int[](7);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
    }

    function ia(int a_, int b, int c, int d, int e, int f, int g, int h) internal pure returns (int[] memory result) {
        result = new int[](8);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
    }

    function ia(
        int a_,
        int b,
        int c,
        int d,
        int e,
        int f,
        int g,
        int h,
        int i
    ) internal pure returns (int[] memory result) {
        result = new int[](9);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
    }

    function ia(
        int a_,
        int b,
        int c,
        int d,
        int e,
        int f,
        int g,
        int h,
        int i,
        int j
    ) internal pure returns (int[] memory result) {
        result = new int[](10);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
        result[9] = j;
    }

    function aa() internal pure returns (address[] memory result) {
        result = new address[](0);
    }
    function aa(address a_) internal pure returns (address[] memory result) {
        result = new address[](1);
        result[0] = a_;
    }
    function aa(address a_, address b) internal pure returns (address[] memory result) {
        result = new address[](2);
        result[0] = a_;
        result[1] = b;
    }
    function aa(address a_, address b, address c) internal pure returns (address[] memory result) {
        result = new address[](3);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
    }
    function aa(address a_, address b, address c, address d) internal pure returns (address[] memory result) {
        result = new address[](4);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
    }
    function aa(
        address a_,
        address b,
        address c,
        address d,
        address e
    ) internal pure returns (address[] memory result) {
        result = new address[](5);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
    }
    function aa(
        address a_,
        address b,
        address c,
        address d,
        address e,
        address f
    ) internal pure returns (address[] memory result) {
        result = new address[](6);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
    }

    function sa() internal pure returns (string[] memory result) {
        result = new string[](0);
    }
    function sa(string memory a_) internal pure returns (string[] memory result) {
        result = new string[](1);
        result[0] = a_;
    }
    function sa(string memory a_, string memory b) internal pure returns (string[] memory result) {
        result = new string[](2);
        result[0] = a_;
        result[1] = b;
    }
    function sa(string memory a_, string memory b, string memory c) internal pure returns (string[] memory result) {
        result = new string[](3);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d
    ) internal pure returns (string[] memory result) {
        result = new string[](4);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d,
        string memory e
    ) internal pure returns (string[] memory result) {
        result = new string[](5);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d,
        string memory e,
        string memory f
    ) internal pure returns (string[] memory result) {
        result = new string[](6);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d,
        string memory e,
        string memory f,
        string memory g
    ) internal pure returns (string[] memory result) {
        result = new string[](7);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d,
        string memory e,
        string memory f,
        string memory g,
        string memory h
    ) internal pure returns (string[] memory result) {
        result = new string[](8);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d,
        string memory e,
        string memory f,
        string memory g,
        string memory h,
        string memory i
    ) internal pure returns (string[] memory result) {
        result = new string[](9);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d,
        string memory e,
        string memory f,
        string memory g,
        string memory h,
        string memory i,
        string memory j
    ) internal pure returns (string[] memory result) {
        result = new string[](10);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
        result[9] = j;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d,
        string memory e,
        string memory f,
        string memory g,
        string memory h,
        string memory i,
        string memory j,
        string memory k
    ) internal pure returns (string[] memory result) {
        result = new string[](11);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
        result[9] = j;
        result[10] = k;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d,
        string memory e,
        string memory f,
        string memory g,
        string memory h,
        string memory i,
        string memory j,
        string memory k,
        string memory l
    ) internal pure returns (string[] memory result) {
        result = new string[](12);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
        result[9] = j;
        result[10] = k;
        result[11] = l;
    }

    function sa(
        string memory a_,
        string memory b,
        string memory c,
        string memory d,
        string memory e,
        string memory f,
        string memory g,
        string memory h,
        string memory i,
        string memory j,
        string memory k,
        string memory l,
        string memory m
    ) internal pure returns (string[] memory result) {
        result = new string[](13);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
        result[6] = g;
        result[7] = h;
        result[8] = i;
        result[9] = j;
        result[10] = k;
        result[11] = l;
        result[12] = m;
    }

    function cons(uint car, uint[] memory cdr) internal pure returns (uint[] memory list) {
        list = new uint[](cdr.length + 1);
        list[0] = car;
        for (uint i = 0; i < cdr.length; i++) {
            list[i + 1] = cdr[i];
        }
    }

    function cons(int car, int[] memory cdr) internal pure returns (int[] memory list) {
        list = new int[](cdr.length + 1);
        list[0] = car;
        for (uint i = 0; i < cdr.length; i++) {
            list[i + 1] = cdr[i];
        }
    }

    function cons(address car, address[] memory cdr) internal pure returns (address[] memory list) {
        list = new address[](cdr.length + 1);
        list[0] = car;
        for (uint i = 0; i < cdr.length; i++) {
            list[i + 1] = cdr[i];
        }
    }

    function ultimate(uint[] memory list) internal pure returns (uint) {
        return list[list.length - 1];
    }

    function ultimate(int[] memory list) internal pure returns (int) {
        return list[list.length - 1];
    }

    function ultimate(address[] memory list) internal pure returns (address) {
        return list[list.length - 1];
    }

    function penultimate(uint[] memory list) internal pure returns (uint) {
        return list[list.length - 2];
    }

    function penultimate(int[] memory list) internal pure returns (int) {
        return list[list.length - 2];
    }

    function penultimate(address[] memory list) internal pure returns (address) {
        return list[list.length - 2];
    }

    function initial(uint[] memory list) internal pure returns (uint) {
        return list[0];
    }

    function initial(int[] memory list) internal pure returns (int) {
        return list[0];
    }

    function initial(address[] memory list) internal pure returns (address) {
        return list[0];
    }

    function second(uint[] memory list) internal pure returns (uint) {
        return list[1];
    }

    function second(int[] memory list) internal pure returns (int) {
        return list[1];
    }

    function second(address[] memory list) internal pure returns (address) {
        return list[1];
    }
}

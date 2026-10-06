// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// A family with only its first version, which has no predecessor to name: this passes.

contract SingleVersion_v1 is Initializable {}

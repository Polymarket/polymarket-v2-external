// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { EnumerableSetLib } from "@solady/src/utils/EnumerableSetLib.sol";

/// @title EnumerableSetShimHarness
/// @notice Externalises one `AddressSet` so the set ADT laws can be proved about it directly.
contract EnumerableSetShimHarness {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    EnumerableSetLib.AddressSet internal setA;
    EnumerableSetLib.AddressSet internal setB;

    function addToA(address a) external returns (bool) {
        return setA.add(a);
    }

    function removeFromA(address a) external returns (bool) {
        return setA.remove(a);
    }

    function addToB(address a) external returns (bool) {
        return setB.add(a);
    }

    function removeFromB(address a) external returns (bool) {
        return setB.remove(a);
    }

    function containsInA(address a) external view returns (bool) {
        return setA.contains(a);
    }

    function containsInB(address a) external view returns (bool) {
        return setB.contains(a);
    }

    function lengthOfA() external view returns (uint256) {
        return setA.length();
    }

    function lengthOfB() external view returns (uint256) {
        return setB.length();
    }

    /// @notice `at` is spelled out because `at` is a reserved word in CVL.
    function elementOfAAt(uint256 i) external view returns (address) {
        return setA.at(i);
    }

    /// @notice A's element at a 1-BASED index; `address(0)` when the index is 0 or out of range.
    /// @dev Total on purpose — no revert — so it can appear inside an invariant whose antecedent is
    ///      false. 1-based to match `rawIndexInA`, which keeps the well-formedness clauses free of
    ///      `index - 1` and therefore free of mathint-to-uint256 cast edges at index zero.
    function elementOfAAtOneBased(uint256 oneBased) external view returns (address) {
        if (oneBased == 0 || oneBased > setA._elements.length) return address(0);
        return setA._elements[oneBased - 1];
    }

    /// @notice A's raw 1-based index for `a`; zero means absent.
    /// @dev Deliberately non-reverting, so it can appear inside an invariant expression whose
    ///      antecedent is false. Reads the shim's own field, so this harness only compiles under the
    ///      shim remapping — which is the point.
    function rawIndexInA(address a) external view returns (uint256) {
        return setA._indexes[a];
    }
}

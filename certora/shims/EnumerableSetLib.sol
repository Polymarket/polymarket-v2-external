// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

// VERIFICATION SHIM for Solady's EnumerableSetLib — an assembly-free re-implementation of the same
// ADT, substituted at build time by a FILE-GRANULAR remapping in the aggregator confs' `packages`
// list, mapping the solady path for this one file to this one file. `src/` is never touched, and only
// the confs that opt in ever see it.
//
// WHY. Solady's real implementation is opaque to the Prover. `struct AddressSet { uint256 _spacer; }`
// is a decoy: the data lives at keccak256(set.slot, 0x978aab92), plus rootSlot+1, rootSlot+2,
// not(rootSlot) for a lazy length, and a keccak256(value, rootSlot) position map — across two
// representations (up to 3 elements packed inline in the top 160 bits of three consecutive slots,
// switching to the position map at the 4th). Storage analysis, storage splitting, memory partitioning
// AND hashing-correctness analysis all fail on every operation, so the Prover cannot link a slot write
// to a later slot read.
//
// Measured, not assumed:
//   * job 21c758ad — the ADT laws against the real library in a ONE-CONTRACT scene, no summaries, no
//     ghosts: all five FAIL, including "an added element is a member";
//   * jobs 62e4ae73 / 3525e6ae / f8be92fb — identical failures with the optimizer off, with solc
//     passes re-enabled, and with optimistic_hashing off, so it is not a compile-settings artifact;
//   * job 46c1fd07 — the same in behavioural-equivalence form against a CVL model: add's return value,
//     membership, frame AND cardinality all Violated. Only remove's return value verifies, because it
//     is a pure read of the pre-state — which is also why the aggregator's ACC-03/ACC-04 pass, since
//     they use `contains` as an opaque pre-state predicate and never link a write to a read.
//
// WHY NOT A CVL GHOST MODEL. That was tried first and it works: job 74de9a54 flips all five ADT laws
// from FAIL to PASS by summarizing the library's internal functions with ghosts, and storage-pointer
// parameters in wildcard summaries are supported (they just may not declare return types). It was
// rejected for the aggregator for one reason: the summary can BIND the `AddressSet storage` pointer but
// cannot use it as a ghost key ("Cannot convert EnumerableSetLib.AddressSet to uint256"), and its only
// field `_spacer` is always zero, so it carries no identity. Every set instance would collapse into one
// ghost — answering reporter-membership questions with disputer state, silently voiding ACC-03/ACC-04.
// In Solidity the compiler keys the sets for us, so this shim keeps them distinct by construction.
//
// DIVERGENCES from Solady, both deliberate, both outside the aggregator's use:
//   1. Solady stores address(0) as a sentinel and REVERTS ValueIsZeroSentinel if you pass the literal
//      0xfbb67fda52d4bfb8bf. Here address(0) is an ordinary member, and so is that literal. The
//      aggregator never registers either as a module.
//   2. Storage layout: two fields instead of one `_spacer`. Harmless for the verification build (no
//      storage-layout baseline applies to it) but it is why this shim must never reach `src/`.
//
// RESIDUAL ASSUMPTION: that Solady satisfies the same ADT laws this shim is proved to satisfy. The laws
// themselves are proved AND mutation-tested over this file (certora/specs/oracle/EnumerableSetShim.spec;
// mutation M14 drops the swap-and-pop and kills `setAIsWellFormed`). The conformance step is what is
// assumed, and it is the one obligation in this family Certora cannot discharge — the same analysis
// failure that forces this shim also makes any equivalence proof against the real library underivable.
// It belongs in Foundry, as a differential test against Solady over random op sequences plus a
// bounded-exhaustive pass across the 4th-element representation switch. NOT YET WRITTEN.

/// @notice Assembly-free stand-in for Solady's `EnumerableSetLib`, for verification builds only.
/// @dev See the file header for why it exists, what it diverges on, and what it assumes.
library EnumerableSetLib {
    /// @dev Thrown when an index is out of bounds. Same name and shape as Solady's.
    error IndexOutOfBounds();

    /// @dev Declared for signature compatibility; unreachable in this shim (see divergence 1).
    error ValueIsZeroSentinel();

    /// @dev An enumerable address set, stored as an insertion-order array plus a 1-based index map.
    struct AddressSet {
        address[] _elements;
        mapping(address => uint256) _indexes;
    }

    /// @dev Returns the number of elements in the set.
    function length(AddressSet storage set) internal view returns (uint256) {
        return set._elements.length;
    }

    /// @dev Returns whether `value` is in the set.
    function contains(AddressSet storage set, address value) internal view returns (bool) {
        return set._indexes[value] != 0;
    }

    /// @dev Adds `value`. Returns whether `value` was NOT already in the set.
    function add(AddressSet storage set, address value) internal returns (bool) {
        if (set._indexes[value] != 0) return false;
        set._elements.push(value);
        set._indexes[value] = set._elements.length;
        return true;
    }

    /// @dev Removes `value`. Returns whether `value` WAS in the set.
    ///      Swap-and-pop, matching Solady's observable enumeration order.
    function remove(AddressSet storage set, address value) internal returns (bool) {
        uint256 position = set._indexes[value];
        if (position == 0) return false;

        uint256 lastIndex = set._elements.length - 1;
        if (position - 1 != lastIndex) {
            address moved = set._elements[lastIndex];
            set._elements[position - 1] = moved;
            set._indexes[moved] = position;
        }
        set._elements.pop();
        delete set._indexes[value];
        return true;
    }

    /// @dev Returns the element at index `i`, reverting when out of range.
    function at(AddressSet storage set, uint256 i) internal view returns (address) {
        if (i >= set._elements.length) revert IndexOutOfBounds();
        return set._elements[i];
    }

    /// @dev Returns all elements, in enumeration order.
    function values(AddressSet storage set) internal view returns (address[] memory) {
        return set._elements;
    }
}

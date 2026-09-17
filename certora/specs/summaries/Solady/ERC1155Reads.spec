// ============================================================
// ERC1155Reads.spec — opt-in balance-read summaries for the Solady ERC1155
// ghost model
//
// balanceOf / balanceOfBatch summaries are kept OUT of ERC1155.spec so that
// each scene can choose how balance reads behave:
//   * import this file -> reads answer from the ghost model (ghostBalance),
//     consistent with the ghost-modeled writes. Currently no scene imports
//     this — available for future specs that need ghost-modeled reads.
//   * omit it          -> reads execute Solady's native assembly against real
//     storage. Used by certora/specs/solvency/PositionManager.spec, whose
//     mint/burn integrity rules call the native balanceOf to observe the
//     real storage written by the concretely-executed mint/burn bodies.
//
// The balanceOfCVL / balanceOfBatchCVL helper bodies live in ERC1155.spec.
// ============================================================

import "ERC1155.spec";

methods {
    function _.balanceOf(address owner, uint256 id) internal =>
        balanceOfCVL(owner, id) expect uint256;
    // balanceOfBatch: unrolled read for up to 3 elements; result[i] is constrained
    // to ghostBalance[owners[i]][ids[i]] via require inside the CVL function.
    function _.balanceOfBatch(address[] calldata owners, uint256[] calldata ids) internal =>
        balanceOfBatchCVL(owners, ids) expect uint256[] memory;
}

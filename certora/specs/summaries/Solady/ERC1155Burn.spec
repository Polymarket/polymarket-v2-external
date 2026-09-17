// ============================================================
// ERC1155Burn.spec — opt-in burn summaries for the Solady ERC1155 ghost model
//
// _burn / _batchBurn summaries are kept OUT of ERC1155.spec so that each scene
// can choose how burn paths behave:
//   * import this file -> burn paths are ghost-modeled (ghostBalance/ghostSupply
//     move; Solady's assembly never runs). Currently no scene imports this —
//     available for future specs that need ghost-modeled burn paths.
//   * omit it          -> burn paths execute Solady's real assembly against real
//     storage, like PositionManager's external mint/transfer assembly. Used by
//     certora/specs/solvency/PositionManager.spec so that burn integrity is
//     proven on the real code (read back via the native balanceOf, whose
//     ghost summary is likewise opt-in — see ERC1155Reads.spec).
//
// The burnByCVL / batchBurnByCVL helper bodies live in ERC1155.spec.
// ============================================================

import "ERC1155.spec";

methods {
    // 4-arg _burn is the assembly-heavy version; the 3-arg wrapper delegates to it,
    // so summarizing only this one is sufficient.
    function _._burn(address by, address from, uint256 id, uint256 amount) internal =>
        burnByCVL(by, from, id, amount) expect void;
    // 4-arg _batchBurn is internal — arrays are memory.
    function _._batchBurn(address by, address from, uint256[] memory ids, uint256[] memory amounts) internal =>
        batchBurnByCVL(by, from, ids, amounts) expect void;
}

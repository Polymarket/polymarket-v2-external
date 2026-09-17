// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ConditionId, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";

/// @dev Certora scene stub. The Exchange calls the PositionManager and the modules
/// through external calls whose selectors must be known to the Prover for the
/// wildcard (`_.`) summaries in solvencyExchange.spec to bind. With the real
/// contracts out of scene those selectors are unresolved, so the calls AUTO-havoc:
/// they skip the merge credit and scramble the balance ghost. This stub registers
/// exactly those selectors. Bodies are never executed (every call is summarized);
/// it contains no Solady assembly, so it avoids the pointer-analysis crash the real
/// PositionManager / BinaryModule / CollateralToken trigger.
contract SceneStub {
    mapping(uint256 => address) public moduleById;

    function unsafeTransferFrom(address from, address to, PositionId id, uint256 amount) external { }

    function split(address[] calldata _to, ConditionId _conditionId, uint256 _amount) external { }

    function merge(address _to, ConditionId _conditionId, uint256 _amount) external { }

    function prepareCondition(PositionId[] calldata _legs) external returns (ConditionId conditionId) { }
}

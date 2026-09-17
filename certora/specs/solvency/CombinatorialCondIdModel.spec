methods {
    function CombinatorialModule.getConditionId(CombinatorialModule.PositionId[] memory _legs) internal
        returns (CombinatorialModule.ConditionId) => getCondIdCVL(_legs);
}

// Uninterpreted (length, leg0, leg1) -> ConditionId. Collisions between distinct
// arguments are permitted; equal arguments always give the same id.
ghost condIdGhost(uint256, uint256, uint256) returns CombinatorialModule.ConditionId;

// Summary for getConditionId. It computes nondeterministic fixed condition ids based 
// its input legs, allowing for collisions. It has been introduced to extend coverage
// and remove the Prover's hashing injectivity property.
function getCondIdCVL(CombinatorialModule.PositionId[] _legs) returns CombinatorialModule.ConditionId {
    uint256 n = _legs.length;
    uint256 a = 0;
    uint256 b = 0;
    if (n > 0) { a = _legs[0]; }
    if (n > 1) { b = _legs[1]; }
    return condIdGhost(n, a, b);
}

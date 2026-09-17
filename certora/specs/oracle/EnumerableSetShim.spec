

methods {
    function addToA(address) external returns (bool);
    function removeFromA(address) external returns (bool);
    function addToB(address) external returns (bool);
    function removeFromB(address) external returns (bool);
    function containsInA(address) external returns (bool) envfree;
    function containsInB(address) external returns (bool) envfree;
    function lengthOfA() external returns (uint256) envfree;
    function lengthOfB() external returns (uint256) envfree;
    function elementOfAAtOneBased(uint256) external returns (address) envfree;
    function rawIndexInA(address) external returns (uint256) envfree;
}

/*--------------------------------------------------------------
                REACHABILITY: LENGTH NEVER SATURATES
--------------------------------------------------------------*/

/// @dev It has to be excluded because `push` onto a `2^256-1`-length array wraps the
///      1-based index back to zero, which would make `contains` report false for an element just added.
function requireLengthNotSaturated() {
    require lengthOfA() < max_uint256 && lengthOfB() < max_uint256,
        "unreachable state: a set holding 2^256-1 distinct addresses";
}

/*--------------------------------------------------------------
                REPRESENTATION WELL-FORMEDNESS
--------------------------------------------------------------*/

/**
 * @title the shim is well-formed
 * @description The shim's backing array and its index map agree in both directions.
 */
invariant setAIsWellFormed(address a, uint256 i)
    (containsInA(a)
        <=> (rawIndexInA(a) >= 1 && rawIndexInA(a) <= lengthOfA()
            && elementOfAAtOneBased(rawIndexInA(a)) == a))
    && ((i >= 1 && i <= lengthOfA()) => rawIndexInA(elementOfAAtOneBased(i)) == i)
    filtered { f -> !f.isView }
    {
        preserved with (env e) {
            requireLengthNotSaturated();
        }
        preserved addToA(address x) with (env e) {
            requireLengthNotSaturated();
            requireInvariant setAIsWellFormed(x, i);
            requireInvariant setAIsWellFormed(x, rawIndexInA(x));
        }
        preserved removeFromA(address x) with (env e) {
            requireLengthNotSaturated();
            // x's own slot: which index is being vacated.
            requireInvariant setAIsWellFormed(x, rawIndexInA(x));
            // The last slot: which element gets moved, and what index it currently records.
            requireInvariant setAIsWellFormed(a, lengthOfA());
            requireInvariant setAIsWellFormed(elementOfAAtOneBased(lengthOfA()), lengthOfA());
            requireInvariant setAIsWellFormed(elementOfAAtOneBased(lengthOfA()), rawIndexInA(x));
        }
    }

/**
 * @title enumeration has no duplicates
 * @description No element appears twice in the enumeration of a set.
 */
rule enumerationHasNoDuplicates(uint256 i, uint256 j) {
    requireLengthNotSaturated();
    requireInvariant setAIsWellFormed(elementOfAAtOneBased(i), i);
    requireInvariant setAIsWellFormed(elementOfAAtOneBased(j), j);
    require i >= 1 && i <= lengthOfA();
    require j >= 1 && j <= lengthOfA();
    require i != j;

    assert elementOfAAtOneBased(i) != elementOfAAtOneBased(j),
        "distinct slots hold distinct elements";
}

/*--------------------------------------------------------------
                    ADT LAWS — add
--------------------------------------------------------------*/

/**
 * @title add behaviour
 * @description add returns whether the element was new, makes it a member, leaves other elements alone, and moves cardinality accordingly.
 */
rule addBehaviour(env e, address a, address other) {
    requireLengthNotSaturated();
    requireInvariant setAIsWellFormed(a, rawIndexInA(a));
    requireInvariant setAIsWellFormed(other, rawIndexInA(other));
    require other != a;

    bool memberBefore = containsInA(a);
    bool otherBefore = containsInA(other);
    uint256 lengthBefore = lengthOfA();

    bool added = addToA(e, a);

    assert added == !memberBefore, "add reports whether the element was absent";
    assert containsInA(a), "the element is a member afterwards, either way";
    assert containsInA(other) == otherBefore, "frame: no other element's membership changes";
    assert to_mathint(lengthOfA()) == (added ? to_mathint(lengthBefore) + 1 : to_mathint(lengthBefore)),
        "the length grows by one exactly when it added";
}

/*--------------------------------------------------------------
                    ADT LAWS — remove
--------------------------------------------------------------*/

/**
 * @title remove behaviour
 * @description remove returns whether the element was present, ends its membership, leaves other elements alone, and moves cardinality accordingly.
 */
rule removeBehaviour(env e, address a, address other) {
    requireLengthNotSaturated();
    requireInvariant setAIsWellFormed(a, rawIndexInA(a));
    requireInvariant setAIsWellFormed(other, rawIndexInA(other));
    requireInvariant setAIsWellFormed(elementOfAAtOneBased(lengthOfA()), lengthOfA());
    require other != a;

    bool memberBefore = containsInA(a);
    bool otherBefore = containsInA(other);
    uint256 lengthBefore = lengthOfA();

    bool removed = removeFromA(e, a);

    assert removed == memberBefore, "remove reports whether the element was present";
    assert !containsInA(a), "the element is not a member afterwards, either way";
    assert containsInA(other) == otherBefore, "frame: no other element's membership changes";
    assert to_mathint(lengthOfA())
        == (removed ? to_mathint(lengthBefore) - 1 : to_mathint(lengthBefore)),
        "the length shrinks by one exactly when it removed";
}

/*--------------------------------------------------------------
            THE TWO SETS ARE INDEPENDENT
--------------------------------------------------------------*/

/**
 * @title add does not leak across sets
 * @description Adding to one set never touches another set.
 */
rule addToOneSetLeavesTheOtherAlone(env e, address a) {
    requireLengthNotSaturated();

    bool inBBefore = containsInB(a);
    uint256 lengthBBefore = lengthOfB();

    addToA(e, a);

    assert containsInA(a), "the element joins A";
    assert containsInB(a) == inBBefore, "and does not join B";
    assert lengthOfB() == lengthBBefore, "B's cardinality is untouched";
}

/**
 * @title remove does not leak across sets
 * @description Removing from one set never touches another set.
 */
rule removeFromOneSetLeavesTheOtherAlone(env e, address a) {
    requireLengthNotSaturated();
    requireInvariant setAIsWellFormed(a, rawIndexInA(a));

    bool inBBefore = containsInB(a);
    uint256 lengthBBefore = lengthOfB();

    removeFromA(e, a);

    assert !containsInA(a), "the element leaves A";
    assert containsInB(a) == inBBefore, "and its B membership is unchanged";
    assert lengthOfB() == lengthBBefore, "B's cardinality is untouched";
}

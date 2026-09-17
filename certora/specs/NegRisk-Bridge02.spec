/* =============================================================================
 * BRIDGE-02 — mintFromBridge / burnFromBridge functional correctness
 * Contract under verification: NegRiskModule (via NegRiskModuleHarness)
 *
 * The rules live in the shared bridge02BaseModule.spec (mint/burnFromBridge are in BaseModule and not overridden)
 * This file only carries NegRisk Module scene wiring: harness/collateral using immutable summaries,
 * and the legacy/migration NONDET firewall keeping the scene free of legacy-CTF PTA blowup.
 * ============================================================================= */

/*
 * MODULE
 * @module NegRiskModule Bridge Authorization
 * @contract NegRiskModule
 * @impact An unauthorized caller could mint or burn positions, forging value out of nothing
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 5 iterations
 * @global_assumption PositionManager mint, burn and transfer are replaced by an equivalent CVL model
 * PROPERTIES
 * @property NEGRISK-BRIDGE-02 NegRiskModule mintFromBridge and burnFromBridge are bridge-role-only and move exactly the tuple they are given.
 */


import "bridge02BaseModule.spec";

using NegRiskModuleHarness as NegRiskModule;
using DummyERC20Impl as CollateralToken;
using ConditionalTokens as ConditionalTokens;

methods {
    /* ---- module immutable wiring (mirrors solvencyNegRisk: NOT linked) ---- */
    function _.POSITION_MANAGER() external => PositionManager expect address;
    function _.COLLATERAL_TOKEN() external => CollateralToken expect address;
    function _.CONDITIONAL_TOKENS() external => ConditionalTokens expect address;

    /* ---- legacy/migration subtree: unreached by mint/burnFromBridge; NONDET keeps
            the scene free of the legacy-CTF pointer-analysis blowup ---- */
    function _._resolveMigrationCondition(NegRiskModule.ConditionId) internal => NONDET;
    function _._redeemLegacyPositions(bytes32) internal => NONDET;
    function _._settleLegacyCollateralToVault() internal => NONDET;
    function CTHelpers.getCollectionId(bytes32, bytes32, uint256) internal returns (bytes32) => NONDET;
    function _.redeemPositions(address, bytes32, bytes32, uint256[]) external => NONDET;
    function _.mergePositions(address, bytes32, bytes32, uint256[], uint256) external => NONDET;
    function _.NEG_RISK_ADAPTER() external => NONDET;
    function _.getQuestionCount(bytes32) external => NONDET;
    function _.unwrap(address, uint256) external => NONDET;
    function _.wcol() external => NONDET;
}

/**
 * @title bridge mint requires the bridge role
 * @description Only an address holding the bridge role can mint; without it the call reverts.
 * @link_property NEGRISK-BRIDGE-02
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/8c27629322974909aa8b621dab3cf3b2?anonymousKey=3d87cddfe0cb0c1af7f68b16f963807e193448f1
 */
use rule mintFromBridgeOnlyBridge;
/**
 * @title bridge mint credits the recipient
 * @description A successful bridge mint credits exactly the requested amount to the recipient and raises supply by the same.
 * @link_property NEGRISK-BRIDGE-02
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/8c27629322974909aa8b621dab3cf3b2?anonymousKey=3d87cddfe0cb0c1af7f68b16f963807e193448f1
 */
use rule mintFromBridgeCreditsRecipient;
/**
 * @title bridge mint touches no other balance
 * @description A bridge mint touches no balance other than the credited one.
 * @link_property NEGRISK-BRIDGE-02
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/8c27629322974909aa8b621dab3cf3b2?anonymousKey=3d87cddfe0cb0c1af7f68b16f963807e193448f1
 */
use rule mintFromBridgeNoOtherBalanceChange;
/**
 * @title bridge burn requires the bridge role
 * @description Only an address holding the bridge role can burn; without it the call reverts.
 * @link_property NEGRISK-BRIDGE-02
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/8c27629322974909aa8b621dab3cf3b2?anonymousKey=3d87cddfe0cb0c1af7f68b16f963807e193448f1
 */
use rule burnFromBridgeOnlyBridge;
/**
 * @title bridge burn debits the module
 * @description A successful bridge burn debits the module by exactly the total targeting each id and lowers supply by the same.
 * @link_property NEGRISK-BRIDGE-02
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/8c27629322974909aa8b621dab3cf3b2?anonymousKey=3d87cddfe0cb0c1af7f68b16f963807e193448f1
 */
use rule burnFromBridgeDebitsModule;
/**
 * @title bridge burn touches no other holder
 * @description A bridge burn only ever debits the module; no other holder is touched.
 * @link_property NEGRISK-BRIDGE-02
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/8c27629322974909aa8b621dab3cf3b2?anonymousKey=3d87cddfe0cb0c1af7f68b16f963807e193448f1
 */
use rule burnFromBridgeNoOtherAddressChange;

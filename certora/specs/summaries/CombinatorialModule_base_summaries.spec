// Alias-free by convention: the `using` declarations for this scene live in
// CombinatorialModule_solvency_call_resolution.spec (one owner per scene); this file only
// references the aliases.
//
// Combinatorial-specific summaries. The shared address-getter wildcards
// (_.POSITION_MANAGER / _.COLLATERAL_TOKEN / _.CONDITIONAL_TOKENS / _.USDCE /
// _._legacyConditionalTokens) and the NegRisk participant links are provided by the
// imported NegRiskModule_base_summaries.spec, so they are intentionally NOT redeclared
// here (CVL rejects duplicate summaries across an import closure).
methods {
    function CombinatorialModule.moduleId() external returns uint256 => 3; // 3 == ModuleIds.COMBINATORIAL
}

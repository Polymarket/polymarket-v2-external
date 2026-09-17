// Alias-free by convention: the `using` declarations for this scene live in
// NegRiskModule_call_resolution.spec (one owner per scene); this file only
// references the aliases.
methods {
    function NegRiskModule.moduleId() external returns uint256 => 2; // 2 == ModuleIds.NEGRISK
    function _.POSITION_MANAGER() external => PositionManager expect address;
    function _.COLLATERAL_TOKEN() external => CollateralToken expect address;
    function _.CONDITIONAL_TOKENS() external => ConditionalTokens expect address;
    function _.USDCE() external => USDCe expect address;
    function _._legacyConditionalTokens() external => ConditionalTokens expect address;

    // NegRisk-specific: the legacy NegRiskAdapter is out of scene.
    function _.NEG_RISK_ADAPTER() external => NONDET;          // _authorizeUpgrade probe
    function _.getQuestionCount(bytes32) external => NONDET;   // prepareMigrationEvent
    function _.unwrap(address, uint256) external => NONDET;    // wcol settlement to vault

}

links {
    NegRiskModule.COLLATERAL_TOKEN => CollateralToken;
    NegRiskModule.POSITION_MANAGER => PositionManager;
    NegRiskModule.CONDITIONAL_TOKENS => ConditionalTokens;
    NegRiskModule.WRAPPED_COLLATERAL_TOKEN => Wcol;
}

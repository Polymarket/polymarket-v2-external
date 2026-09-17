methods {
    function BinaryModule.moduleId() external returns uint256 => 1; // 1 == ModuleIds.BINARY
    function _.POSITION_MANAGER() external => PositionManager expect address;
    function _.COLLATERAL_TOKEN() external => CollateralToken expect address;
    function _.CONDITIONAL_TOKENS() external => ConditionalTokens expect address;
    function _.USDCE() external => USDCe expect address;
    // function _._legacyConditionalTokens() internal => ConditionalTokens expect address;
    function _._legacyConditionalTokens() external => ConditionalTokens expect address;

}

links {
    BinaryModule.COLLATERAL_TOKEN => CollateralToken;
    BinaryModule.POSITION_MANAGER => PositionManager;
    BinaryModule.CONDITIONAL_TOKENS => ConditionalTokens;
}

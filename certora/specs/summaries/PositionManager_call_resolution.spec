// Scene file for the PositionManager verification scenes
// (certora/confs/PositionManager.conf and the certora/confs/solvency/
// PositionManager / BinaryModule* confs).
// Owns the `using` alias declarations for every contract in the scene's `files` list.
// Convention: aliases are declared EXACTLY ONCE per scene, in its call-resolution
// file; shared summary files and top-level specs only reference them.
using PositionManager as PositionManager;
using BinaryModule as BinaryModule;
using NegRiskModule as NegRiskModule;
using CombinatorialModule as CombinatorialModule;
using CollateralToken as CollateralToken;

links {
    PositionManager.moduleById[_] => [BinaryModule, CombinatorialModule, NegRiskModule];
    PositionManager.COLLATERAL_TOKEN => CollateralToken;

    CombinatorialModule.POSITION_MANAGER => PositionManager;
}

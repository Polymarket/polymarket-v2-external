# Polymarket V2 Oracle Subsystem

The modular oracle that resolves Polymarket V2 prediction markets. A single upgradeable
**OracleAggregator** coordinates pluggable **reporter**, **disputer**, and **arbitrator** modules and
delivers final results to the position modules (BinaryModule, NegRiskModule) that hold the markets.
Built with Foundry and Solady.

This repository is a snapshot of the oracle subsystem from
[`Polymarket/polymarket-v2`](https://github.com/Polymarket/polymarket-v2) at release
[`v1.2.0`](https://github.com/Polymarket/polymarket-v2/releases/tag/v1.2.0). It contains `src/oracle/`
in full, plus the minimum set of positions-stack contracts the oracle compiles and tests against.

## Architecture

```
                    ┌─────────────────────┐
                    │  OracleAggregator   │
                    │  (singleton, UUPS)  │
                    └────┬───────┬───────┬┘
                         │       │       │
              ┌──────────┘       │       └──────────┐
              ▼                  ▼                   ▼
     ReporterModules      DisputerModules     ArbitratorModule
     ─────────────        ──────────────      ────────────────
     EOAReporterModule                        Independent module
     ChainlinkReporterModule
     OOReporterModule
                                  │
                                  ▼
                          Target Contract
                     (BinaryModule / NegRiskModule)
```

- **OracleAggregator** — central request registry and resolution state machine. Requests are registered
  via `initializeRequest`, with targets validated against the `PositionManager` module registry, and
  resolved through reporter-vote or arbitrator-finalization flows.
- **OOReporterModule** — UMA managed OOReporter result reporter and finalizer.
- **EOAReporterModule** / **ChainlinkReporterModule** — signer-based and Chainlink feed reporters.
- **OracleModuleBase** — shared base for reporter, disputer, and arbitrator modules.
- **MarketDataRegistry** — product specs and per-request rules (ERC-7201 namespaced storage).

See [`src/oracle/README.md`](src/oracle/README.md) for the full architecture guide,
[`src/oracle/GLOSSARY.md`](src/oracle/GLOSSARY.md) for canonical terminology, and
[`src/oracle/modules/README.md`](src/oracle/modules/README.md) for the OOReporterModule.

## Repository Layout

```
src/
├── oracle/               # The oracle subsystem (aggregator, modules, mixins, interfaces, tests)
├── modules/              # BinaryModule, NegRiskModule, CombinatorialModule — resolution targets
├── positionManager/      # ERC1155 position token; module registry the aggregator validates against
├── collateral/           # CollateralToken and ramps (dependency of PositionManager)
├── auth/, libraries/     # Roles, position ID encoding (Ids.sol), module IDs
├── legacy/, external/    # Legacy CTF interfaces and the UMA OOReporter mock used in tests
└── dev/, mocks/, test/   # Test helpers, mocks, and storage slot tests
docs/                     # System documentation for the contracts in this tree
audit/                    # Oracle subsystem audit reports
.storage-layouts/         # Storage layout baselines for the upgradeable contracts
```

Contracts outside `src/oracle/` are included as dependencies so the oracle test suite exercises real
resolution targets. They are developed, tested, and released from the upstream repository.

## Usage

```shell
git submodule update --init --recursive   # forge-std, solady, UMA managed-oracle
forge build        # compile
forge test         # run tests
forge fmt          # format
forge snapshot     # gas snapshots
make setup         # install git hooks (pre-commit: fmt + snapshot)
```

CI runs `forge fmt --check`, `forge build`, `make wrap-check`, `make sizes`, `forge test`, the gas
snapshot diff, `make coverage` (90% line / 80% branch on `src/oracle/`), and `make storage-check`.

## Documentation

- [Oracle](docs/oracle.md) — OracleAggregator, modular resolution system
- [Modules](docs/modules.md) — BinaryModule, NegRiskModule, CombinatorialModule, resolution roles
- [Position IDs](docs/position-ids.md) — structured ID schema and the `Ids.sol` API
- [Position Manager](docs/position-manager.md) — ERC1155 contract and module registration
- [Collateral](docs/collateral.md) — CollateralToken, onramp, offramp, PermissionedRamp
- [Auth](docs/auth.md) — roles, access control, role assignment
- [Migration](docs/migration.md) — legacy CTF/NegRiskAdapter position migration

## Audits

- [Oracle Subsystem — Cantina — July 2026](<audit/Oracle Subsystem - Cantina - July 2026.pdf>)
- [Oracle Subsystem — Certora — July 2026](<audit/Oracle Subsystem - Certora - July 2026.pdf>)

## License

[BUSL-1.1](LICENSE.md). Files under `src/legacy/` and `src/external/` keep their original licenses.

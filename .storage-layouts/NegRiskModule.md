| Name                         | Type                              | Slot | Offset | Bytes | Contract                                    |
| resolverPausedAt             | mapping(address => uint256)       | 0    | 0      | 32    | src/modules/NegRiskModule.sol:NegRiskModule |
| resolutionPausedAt           | mapping(EventId => uint256)       | 1    | 0      | 32    | src/modules/NegRiskModule.sol:NegRiskModule |
| __gap                        | uint256[48]                       | 2    | 0      | 1536  | src/modules/NegRiskModule.sol:NegRiskModule |
| result                       | mapping(ConditionId => uint256[]) | 50   | 0      | 32    | src/modules/NegRiskModule.sol:NegRiskModule |
| __gap                        | uint256[49]                       | 51   | 0      | 1568  | src/modules/NegRiskModule.sol:NegRiskModule |
| __gap                        | uint256[50]                       | 100  | 0      | 1600  | src/modules/NegRiskModule.sol:NegRiskModule |
| legacyEventId                | mapping(EventId => bytes32)       | 150  | 0      | 32    | src/modules/NegRiskModule.sol:NegRiskModule |
| legacyConditionToConditionId | mapping(bytes32 => ConditionId)   | 151  | 0      | 32    | src/modules/NegRiskModule.sol:NegRiskModule |
| __gap                        | uint256[48]                       | 152  | 0      | 1536  | src/modules/NegRiskModule.sol:NegRiskModule |
| resultsSum                   | mapping(EventId => uint256)       | 200  | 0      | 32    | src/modules/NegRiskModule.sol:NegRiskModule |
| conditionsResolved           | mapping(EventId => uint256)       | 201  | 0      | 32    | src/modules/NegRiskModule.sol:NegRiskModule |

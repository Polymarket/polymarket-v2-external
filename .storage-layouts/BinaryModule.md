| Name               | Type                              | Slot | Offset | Bytes | Contract                                  |
| resolverPausedAt   | mapping(address => uint256)       | 0    | 0      | 32    | src/modules/BinaryModule.sol:BinaryModule |
| resolutionPausedAt | mapping(EventId => uint256)       | 1    | 0      | 32    | src/modules/BinaryModule.sol:BinaryModule |
| __gap              | uint256[48]                       | 2    | 0      | 1536  | src/modules/BinaryModule.sol:BinaryModule |
| result             | mapping(ConditionId => uint256[]) | 50   | 0      | 32    | src/modules/BinaryModule.sol:BinaryModule |
| __gap              | uint256[49]                       | 51   | 0      | 1568  | src/modules/BinaryModule.sol:BinaryModule |
| __gap              | uint256[50]                       | 100  | 0      | 1600  | src/modules/BinaryModule.sol:BinaryModule |
| legacyConditionId  | mapping(ConditionId => bytes32)   | 150  | 0      | 32    | src/modules/BinaryModule.sol:BinaryModule |
| __gap              | uint256[49]                       | 151  | 0      | 1568  | src/modules/BinaryModule.sol:BinaryModule |

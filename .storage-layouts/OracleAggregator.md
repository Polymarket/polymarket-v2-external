| Name                  | Type                                                        | Slot | Offset | Bytes | Contract                                         |
| globalPaused          | bool                                                        | 0    | 0      | 1     | src/oracle/OracleAggregator.sol:OracleAggregator |
| __gap                 | uint256[49]                                                 | 1    | 0      | 1568  | src/oracle/OracleAggregator.sol:OracleAggregator |
| requestConfigs        | mapping(EventId => struct OracleAggregator.RequestConfig)   | 50   | 0      | 32    | src/oracle/OracleAggregator.sol:OracleAggregator |
| resolutionStates      | mapping(bytes32 => struct OracleAggregator.ResolutionState) | 51   | 0      | 32    | src/oracle/OracleAggregator.sol:OracleAggregator |
| _reporterModules      | mapping(EventId => struct EnumerableSetLib.AddressSet)      | 52   | 0      | 32    | src/oracle/OracleAggregator.sol:OracleAggregator |
| _disputerModules      | mapping(EventId => struct EnumerableSetLib.AddressSet)      | 53   | 0      | 32    | src/oracle/OracleAggregator.sol:OracleAggregator |
| voteCount             | mapping(bytes32 => uint256)                                 | 54   | 0      | 32    | src/oracle/OracleAggregator.sol:OracleAggregator |
| hasReporterVoted      | mapping(bytes32 => mapping(address => bool))                | 55   | 0      | 32    | src/oracle/OracleAggregator.sol:OracleAggregator |
| marketPaused          | mapping(EventId => bool)                                    | 56   | 0      | 32    | src/oracle/OracleAggregator.sol:OracleAggregator |
| hasDisputerVoted      | mapping(bytes32 => mapping(address => bool))                | 57   | 0      | 32    | src/oracle/OracleAggregator.sol:OracleAggregator |
| conflictingResultHash | mapping(bytes32 => bytes32)                                 | 58   | 0      | 32    | src/oracle/OracleAggregator.sol:OracleAggregator |

#!/bin/bash
# Launch every conf in the oracle directory as its own cloud job.
#
# OOReporterModule family (OO-*), verify target OOReporterModule:
#   - OOReporterPure.conf          (OO-PRICE-01, OO-PAYOUT-01)
#   - OOReporterRelay.conf         (OO-RELAY-01, OO-ATOMIC-01)
#   - OOReporterRegistration.conf  (OO-REG-01)
#   - OOReporterAccess.conf        (OO-ACCESS-01, OO-INIT-MONO-01, OO-CUSTODY-01)
#
# OracleAggregator family, verify target OracleAggregator:
#   - AggregatorAccess.conf        (ACC-01 .. ACC-07)
#   - AggregatorLifecycle.conf     (ORACLE-LIFE-01/02, ORACLE-RES-01, ORACLE-TGT-02)
#   - AggregatorVotes.conf         (ORACLE-THRESH-01, ORACLE-VOTE-01/02, ORACLE-DISP-01)
#   - AggregatorWindows.conf       (ORACLE-WIND-01/02)
#   - AggregatorResolution.conf    (ORACLE-TGT-01, ORACLE-FIN-01, ORACLE-ARB-01)
#   - AggregatorConfig.conf        (ORACLE-CONF-01/02)
#
# Supporting obligation, verify target EnumerableSetShimHarness:
#   - EnumerableSetShim.conf       (the set ADT laws the four shimmed aggregator confs rest on)
#
# Each conf carries its own "msg" tag; jobs are fire-and-forget
# (wait_for_results: none). Run from the repo root with the Certora CLI
# available (e.g. `source .venv/bin/activate`).
set -u

CONFS=(certora/confs/oracle/*.conf)

for conf in "${CONFS[@]}"; do
    echo "[*] $conf"
    certoraRun "$conf" --server production
done

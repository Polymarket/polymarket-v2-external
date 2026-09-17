#!/bin/bash
# Launch every accesscontrol-family conf as its own cloud job:
#   - PositionManager.conf                (ACCESS-PM-MINT-01 + ACCESS-PM-REGISTRY-01)
#   - Initializable_<Contract>.conf x15   (ACCESS-INIT-01)
# Each conf carries its own "msg" tag; jobs are fire-and-forget
# (wait_for_results: none). Run from the repo root with the Certora CLI
# available (e.g. `source .venv/bin/activate`).
set -u

CONFS=(certora/confs/accesscontrol/*.conf)

for conf in "${CONFS[@]}"; do
    echo "[*] $conf"
    certoraRun "$conf" --server production
done

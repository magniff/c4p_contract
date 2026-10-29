#!/usr/bin/env bash
# Symbolic proofs with Halmos (needs Python >= 3.11):
#   python3.12 -m venv .venv-halmos && .venv-halmos/bin/pip install halmos==0.3.3
#   scripts/prove.sh                      # all proofs
#   scripts/prove.sh --function check_draw  # one
# Foundry 1.x compiles `new X()` in tests to a deployCode cheatcode Halmos does not support; turn that off here.
set -euo pipefail
cd "$(dirname "$0")/.."
export FOUNDRY_DYNAMIC_TEST_LINKING=false
for c in EngineProofs ContractProofs; do
  .venv-halmos/bin/halmos --contract "$c" "$@"
done

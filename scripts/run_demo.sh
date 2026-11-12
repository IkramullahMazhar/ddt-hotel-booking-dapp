#!/usr/bin/env bash
# run_demo.sh - starts a local Ganache blockchain, runs the Python deploy/test
# script against it, then shuts Ganache down.
# Windows: run this in Git Bash.   macOS/Linux: normal terminal.
# Usage:  bash scripts/run_demo.sh

set -e
cd "$(dirname "$0")/.."

PORT=8545

echo "==> Checking tools"
command -v ganache >/dev/null 2>&1 || { echo "Ganache not found. Run: npm install -g ganache"; exit 1; }
PY=$(command -v python || command -v python3)
[ -n "$PY" ] || { echo "Python not found"; exit 1; }

echo "==> Installing Python packages"
"$PY" -m pip install -q -r requirements.txt

echo "==> Starting Ganache on port $PORT (10 test accounts, 100 ETH each)"
ganache --wallet.deterministic --server.port "$PORT" > ganache.log 2>&1 &
GANACHE_PID=$!
trap 'echo "==> Stopping Ganache"; kill $GANACHE_PID 2>/dev/null' EXIT

# wait until Ganache is ready
for i in $(seq 1 30); do
  grep -q "RPC Listening" ganache.log 2>/dev/null && break
  sleep 1
done

echo "==> Running deploy_and_test.py"
"$PY" scripts/deploy_and_test.py

#!/usr/bin/env bash
set -euo pipefail

# SQLodin Bootstrap Build Script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

mkdir -p bin
echo "==> Building SQLodin CLI (bin/sqlodin)..."
odin build cli -out:bin/sqlodin -o:speed

echo "==> CLI built successfully."
echo "You can now run:"
echo "  ./bin/sqlodin build all"
echo "  ./bin/sqlodin test"
echo "  ./bin/sqlodin check"
echo "  ./bin/sqlodin sim --seed=42"
echo "  ./bin/sqlodin bench"
echo "  ./bin/sqlodin docs all"

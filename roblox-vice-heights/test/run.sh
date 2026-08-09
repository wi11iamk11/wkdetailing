#!/usr/bin/env bash
# Bundles the game with the Roblox API mock and runs the integration smoke test.
#
# Needs a `luau` interpreter. Either put one on your PATH or point LUAU at it:
#   LUAU=/path/to/luau test/run.sh
# Build one with:
#   git clone --depth 1 https://github.com/luau-lang/luau
#   cd luau && cmake -DCMAKE_BUILD_TYPE=Release -B build . \
#     && cmake --build build --target Luau.Repl.CLI -j 8
set -euo pipefail

cd "$(dirname "$0")/.."

LUAU="${LUAU:-$(command -v luau || true)}"
if [[ -z "$LUAU" ]]; then
	echo "error: no luau interpreter found. Set LUAU=/path/to/luau (see the header of this script)." >&2
	exit 127
fi

python3 test/bundle.py
exec "$LUAU" test/build/smoke.luau

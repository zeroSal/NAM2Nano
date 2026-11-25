#!/usr/bin/env bash
# Build the offline engine test against a NeuralAmpModelerCore checkout.
#   Tools/engine_test/build.sh [path-to-NeuralAmpModelerCore] [extra compiler flags...]
# Default core path: NAM2Nano/Core/NAM/ThirdParty/NeuralAmpModelerCore (see Scripts/bootstrap.sh)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CORE="${1:-$ROOT/NAM2Nano/Core/NAM/ThirdParty/NeuralAmpModelerCore}"
shift || true
ENGINE="$ROOT/NAM2Nano/Core/NAM/Engine"
OUT="$HERE/build"
mkdir -p "$OUT"
CXX="${CXX:-c++}"
"$CXX" -std=c++20 -O2 -DNAM_SAMPLE_FLOAT -DNAM_ENABLE_A2_FAST "$@" \
  -I"$ENGINE" -I"$CORE/NAM" -I"$CORE/Dependencies/eigen" -I"$CORE/Dependencies/nlohmann" \
  "$HERE/main.cpp" "$ENGINE/NAMEngine.cpp" "$CORE"/NAM/*.cpp "$CORE"/NAM/wavenet/*.cpp \
  -lpthread -o "$OUT/${OUT_NAME:-engine_test}"
echo "built $OUT/${OUT_NAME:-engine_test}"

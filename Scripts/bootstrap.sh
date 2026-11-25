#!/usr/bin/env bash
# NAM2Nano bootstrap (macOS):
#  1. fetches NeuralAmpModelerCore (pinned) + Eigen into NAM2Nano/Core/NAM/ThirdParty
#  2. generates NAM2Nano.xcodeproj with XcodeGen (brew install xcodegen)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE_DIR="$ROOT/NAM2Nano/Core/NAM/ThirdParty/NeuralAmpModelerCore"
# Commit verified with Tools/engine_test (2026-11-10, "Fix prewarming for linear models (#352)")
NAM_CORE_COMMIT="${NAM_CORE_COMMIT:-d3189ed}"

if [ ! -d "$CORE_DIR/.git" ]; then
  echo "→ cloning NeuralAmpModelerCore"
  mkdir -p "$(dirname "$CORE_DIR")"
  git clone https://github.com/sdatkinson/NeuralAmpModelerCore.git "$CORE_DIR"
fi
echo "→ checking out NeuralAmpModelerCore @ $NAM_CORE_COMMIT"
git -C "$CORE_DIR" fetch --quiet origin
git -C "$CORE_DIR" checkout --quiet "$NAM_CORE_COMMIT"
echo "→ fetching Eigen (submodule)"
git -C "$CORE_DIR" submodule update --init --depth 1 Dependencies/eigen

if command -v xcodegen >/dev/null 2>&1; then
  echo "→ generating Xcode project"
  (cd "$ROOT" && xcodegen generate)
  echo "Done: open NAM2Nano.xcodeproj"
else
  echo "XcodeGen not found: brew install xcodegen && (cd \"$ROOT\" && xcodegen generate)"
fi

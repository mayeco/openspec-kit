#!/usr/bin/env bash
# ==============================================================================
# install.sh - Install, upgrade or verify the OpenSpec orchestration kit
# ==============================================================================
# Run it from a checkout of the release tag you want:
#   ./install.sh init <app-dir> [--tools claude,hermes,opencode]   # start an application
#   ./install.sh upgrade <app-dir> [--force]                       # move it to this release
#   ./install.sh verify <app-dir>                                  # kit files match its lock
# Requires Ruby >= 3.1, git and the openspec CLI (see MANIFEST.json, toolchain).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
case "${1:-}" in
  init|upgrade) exec ruby "$HERE/bin/openspec_kit.rb" "$@" --source "$HERE" ;;
  verify) exec ruby "$HERE/bin/openspec_kit.rb" "$@" ;;
  *) sed -n '2,9p' "$0"; exit 2 ;;
esac

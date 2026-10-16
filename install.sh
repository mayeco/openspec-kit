#!/usr/bin/env bash
# ==============================================================================
# install.sh - Install, upgrade or verify the OpenSpec orchestration kit
# ==============================================================================
# Run it from a checkout of the release tag you want:
#   ./install.sh init <app-dir> [--tools claude,hermes,opencode]   # start an application
#   ./install.sh upgrade <app-dir> [--force]                       # move it to this release
#   ./install.sh verify <app-dir>                                  # kit files match its lock
#
# init copies the kit (bin/, templates/, config/repo.template.yaml, agent skills),
# creates the files the application owns from then on (README.md, docs/README.md,
# MEMORY.md, config/*.yaml, config/agent_backlog.json), runs `openspec init` and
# writes .openspec-kit.lock. Fill the {{...}} placeholders, add repos/, commit,
# then schedule the cycle (.claude/skills/openspec-cycle/references/routine-prompt.md).
# upgrade works on a branch kit-upgrade-v<version> and commits there for review.
# Requires Ruby >= 3.1, git and the openspec CLI (see MANIFEST.json, toolchain).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
case "${1:-}" in
  init|upgrade) exec ruby "$HERE/bin/openspec_kit.rb" "$@" --source "$HERE" ;;
  verify) exec ruby "$HERE/bin/openspec_kit.rb" "$@" ;;
  *) sed -n '2,16p' "$0"; exit 2 ;;
esac

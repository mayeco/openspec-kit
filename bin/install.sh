#!/usr/bin/env bash
# ==============================================================================
# bin/install.sh - Install, upgrade or verify the OpenSpec orchestration kit
# ==============================================================================
# From a checkout of the release tag you want (it holds MANIFEST.json):
#   bin/install.sh init <app-dir> --agents hermes,opencode [--plan A --build A --cycle A]
#   bin/install.sh upgrade <app-dir> [--agents LIST --plan A --build A --cycle A] [--force]
#   bin/install.sh verify <app-dir>
# Inside an application, where it arrives with the rest of bin/, only
# `bash bin/install.sh verify` applies: kit files match .openspec-kit.lock.
#
# Agents: claude, codex, copilot, hermes, opencode. init installs the kit (bin/,
# templates/, config/repo*.template.*) and the skills of the selected agents
# only, each in its agent's own directory. It records the agents, and the one
# that runs each role (plan, build, cycle), in config/agents.yaml, which the
# scripts read. With one agent it runs every role; with more, a role not given
# as an option is asked. init also creates the files the application owns from
# then on (README.md, ROADMAP.md, MEMORY.md, config/*.yaml, config/*.json),
# runs `openspec init` for the selected agents and writes .openspec-kit.lock.
# Fill the {{...}} placeholders, add repos/, commit, then schedule the cycle and
# the visual QA session with the routine prompts that init names.
# upgrade moves the application to this release on a branch kit-upgrade-v<version>,
# or only changes its agents with --agents; it commits there for review.
# Requires Ruby >= 3.1, git and the openspec CLI (see MANIFEST.json, toolchain).
set -euo pipefail
RELEASE="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  init|upgrade)
    if [ ! -f "$RELEASE/MANIFEST.json" ]; then
      echo "install.sh: $RELEASE is not a release (no MANIFEST.json): run $1 from a checkout of the release tag" >&2
      exit 2
    fi
    exec ruby "$RELEASE/bin/openspec_kit.rb" "$@" --source "$RELEASE" ;;
  verify) exec ruby "$RELEASE/bin/openspec_kit.rb" "$@" ;;
  *) sed -n '2,24p' "$0"; exit 2 ;;
esac

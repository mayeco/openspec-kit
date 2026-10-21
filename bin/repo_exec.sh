#!/usr/bin/env bash
# ==============================================================================
# bin/repo_exec.sh - Run a command in a child repository, in its own environment
# ==============================================================================
# Usage: bin/repo_exec.sh <repo> <command> [args...]
#   <repo>  a name under repos/ (backend) or a path (repos/backend)
#
# Runs the command from the repository's root after sourcing the script that
# `env_script` in its repo.config.yaml names (the repository's own file, from
# config/templates/repo_env.sh): it activates the toolchain the repository pins
# and exports what its commands need. Without env_script the command runs in the
# plain shell. A configured script that is missing fails with exit 2.
# The gates (bin/run_gates.sh) run through it; agents and QA skills should too:
#   bash bin/repo_exec.sh backend bundle exec rspec spec/models/user_spec.rb
#   bash bin/repo_exec.sh frontend pnpm dev
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${1:?usage: repo_exec.sh <repo> <command> [args...]}"
shift
[ $# -gt 0 ] || { echo "usage: repo_exec.sh <repo> <command> [args...]" >&2; exit 2; }

# A visual QA session runs in .worktrees/_visual_qa on slot 97, so its dev server
# and database never collide with the main checkout or the cycle's judgment (slot 98).
# Only while it lives: a lock past its start plus its time-to-live is a dead session's.
VISUAL_LOCK="$ROOT/log/visual_qa.lock"
if [ -z "${OPENSPEC_SLOT:-}" ] && [ -d "$VISUAL_LOCK" ] &&
   [ $(( $(date +%s) - $(cat "$VISUAL_LOCK/started" 2>/dev/null || echo 0) )) -lt "$(cat "$VISUAL_LOCK/ttl" 2>/dev/null || echo 0)" ]; then
  export OPENSPEC_SLOT="${OPENSPEC_VISUAL_SLOT:-97}"
  [ -d "${OPENSPEC_WORKTREE_BASE:-$ROOT/.worktrees}/_visual_qa" ] && ROOT="${OPENSPEC_WORKTREE_BASE:-$ROOT/.worktrees}/_visual_qa"
fi

case "$REPO" in
  /*) DIR="$REPO" ;;
  */*) DIR="$ROOT/$REPO" ;;
  *) DIR="$ROOT/repos/$REPO" ;;
esac
[ -d "$DIR" ] || { echo "repo_exec: no repository at $DIR" >&2; exit 2; }
cd "$DIR" || exit 2

ENV_SCRIPT=""
if [ -f repo.config.yaml ]; then
  ENV_SCRIPT="$(ruby -ryaml -e 'puts((YAML.safe_load_file(ARGV[0]) || {})["env_script"].to_s.strip)' repo.config.yaml)" || {
    echo "repo_exec: $DIR/repo.config.yaml is not valid YAML" >&2; exit 2
  }
fi
if [ -n "$ENV_SCRIPT" ]; then
  [ -f "$ENV_SCRIPT" ] || { echo "repo_exec: env_script $ENV_SCRIPT of $DIR/repo.config.yaml does not exist" >&2; exit 2; }
  set +u   # version managers read unset variables
  # shellcheck disable=SC1090
  . "./$ENV_SCRIPT"
fi
exec "$@"

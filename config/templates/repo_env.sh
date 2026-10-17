# shellcheck shell=bash
# ==============================================================================
# repos/<repo-name>/<env_script> - Prepares the shell for this repository's commands
# ==============================================================================
# Template: copy it into the child repository (for example as script/env.sh), set
# `env_script` in its repo.config.yaml to that path, adapt it and commit it there.
# bin/repo_exec.sh sources it from the repository root before every command of the
# repository: its gates, its dev command, and what agents and QA skills run through
# `bash bin/repo_exec.sh repos/<name> <command>`.
#
# Why: schedulers, agents and gates run non-interactive shells, where the cd hooks
# of RVM, rbenv, chruby, asdf, mise, nvm or pyenv never run, so `bundle exec`,
# `pnpm` or `pytest` would find the wrong version or none.
#
# Rules: it is sourced, not executed. It must not exit, must not fail the caller,
# must not print secrets, and should stay quiet. Agents may not change it: the
# merger blocks a change that touches it, like repo.config.yaml itself.

openspec_repo_env() {
  local had_u=0 want gemset
  case $- in *u*) had_u=1; set +u ;; esac

  # Ruby: .ruby-version (e.g. ruby-3.4.1) and an optional RVM .ruby-gemset.
  want=""; gemset=""
  [ -f .ruby-version ] && want="$(tr -d '[:space:]' < .ruby-version)"
  [ -f .ruby-gemset ] && gemset="$(tr -d '[:space:]' < .ruby-gemset)"
  if [ -n "$want" ]; then
    if [ -s "$HOME/.rvm/scripts/rvm" ]; then
      # shellcheck disable=SC1091
      source "$HOME/.rvm/scripts/rvm"
      rvm use "${want}${gemset:+@${gemset}}" >/dev/null 2>&1 || rvm use "$want" >/dev/null 2>&1 || true
    elif command -v rbenv >/dev/null 2>&1; then
      eval "$(rbenv init - bash 2>/dev/null)" || true
    elif [ -s /opt/homebrew/opt/chruby/share/chruby/chruby.sh ] || [ -s /usr/local/share/chruby/chruby.sh ]; then
      # shellcheck disable=SC1091
      source /opt/homebrew/opt/chruby/share/chruby/chruby.sh 2>/dev/null || source /usr/local/share/chruby/chruby.sh
      chruby "${want#ruby-}" >/dev/null 2>&1 || true
    fi
  fi

  # Node: .nvmrc or .node-version, through nvm or fnm.
  want=""
  [ -f .nvmrc ] && want="$(tr -d '[:space:]' < .nvmrc)"
  [ -z "$want" ] && [ -f .node-version ] && want="$(tr -d '[:space:]' < .node-version)"
  if [ -n "$want" ]; then
    if [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
      # shellcheck disable=SC1091
      source "${NVM_DIR:-$HOME/.nvm}/nvm.sh" && nvm use "$want" >/dev/null 2>&1 || true
    elif command -v fnm >/dev/null 2>&1; then
      eval "$(fnm env --shell bash 2>/dev/null)" && fnm use "$want" >/dev/null 2>&1 || true
    fi
  fi

  # Python: .python-version through pyenv.
  if [ -f .python-version ] && command -v pyenv >/dev/null 2>&1; then
    eval "$(pyenv init - bash 2>/dev/null)" || true
  fi

  # mise and asdf read .tool-versions and .mise.toml for every language at once.
  if command -v mise >/dev/null 2>&1; then
    eval "$(mise env -s bash 2>/dev/null)" || true
  elif [ -s "$HOME/.asdf/asdf.sh" ] && [ -f .tool-versions ]; then
    # shellcheck disable=SC1091
    source "$HOME/.asdf/asdf.sh" || true
  fi

  [ "$had_u" -eq 1 ] && set -u
  return 0
}
openspec_repo_env

# What this repository's commands need besides the toolchain, for example:
# export PGGSSENCMODE=disable          # local PostgreSQL without GSS encryption
# export RAILS_ENV=test

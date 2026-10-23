#!/bin/sh
# ==============================================================================
# install.sh - Bootstrap installer for the OpenSpec orchestration kit CLI
# ==============================================================================
# Install with:
#   curl -fsSL https://raw.githubusercontent.com/mayeco/openspec-kit/master/install.sh | sh
#
# Clones the OpenSpec kit repository into ~/.openspec-kit (or $OPENSPEC_KIT_HOME)
# and installs the executable wrapper ~/.local/bin/openspec-kit (or
# $OPENSPEC_KIT_BIN_DIR/openspec-kit):
#   #!/bin/sh
#   exec "$HOME/.openspec-kit/bin/openspec-kit" "$@"
#
# Once installed, run from anywhere:
#   openspec-kit init <app-dir> --agents claude,hermes ...
#   openspec-kit update <app-dir> [--agents ...]
#   openspec-kit self-upgrade [<tag-or-branch>]
#   openspec-kit verify [<app-dir>]
#   openspec-kit portal
set -eu

KIT_HOME="${OPENSPEC_KIT_HOME:-$HOME/.openspec-kit}"
BIN_DIR="${OPENSPEC_KIT_BIN_DIR:-$HOME/.local/bin}"
REPO_URL="${OPENSPEC_KIT_REPO:-https://github.com/mayeco/openspec-kit.git}"
REF="${OPENSPEC_KIT_REF:-}"

if ! command -v git >/dev/null 2>&1; then
  echo "openspec-kit: git is required" >&2
  exit 1
fi
if ! command -v ruby >/dev/null 2>&1; then
  echo "openspec-kit: ruby (>= 3.1) is required" >&2
  exit 1
fi

if [ -d "$KIT_HOME/.git" ]; then
  echo "openspec-kit: updating $KIT_HOME from origin..."
  git -C "$KIT_HOME" remote set-url origin "$REPO_URL" 2>/dev/null || true
  git -C "$KIT_HOME" fetch --tags --prune --quiet origin
  if [ -n "$REF" ]; then
    git -C "$KIT_HOME" checkout --quiet "$REF"
    if git -C "$KIT_HOME" symbolic-ref -q HEAD >/dev/null 2>&1; then
      git -C "$KIT_HOME" merge --ff-only --quiet "origin/$REF" 2>/dev/null || true
    fi
  else
    branch="$(git -C "$KIT_HOME" symbolic-ref -q --short HEAD || true)"
    if [ -n "$branch" ]; then
      git -C "$KIT_HOME" merge --ff-only --quiet "origin/$branch"
    fi
  fi
else
  echo "openspec-kit: cloning $REPO_URL into $KIT_HOME..."
  rm -rf "$KIT_HOME"
  mkdir -p "$(dirname "$KIT_HOME")"
  if [ -n "$REF" ]; then
    git clone --quiet --branch "$REF" "$REPO_URL" "$KIT_HOME"
  else
    git clone --quiet "$REPO_URL" "$KIT_HOME"
  fi
fi

mkdir -p "$BIN_DIR"
SHIM="$BIN_DIR/openspec-kit"
cat > "$SHIM" <<EOF
#!/bin/sh
exec "$KIT_HOME/bin/openspec-kit" "\$@"
EOF
chmod +x "$SHIM" "$KIT_HOME/bin/openspec-kit"

VER="$(ruby -rjson -e 'puts((JSON.parse(File.read(ARGV[0]))["version"] rescue "unknown"))' "$KIT_HOME/MANIFEST.json" 2>/dev/null || echo unknown)"
echo "openspec-kit: installed v$VER at $SHIM (-> $KIT_HOME/bin/openspec-kit)"
case ":${PATH:-}:" in
  *":$BIN_DIR:"*) ;;
  *) echo "openspec-kit: add $BIN_DIR to your PATH (export PATH=\"$BIN_DIR:\$PATH\")" ;;
esac
echo "next:"
echo "  openspec-kit init <app-dir> --agents claude"
echo "  openspec-kit update <app-dir>"
echo "  openspec-kit self-upgrade"

#!/usr/bin/env bash
# Removes what install.sh added.
#
#   ./uninstall.sh                   remove the commands, keep configs and history
#   ./uninstall.sh --remove-configs  also delete the ~/.claude-* directories
#
# Leaves Node, OmniRoute, your provider logins and your normal `claude` alone.

set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
MARKER="claude-code-profiles"
LEGACY="omniroute-profiles"   # pre-rename marker

REMOVE_CONFIGS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --remove-configs) REMOVE_CONFIGS=1; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
ok()   { printf '   [ok] %s\n' "$*"; }
warn() { printf '   [!]  %s\n' "$*"; }
topath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

say ""
say "  Removing $MARKER"
say ""

# --- shell profile block --------------------------------------------------
case "${SHELL##*/}" in
  zsh)  RC="$HOME/.zshrc" ;;
  bash) if [ "$(uname -s)" = "Darwin" ] && [ -f "$HOME/.bash_profile" ]; then RC="$HOME/.bash_profile"; else RC="$HOME/.bashrc"; fi ;;
  *)    RC="$HOME/.profile" ;;
esac

if [ -f "$RC" ]; then
  if grep -q ">>> $MARKER >>>\|>>> $LEGACY >>>" "$RC" 2>/dev/null; then
    CLEAN="$(mktemp)"
    awk -v m="$MARKER" -v l="$LEGACY" '
      $0 ~ ("^# >>> "m" >>>") { skip=1 }
      $0 ~ ("^# >>> "l" >>>") { skip=1 }
      skip==0 { print }
      $0=="# <<< "m" <<<" || $0=="# <<< "l" <<<" { skip=0 }
    ' "$RC" > "$CLEAN"
    mv "$CLEAN" "$RC"
    ok "removed the managed block from $RC"
  else
    warn "no managed block found in $RC"
  fi
else
  warn "no shell profile at $RC"
fi

# --- config dirs ----------------------------------------------------------
CFG="$ROOT/profiles.json"
if [ -f "$CFG" ] && command -v node >/dev/null 2>&1; then
  for dir in $(node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(c.profiles.map(p=>p.dir).join("\n"))' "$(topath "$CFG")"); do
    target="$HOME/$dir"
    [ -d "$target" ] || continue
    if [ "$REMOVE_CONFIGS" = "1" ]; then
      rm -rf "$target"
      ok "deleted $target"
    else
      say "   kept  $target   (delete with: ./uninstall.sh --remove-configs)"
    fi
  done
fi

say ""
say "  Left alone on purpose: Node.js, the OmniRoute install, your provider logins,"
say "  your routing combos, and your original claude command."
say ""
say "  To go further:"
say "    omniroute stop              stop the router"
say "    npm uninstall -g omniroute  remove the router"
say ""

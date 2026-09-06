#!/usr/bin/env bash
# Installs multi-provider Claude Code profiles backed by a local OmniRoute gateway.
# Idempotent. Safe to re-run after editing profiles.json - that is how you customize.
#
#   ./install.sh                 install
#   ./install.sh --dry-run       show what would happen, write nothing
#   ./install.sh --list-models   print every model your account exposes
#   ./install.sh --test-models   call every model in profiles.json, report dead ones
#
# Written for bash 3.2 (what macOS ships) - no associative arrays, no mapfile.
# JSON is handled by node, which is already required to run the gateway.

set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
MARKER="claude-code-profiles"
LEGACY="omniroute-profiles"   # pre-rename marker, still cleaned up on upgrade

API_KEY=""; DRY_RUN=0; LIST_MODELS=0; TEST_MODELS=0; SKIP_SMOKE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --api-key)      API_KEY="${2:-}"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --list-models)  LIST_MODELS=1; shift ;;
    --test-models)  TEST_MODELS=1; shift ;;
    --skip-smoke-test) SKIP_SMOKE=1; shift ;;
    -h|--help)      sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -t 1 ]; then C_CY=$'\033[36m'; C_GR=$'\033[32m'; C_YL=$'\033[33m'; C_RD=$'\033[31m'; C_0=$'\033[0m'
else C_CY=""; C_GR=""; C_YL=""; C_RD=""; C_0=""; fi
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s== %s%s\n' "$C_CY" "$*" "$C_0"; }
ok()   { printf '   %s[ok]%s %s\n' "$C_GR" "$C_0" "$*"; }
warn() { printf '   %s[!]%s  %s\n' "$C_YL" "$C_0" "$*"; }
die()  { printf '\n%s[X] %s%s\n' "$C_RD" "$*" "$C_0"; exit 1; }

# Under Git Bash/MSYS, node is a Windows binary and cannot resolve /c/... paths.
# A no-op on macOS and Linux, where cygpath does not exist.
topath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# node -e helper: run a script with profiles.json already parsed as `cfg`
nodejs() { node -e "const fs=require('fs');const cfg=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));$1" "$(topath "$CFG")" "${@:2}"; }

say ""
say "  Claude Code multi-provider profiles"
say "  -----------------------------------"
say "  Installs a local model router and adds one Claude Code command per profile."
say ""

# ---------------------------------------------------------------- config
step "Reading profiles.json"
CFG="$ROOT/profiles.json"
[ -f "$CFG" ] || die "profiles.json not found next to this script."
command -v node >/dev/null 2>&1 || die "Node.js is required. Install it from https://nodejs.org (LTS), then re-run."
node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$(topath "$CFG")" 2>/dev/null || die "profiles.json is not valid JSON."
PORT=$(nodejs 'process.stdout.write(String(cfg.gateway.port))')
CTX=$(nodejs 'process.stdout.write(String(cfg.gateway.contextTokens))')
BASE="http://127.0.0.1:$PORT"
N_PROF=$(nodejs 'process.stdout.write(String(cfg.profiles.length))')
N_COMBO=$(nodejs 'process.stdout.write(String(cfg.combos.length))')
ok "$N_PROF profiles, $N_COMBO combos, gateway port $PORT"

# ---------------------------------------------------------------- claude
step "Checking Claude Code"
command -v claude >/dev/null 2>&1 || die "Claude Code is not on PATH. Install it first: https://claude.com/claude-code"
ok "claude found"

# ---------------------------------------------------------------- omniroute
step "Installing the OmniRoute router"
if command -v omniroute >/dev/null 2>&1; then
  ok "already installed"
else
  command -v npm >/dev/null 2>&1 || die "npm is required. Install Node.js LTS from https://nodejs.org , then re-run."
  say "   npm install -g omniroute   (a few minutes)"
  npm install -g omniroute --silent || die "omniroute install failed."
  command -v omniroute >/dev/null 2>&1 || die "omniroute installed but not on PATH. Open a new shell and re-run."
  ok "installed"
fi

# ---------------------------------------------------------------- server
step "Starting the router"
# Any HTTP status means it is listening - an unauthenticated probe returns 401,
# which is still proof of life. Only a transport failure means "not running".
gateway_up() {
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$BASE/v1/models" 2>/dev/null || true)
  [ -n "$code" ] && [ "$code" != "000" ]
}
if gateway_up; then
  ok "already running on $BASE"
else
  nohup omniroute serve >/dev/null 2>&1 &
  say "   waiting for it to come up..."
  i=0
  while [ $i -lt 40 ]; do sleep 1.5; gateway_up && break; i=$((i+1)); done
  gateway_up || die "Router did not come up on $BASE. Run 'omniroute serve' in another terminal, watch for an error, then re-run."
  ok "running on $BASE"
fi

# ---------------------------------------------------------------- accounts
step "Provider accounts and API key"
say ""
say "   In the dashboard, do two things:"
say "     1. Add providers   (sign in to each one you want; the free ones need nothing)"
say "     2. Create an API key and copy it"
say ""
say "   Dashboard: $BASE/dashboard"
say ""
if [ -z "$API_KEY" ]; then
  if command -v open    >/dev/null 2>&1; then open    "$BASE/dashboard" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$BASE/dashboard" >/dev/null 2>&1 || true; fi
  printf '   Paste your OmniRoute API key: '
  read -r API_KEY
fi
[ -n "$API_KEY" ] || die "No API key supplied."

MODELS_JSON="$(mktemp)"
trap 'rm -f "$MODELS_JSON"' EXIT
curl -s -m 20 -H "Authorization: Bearer $API_KEY" "$BASE/v1/models" -o "$MODELS_JSON" || true
node -e "const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));if(!d.data)process.exit(1)" "$(topath "$MODELS_JSON")" 2>/dev/null \
  || die "That key was rejected. Create one at $BASE/dashboard and re-run."
N_MODELS=$(node -e "process.stdout.write(String(JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).data.length))" "$(topath "$MODELS_JSON")")
ok "key accepted - $N_MODELS models visible"

# ---------------------------------------------------------------- list
if [ "$LIST_MODELS" = "1" ]; then
  step "Models your account exposes"
  node -e '
    const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).data;
    const g={}; d.forEach(m=>{const p=m.id.split("/")[0];(g[p]=g[p]||[]).push(m.id)});
    Object.keys(g).sort().forEach(p=>{
      console.log("\n  "+p+"  ("+g[p].length+")");
      g[p].sort().forEach(i=>console.log("     "+i));
    });' "$(topath "$MODELS_JSON")"
  say ""
  say "  Put the ones you want into profiles.json, then run --test-models."
  say ""
  exit 0
fi

# ---------------------------------------------------------------- test
# A router's catalog lists what its providers advertise, not what your account
# can actually serve. The only reliable check is to call each model once.
if [ "$TEST_MODELS" = "1" ]; then
  step "Testing every model named in profiles.json"
  DEAD=0; TOTAL=0
  for m in $(nodejs 'const s=new Set();cfg.combos.forEach(c=>c.models.forEach(x=>s.add(x)));console.log([...s].join("\n"))'); do
    TOTAL=$((TOTAL+1))
    body=$(node -e 'process.stdout.write(JSON.stringify({model:process.argv[1],max_tokens:8,messages:[{role:"user",content:"Say OK"}]}))' "$m")
    resp=$(curl -s -m 120 -X POST "$BASE/v1/messages" -H 'content-type: application/json' \
             -H "Authorization: Bearer $API_KEY" -H 'anthropic-version: 2023-06-01' -d "$body" 2>/dev/null || true)
    verdict=$(printf '%s' "$resp" | node -e '
      let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
        try{const d=JSON.parse(s);
          if(d.error) return console.log("DEAD "+String(d.error.message).slice(0,55));
          if(d.reason) return console.log("DEAD "+String(d.message).slice(0,55));
          if(d.content) return console.log("LIVE");
          console.log("DEAD empty reply");
        }catch(e){console.log("DEAD unparseable response")}});' 2>/dev/null || echo "DEAD no response")
    case "$verdict" in
      LIVE) ok "$m" ;;
      *)    warn "$m - ${verdict#DEAD }"; DEAD=$((DEAD+1)) ;;
    esac
  done
  say ""
  if [ "$DEAD" = "0" ]; then ok "all $TOTAL models work"
  else warn "$DEAD of $TOTAL models are unusable - remove them from profiles.json"; fi
  say ""
  exit 0
fi

# ---------------------------------------------------------------- combos
step "Creating routing combos"
export OMNIROUTE_API_KEY="$API_KEY"
GOOD_COMBOS=""
COMBO_NAMES=$(nodejs 'console.log(cfg.combos.map(c=>c.name).join("\n"))')
for name in $COMBO_NAMES; do
  strategy=$(nodejs 'const c=cfg.combos.find(x=>x.name===process.argv[2]);process.stdout.write(c.strategy)' "$name")
  have=$(node -e '
    const fs=require("fs");
    const cfg=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const avail=new Set(JSON.parse(fs.readFileSync(process.argv[2],"utf8")).data.map(m=>m.id));
    const c=cfg.combos.find(x=>x.name===process.argv[3]);
    process.stdout.write(c.models.filter(m=>avail.has(m)).join(","));' "$(topath "$CFG")" "$(topath "$MODELS_JSON")" "$name")
  missing=$(node -e '
    const fs=require("fs");
    const cfg=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const avail=new Set(JSON.parse(fs.readFileSync(process.argv[2],"utf8")).data.map(m=>m.id));
    const c=cfg.combos.find(x=>x.name===process.argv[3]);
    process.stdout.write(c.models.filter(m=>!avail.has(m)).join(", "));' "$(topath "$CFG")" "$(topath "$MODELS_JSON")" "$name")
  if [ -z "$have" ]; then warn "$name: skipped - you have none of its models"; continue; fi
  [ -n "$missing" ] && warn "$name: dropping unavailable - $missing"
  count=$(printf "%s
" "$have" | tr "," "
" | wc -l | tr -d " ")
  if [ "$DRY_RUN" = "1" ]; then
    GOOD_COMBOS="$GOOD_COMBOS $name"
    ok "would create $name [$strategy] - $count models"
    continue
  fi
  omniroute combo delete "$name" --yes >/dev/null 2>&1 || true
  if omniroute combo create "$name" --strategy "$strategy" --models "$have" >/dev/null 2>&1; then
    GOOD_COMBOS="$GOOD_COMBOS $name"
    ok "$name [$strategy] - $count models"
  else
    warn "$name: create failed"
  fi
done
[ -n "$GOOD_COMBOS" ] || die "No combos could be created. Add at least one provider at $BASE/dashboard."

has_combo() { case " $GOOD_COMBOS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------- profiles
step "Writing Claude Code profiles"
INSTALLED=""
for cmd in $(nodejs 'console.log(cfg.profiles.map(p=>p.command).join("\n"))'); do
  dir=$(nodejs   'process.stdout.write(cfg.profiles.find(p=>p.command===process.argv[2]).dir)' "$cmd")
  opus=$(nodejs  'process.stdout.write(cfg.profiles.find(p=>p.command===process.argv[2]).slots.opus)' "$cmd")
  sonnet=$(nodejs 'process.stdout.write(cfg.profiles.find(p=>p.command===process.argv[2]).slots.sonnet)' "$cmd")
  haiku=$(nodejs 'process.stdout.write(cfg.profiles.find(p=>p.command===process.argv[2]).slots.haiku)' "$cmd")
  bad=""
  for c in "$opus" "$sonnet" "$haiku"; do has_combo "$c" || bad="$bad $c"; done
  if [ -n "$bad" ]; then warn "$cmd: skipped - needs combo(s)$bad"; continue; fi

  target="$HOME/$dir"
  if [ "$DRY_RUN" = "1" ]; then
    INSTALLED="$INSTALLED $cmd"
    ok "would write $cmd  ->  ~/$dir  [opus=$opus sonnet=$sonnet haiku=$haiku]"
    continue
  fi
  mkdir -p "$target"
  node -e '
    const fs=require("fs"),[,dir,base,key,opus,sonnet,haiku,ctx]=process.argv;
    fs.writeFileSync(dir+"/settings.json", JSON.stringify({
      env:{ANTHROPIC_BASE_URL:base,ANTHROPIC_AUTH_TOKEN:key,
           ANTHROPIC_DEFAULT_OPUS_MODEL:opus,ANTHROPIC_DEFAULT_SONNET_MODEL:sonnet,
           ANTHROPIC_DEFAULT_HAIKU_MODEL:haiku,ANTHROPIC_DEFAULT_FABLE_MODEL:opus,
           ANTHROPIC_MODEL:opus,CLAUDE_CODE_MAX_CONTEXT_TOKENS:String(ctx)},
      model:opus},null,2)+"\n");
    // never clobber an existing .claude.json - it holds that profile history
    if(!fs.existsSync(dir+"/.claude.json"))
      fs.writeFileSync(dir+"/.claude.json", JSON.stringify({hasCompletedOnboarding:true},null,2)+"\n");
  ' "$(topath "$target")" "$BASE" "$API_KEY" "$opus" "$sonnet" "$haiku" "$CTX"

  deleg=$(nodejs 'process.stdout.write(String(!!cfg.profiles.find(p=>p.command===process.argv[2]).delegation))' "$cmd")
  if [ "$deleg" = "true" ]; then
    # CLAUDE.md is the file people tailor, so never clobber an edited one
    if [ ! -f "$target/CLAUDE.md" ]; then cp "$ROOT/templates/CLAUDE.md" "$target/CLAUDE.md"
    elif ! cmp -s "$ROOT/templates/CLAUDE.md" "$target/CLAUDE.md"; then
      warn "$cmd: kept your edited CLAUDE.md (delete it to take the template version)"
    fi
    mkdir -p "$target/agents"
    cp "$ROOT"/templates/agents/*.md "$target/agents/"
  fi
  INSTALLED="$INSTALLED $cmd"
  ok "$cmd  ->  ~/$dir"
done
[ -n "$INSTALLED" ] || die "No profiles could be installed."

# ---------------------------------------------------------------- launchers
if [ "$DRY_RUN" = "1" ]; then
  step "Dry run complete - nothing was changed"
  say ""
  say "   Would install:$INSTALLED"
  say ""
  say "   Re-run without --dry-run to apply."
  say ""
  exit 0
fi

step "Adding commands to your shell profile"
case "${SHELL##*/}" in
  zsh)  RC="$HOME/.zshrc" ;;
  bash) if [ "$(uname -s)" = "Darwin" ] && [ -f "$HOME/.bash_profile" ]; then RC="$HOME/.bash_profile"; else RC="$HOME/.bashrc"; fi ;;
  *)    RC="$HOME/.profile" ;;
esac
touch "$RC"

BLOCK="$(mktemp)"
{
  echo "# >>> $MARKER >>>  (managed block - edit profiles.json and re-run install.sh)"
  echo '_omni_vars="CLAUDE_CONFIG_DIR ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL'
  echo ' ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL'
  echo ' ANTHROPIC_DEFAULT_FABLE_MODEL CLAUDE_CODE_MAX_CONTEXT_TOKENS"'
  echo '_omni_clear() { for v in $_omni_vars; do unset "$v"; done; }'
  echo 'omni-profile() { [ -n "${CLAUDE_CONFIG_DIR:-}" ] || { echo "no profile active"; return; }'
  echo '  echo "dir:    $CLAUDE_CONFIG_DIR"; echo "opus:   $ANTHROPIC_DEFAULT_OPUS_MODEL"'
  echo '  echo "sonnet: $ANTHROPIC_DEFAULT_SONNET_MODEL"; echo "haiku:  $ANTHROPIC_DEFAULT_HAIKU_MODEL"; }'
  echo '# The gateway does not autostart, so bring it up on demand.'
  echo '_omni_gateway() {'
  echo '  c=$(curl -s -o /dev/null -w "%{http_code}" -m 3 "$1/v1/models" 2>/dev/null || true)'
  echo '  [ -n "$c" ] && [ "$c" != "000" ] && return 0'
  echo '  echo "  starting the model router..." >&2'
  echo '  nohup omniroute serve >/dev/null 2>&1 &'
  echo '  i=0; while [ $i -lt 30 ]; do sleep 1'
  echo '    c=$(curl -s -o /dev/null -w "%{http_code}" -m 3 "$1/v1/models" 2>/dev/null || true)'
  echo '    [ -n "$c" ] && [ "$c" != "000" ] && return 0; i=$((i+1)); done'
  echo '  return 1; }'
  echo '_omni_run() {'
  echo '  _omni_dir="$1"; shift'
  echo '  _omni_clear   # entry-clear: a killed run can never leak into another profile'
  echo '  _omni_path="$HOME/$_omni_dir"'
  echo '  [ -f "$_omni_path/settings.json" ] || { echo "Missing $_omni_path/settings.json" >&2; return 1; }'
  echo '  export CLAUDE_CONFIG_DIR="$_omni_path"'
  echo '  eval "$(node -e '"'"'const e=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).env;'
  echo '    Object.keys(e).forEach(k=>console.log("export "+k+"="+JSON.stringify(String(e[k]))));'"'"' "$_omni_path/settings.json")"'
  echo '  if ! _omni_gateway "$ANTHROPIC_BASE_URL"; then _omni_clear'
  echo '    echo "The model router is not responding. Run '"'"'omniroute serve'"'"' in another terminal to see why." >&2'
  echo '    return 1; fi'
  echo '  claude "$@"; _omni_rc=$?; _omni_clear; return $_omni_rc; }'
  for cmd in $INSTALLED; do
    dir=$(nodejs 'process.stdout.write(cfg.profiles.find(p=>p.command===process.argv[2]).dir)' "$cmd")
    extra=$(nodejs 'const a=cfg.profiles.find(p=>p.command===process.argv[2]).extraArgs||[];process.stdout.write(a.join(" "))' "$cmd")
    summary=$(nodejs 'process.stdout.write(cfg.profiles.find(p=>p.command===process.argv[2]).summary)' "$cmd")
    echo "# $summary"
    echo "$cmd() { _omni_run '$dir' $extra \"\$@\"; }"
  done
  echo "# <<< $MARKER <<<"
} > "$BLOCK"

# strip any previous block (current and pre-rename marker), then append
CLEAN="$(mktemp)"
awk -v m="$MARKER" -v l="$LEGACY" '
  $0=="# >>> "m" >>>" || $0 ~ ("^# >>> "m" >>>")  { skip=1 }
  $0 ~ ("^# >>> "l" >>>")                          { skip=1 }
  skip==0 { print }
  $0=="# <<< "m" <<<" || $0=="# <<< "l" <<<"       { skip=0 }
' "$RC" > "$CLEAN"
{ cat "$CLEAN"; echo ""; cat "$BLOCK"; } > "$RC"
rm -f "$CLEAN" "$BLOCK"
ok "shell profile: $RC"

# ---------------------------------------------------------------- verify
if [ "$SKIP_SMOKE" = "0" ]; then
  step "Testing each profile end to end"
  # shellcheck disable=SC1090
  . "$RC" 2>/dev/null || true
  for cmd in $INSTALLED; do
    out=$($cmd -p 'Reply with exactly: OK' 2>&1 | grep -v '^\[claude-code:' | tr -d '\r' | tail -1)
    case "$out" in
      *OK*) ok "$cmd works" ;;
      *)    warn "$cmd - unexpected reply: $out" ;;
    esac
  done
fi

step "Done"
say ""
say "   Reload your shell, then use:"
say ""
for cmd in $INSTALLED; do
  summary=$(nodejs 'process.stdout.write(cfg.profiles.find(p=>p.command===process.argv[2]).summary)' "$cmd")
  printf '     %-16s %s\n' "$cmd" "$summary"
done
say ""
say "     source $RC"
say ""
say "   Customize: edit profiles.json, re-run this script."
say "   Remove:    ./uninstall.sh"
say ""

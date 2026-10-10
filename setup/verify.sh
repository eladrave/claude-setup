#!/usr/bin/env bash
# claude-setup verify step: check that a target is ready to run Claude Code with
# this config. Runs on the target as the user Claude Code runs as, in a
# non-interactive shell (the same kind of shell Codex remote and similar tools use).
#
# Usage: verify.sh [smoke 0|1] [fable 0|1]
#   smoke  1 = ask Claude Code (Haiku, one short prompt) to prove it loaded CLAUDE.md
#   fable  1 = also run one tiny task through the fable-escalation subagent (costs Fable usage)

set -u

smoke="${1:-1}"
fable="${2:-0}"

BIN="$HOME/.local/bin"
case ":$PATH:" in *":$BIN:"*) path_ok=1 ;; *) path_ok=0 ;; esac
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

pass=0; warn=0; fail=0
ok()   { printf '  PASS  %s\n' "$*"; pass=$((pass + 1)); }
wrn()  { printf '  WARN  %s\n' "$*"; warn=$((warn + 1)); }
bad()  { printf '  FAIL  %s\n' "$*"; fail=$((fail + 1)); }
have() { command -v "$1" >/dev/null 2>&1; }

run_limited() {  # run_limited SECONDS cmd...
  t="$1"; shift
  if have timeout; then timeout "$t" "$@"; else "$@"; fi
}

# --- who and where -----------------------------------------------------------
user="$(id -un)"
if [ "$(id -u)" = 0 ]; then
  wrn "running as root: Claude Code disables --dangerously-skip-permissions for root; use a non-root user for unattended runs"
else
  ok "user is $user (not root)"
fi

# --- config files --------------------------------------------------------------
if [ -s "$cfg/CLAUDE.md" ]; then ok "$cfg/CLAUDE.md present"; else bad "$cfg/CLAUDE.md missing"; fi
agent="$cfg/agents/fable-escalation.md"
if [ -s "$agent" ]; then
  if grep -q '^model: *fable' "$agent"; then ok "fable-escalation agent present (model: fable)"
  else wrn "fable-escalation agent present but its model is not fable"; fi
else
  bad "$agent missing"
fi

# --- PATH as seen by non-interactive SSH ---------------------------------------
if [ $path_ok -eq 1 ]; then ok "~/.local/bin is on PATH for non-interactive shells"
else wrn "~/.local/bin is NOT on PATH for non-interactive shells (Codex remote may not find tools there)"; fi

# --- commands ------------------------------------------------------------------
for t in claude gh gcloud git; do
  if have "$t"; then ok "$t found: $(command -v "$t")"
  else
    case "$t" in
      claude) bad "claude not found on PATH (install as this user: curl -fsSL https://claude.ai/install.sh | bash)" ;;
      *)      bad "$t not found on PATH" ;;
    esac
  fi
done
if have codex; then ok "codex found: $(command -v codex)"; else wrn "codex CLI not found (only needed if your Codex setup runs it on this machine)"; fi

# --- gh ------------------------------------------------------------------------
if have gh; then
  if gh auth status >/dev/null 2>&1; then
    ok "gh signed in as $(gh api user --jq .login 2>/dev/null || echo '?')"
    if git config --global --get-all credential.https://github.com.helper 2>/dev/null | grep -q gh; then
      ok "git uses gh credentials for github.com"
    else
      wrn "git is not set to use gh credentials (run: gh auth setup-git)"
    fi
  else
    bad "gh is not signed in (run: gh auth login)"
  fi
fi

# --- gcloud --------------------------------------------------------------------
if have gcloud; then
  acct="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
  if [ -n "$acct" ]; then ok "gcloud signed in as $acct"; else bad "gcloud is not signed in (run: gcloud auth login --no-launch-browser)"; fi
  proj="$(gcloud config get-value project 2>/dev/null || true)"
  if [ -n "$proj" ] && [ "$proj" != "(unset)" ]; then ok "gcloud default project: $proj"
  else wrn "gcloud has no default project (gcloud config set project PROJECT_ID)"; fi
  if gcloud auth application-default print-access-token >/dev/null 2>&1; then ok "gcloud application default credentials present"
  else wrn "no gcloud application default credentials (only needed for client libraries, Terraform)"; fi
fi

# --- Claude Code smoke test ------------------------------------------------------
explain_claude_error() {
  out="$1"
  if printf '%s' "$out" | grep -qi 'root'; then
    bad "Claude Code refused to run with --dangerously-skip-permissions as root"
  elif printf '%s' "$out" | grep -Eqi 'log ?in|not authenticated|invalid api key|unauthorized|credentials'; then
    bad "Claude Code is not signed in for $user (run 'claude' once and log in)"
  else
    bad "Claude Code smoke test failed; last output:"
    printf '%s\n' "$out" | tail -5 | sed 's/^/          /'
  fi
}

if [ "$smoke" = 1 ] && have claude; then
  scratch="$(mktemp -d)"
  out="$(cd "$scratch" && run_limited 180 claude -p --model haiku --dangerously-skip-permissions \
    "Reply with only the exact name of the custom subagent that your user-level instructions designate for model escalation. No other words." 2>&1)"
  rc=$?
  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qi 'fable-escalation'; then
    ok "Claude Code runs with --dangerously-skip-permissions and has loaded CLAUDE.md (answered: $(printf '%s' "$out" | tr -d '\n' | cut -c1-40))"
  elif [ $rc -eq 0 ]; then
    bad "Claude Code ran but did not show the CLAUDE.md routing policy (answered: $(printf '%s' "$out" | tr -d '\n' | cut -c1-80))"
  else
    explain_claude_error "$out"
  fi

  if [ "$fable" = 1 ]; then
    out="$(cd "$scratch" && run_limited 300 claude -p --dangerously-skip-permissions --output-format stream-json --verbose \
      "Use the fable-escalation subagent to answer in one short line: what does 'set -euo pipefail' do in bash? Return its answer." 2>&1)"
    rc=$?
    if printf '%s' "$out" | grep -Eq '"subagent_type": ?"fable-escalation"'; then
      ok "fable-escalation subagent ran"
    elif [ $rc -eq 0 ]; then
      bad "Claude Code did not invoke the fable-escalation subagent"
    else
      explain_claude_error "$out"
    fi
  fi
  rm -rf "$scratch"
elif [ "$smoke" = 1 ]; then
  wrn "skipped Claude Code smoke test (claude not installed)"
fi

printf '  ---\n  %d passed, %d warnings, %d failed\n' "$pass" "$warn" "$fail"
if [ $fail -gt 0 ]; then exit 1; fi
exit 0

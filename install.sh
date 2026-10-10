#!/usr/bin/env bash
# claude-setup: install global Claude Code configuration (CLAUDE.md, agents, ...)
# onto this machine and/or remote machines reachable over SSH.
#
# Everything under claude/ in this repo is copied into the target's Claude config
# directory (${CLAUDE_CONFIG_DIR:-~/.claude}), keeping the same relative paths.
# Existing files that would change are backed up first.
#
# Usage:
#   ./install.sh vmforclaude              # one SSH host (any name `ssh` accepts)
#   ./install.sh host1 user@host2         # several hosts
#   ./install.sh --local                  # this machine
#   ./install.sh                          # asks for a host
#
# Then, on each target, installs Claude Code, gh and gcloud if missing (no sudo),
# walks you through signing in to both, and verifies the result: user is not
# root, config files present, tools on PATH for non-interactive SSH, gh and
# gcloud signed in, and a one-prompt Claude Code smoke test.
#   ./install.sh --verify-only claude@vmforclaude    # re-check without installing
#
# One-liners (see README for which one fits public vs private repos):
#   curl -fsSL https://raw.githubusercontent.com/eladrave/claude-setup/main/install.sh | bash -s -- vmforclaude
#   gh api repos/eladrave/claude-setup/contents/install.sh -H "Accept: application/vnd.github.raw" | bash -s -- vmforclaude

set -euo pipefail

REPO="${CLAUDE_SETUP_REPO:-eladrave/claude-setup}"
REF="${CLAUDE_SETUP_REF:-main}"

usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed 's/^# \{0,1\}//' || true
  cat <<'EOF'
Options:
  --local       Install on this machine as well (or only).
  --dry-run     Show what would change without writing anything.
  --no-tools    Do not install Claude Code, gh, gcloud or sign in to gh and gcloud.
  --verify-only Only run the checks; install nothing.
  --no-verify   Skip the checks.
  --no-smoke    Run the checks but skip the Claude Code prompt (no model usage).
  --test-fable  Also run one tiny task through the fable-escalation agent (uses Fable).
  -h, --help    Show this help.
EOF
}

log()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

hosts=()
do_local=0
dry_run=0
do_tools=1
do_apply=1
do_verify=1
smoke=1
test_fable=0
while [ $# -gt 0 ]; do
  case "$1" in
    --local)   do_local=1 ;;
    --dry-run) dry_run=1 ;;
    --no-tools) do_tools=0 ;;
    --verify-only) do_apply=0; do_tools=0 ;;
    --no-verify) do_verify=0 ;;
    --no-smoke) smoke=0 ;;
    --test-fable) test_fable=1 ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; hosts+=("$@"); break ;;
    -*)        die "unknown option: $1 (see --help)" ;;
    *)         hosts+=("$1") ;;
  esac
  shift
done

# Ask for a host when none was given. Read from the terminal, not stdin,
# because stdin is the script itself when run as `... | bash`.
if [ ${#hosts[@]} -eq 0 ] && [ $do_local -eq 0 ]; then
  [ -r /dev/tty ] || die "no host given and no terminal to ask on; pass a host or --local"
  printf 'SSH host (whatever you type after "ssh", e.g. vmforclaude or root@1.2.3.4): ' > /dev/tty
  IFS= read -r answer < /dev/tty
  [ -n "$answer" ] || die "no host given"
  hosts=("$answer")
fi

workdir="$(mktemp -d)"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

# Locate the payload: the claude/ folder next to this script when run from a
# checkout, otherwise download the repo from GitHub.
script_dir=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -n "$script_dir" ] && [ -d "$script_dir/claude" ]; then
  root="$script_dir"
else
  # Try, in order: a signed-in GitHub CLI, a GITHUB_TOKEN, then anonymous curl
  # (anonymous only works while the repo is public).
  log "Downloading $REPO@$REF ..."
  tgz="$workdir/repo.tgz"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 \
     && gh api "repos/$REPO/tarball/$REF" > "$tgz" 2>/dev/null; then
    :
  elif [ -n "${GITHUB_TOKEN:-}" ] \
     && curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" "https://api.github.com/repos/$REPO/tarball/$REF" -o "$tgz"; then
    :
  elif curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" -o "$tgz"; then
    :
  else
    die "could not download $REPO. For a private repo, sign in with 'gh auth login' or set GITHUB_TOKEN."
  fi
  mkdir -p "$workdir/repo"
  tar -xzf "$tgz" -C "$workdir/repo" --strip-components=1
  root="$workdir/repo"
  [ -d "$root/claude" ] || die "downloaded repo has no claude/ folder"
fi
src="$root/claude"
tools="$root/setup/tools.sh"
if [ $do_tools -eq 1 ] && [ ! -f "$tools" ]; then
  log "Note: $tools not found, skipping the gh/gcloud step."
  do_tools=0
fi
tools_mode=install
[ $dry_run -eq 1 ] && tools_mode=check
verify="$root/setup/verify.sh"
if [ $do_verify -eq 1 ] && [ ! -f "$verify" ]; then
  log "Note: $verify not found, skipping checks."
  do_verify=0
fi
# A dry run must not spend model usage.
if [ $dry_run -eq 1 ]; then smoke=0; test_fable=0; fi

# Interactive steps (logins) need the real terminal: stdin is the script itself
# when run as `curl ... | bash`.
tty_in=/dev/null
if [ -r /dev/tty ] && { : < /dev/tty; } 2>/dev/null; then tty_in=/dev/tty; fi

# Bundle the payload once.
payload="$workdir/payload.tar"
tar -C "$src" -cf "$payload" .
count="$(tar -tf "$payload" | grep -vc '/$' || true)"
log "Payload: $count file(s) from $src"

# Runs on the target. Args: <payload tar path> <dry-run 0|1>
apply_script='
set -eu
tarball="$1"; dry="$2"
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
tmp="$(mktemp -d)"
trap "rm -rf \"$tmp\"" EXIT
tar -xf "$tarball" -C "$tmp"
ts="$(date +%Y%m%d-%H%M%S)"
bk="$cfg/claude-setup-backups/$ts"
echo "  user: $(id -un)   config dir: $cfg"
changed=0
backed_up=0
cd "$tmp"
while IFS= read -r f; do
  dest="$cfg/$f"
  if [ -f "$dest" ] && cmp -s "$f" "$dest"; then
    echo "  unchanged  $f"
    continue
  fi
  changed=$((changed + 1))
  if [ "$dry" = 1 ]; then
    if [ -f "$dest" ]; then echo "  would update  $f"; else echo "  would add     $f"; fi
    continue
  fi
  if [ -f "$dest" ]; then
    mkdir -p "$bk/$(dirname "$f")"
    cp -p "$dest" "$bk/$f"
    backed_up=1
    action="updated"
  else
    action="added"
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$f" "$dest"
  echo "  $action  $f"
done < <(find . -type f | sed "s|^\./||" | sort)
if [ "$backed_up" = 1 ]; then echo "  backups: $bk"; fi
echo "  $changed file(s) changed"
'

failures=0

if [ $do_local -eq 1 ]; then
  log ""
  log "== local ($(hostname)) =="
  if [ $do_apply -eq 1 ]; then
    bash -c "$apply_script" apply "$payload" "$dry_run" || failures=$((failures + 1))
  fi
  if [ $do_tools -eq 1 ]; then
    log "  -- tools: claude, gh, gcloud --"
    bash "$tools" "$tools_mode" < "$tty_in" || failures=$((failures + 1))
  fi
  if [ $do_verify -eq 1 ]; then
    log "  -- checks --"
    if [ "$(uname -s)" = Linux ]; then
      # Fresh environment that loads ~/.bashrc the way sshd's non-interactive
      # commands do, so PATH changes made above are seen, as Codex would see them.
      env -i HOME="$HOME" USER="$(id -un)" LOGNAME="$(id -un)" SHELL="${SHELL:-/bin/bash}" \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        ${CLAUDE_CONFIG_DIR:+CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR"} \
        bash -c '. "$HOME/.bashrc" >/dev/null 2>&1 || true; exec bash "$@"' verify "$verify" "$smoke" "$test_fable" < /dev/null \
        || failures=$((failures + 1))
    else
      bash "$verify" "$smoke" "$test_fable" < /dev/null || failures=$((failures + 1))
    fi
  fi
fi

# ${arr[@]+...} keeps bash 3.2 (macOS default) happy with an empty array under set -u.
for host in ${hosts[@]+"${hosts[@]}"}; do
  log ""
  log "== $host =="
  # Reuse one SSH connection for both steps so you authenticate only once.
  ctl="$workdir/ssh-%C"
  sshopts=(-o ControlMaster=auto -o "ControlPath=$ctl" -o ControlPersist=60)
  remote_tar="/tmp/claude-setup-$$-$RANDOM.tar"
  if [ $do_apply -eq 1 ]; then
    if ssh "${sshopts[@]}" "$host" "cat > $remote_tar" < "$payload" \
       && printf '%s' "$apply_script" | ssh "${sshopts[@]}" "$host" "bash -s -- $remote_tar $dry_run; rc=\$?; rm -f $remote_tar; exit \$rc"; then
      :
    else
      log "  FAILED on $host"
      failures=$((failures + 1))
    fi
  fi
  if [ $do_tools -eq 1 ]; then
    log "  -- tools: claude, gh, gcloud --"
    remote_tools="/tmp/claude-setup-tools-$$-$RANDOM.sh"
    tflag=-T
    [ "$tty_in" = /dev/tty ] && tflag=-t
    if ssh "${sshopts[@]}" "$host" "cat > $remote_tools" < "$tools" \
       && ssh "${sshopts[@]}" $tflag "$host" "bash $remote_tools $tools_mode; rc=\$?; rm -f $remote_tools; exit \$rc" < "$tty_in"; then
      :
    else
      log "  tools step had problems on $host (see messages above)"
      failures=$((failures + 1))
    fi
  fi
  if [ $do_verify -eq 1 ]; then
    log "  -- checks --"
    remote_verify="/tmp/claude-setup-verify-$$-$RANDOM.sh"
    # Plain non-interactive SSH command, the same way Codex remote runs commands.
    if ssh "${sshopts[@]}" "$host" "cat > $remote_verify" < "$verify" \
       && ssh "${sshopts[@]}" -T "$host" "bash $remote_verify $smoke $test_fable; rc=\$?; rm -f $remote_verify; exit \$rc" < /dev/null; then
      :
    else
      failures=$((failures + 1))
    fi
  fi
  ssh "${sshopts[@]}" -O exit "$host" >/dev/null 2>&1 || true
done

log ""
if [ $failures -gt 0 ]; then
  die "$failures step(s) failed or reported problems (see FAIL lines above)"
fi
if [ $dry_run -eq 1 ]; then
  log "Dry run complete. Nothing was written."
elif [ $do_apply -eq 0 ]; then
  log "Checks complete."
else
  log "Done. Set the default model once per machine inside claude: /model opus and /effort high."
fi

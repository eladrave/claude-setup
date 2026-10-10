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
# Remote one-liner (private repo, needs an authenticated `gh` on this machine):
#   gh api repos/eladrave/claude-setup/contents/install.sh -H "Accept: application/vnd.github.raw" | bash -s -- vmforclaude

set -euo pipefail

REPO="${CLAUDE_SETUP_REPO:-eladrave/claude-setup}"
REF="${CLAUDE_SETUP_REF:-main}"

usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed 's/^# \{0,1\}//' || true
  cat <<'EOF'
Options:
  --local       Install on this machine as well (or only).
  --dry-run     Show what would change without writing anything.
  -h, --help    Show this help.
EOF
}

log()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

hosts=()
do_local=0
dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --local)   do_local=1 ;;
    --dry-run) dry_run=1 ;;
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
# checkout, otherwise download the repo via the GitHub CLI (works for private repos).
script_dir=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -n "$script_dir" ] && [ -d "$script_dir/claude" ]; then
  src="$script_dir/claude"
else
  command -v gh >/dev/null 2>&1 || die "GitHub CLI (gh) is required to download $REPO; install it and run 'gh auth login'"
  log "Downloading $REPO@$REF ..."
  gh api "repos/$REPO/tarball/$REF" > "$workdir/repo.tgz" || die "could not download $REPO (check 'gh auth status' and repo access)"
  mkdir -p "$workdir/repo"
  tar -xzf "$workdir/repo.tgz" -C "$workdir/repo" --strip-components=1
  src="$workdir/repo/claude"
  [ -d "$src" ] || die "downloaded repo has no claude/ folder"
fi

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
  bash -c "$apply_script" apply "$payload" "$dry_run" || failures=$((failures + 1))
fi

# ${arr[@]+...} keeps bash 3.2 (macOS default) happy with an empty array under set -u.
for host in ${hosts[@]+"${hosts[@]}"}; do
  log ""
  log "== $host =="
  # Reuse one SSH connection for both steps so you authenticate only once.
  ctl="$workdir/ssh-%C"
  sshopts=(-o ControlMaster=auto -o "ControlPath=$ctl" -o ControlPersist=60)
  remote_tar="/tmp/claude-setup-$$-$RANDOM.tar"
  if ssh "${sshopts[@]}" "$host" "cat > $remote_tar" < "$payload" \
     && printf '%s' "$apply_script" | ssh "${sshopts[@]}" "$host" "bash -s -- $remote_tar $dry_run; rc=\$?; rm -f $remote_tar; exit \$rc"; then
    :
  else
    log "  FAILED on $host"
    failures=$((failures + 1))
  fi
  ssh "${sshopts[@]}" -O exit "$host" >/dev/null 2>&1 || true
done

log ""
if [ $failures -gt 0 ]; then
  die "$failures target(s) failed"
fi
if [ $dry_run -eq 1 ]; then
  log "Dry run complete. Nothing was written."
else
  log "Done. Start a new 'claude' session on each target and run /memory and /agents to confirm."
fi

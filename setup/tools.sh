#!/usr/bin/env bash
# claude-setup tools step: make sure Claude Code, the GitHub CLI (gh) and the
# Google Cloud CLI (gcloud) are installed for the current user, and that gh and
# gcloud are signed in. (Claude Code signs in on its first interactive run.)
#
# Runs on the target machine as the user Claude Code runs as. Needs no sudo:
# on Linux, missing tools go into ~/.local/bin (gh) and ~/google-cloud-sdk (gcloud).
# On macOS, Homebrew is used.
#
# Usage: tools.sh [check]
#   check   only report what is installed and signed in; change nothing

set -eu

mode="${1:-install}"
BIN="$HOME/.local/bin"
case ":$PATH:" in *":$BIN:"*) ;; *) PATH="$BIN:$PATH"; export PATH ;; esac
# Pick up a previous user-level gcloud install even if PATH was never updated.
[ -x "$HOME/google-cloud-sdk/bin/gcloud" ] && PATH="$PATH:$HOME/google-cloud-sdk/bin"

interactive=0
if [ -t 0 ] && [ -t 1 ]; then interactive=1; fi

say()  { printf '  %s\n' "$*"; }
warn() { printf '  WARNING: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

os="$(uname -s)"
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64)  gh_arch=amd64; gc_arch=x86_64 ;;
  aarch64|arm64) gh_arch=arm64; gc_arch=arm ;;
  *)             gh_arch=""; gc_arch="" ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- PATH persistence --------------------------------------------------------
# Non-interactive SSH commands (used by Codex remote and similar tools) often
# skip the end of ~/.bashrc, so the PATH line goes at the top of it.
ensure_path_rc() {
  line='case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac  # claude-setup'
  for rc in "$HOME/.profile" "$HOME/.bashrc"; do
    [ -f "$rc" ] || : > "$rc"
    if ! grep -q '# claude-setup' "$rc"; then
      { printf '%s\n' "$line"; cat "$rc"; } > "$tmp/rc" && cat "$tmp/rc" > "$rc"
      say "added ~/.local/bin to PATH in ~/$(basename "$rc")"
    fi
  done
  case "${SHELL:-}" in
    *zsh) rc="$HOME/.zshenv"; [ -f "$rc" ] || : > "$rc"
          grep -q '# claude-setup' "$rc" || { printf '%s\n' "$line" >> "$rc"; say "added ~/.local/bin to PATH in ~/.zshenv"; } ;;
  esac
}

# --- Claude Code ---------------------------------------------------------------
install_claude() {
  # Native installer: per-user, no sudo, installs to ~/.local/bin/claude.
  say "installing Claude Code for $(id -un)"
  curl -fsSL https://claude.ai/install.sh | bash >"$tmp/claude-install.log" 2>&1 \
    || { warn "Claude Code install failed; see: curl -fsSL https://claude.ai/install.sh | bash"; tail -5 "$tmp/claude-install.log" >&2; return 1; }
  if have claude || [ -x "$BIN/claude" ]; then
    say "installed Claude Code: $( (claude --version || "$BIN/claude" --version) 2>/dev/null | head -1)"
    say "Claude Code: run 'claude' once in a terminal to sign in"
  else
    warn "Claude Code installer finished but claude was not found"; return 1
  fi
}

# --- gh ----------------------------------------------------------------------
install_gh() {
  if [ "$os" = Darwin ]; then
    have brew || { warn "gh missing and Homebrew not found; install gh from https://cli.github.com"; return 1; }
    brew install gh
    return
  fi
  [ "$os" = Linux ] && [ -n "$gh_arch" ] || { warn "no gh build for $os/$arch; install it manually"; return 1; }
  # The "latest" page redirects to .../releases/tag/vX.Y.Z
  latest="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/cli/cli/releases/latest)"
  ver="${latest##*/v}"
  case "$ver" in [0-9]*) ;; *) warn "could not determine the latest gh version"; return 1 ;; esac
  name="gh_${ver}_linux_${gh_arch}"
  say "downloading gh $ver"
  curl -fsSL "https://github.com/cli/cli/releases/download/v${ver}/${name}.tar.gz" | tar -xz -C "$tmp"
  mkdir -p "$BIN"
  cp "$tmp/$name/bin/gh" "$BIN/gh"
  chmod 755 "$BIN/gh"
  say "installed gh $ver to ~/.local/bin/gh"
}

login_gh() {
  if gh auth status >/dev/null 2>&1; then
    say "gh: signed in as $(gh api user --jq .login 2>/dev/null || echo '?')"
  elif [ $interactive -eq 1 ]; then
    say "gh: not signed in; starting login (open the URL on any device and enter the code)"
    gh auth login --hostname github.com --git-protocol https --web
  else
    warn "gh: not signed in and no terminal to log in on; rerun from a terminal"
    return 0
  fi
  gh auth status >/dev/null 2>&1 && gh auth setup-git >/dev/null 2>&1 && say "gh: git configured to use gh credentials"
  return 0
}

# --- gcloud ------------------------------------------------------------------
install_gcloud() {
  if [ "$os" = Darwin ]; then
    have brew || { warn "gcloud missing and Homebrew not found; install from https://cloud.google.com/sdk/docs/install"; return 1; }
    brew install --cask gcloud-cli || brew install --cask google-cloud-sdk
    return
  fi
  [ "$os" = Linux ] && [ -n "$gc_arch" ] || { warn "no gcloud build for $os/$arch; install it manually"; return 1; }
  if [ ! -x "$HOME/google-cloud-sdk/bin/gcloud" ]; then
    say "downloading gcloud (a few hundred MB, this can take a minute)"
    curl -fsSL "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-${gc_arch}.tar.gz" | tar -xz -C "$HOME"
    "$HOME/google-cloud-sdk/install.sh" --quiet --usage-reporting=false --path-update=false --command-completion=false >/dev/null 2>&1 \
      || { warn "gcloud install.sh failed; run ~/google-cloud-sdk/install.sh by hand to see why"; return 1; }
  fi
  mkdir -p "$BIN"
  for t in gcloud gsutil bq; do
    [ -x "$HOME/google-cloud-sdk/bin/$t" ] && ln -sf "$HOME/google-cloud-sdk/bin/$t" "$BIN/$t"
  done
  say "installed gcloud to ~/google-cloud-sdk (linked in ~/.local/bin)"
}

login_gcloud() {
  account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
  if [ -n "$account" ]; then
    say "gcloud: signed in as $account"
  elif [ $interactive -eq 1 ]; then
    say "gcloud: not signed in; starting login (open the URL, sign in, paste the code back here)"
    gcloud auth login --no-launch-browser
  else
    warn "gcloud: not signed in and no terminal to log in on; rerun from a terminal"
    return 0
  fi

  if gcloud auth application-default print-access-token >/dev/null 2>&1; then
    say "gcloud: application default credentials present"
  elif [ $interactive -eq 1 ]; then
    printf '  Also set up Application Default Credentials (used by client libraries, Terraform)? [y/N] '
    read -r ans || ans=""
    case "$ans" in
      [yY]*) gcloud auth application-default login --no-launch-browser ;;
      *)     say "gcloud: skipped application default credentials" ;;
    esac
  fi

  project="$(gcloud config get-value project 2>/dev/null || true)"
  if [ -n "$project" ] && [ "$project" != "(unset)" ]; then
    say "gcloud: default project $project"
  else
    say "gcloud: no default project (set one with: gcloud config set project PROJECT_ID)"
  fi
}

# --- main --------------------------------------------------------------------
status() {
  t="$1"
  if have "$t"; then say "$t: installed at $(command -v "$t")"; else say "$t: NOT installed"; fi
}

if [ "$mode" = check ]; then
  status claude
  status gh
  have gh && { gh auth status >/dev/null 2>&1 && say "gh: signed in" || say "gh: NOT signed in"; }
  status gcloud
  if have gcloud; then
    a="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
    [ -n "$a" ] && say "gcloud: signed in as $a" || say "gcloud: NOT signed in"
  fi
  exit 0
fi

[ "$os" = Linux ] && ensure_path_rc

failed=0
have claude || install_claude || failed=1
have gh     || install_gh     || failed=1
if have gh; then login_gh || failed=1; fi
have gcloud || install_gcloud || failed=1
if have gcloud; then login_gcloud || failed=1; fi

exit $failed

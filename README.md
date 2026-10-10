# claude-setup

My global Claude Code configuration, plus an installer that puts it on any machine I run `claude` on and makes sure `gh` and `gcloud` are installed and signed in there.

Everything under [`claude/`](claude/) mirrors the layout of `~/.claude` and is copied there as is:

| File | Purpose |
| --- | --- |
| `claude/CLAUDE.md` | Global working instructions: autonomy, delegation, Opus/Fable model routing, telemetry, knowledge storage, communication |
| `claude/agents/fable-escalation.md` | Escalation subagent pinned to Claude Fable 5.1 |
| `setup/tools.sh` | Installs and signs in `gh` and `gcloud` on the target (not copied into `~/.claude`) |
| `setup/verify.sh` | Checks the target is ready (not copied into `~/.claude`) |

To add more global config later (skills, commands, more agents), put it under `claude/` at the path it should have inside `~/.claude`. The installer picks it up automatically.

## Install

**If the repo is public**, plain curl works from any machine:

```bash
curl -fsSL https://raw.githubusercontent.com/eladrave/claude-setup/main/install.sh | bash -s -- claude@vmforclaude
```

**If the repo is private**, anonymous curl gets a 404, so authenticate with the GitHub CLI's stored login:

```bash
# with gh
gh api repos/eladrave/claude-setup/contents/install.sh -H "Accept: application/vnd.github.raw" | bash -s -- claude@vmforclaude

# curl, using gh only for the token
curl -fsSL -H "Authorization: Bearer $(gh auth token)" -H "Accept: application/vnd.github.raw" \
  https://api.github.com/repos/eladrave/claude-setup/contents/install.sh | GITHUB_TOKEN="$(gh auth token)" bash -s -- claude@vmforclaude
```

Arguments work the same with every form:

```bash
... | bash -s -- host1 host2 --local     # several machines, plus this one
... | bash -s -- vmforclaude --dry-run   # preview without writing
... | bash -s -- --local                 # run inside a terminal on the target itself (e.g. Codex app over SSH)
... | bash -s -- vmforclaude --verify-only   # only run the checks
... | bash                               # no arguments: asks for the SSH host
```

From a checkout or the zip: `./install.sh claude@vmforclaude`.

The installer downloads the rest of the repo itself, trying a signed-in `gh` first, then `GITHUB_TOKEN`, then anonymous download (public repo only).

Optional alias for `~/.zshrc` (private repo):

```bash
alias claude-setup='gh api repos/eladrave/claude-setup/contents/install.sh -H "Accept: application/vnd.github.raw" | bash -s --'
# then: claude-setup claude@vmforclaude
```

## What it does

1. Downloads this repo (signed-in `gh`, then `GITHUB_TOKEN`, then anonymous), or uses the checkout it runs from.
2. Copies the `claude/` payload to each target over one SSH connection.
3. On the target, resolves the config directory as `${CLAUDE_CONFIG_DIR:-~/.claude}` for the SSH login user.
4. For each file: skips it if identical, otherwise backs up the existing copy to `~/.claude/claude-setup-backups/<timestamp>/` and writes the new one.
5. Runs [`setup/tools.sh`](setup/tools.sh) on the target (skip with `--no-tools`):
   * Installs Claude Code (native installer, ~/.local/bin/claude), `gh` and `gcloud` if missing, without sudo. On Linux, `gh` goes to `~/.local/bin` and `gcloud` to `~/google-cloud-sdk` (with `gcloud`, `gsutil`, `bq` linked into `~/.local/bin`). On macOS it uses Homebrew.
   * Puts `~/.local/bin` on PATH at the top of `~/.bashrc` and in `~/.profile`, so non-interactive SSH commands (Codex remote) find the tools.
   * Signs in to `gh` if needed (device code: open the URL on any device, enter the code) and runs `gh auth setup-git`.
   * Signs in to `gcloud` if needed (`--no-launch-browser`: open the URL, paste the code back), optionally sets up Application Default Credentials, and reports the default project.
   * With `--dry-run`, only reports what is installed and signed in.

6. Runs [`setup/verify.sh`](setup/verify.sh) on the target over a plain non-interactive SSH command, the same way Codex remote runs commands, and prints PASS / WARN / FAIL for:
   * the user is not root (Claude Code disables `--dangerously-skip-permissions` for root)
   * `CLAUDE.md` and the `fable-escalation` agent are in place
   * `~/.local/bin` is on PATH for non-interactive shells
   * `claude`, `gh`, `gcloud`, `git` are found (and whether one is installed in ~/.local/bin but missing from PATH)
   * `gh` is signed in and git uses its credentials; `gcloud` is signed in, has a default project, and has Application Default Credentials
   * a smoke test: `claude -p --model haiku --dangerously-skip-permissions` must name `fable-escalation` from the loaded instructions (one short Haiku prompt)
   * with `--test-fable`: one tiny task routed through the `fable-escalation` subagent (uses some Fable usage)

   `--no-smoke` skips the model prompt, `--no-verify` skips the checks, and `--dry-run` runs them without any model usage. The installer exits non-zero if any check FAILs.

It never deletes files and only touches the paths that exist under `claude/`. Running it again is safe: identical files, installed tools, and existing logins are left alone.

Logins need a terminal. The installer reads from your terminal even when run as `curl ... | bash`; without one it installs the tools and skips the logins.

## Which user gets the config

Claude Code reads the config of the user that runs `claude`. The installer writes to the user you SSH in as.

* If you SSH in as `root` and start `claude` in that session, root is correct.
* If you start `claude` with `sudo -u someone`, `su`, or as a service account, install for that user instead, for example `./install.sh someone@vmforclaude`.

To check, run `!whoami` inside a Claude session on the remote, or `ps -o user= -p "$(pgrep -n claude)"` while it runs.

## After installing

Claude Code reads this config when a session starts, so start a new session after installing. Sessions that were already open, including desktop app SSH sessions, keep the old config.

To confirm a session loaded it, ask: *"List the subagent types you can launch, and quote the first heading of your user CLAUDE.md."* It should list `fable-escalation` and quote "Working instructions for Claude Code and Claude".

The checks cover the rest of what you would otherwise test by hand. Two things remain manual, once per machine, inside `claude`:

* `/model opus` and `/effort high` (the default model is not part of this config)
* the first interactive `claude --dangerously-skip-permissions` run may ask you to accept the bypass-permissions warning

## Not covered

* Claude Code cloud sessions (claude.ai/code) do not read `~/.claude`. Commit `CLAUDE.md` and `.claude/agents/` into each repo, or write them from the cloud environment's setup script.
* The `codex-drive-as-knowledge` skill is enabled on my claude.ai account, not installed by this repo.
* The Codex CLI is not installed or checked; the Codex app does not need it on the remote.
* With `--dangerously-skip-permissions`, the agent can do anything these `gh` and `gcloud` logins allow. Prefer a fine-grained GitHub token and a scoped Google service account for an unattended user.

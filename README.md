# claude-setup

My global Claude Code configuration, plus an installer that puts it on any machine I run `claude` on.

Everything under [`claude/`](claude/) mirrors the layout of `~/.claude` and is copied there as is:

| File | Purpose |
| --- | --- |
| `claude/CLAUDE.md` | Global working instructions: autonomy, delegation, Opus/Fable model routing, telemetry, knowledge storage, communication |
| `claude/agents/fable-escalation.md` | Escalation subagent pinned to Claude Fable 5.1 |

To add more global config later (skills, commands, more agents), put it under `claude/` at the path it should have inside `~/.claude`. The installer picks it up automatically.

## Install

From my Mac, with `gh` signed in (`gh auth status`):

```bash
# one remote machine (any name `ssh` accepts, including Host aliases from ~/.ssh/config)
gh api repos/eladrave/claude-setup/contents/install.sh -H "Accept: application/vnd.github.raw" | bash -s -- vmforclaude

# several machines, or this Mac too
gh api repos/eladrave/claude-setup/contents/install.sh -H "Accept: application/vnd.github.raw" | bash -s -- host1 host2 --local

# preview without writing
gh api repos/eladrave/claude-setup/contents/install.sh -H "Accept: application/vnd.github.raw" | bash -s -- vmforclaude --dry-run

# no arguments: asks for the SSH host
gh api repos/eladrave/claude-setup/contents/install.sh -H "Accept: application/vnd.github.raw" | bash
```

Plain `curl https://raw.githubusercontent.com/... | bash` does not work because the repo is private. `gh api` authenticates with the GitHub CLI's stored login instead of a token on the command line.

From a checkout it works the same way: `./install.sh vmforclaude`.

Optional alias for `~/.zshrc`:

```bash
alias claude-setup='gh api repos/eladrave/claude-setup/contents/install.sh -H "Accept: application/vnd.github.raw" | bash -s --'
# then: claude-setup vmforclaude
```

## What it does

1. Downloads this repo with `gh` (or uses the checkout it runs from).
2. Copies the `claude/` payload to each target over one SSH connection.
3. On the target, resolves the config directory as `${CLAUDE_CONFIG_DIR:-~/.claude}` for the SSH login user.
4. For each file: skips it if identical, otherwise backs up the existing copy to `~/.claude/claude-setup-backups/<timestamp>/` and writes the new one.

It never deletes files and only touches the paths that exist under `claude/`. Running it again is safe.

## Which user gets the config

Claude Code reads the config of the user that runs `claude`. The installer writes to the user you SSH in as.

* If you SSH in as `root` and start `claude` in that session, root is correct.
* If you start `claude` with `sudo -u someone`, `su`, or as a service account, install for that user instead, for example `./install.sh someone@vmforclaude`.

To check, run `!whoami` inside a Claude session on the remote, or `ps -o user= -p "$(pgrep -n claude)"` while it runs.

## After installing

Start a new `claude` session on the target and run `/memory` (the user `CLAUDE.md` should be listed) and `/agents` (`fable-escalation` should be listed).

The default model is not part of this config. Set it once per machine with `/model opus` and `/effort high`.

## Not covered

* Claude Code cloud sessions (claude.ai/code) do not read `~/.claude`. Commit `CLAUDE.md` and `.claude/agents/` into each repo, or write them from the cloud environment's setup script.
* The `codex-drive-as-knowledge` skill is enabled on my claude.ai account, not installed by this repo.

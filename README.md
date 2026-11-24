# Attention Island

A macOS notch island for people running several Claude Code sessions at once. It sits around the camera notch and shows:

- **Claude sessions** that need you (waiting for input or finished), fed by a Claude Code hook. Click one to jump to it.
- **Pull requests** waiting on your review and your own open PRs, with an optional pre-review by Codex or Claude running in a read-only sandbox.
- **Memory**, shown once usage passes 80%. Click it for CPU and memory, the local dev environments (tmux dev servers and agent-browser sessions, grouped by git worktree), one-click kill, and a "Clean up with Claude" button that stops what is stale.

## Install

Needs macOS 14+, Swift 5.10, and the `gh` CLI signed in. `codex` or `claude` is needed for pre-reviews and cleanup.

```sh
./build.sh
```

This builds the app, installs it to `/Applications`, copies the hook to `~/.attention-island/` and adds it to `~/.claude/settings.json` (a backup is kept next to it).

## Settings

Optional, for the one repository you work in most:

```sh
defaults write com.jimmy.attentionisland workRepo owner/name          # scopes the cleanup's merged-PR check
defaults write com.jimmy.attentionisland workRepoPath ~/code/name     # folder "Ask Claude" opens for that repo's PRs
defaults write com.jimmy.attentionisland releaseWorkflow release.yml  # adds a two-click release button
```

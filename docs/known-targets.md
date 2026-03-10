# Known OpenClaw Targets

This document records what the scripts remove and why.

## Shared Targets

- CLI uninstall command: `openclaw uninstall --all --yes --non-interactive`
- Optional automation fallback: `npx -y openclaw uninstall --all --yes --non-interactive`
- Default state directory: `${OPENCLAW_STATE_DIR:-$HOME/.openclaw}` on POSIX, `%OPENCLAW_STATE_DIR%` or `%USERPROFILE%\.openclaw` on Windows
- External config file: `OPENCLAW_CONFIG_PATH` if it points outside the default state directory
- Default workspace directory: `${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/workspace`
- Profile state directories: `~/.openclaw-*` or `%USERPROFILE%\.openclaw-*`
- Known package managers: `npm`, `pnpm`, `bun`
- Optional explicit source checkout removal: user-provided `--repo-path` / `-RepoPath`

## macOS Targets

- LaunchAgent labels and plists matching:
  - `~/Library/LaunchAgents/ai.openclaw*.plist`
  - `~/Library/LaunchAgents/com.openclaw*.plist`
- Desktop apps:
  - `/Applications/OpenClaw.app`
  - `~/Applications/OpenClaw.app`
- Aggressive scan roots:
  - `~/Library/Application Support`
  - `~/Library/Caches`
  - `~/Library/Logs`
  - `~/Library/Preferences`
  - `~/Library/Saved Application State`
  - `~/Library/WebKit`

## Linux Targets

- Systemd user units matching:
  - `~/.config/systemd/user/openclaw-gateway*.service`
- Aggressive scan roots:
  - `~/.config`
  - `~/.cache`
  - `~/.local/share`
  - `~/.local/state`

## Windows Targets

- Scheduled tasks with names:
  - `OpenClaw Gateway`
  - `OpenClaw Gateway (*)`
- Known files and directories:
  - `%USERPROFILE%\.openclaw\gateway.cmd`
  - `%USERPROFILE%\.openclaw\workspace`
  - `%APPDATA%\OpenClaw`
  - `%LOCALAPPDATA%\OpenClaw`
  - `%LOCALAPPDATA%\Programs\OpenClaw`
  - `%APPDATA%\Microsoft\Windows\Start Menu\Programs\OpenClaw*`
- Aggressive scan roots:
  - `%APPDATA%`
  - `%LOCALAPPDATA%`

## Out of Scope

- Remote gateway hosts not mounted or accessed from the current machine
- Arbitrary source clones or renamed directories with no stable OpenClaw naming, unless the user passes an explicit repo path
- System-wide files that would require `sudo`

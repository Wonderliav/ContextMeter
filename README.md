# ContextMeter

A small always-on-top pill for the Claude desktop app (Code tab). It shows:
- **Header:** whole-account usage, i.e. the extra-usage budget as a percent and dollars ("$1,615 of $3.5k").
- **List:** each Claude Code chat used in the last 7 days, with how full its context window is. Chats in the Archive sidebar group are hidden.
- **Badge:** the number of chats at or above `askAtPercent` that were active in the last 24 h.
- **Replace** (hover a row): writes a handoff, opens a new chat with it, names it "Name vN", files it in the old chat's sidebar group, moves the old chat to the Archive group, and carries over model, effort and permission mode.

Developed by Liav.T.

> Note for Claude: this file is the whole spec. Read it and `ContextMeter.swift` before changing anything.

## Install (macOS 13+)
```bash
xcode-select --install          # once, if swiftc is missing
git clone https://github.com/Wonderliav/ContextMeter.git ~/Documents/Claude/ContextMeter
cd ~/Documents/Claude/ContextMeter && ./build.sh
```
1. First run asks for Keychain access to "Claude Code-credentials". Choose **Always Allow**. The app reads it through `/usr/bin/security`, read-only, and never logs it. It is only used to get account usage.
2. On first launch the pill asks once for **Accessibility** (macOS prompt + the settings page opens) — switch ContextMeter on. With this, Replace presses Return in the new chat itself. Without it, the new chat opens prefilled and you press Return.
3. It adds itself to **Login Items** on first launch, so it starts with your Mac. You can turn that off in System Settings → General → Login Items, and it won't re-add itself. Only one pill runs at a time.
4. Optional: set the default permission mode to Auto in Settings → Claude Code, so new chats don't ask to switch modes.
5. Optional: copy `config.example.json` to `config.json` and change the thresholds. The defaults are used when the file is missing.
6. Optional: put your code-signing identity hash (from `security find-identity -p codesigning`) in a file named `signing-id`, so Accessibility approval survives updates.

## Updates
The pill checks GitHub every hour. When there's a new version and the pill is idle, it installs it by itself: `git pull`, then `./build.sh`, then a restart. If a build fails, the old pill keeps running. A small blue **Update** at the bottom-right of the list does the same by hand. Your `config.json` and `signing-id` are never touched, since both are git-ignored.

To publish a change: edit, run `./build.sh`, test, then `git commit` and `git push`.

## Files
| File | What |
|---|---|
| `ContextMeter.swift` | Whole app, a single AppKit file |
| `config.example.json` | Template for `config.json`: thresholds, archive group, snooze, `windowOverride`, `pinFiles` |
| `build.sh` | Compiles, signs (`signing-id` or ad-hoc), relaunches |
| `Info.plist` | Bundle info (LSUIElement, so no Dock icon) |
| `config.json` | `askAtPercent`, `redAtPercent`, `archiveGroup`, `snoozeMinutes`, `windowOverride` (force a context size) |
| `config.json`, `signing-id`, `debug.log`, `usage-cache.json` | Local only, git-ignored |

## Where the data comes from
- **Chats:** `~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json` gives title, cwd, model, effort, permissionMode, lastActivityAt, cliSessionId.
- **Context fill:** the last assistant `usage` in `~/.claude/projects/*/<cliSessionId>.jsonl`, skipping subagent lines. Reads widen from 600 KB up to 40 MB, with a last-good cache. The window is 1M for `(opus|sonnet|fable)-5` or `[1m]` models, 200k otherwise.
- **Sidebar groups:** `~/Library/Application Support/Claude/claude_desktop_config.json`. Assignments use `code:<id>` keys.
- **Account usage:** `GET https://api.anthropic.com/api/oauth/usage` with the Claude Code OAuth token from the Keychain.
- **Handoff:** `claude -p … --resume <cli id> --fork-session` writes the note. It opens via `claude://code/new?q=…&folder=…`, and that link only accepts q, folder and file. Notes are saved in `~/Documents/Claude/handoffs/`.
- **Model/effort carry-over:** a chat can't change its own model or effort. The new chat asks the old chat, via send_message, to call set_session_model and set_session_effort on it. The change applies from the new chat's second turn.
- **Optional pins:** for each JSON file listed in `config.json → pinFiles`, if its `chatLink` points at the replaced chat, it is moved to the new chat. This lets other tools that pin a chat follow it.

## Known limits
- Passing a scratch-workspace folder in the link shows the app's "Trust this workspace?" dialog. That is a security prompt, and it is left for the user.
- The usage endpoint sometimes fails ("usage: request failed" in debug.log). The header then shows the last cached value.

## Windows PC
This build is macOS only (AppKit + Keychain). To port it, keep the same logic and swap the platform parts:
- UI: a small topmost borderless window, for example WPF/WinUI or a Tauri/Electron tray app.
- Paths: the app data is under `%APPDATA%\Claude\` (`claude-code-sessions`, `claude_desktop_config.json`), and transcripts are under `%USERPROFILE%\.claude\projects`. Verify these on the machine first.
- Token: Claude Code on Windows stores credentials in `%USERPROFILE%\.claude\.credentials.json` instead of a Keychain. Verify this too, read it only, and never log it.
- Return press: SendInput instead of CGEvent.

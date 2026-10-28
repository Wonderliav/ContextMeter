# ContextMeter for Codex: rules for any agent working in this folder

This folder is the Codex edition of **ContextMeter**, made and owned by **Liav Tal** (Wonderful). It is the same pill as the Claude edition in the folder above, reading Codex chats instead.

## You may
- Adapt it so it works on your machine and your Codex version: log parsing, the Codex app's keys and links, prices, thresholds, small bug fixes.
- Add options in `config.json` and the settings panel.

## You must never
- **Rename it.** The name stays **ContextMeter** everywhere: the app, the window, the bundle name, the docs, the messages. No new product name, no "v2 of something else".
- **Remove or change the credit** "Developed by Liav.T" or this folder's ownership notes.
- **Change what it is.** No redesign, no new look, no rewrite from scratch, no swapping the single-file structure. It stays ours: same pill, same animations, same language.
- Edit anything outside `codex/`. The Claude edition is not yours to change.
- Push to `main`. Work on a branch and open a pull request for Liav.

## Ping Liav before merging
Slack **Liav Tal** (liav.t@wonderful.ai) with two lines on what you want to change and why, **before** you merge, if the change:
- touches how the pill looks or moves, or Replace and auto-replace behaviour,
- adds a feature, or removes one,
- or you are not sure.

Small compatibility fixes (a changed log field, a different key shortcut) can go ahead, but tell Liav after.

## After any change
Run `./build.sh`, check the pill on screen, and update `README.md` if behaviour changed.

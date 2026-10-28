# ContextMeter for Codex

The same always-on-top pill as ContextMeter, reading **Codex** chats instead of Claude Code chats. Developed by Liav.T.

- **List:** each Codex chat used in the last 7 days with how full its context is (from the `token_count` events in `~/.codex/sessions`), its cost so far at OpenAI list prices (an estimate), and ❄ when it has sat idle for 15+ minutes (its cache is gone).
- **Header:** your plan's limit window as a percent when Codex reports one; otherwise this month's list-price spend. Set `monthlyLimitUsd` in `config.json` to get a ring against your own budget.
- **Dock:** drag the pill to a screen edge and it hides as a line (amber/red when something needs you). The drag is magnetic. Hold ⌥ to drag without the magnet.
- **Replace:** hover a chat and click the arrow. It asks Codex for a handoff, puts it in a new chat and hides the old one in the pill. It also suggests a model and effort for the next steps.
- **Auto-replace:** the gear opens settings. Switch it on and idle chats are replaced by themselves at the percent you choose (default 75%).

## Install (macOS 13+)
```bash
xcode-select --install          # once, if swiftc is missing
git clone https://github.com/Wonderliav/ContextMeter.git ~/Documents/Codex/ContextMeter
cd ~/Documents/Codex/ContextMeter/codex && ./build.sh
```
On first launch allow **Accessibility** (Replace uses it to press ⌘N, ⌘V and Return in the Codex app). It adds itself to Login Items.

## Not yet confirmed on a live Codex app
Built from the Codex log format, tested on saved chat logs only. These two steps have not been run against a live Codex app, so check them on the first Replace:
1. The handoff summary runs `codex exec resume <chat id> <prompt> -o <file>`. If the flags differ in your version, the pill falls back to telling the new chat to read the old chat's log.
2. The new chat is opened with ⌘N and the handoff is pasted and sent. If your Codex app uses other keys, change them in `sendToNewChat`.

Read `AGENTS.md` before changing anything.

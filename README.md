<div align="center">
  <img src="ClaudeIsland/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Logo" width="100" height="100">
  <h3 align="center">Claude Island</h3>
  <p align="center">
    A macOS menu bar app that brings Dynamic Island-style notifications to Claude Code CLI sessions.
    <br />
    <br />
    <a href="https://github.com/farouqaldori/claude-island/releases/latest" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/github/v/release/farouqaldori/claude-island?style=rounded&color=white&labelColor=000000&label=release" alt="Release Version" />
    </a>
    <a href="#" target="_blank" rel="noopener noreferrer">
      <img alt="GitHub Downloads" src="https://img.shields.io/github/downloads/farouqaldori/claude-island/total?style=rounded&color=white&labelColor=000000">
    </a>
  </p>
</div>

## Features

- **Notch UI** — Animated overlay that expands from the MacBook notch
- **Live Session Monitoring** — Track multiple Claude Code sessions in real-time
- **Permission Approvals** — Approve or deny tool executions directly from the notch
- **Chat with Claude** — Send messages to Claude directly from the notch UI
- **Chat History** — View full conversation history with markdown rendering
- **Global Hotkey** — Press `Cmd+Shift+C` anywhere to open notch and focus chat
- **Open in iTerm** — Jump directly to your terminal session with one click
- **Multi-line Input** — Write multi-line messages with `Cmd+Enter` to send
- **Auto-Setup** — Hooks install automatically on first launch

## Requirements

- macOS 15.6+
- Claude Code CLI
- **tmux** (required for chat functionality)

## Install

Download the latest release or build from source:

```bash
xcodebuild -scheme ClaudeIsland -configuration Release build
```

### Install tmux (required for chat)

```bash
brew install tmux
```

## Usage

### Basic Setup

1. **Start a tmux session:**
   ```bash
   tmux new -s claude
   ```

2. **Run Claude Code inside tmux:**
   ```bash
   claude
   ```

3. **Open Claude Island notch:**
   - Click on the notch area, or
   - Press `Cmd+Shift+C` (global hotkey)

4. **Chat with Claude:**
   - Select your session from the list
   - Type your message in the input field
   - Press `Cmd+Enter` to send (or click the send button)

### Why tmux is Required

Claude Island sends messages to Claude Code using `tmux send-keys`. Without tmux, the app cannot communicate with your terminal session.

```
iTerm/Terminal
  └── tmux (session manager) ← Claude Island sends messages here
        └── Claude Code
```

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+Shift+C` | Open notch and focus chat input |
| `Cmd+Enter` | Send message (in chat input) |
| `Enter` | Add new line (multi-line input) |

### tmux Basics

| Command | Description |
|---------|-------------|
| `tmux new -s claude` | Create new session named "claude" |
| `tmux attach -t claude` | Attach to existing session |
| `Ctrl+B` then `D` | Detach from session (keeps it running) |
| `tmux list-sessions` | List all sessions |
| `tmux kill-session -t claude` | Kill a session |

### Open in iTerm

Click the terminal icon in the chat header to open iTerm and:
- Attach to the tmux session (if running in tmux)
- Or navigate to the working directory

## Settings

Access settings by clicking the notch and selecting the menu icon:

- **Notification Sound** — Choose sound when Claude is ready for input
- **Launch at Login** — Start Claude Island automatically
- **Share Analytics** — Opt-in to anonymous usage analytics (off by default)
- **Display Screen** — Choose which screen to show the notch

## How It Works

Claude Island installs hooks into `~/.claude/hooks/` that communicate session state via a Unix socket. The app listens for events and displays them in the notch overlay.

When Claude needs permission to run a tool, the notch expands with approve/deny buttons—no need to switch to the terminal.

## Analytics

Claude Island uses Mixpanel to collect anonymous usage data (opt-in, disabled by default):

- **App Launched** — App version, build number, macOS version
- **Session Started** — When a new Claude Code session is detected

No personal data or conversation content is collected. You can enable/disable analytics in Settings.

## Troubleshooting

### Chat input is disabled

**Problem:** Input field shows "Open Claude Code in tmux to enable messaging"

**Solution:** Make sure Claude Code is running inside a tmux session:
```bash
tmux new -s claude
claude
```

### Global hotkey not working

**Problem:** `Cmd+Shift+C` doesn't open the notch

**Solution:** Grant Accessibility permissions to Claude Island in System Settings → Privacy & Security → Accessibility

### Notch not appearing

**Problem:** The notch UI doesn't show up

**Solution:**
1. Check if Claude Island is running (look for the menu bar icon)
2. Make sure you're on a display with a notch, or check "Display Screen" in settings

## License

Apache 2.0

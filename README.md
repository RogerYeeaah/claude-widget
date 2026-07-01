# Claude Usage Widget

A native macOS WidgetKit widget that shows your [Claude Code](https://claude.ai/code) usage — 5-hour and weekly quota — directly on your desktop.

## Features

- **Small, Medium, Large** widget sizes
- Reset countdown per window (e.g. `resets in 2h 15m`)
- Color-coded usage: normal → orange at 70% → red at 85%
- Shows "Server offline" when the dashboard server isn't reachable
- Updates every minute
- **History chart** (Medium: 2h sparkline, Large: 12h dual-line chart)
  - Dynamic Y-axis scaled to actual data range for clear visibility
  - Line breaks on gaps (e.g. after server restart)
  - History persists across server restarts (`~/.claude/widget-history.json`)

## Requirements

- macOS 14.0+
- Xcode with your Apple ID signed in (**Xcode → Settings → Accounts**)
- [claude-codex-usage-dashboard](https://github.com/frankchiu-dev/claude-codex-usage-dashboard) running locally on port 8787

## Setup

### 1. Install the dashboard server

Follow the instructions at [claude-codex-usage-dashboard](https://github.com/frankchiu-dev/claude-codex-usage-dashboard) to get the local server running at `http://localhost:8787`.

### 2. Clone this repo

```bash
git clone https://github.com/RogerYeeaah/claude-usage-widget.git
cd claude-usage-widget
```

### 3. Deploy

```bash
./deploy.sh
```

The script will:
1. Install `xcodegen` via Homebrew if needed
2. Generate the Xcode project
3. Build in Release configuration
4. Copy to `/Applications` and register the widget

> **First time only:** If the build fails due to signing, open Xcode, sign in with your Apple ID, then run `./deploy.sh` again.

### 4. Add to your desktop

1. Right-click the desktop → **Edit Widgets**
2. Search for **Claude**
3. Add the widget in Small, Medium, or Large size

## Updating

```bash
git pull && ./deploy.sh
```

## How it works

The widget fetches data from `http://127.0.0.1:8787/api/usage` and `http://127.0.0.1:8787/api/history` every minute. The dashboard server reads from `~/.claude/usage-cache.json`, which Claude Code maintains automatically. No network requests to Anthropic, no API keys needed.

History is accumulated by the server and saved to `~/.claude/widget-history.json` so it survives restarts.

## Notes

- Each person must build the widget with their own Apple ID — pre-built binaries can't be distributed without a paid Apple Developer account
- The history chart shows "Collecting history…" until enough data points accumulate
- Tested on macOS 26 with Xcode 26

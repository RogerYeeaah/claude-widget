# Claude Usage Widget

A native macOS WidgetKit widget that shows your [Claude Code](https://claude.ai/code) usage — 5-hour and weekly quota — directly on your desktop.

## Features

- **Small, Medium, Large** widget sizes
- Reset countdown per window (e.g. `resets in 2h 15m`)
- Color-coded usage: normal → orange at 70% → red at 85%
- Weekly quota uses blue to match the history chart
- Adaptive refresh: every 2 minutes when usage ≥ 80%, every 5 minutes otherwise
- Stale data indicator: timestamp turns orange when data is over 30 minutes old
- Shows "Server offline" (with server icon) when the app isn't reachable
- **History chart** (Medium: 4h sparkline, Large: 12h dual-line chart)
  - Dynamic Y-axis scaled to actual data range for clear visibility
  - Line breaks on gaps (e.g. after app restart)
  - History persists across restarts (`~/.claude/widget-history.json`)
- **Launch at login** toggle built into the app (no manual launchd setup)

## Requirements

- macOS 14.0+
- Xcode with your Apple ID signed in (**Xcode → Settings → Accounts**)

> No separate dashboard server needed — the HTTP server runs inside the app itself.

## Setup

### 1. Clone this repo

```bash
git clone https://github.com/RogerYeeaah/claude-widget.git
cd claude-widget
```

### 2. Deploy

```bash
./deploy.sh
```

The script will:
1. Install `xcodegen` via Homebrew if needed
2. Generate the Xcode project
3. Build in Release configuration
4. Copy to `/Applications` and register the widget

> **First time only:** If the build fails due to signing, open Xcode, sign in with your Apple ID, then run `./deploy.sh` again.

### 3. Enable launch at login

Open **ClaudeWidget** from `/Applications`, then toggle **開機自動啟動** in the app window. The widget will be available as long as the app is running.

### 4. Add to your desktop

1. Right-click the desktop → **Edit Widgets**
2. Search for **Claude**
3. Add the widget in Small, Medium, or Large size

## Updating

```bash
git pull && ./deploy.sh
```

## How it works

The app runs an embedded HTTP server on `http://127.0.0.1:8787`. The widget fetches `/api/usage` and `/api/history` from it on each refresh. The server reads `~/.claude/usage-cache.json`, which Claude Code maintains automatically. No network requests to Anthropic, no API keys needed.

History is accumulated in memory and saved to `~/.claude/widget-history.json` so it survives app restarts.

## Notes

- Each person must build the widget with their own Apple ID — pre-built binaries can't be distributed without a paid Apple Developer account
- The history chart shows "Collecting history…" until enough data points accumulate
- Tested on macOS 26 with Xcode 26

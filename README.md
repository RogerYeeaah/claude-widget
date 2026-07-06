# Claude Usage Widget

A native macOS WidgetKit widget that shows your [Claude Code](https://claude.ai/code) usage — 5-hour and weekly quota — directly on your desktop.

## Features

- **Small, Medium, Large** widget sizes
- Reset countdown per window (e.g. `resets in 2h 15m`)
- Color-coded usage: normal → orange at 70% → red at 85%
- Weekly quota uses blue to match the history chart
- Adaptive refresh: every 3 minutes when usage ≥ 90%, every 5 minutes otherwise
- Stale data indicator: timestamp turns orange when data is over 30 minutes old
- Shows "Server offline" (with server icon) when the app isn't reachable
- **History chart** (Medium: 4h sparkline, Large: 12h dual-line chart)
  - Dynamic Y-axis scaled to actual data range for clear visibility
  - Line breaks on gaps (e.g. after app restart)
  - History persists across restarts (`~/.claude/widget-history.json`)
- **Launch at login** toggle built into the app (no manual launchd setup)
- **Menu bar icon** — app minimizes to menu bar; icon changes to `↑` when an update is available
- **One-click updates** — right-click the menu bar icon → "Check for Updates" → "Install Update & Restart"
- **Pre-reset dimming** — in the Large widget, data before the 5-hour window reset is shown at low opacity so the current window stands out

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
5. Install the usage cache refresh hook into `~/.claude/`

> **First time only:** If the build fails due to signing, open Xcode, sign in with your Apple ID, then run `./deploy.sh` again.

### 3. Enable launch at login

Open **ClaudeWidget** from `/Applications`, then toggle **開機自動啟動** in the app window. The widget will be available as long as the app is running.

### 4. Add to your desktop

1. Right-click the desktop → **Edit Widgets**
2. Search for **Claude**
3. Add the widget in Small, Medium, or Large size

## Updating

Right-click the menu bar icon → **Check for Updates** → **Install Update & Restart** (auto git pull + redeploy).

Or manually:

```bash
git pull && ./deploy.sh
```

## How it works

The app runs an embedded HTTP server on `http://127.0.0.1:8787`. The widget fetches `/api/usage` and `/api/history` from it on each refresh. The server watches `~/.claude/usage-cache.json` with a file-system event source and pre-parses it on change; `/api/usage` responses are served from an in-memory cache (no disk read per request).

**Claude Code 2.1.196+** stopped writing this file automatically. The included `Stop` hook (`refresh-usage-cache.sh`) fills the gap: after each Claude Code response it makes a minimal API call, extracts the rate-limit headers, and writes them to the cache. The hook skips the API call if the cache is less than 10 minutes old.

History is accumulated in memory and flushed to `~/.claude/widget-history.json` every 5 minutes and on app quit, so it survives restarts.

## Notes

- Each person must build the widget with their own Apple ID — pre-built binaries can't be distributed without a paid Apple Developer account
- The history chart shows "Collecting history…" until enough data points accumulate
- Tested on macOS 26 with Xcode 26

<div align="right">
  <a href="README.zh-TW.md"><img src="https://img.shields.io/badge/繁體中文-README-blue?style=flat-square" alt="繁體中文"></a>
</div>

# Claude Usage Widget

A native macOS WidgetKit widget that shows your [Claude Code](https://claude.ai/code) usage — 5-hour and weekly quota — directly on your desktop.

## Features

- **Small, Medium, Large** widget sizes
- **Live reset countdown** per window — updates in real time and stops at zero (no counting up past the reset)
- Color-coded usage: normal → orange at 70% → red at 85%
- Weekly quota uses blue to match the history chart
- **Accessibility** — VoiceOver reads each quota as a single label, and a ⚠️ icon marks the near-limit state so the warning isn't conveyed by color alone; text scales with Dynamic Type
- **Push-based refresh** — the app reloads the widget the moment `usage-cache.json` changes; a fallback timeline refresh runs every 15 minutes (5 minutes when offline), staying well within WidgetKit's daily budget
- **Live age indicator** — data freshness text updates in real time; turns orange after 30 minutes
- **Tap to open** — clicking the widget launches and surfaces the app window
- Distinguishes two offline states: **「伺服器離線」** (Server offline — app unreachable) vs **「等待資料」** (Waiting for data — server up, no data yet)
- **History chart** (Medium: 4h sparkline, Large: 12h dual-line chart)
  - Dynamic Y-axis scaled to actual data range for clear visibility
  - Line breaks on gaps (e.g. after app restart)
  - Back-fills gaps for **both** the 5h and weekly lines, so the weekly line isn't blank while collecting history
  - History persists across restarts (`~/.claude/widget-history.json`)
- **App window shows live usage** — the companion window displays current 5h/weekly % with color coding, updated every 2 seconds
- **Widget gallery preview uses real data** — shows your actual usage instead of placeholder values
- **Launch at login** toggle built into the app (no manual launchd setup)
- **Menu bar icon** — app minimizes to menu bar; icon changes to `↑` when an update is available
- **One-click updates** — right-click the menu bar icon → **檢查更新** → **安裝更新並重啟** (asks for confirmation before pulling); also checks automatically on launch
- **Pre-reset dimming** — in the Large widget, data before the 5-hour window reset is shown at low opacity so the current window stands out

## Requirements

- macOS 26+
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

Right-click the menu bar icon → **檢查更新** → **安裝更新並重啟** (confirm, then auto git pull + redeploy).

Or manually:

```bash
git pull && ./deploy.sh
```

## How it works

The app runs an embedded HTTP server on `http://127.0.0.1:8787` (loopback only — traffic never leaves the machine). The widget fetches `/api/usage` and `/api/history` from it on each refresh. The server watches `~/.claude/usage-cache.json` with a file-system event source and pre-parses it on change; `/api/usage` responses are served from an in-memory cache (no disk read per request).

For safety, the server only answers requests whose `Host` header is loopback (`127.0.0.1:8787` / `localhost:8787`) and sends no CORS header, so no web page can read your usage data through the browser (blocks DNS-rebinding access).

**Claude Code 2.1.196+** stopped writing this file automatically. The included `Stop` hook (`refresh-usage-cache.sh`) fills the gap: after each Claude Code response it makes a minimal API call, extracts the rate-limit headers, and writes them to the cache. The hook skips the API call if the cache is less than 10 minutes old.

History is accumulated in memory and flushed to `~/.claude/widget-history.json` every 5 minutes and on app quit, so it survives restarts. When a sampling gap appears (app was closed, machine asleep), the server back-interpolates points for both the 5h and weekly series — carrying forward the last known weekly value — so neither line reads as zero while catching up.

## Notes

- Each person must build the widget with their own Apple ID — pre-built binaries can't be distributed without a paid Apple Developer account
- The history chart shows **收集紀錄中…** until enough data points accumulate
- Tested on macOS 26 (Tahoe) with Xcode 26

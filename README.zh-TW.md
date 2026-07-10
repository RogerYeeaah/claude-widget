<div align="right">
  <a href="README.md"><img src="https://img.shields.io/badge/English-README-blue?style=flat-square" alt="English"></a>
</div>

# Claude Usage Widget

在桌面直接顯示 [Claude Code](https://claude.ai/code) 用量（5 小時額度與每週額度）的原生 macOS WidgetKit 小工具。

## 功能特色

- **Small、Medium、Large** 三種尺寸
- **即時重置倒數** — 各窗口剩餘時間即時更新，到期停在 0（不會過了重置點還往上加）
- 用量顏色提示：正常 → 70% 轉橘色 → 85% 轉紅色
- 每週額度以藍色顯示，與歷史圖表一致
- **無障礙支援** — VoiceOver 將每個額度讀成單一標籤；接近上限時顯示 ⚠️ 圖示，警示不再只靠顏色；文字隨 Dynamic Type 縮放
- **推播式刷新** — `usage-cache.json` 一變動 App 就立即刷新 widget；另有保底刷新每 15 分鐘（離線時 5 分鐘），控制在 WidgetKit 每日刷新額度內
- **即時資料新鮮度** — 資料時間戳即時更新；超過 30 分鐘未更新顯示橘色
- **點擊開啟** — 點一下 widget 即啟動並帶出 App 視窗
- 區分兩種離線狀態：**「伺服器離線」**（App 無法連線）vs **「等待資料」**（Server 啟動中，尚未收到資料）
- **歷史圖表**（Medium：4 小時折線，Large：12 小時雙線圖）
  - Y 軸動態縮放至實際資料範圍，便於閱讀
  - 資料中斷時（如 App 重啟）自動斷線
  - 中斷區間會**同時回填** 5 小時與每週兩條線，收集紀錄時每週線不再是空白/0
  - 歷史記錄儲存至 `~/.claude/widget-history.json`，重啟不遺失
- **主視窗即時顯示用量** — 顯示目前 5h/每週用量 %，每 2 秒更新，顏色隨用量變化
- **Widget 選取預覽使用真實資料** — 桌面編輯小工具時顯示實際用量，而非假資料
- **開機自動啟動**切換開關，內建於 App（無需手動設定 launchd）
- **選單列圖示** — App 最小化至選單列；有更新時圖示變為 `↑`
- **一鍵更新** — 右鍵選單列圖示 →「檢查更新」→「安裝更新並重啟」（下載前會先跳出確認）；App 啟動時也會自動檢查
- **重置前淡化** — Large 尺寸中，5 小時窗口重置前的資料以低透明度顯示，讓當前窗口更清晰

## 系統需求

- macOS 26+
- 已登入 Apple ID 的 Xcode（**Xcode → Settings → Accounts**）

> 不需要額外的 dashboard 伺服器 — HTTP server 直接運行在 App 內部。

## 安裝步驟

### 1. Clone 此 repo

```bash
git clone https://github.com/RogerYeeaah/claude-widget.git
cd claude-widget
```

### 2. 部署

```bash
./deploy.sh
```

腳本會自動執行：
1. 若尚未安裝，透過 Homebrew 安裝 `xcodegen`
2. 產生 Xcode 專案
3. 以 Release 設定編譯
4. 複製到 `/Applications` 並註冊 widget
5. 將用量快取更新 hook 安裝至 `~/.claude/`

> **第一次執行：** 若因簽署失敗，請開啟 Xcode，登入 Apple ID 後再執行一次 `./deploy.sh`。

### 3. 設定開機自動啟動

從 `/Applications` 開啟 **ClaudeWidget**，在 App 視窗中開啟「**開機自動啟動**」即可。只要 App 在執行，widget 就會持續運作。

### 4. 加入桌面

1. 右鍵點擊桌面 → **編輯小工具**
2. 搜尋 **Claude**
3. 選擇 Small、Medium 或 Large 尺寸加入

## 更新方式

右鍵點擊選單列圖示 → **檢查更新** → **安裝更新並重啟**（確認後自動 git pull + 重新部署）。

或手動執行：

```bash
git pull && ./deploy.sh
```

## 運作原理

App 在 `http://127.0.0.1:8787` 啟動一個嵌入式 HTTP server（僅綁定 loopback，流量不離開本機）。Widget 每次刷新時從 `/api/usage` 和 `/api/history` 取得資料。Server 以檔案系統事件監聽 `~/.claude/usage-cache.json`，檔案變動時即時解析並快取；`/api/usage` 請求直接從記憶體快取回應（不需每次讀磁碟）。

為了安全，Server 僅回應 `Host` 為 loopback（`127.0.0.1:8787` / `localhost:8787`）的請求，且不送出 CORS header，因此任何網頁都無法透過瀏覽器讀取你的用量資料（可擋 DNS rebinding）。

**Claude Code 2.1.196+** 停止自動寫入此檔案。內附的 `Stop` hook（`refresh-usage-cache.sh`）彌補了這個缺口：每次 Claude Code 回應後，hook 會發送一個最小化的 API 請求，擷取 rate-limit header 並寫入快取。若快取不到 10 分鐘，則跳過 API 呼叫。

歷史記錄保留在記憶體中，每 5 分鐘及 App 退出時寫入 `~/.claude/widget-history.json`，確保重啟後不遺失。當出現取樣中斷（App 關閉、機器休眠）時，Server 會為 5 小時與每週兩條線回填內插點——每週採「沿用上一個已知值」——因此兩條線在補資料期間都不會顯示為 0。

## 注意事項

- 每位使用者需以自己的 Apple ID 自行編譯 — 沒有付費開發者帳號無法散布已編譯的二進位檔
- 歷史圖表在累積足夠資料點前會顯示「收集紀錄中…」
- 已在 macOS 26 (Tahoe) + Xcode 26 上測試

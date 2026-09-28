# Photo Libraries

## Project Overview

Photo Libraries 是 macOS 照片圖庫瀏覽器，讓使用者在同一個視窗查看系統照片圖庫與自行選取的 `.photoslibrary`，依日期、相簿和媒體類型瀏覽，並在明確確認後複製或搬移照片。程式會在自己的儲存空間建立搜尋索引與預覽資料；註冊圖庫的直接讀取、轉移與網頁分享有下述相容性及環境限制。

## Features 與狀態

- **Implemented（已接入）**：以 PhotoKit 瀏覽系統圖庫；以獲授權的圖庫套件建立非系統圖庫目錄；顯示相簿、縮圖、照片／影片、資訊面板、跨圖庫搜尋、地圖與由 metadata 產生的 Memories 建議。
- **Implemented（已接入）**：從系統圖庫複製到註冊圖庫，或從註冊圖庫複製到系統圖庫；搬移時另行核對目的地並要求使用者確認來源刪除。轉移並非交易式，亦不保證保留所有編輯歷史與複合媒體資源。
- **Optional；externally unverified**：Web Gallery 在設定了 `*.ts.net` Serve host、允許的 Tailscale login 及至少一個共享圖庫後，可於 app 啟動時嘗試啟動，也可由 Settings 手動啟停。它只監聽本機 `127.0.0.1:8766`；對外 HTTPS、身分標頭及可達性取決於另外設定的 Tailscale Serve。Apple Maps 網頁地圖另需可選的 MapKit JS token 與網路。
- **Experimental / inactive**：`PoC/` 的獨立探針不在 app target；`PhotosAutomationClient` 的舊式目錄／預覽索引流程仍在 source，但目前的 app 啟動流程改用直接讀取。不能把這些路徑當成已驗證的正常功能。

以上「已接入」是 source 狀態，**不表示本次已編譯或在裝置上成功執行**。實作細節見 [技術文件](TECHNICAL_DOCUMENTATION.md)。

## Requirements

- macOS app 與內嵌的 `PhotoLibrariesDirectHelper` target 均設定 `MACOSX_DEPLOYMENT_TARGET = 27.0`、`SUPPORTED_PLATFORMS = macosx`、`SWIFT_VERSION = 5.0`；沒有受支援的 iOS target。
- 使用可開啟 `Photo Libraries.xcodeproj`、具備對應 macOS SDK 的 Xcode。專案記錄建立工具版本 26.3，但**沒有宣告最低 Xcode 版本**；本次未驗證哪個 Xcode 版本可成功 build。
- Swift app/helper 使用 Apple 系統 frameworks 與 SQLite3；沒有 Swift Package Manager、CocoaPods 或其他已宣告的第三方 app 依賴，也沒有套件 lockfile。
- `Tools/generate_memory_music.py` 僅在重新產生已附帶的音樂資產時才需要 Python 3、NumPy 與 macOS `afconvert`；Python／NumPy 版本沒有固定，平常開啟 app 不需執行此工具。

## Installation / Setup

1. 取得 repository 後，在 root 執行 `open "Photo Libraries.xcodeproj"`，或從 Xcode 開啟該專案。
2. 在 Xcode 選擇 macOS app target `Photo Libraries` 的 runnable，使用 Debug 或 Release 組態。`PhotoLibrariesDirectHelper` 是 app target 的依賴及內嵌工具；repository 沒有獨立提交的 shared `.xcscheme` 檔，請以本機 Xcode 顯示的 scheme 為準。
3. 使用自己的開發者簽署設定。專案目前設為 Automatic signing 並含特定 development team；該值不是可攜的憑證或簽署保證。授權系統照片圖庫及選取 `.photoslibrary` 時，依 macOS 提示授予所需權限。
4. 若要使用 Web Gallery，在 app 的 **Settings → Web Gallery** 輸入自己的 `<your-mac>.ts.net` host（有非標準 HTTPS port 時連同 port）、允許的 Tailscale login，並選擇共享圖庫；Tailscale Serve 必須由使用者另外設定為代理本機 `127.0.0.1:8766`。不要將 Funnel 當作此功能的設定。網頁地圖的 MapKit JS token 為可選設定，請在同一畫面輸入自己的值。

Repository 沒有 `.env`、環境變數範例、API key 或憑證檔，也沒有依賴安裝步驟或可重現的 package-manager 指令。Web Gallery 設定與 Maps token 寫入 `UserDefaults`，不是環境變數或 Keychain。

## How to Run

在 Xcode 選 macOS app runnable 後，由你自行 Build／Run。程式在未設定 Web Gallery 時仍可進入本機瀏覽介面；實際圖庫內容、Photos 權限、非系統套件格式，以及某些可能需要下載的媒體，仍取決於所在 Mac。Web Gallery 對外模式需要 app 與 Mac 保持運作，且須另外配置 Tailscale Serve。Repository 沒有獨立 backend 或離線 demo fixture，也沒有可由已提交 shared scheme 證明的命令列 build/run 指令。

## Development

目前沒有提交的測試 target、CI、lint、format、typecheck 或 fixture-validation 指令。`PoC/` 程式不屬於正常 build；音樂生成工具的原始指令是 `python3 Tools/generate_memory_music.py`，它會重寫音樂資產，僅在有意重新生成時執行。本次僅做文件與 source 靜態核對，**沒有執行 macOS Build／Test**。

## Project Structure

| 路徑 | 用途 |
| --- | --- |
| `Photo Libraries/` | SwiftUI app、模型、圖庫註冊、PhotoKit、搜尋、Memories、視圖及 Web Gallery。 |
| `DirectLibraryHelper/` | 內嵌 helper 的入口、跨行程資料模型與 sandbox entitlement。 |
| `Photo Libraries.xcodeproj/` | Xcode targets、build settings 與專案設定。 |
| `PoC/` | 未接入 app target 的實驗探針。 |
| `Tools/` | 手動產生 Memories 音樂資產的工具。 |

## Known Limitations

非系統圖庫的媒體存取使用未公開 PhotoKit selector，目錄讀取依賴 Apple Photos 套件內部 SQLite schema；跨 macOS 版本的相容性、發佈／審核結果和真實圖庫行為均未由本次文件作業驗證。搜尋的系統圖庫文件不含 caption／keywords 全文；非系統圖庫的某些媒體類型篩選較少。地點名稱、網頁地圖、Tailscale 分享與遠端播放需要各自的系統或外部環境支援。轉移失敗或取消後可能留下已建立的目的地副本，請在重試或刪除來源前檢查兩個圖庫。

## License

Repository 沒有 project-wide `LICENSE` 或等效授權聲明；不能由此推定整個專案的授權。Apple frameworks、MapKit JS、NumPy 等外部元件各有自身條款，應與本專案授權分開確認。

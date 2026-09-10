# TW Stock News AI Monitor

TW Stock News AI Monitor 是一個使用 Flutter 開發的台股新聞AI監控工具。

程式會定期擷取台灣財經新聞，並透過 OpenAI 或 Gemini 進行 AI 分析，協助快速整理新聞重點、利多 / 利空方向、轉單、稀缺題材、受影響公司、風險與後續觀察。  
新聞著作權皆為原新聞來源所有，本程式僅串接AI對新聞內容進行整理與分析研究。

目前支援的新聞來源：

- 工商時報
- MoneyDJ 理財網「產業情報」

本專案採 **純本機架構**，不需要自行架設後端伺服器。

---

## 功能

- 定期檢查最新台股新聞
- 工商時報新聞監控
- MoneyDJ 產業情報監控
- OpenAI / Gemini AI 分析
- 利多、偏多、中性、偏空、利空判斷
- 新聞重點整理
- 轉單題材判斷
- 稀缺題材判斷
- 受影響公司與產業分析
- 風險與後續觀察
- 個別新聞重新分析
- 本機通知
- 本機保存新聞歷史
- 明亮 / 暗色 / 跟隨系統外觀
- 可完整清除已抓取的新聞資料

![image](https://github.com/user-attachments/assets/adc3fa22-2683-47f2-be2b-8c3ab18525e2)  
  
![image](https://github.com/user-attachments/assets/36e43dbd-12c2-4850-9741-e22038929d36)
---

# 1. 安裝開發環境

本專案主要使用 Flutter 開發。

目前 `pubspec.yaml` 的 Dart SDK 需求為：

```text
Dart >= 3.10.0 < 4.0.0
```

因此請安裝內含 **Dart 3.10 或更新版本**的 Flutter SDK。

## 1.1 安裝 Git

請先安裝 Git：

https://git-scm.com/

安裝完成後確認：

```powershell
git --version
```

---

## 1.2 安裝 VS Code（選用）

可使用 VS Code 作為開發工具：

https://code.visualstudio.com/

建議安裝 Extensions：

- Flutter
- Dart

---

## 1.3 安裝 Windows 編譯工具

若要建置 Windows Desktop 版本，需要安裝：

**Visual Studio 2022**

下載：

https://visualstudio.microsoft.com/

安裝時請勾選：

```text
Desktop development with C++
```

這個 Workload 會安裝 Flutter Windows Build 所需的 C++ Compiler、Windows SDK、CMake 等工具。

> 注意：Visual Studio 和 Visual Studio Code 是不同的產品。  
> 即使使用 VS Code 寫程式，Windows Flutter Build 仍需要 Visual Studio 的 C++ Build Tools。

---

## 1.4 安裝 Flutter SDK

Flutter 官方安裝文件：

https://docs.flutter.dev/get-started/install

---

## 1.5 檢查 Flutter 開發環境

執行：

```powershell
flutter doctor -v
```

Windows 開發環境正常時，至少應確認：

```text
Flutter
Windows Version
Visual Studio - develop Windows apps
```

沒有重要錯誤。

如果 Flutter 顯示缺少 Visual Studio C++ 工具，請重新開啟 Visual Studio Installer，確認已安裝：

```text
Desktop development with C++
```

---

# 2. 取得專案

使用 Git：

```powershell
git clone https://github.com/jordan5226/tw_stock_news_ai_monitor.git
cd tw_stock_news_ai_monitor
```

或從 GitHub 下載 ZIP 並解壓縮。

接著安裝 Flutter Packages：

```powershell
flutter pub get
```

---

# 3. 第一次建立 Windows 專案

如果 Repository 中已經存在：

```text
windows\
```

可以跳過這個步驟。

如果沒有 `windows/` 目錄，請在專案根目錄執行：

```powershell
flutter create --platforms=windows .
```

接著執行專案內附的：

```powershell
.\setup_windows_name.ps1
```

這個 Script 會將 Windows 原生專案名稱設定為：

```text
Project / Binary
tw_stock_news_ai_monitor

Application Name
TW Stock News AI Monitor

Executable
tw_stock_news_ai_monitor.exe
```

如果 PowerShell 因 Execution Policy 無法執行 Script，可改用：

```powershell
powershell -ExecutionPolicy Bypass -File .\setup_windows_name.ps1
```

最後重新取得 Packages：

```powershell
flutter pub get
```

---

# 4. 執行專案

先確認 Flutter 可以看到 Windows Desktop：

```powershell
flutter devices
```

正常情況應看到類似：

```text
Windows (desktop)
```

執行 Debug 版本：

```powershell
flutter run -d windows
```

第一次 Build 需要下載 / 編譯相關套件，因此可能需要較長時間。

---

# 5. 建置 Windows Release 版本

在專案根目錄執行：

```powershell
flutter clean
flutter pub get
flutter build windows --release
```

建置完成後，Release 版本通常位於：

```text
build\windows\x64\runner\Release\
```

主要執行檔：

```text
tw_stock_news_ai_monitor.exe
```

完整路徑：

```text
build\windows\x64\runner\Release\tw_stock_news_ai_monitor.exe
```

## 發布 Windows 版本時

不要只複製 `.exe`。

Flutter Windows App 執行時還會使用同一個 Release 目錄中的 DLL、Data 與 Plugin 檔案，因此發布時應保留整個：

```text
build\windows\x64\runner\Release\
```

資料夾內容。

例如可以將整個 `Release` 資料夾壓縮成 ZIP 再提供給其他使用者。

---

# 6. 常用開發指令

取得 Packages：

```powershell
flutter pub get
```

檢查程式：

```powershell
flutter analyze
```

執行 Windows：

```powershell
flutter run -d windows
```

清除 Build Cache：

```powershell
flutter clean
```

建立 Windows Release：

```powershell
flutter build windows --release
```

查看可用裝置：

```powershell
flutter devices
```

查看環境狀態：

```powershell
flutter doctor -v
```

---

# 7. AI API 設定

程式支援：

- OpenAI
- Google Gemini

啟動程式後進入右上角的「設定」，選擇 AI 供應商並輸入自己的 API Key。

API Key 不需要寫入 Source Code。

OpenAI 與 Gemini 的 Key 會分開保存。

## OpenAI

設定：

```text
AI 供應商：OpenAI
API Key：自己的 OpenAI API Key
Model：OpenAI Model
```

設定後可使用「測試 API」確認連線。

## Gemini

設定：

```text
AI 供應商：Gemini
API Key：自己的 Gemini API Key
Model：Gemini Model
```

設定後同樣可使用「測試 API」確認連線。

> API 使用量、費用與額度由各 AI Provider 帳號決定。

---

# 8. 專案結構

主要檔案：

```text
tw_stock_news_ai_monitor/
│
├─ lib/
│  └─ main.dart
│
├─ platform_setup/
│  ├─ AndroidManifest_additions.xml
│  ├─ AppDelegate.swift
│  └─ InfoPlist_additions.xml
│
├─ pubspec.yaml
├─ analysis_options.yaml
├─ setup_windows_name.ps1
└─ README.md
```

其中主要程式目前集中在：

```text
lib/main.dart
```

---

# 9. 平台說明

目前專案主要以 **Windows Desktop** 進行開發與測試。

Flutter 架構亦可延伸到：

- Android
- iOS
- macOS

但不同平台需要額外的原生設定。

`platform_setup/` 中保留部分 Android / iOS 所需設定範例。

---

# 10. 背景監控限制

本專案沒有後端伺服器。

Windows 版本只要程式保持執行，即可持續進行前景新聞監控。

如果程式完全關閉：

```text
新聞監控也會停止
```

Android / iOS 的 Background Task 則會受到作業系統排程與省電機制限制，無法保證固定每分鐘執行。

---

# 11. 注意事項

新聞網站若修改 HTML 結構，可能需要更新對應的 Scraper。

目前新聞來源包含：

```text
工商時報
MoneyDJ 產業情報
```

AI 分析結果僅供資訊整理與研究用途，不代表投資建議。

---

## Project Name

```text
tw_stock_news_ai_monitor
```

## Application Name

```text
TW Stock News AI Monitor
```

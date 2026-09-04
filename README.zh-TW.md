<div align="center">

# WireProxy-install

專為 Linux 伺服器設計的 [WireProxy](https://github.com/windtf/wireproxy) 自動化安裝與多實例管理腳本。

[English](README.md) • [简体中文](README.zh-CN.md) • **繁體中文**

</div>

---

它能將您現有的 WireGuard 設定檔無縫轉換為純使用者態運行的輕量級 **SOCKS5 與 HTTP 代理實例**。所有代理連接埠**嚴格僅監聽於 `127.0.0.1`（本地環回介面）**，從物理層面杜絕外部網路掃描與連線，確保伺服器安全。

## 功能特性

- **嚴格本機隔離**：SOCKS5 與 HTTP 連接埠強制僅監聽 `127.0.0.1`，外部機器完全無法連入。
- **多實例架構**：基於 systemd 範本單元（`wireproxy@<name>.service`），每個 WireGuard 設定獨立運行、獨立監控、支援開機自啟與崩潰自動重啟。
- **純使用者態無污染**：基於 gVisor netstack 虛擬網路棧，無需核心驅動，不新增系統網卡，不修改系統路由表，不影響伺服器既有網路。
- **智慧連接埠防衝突**：自動偵測本機已佔用連接埠，智慧推薦可用連接埠（預設 SOCKS5 由 `10808` 起，HTTP 由 `18080` 起）。
- **內建設定校驗**：服務啟動前自動執行 `wireproxy --configtest` 進行語法校驗，避免設定錯誤。
- **互動選單與 CLI 雙支援**：具備友善的終端互動選單，亦完整支援命令列參數，方便自動化腳本調用。
- **Systemd 安全加固**：服務設定已啟用安全沙箱（`ProtectSystem=full`、`ProtectHome=true`、`NoNewPrivileges=true`）。

---

## 快速開始

### 1. 下載並運行

在 Linux 伺服器上使用 root 權限下載並執行：

```bash
curl -fsSL https://raw.githubusercontent.com/DuolaD/WireProxy-install/main/wireproxy.sh -o wireproxy.sh
chmod +x wireproxy.sh
sudo ./wireproxy.sh
```

*(亦可複製/克隆本儲存庫後直接執行 `./wireproxy.sh`)*

### 2. 互動式選單

直接執行 `./wireproxy.sh` 將啟動終端互動選單：

```text
======================================================
       WireProxy Linux Multi-Instance Manager        
       Version: 1.0.0 | Bound: 127.0.0.1 (Local Only)     
======================================================
 1) Install / Update WireProxy Binary
 2) Add New Instance from WireGuard Config
 3) List All Instances & Status
 4) Test Instance Proxy Connectivity
 5) Restart an Instance
 6) Stop an Instance
 7) Start an Instance
 8) View Instance Logs
 9) Remove an Instance
 10) Uninstall WireProxy & All Instances
 0) Exit
======================================================
```

---

## 命令列（CLI）自動化用法

您亦可直接透過命令列參數執行各項操作，適合批次或腳本自動化部署：

### 安裝/更新 WireProxy
```bash
sudo ./wireproxy.sh install
```

### 新增實例
指定實例名稱與本機既有的 WireGuard 設定檔路徑：

```bash
# 自動分配可用本機連接埠
sudo ./wireproxy.sh add --name proxy1 --wg-conf /etc/wireguard/wg0.conf

# 或自訂連接埠與帳密認證資訊
sudo ./wireproxy.sh add \
  --name us_vpn \
  --wg-conf /path/to/us-server.conf \
  --socks5-port 10808 \
  --http-port 18080 \
  --socks5-user myuser \
  --socks5-pass mysecretpassword
```

### 列出所有實例狀態
```bash
sudo ./wireproxy.sh list
```
輸出範例：
```text
Configured WireProxy Instances:
NAME               STATUS                SOCKS5 (127.0.0.1)   HTTP (127.0.0.1)     UPTIME    
-----------------------------------------------------------------------------------
proxy1             active                127.0.0.1:10808      127.0.0.1:18080      10 min
us_vpn             active                127.0.0.1:10810      127.0.0.1:18082      2 hours
```

### 測試代理連線狀態
透過 `curl` 測試該實例的對外出口 IP：
```bash
sudo ./wireproxy.sh test proxy1
```

### 服務啟停與管理
```bash
# 啟動 / 停止 / 重啟
sudo ./wireproxy.sh start proxy1
sudo ./wireproxy.sh stop proxy1
sudo ./wireproxy.sh restart proxy1

# 查看運作狀態與即時日誌
sudo ./wireproxy.sh status proxy1
sudo ./wireproxy.sh logs proxy1
```

### 刪除實例
停止服務並清理對應的設定檔案：
```bash
sudo ./wireproxy.sh remove proxy1
```

### 徹底解除安裝
停止所有實例，移除 systemd 範本單元與執行檔：
```bash
sudo ./wireproxy.sh uninstall
```

---

## 本機使用代理範例

因代理僅監聽於 `127.0.0.1`，可於本機應用程式中直接調用：

### Curl
```bash
# SOCKS5 代理（由代理端遠端解析 DNS）
curl -x socks5h://127.0.0.1:10808 https://api.ipify.org

# HTTP 代理
curl -x http://127.0.0.1:18080 https://api.ipify.org
```

### 環境變數
```bash
export HTTP_PROXY="http://127.0.0.1:18080"
export HTTPS_PROXY="http://127.0.0.1:18080"
export ALL_PROXY="socks5h://127.0.0.1:10808"
```

### Python
```python
import requests

proxies = {
    'http': 'socks5h://127.0.0.1:10808',
    'https': 'socks5h://127.0.0.1:10808'
}
resp = requests.get('https://api.ipify.org', proxies=proxies)
print(resp.text)
```

---

## 目錄與檔案結構

```text
/usr/local/bin/wireproxy              # WireProxy 執行檔 (Executable binary)
/etc/systemd/system/wireproxy@.service # Systemd 範本服務單元 (Template unit)
/etc/wireproxy/                       # 設定檔目錄 (Config directory, chmod 700)
  ├── <name>.conf                     # WireProxy 實例設定 (Instance config, chmod 600)
  └── <name>.wg.conf                  # 隔離副本之 WG 設定 (Isolated WG config, chmod 600)
```

---

## 授權協議

本專案採用 [MIT 授權條款](LICENSE)。  
WireProxy 採用 [ISC 授權條款](https://github.com/windtf/wireproxy/blob/main/LICENSE)。

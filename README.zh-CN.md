<div align="center">

# WireProxy-install

专为 Linux 服务器设计的 [WireProxy](https://github.com/windtf/wireproxy) 自动化安装与多实例管理脚本。

[English](README.md) • **简体中文** • [繁體中文](README.zh-TW.md)

</div>

---

它可以将你现有的 WireGuard 配置文件无缝转换为纯用户态运行的轻量级 **SOCKS5 和 HTTP 代理实例**。所有代理端口**严格仅监听在 `127.0.0.1`（本地环回接口）**，从物理上杜绝外部网络扫描和连接，保障服务器安全。

## 功能特性

- **严格本地隔离**：SOCKS5 和 HTTP 端口强制仅监听 `127.0.0.1`，外部机器完全无法访问。
- **多实例架构**：基于 systemd 模板单元（`wireproxy@<name>.service`），每个 WireGuard 配置独立运行、独立监控、支持开机自启与崩溃自愈。
- **纯用户态无污染**：基于 gVisor netstack 虚拟网络栈，不需要内核驱动，不新建系统网卡，不修改系统路由表，不影响服务器原有网络。
- **智能端口防冲突**：自动检测本地已占用端口，智能推荐可用端口（默认 SOCKS5 从 `10808` 起，HTTP 从 `18080` 起）。
- **内置配置校验**：服务启动前自动执行 `wireproxy --configtest` 进行语法校验，防止配置错误。
- **交互菜单与 CLI 双支持**：既有易用的终端交互菜单，又支持完整的命令行参数，方便脚本自动化集成。
- **Systemd 安全加固**：服务配置已开启安全沙箱（`ProtectSystem=full`、`ProtectHome=true`、`NoNewPrivileges=true`）。

---

## 快速开始

### 1. 下载并运行

#### 普通用户（推荐） / Normal User

直接从 GitHub Releases 下载并运行最新稳定发行版：

```bash
bash <(wget -qO- https://github.com/DuolaD/WireProxy-install/releases/latest/download/wireproxy.sh)
```

或者：

```bash
bash <(curl -Ls https://github.com/DuolaD/WireProxy-install/releases/latest/download/wireproxy.sh)
```

#### 开发用途 / Development

直接从 GitHub 仓库源码区主分支获取最新开发版：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/DuolaD/WireProxy-install/main/wireproxy.sh)
```

或者：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/DuolaD/WireProxy-install/main/wireproxy.sh)
```

*(亦可下载保存到本地或克隆本仓库后执行：`chmod +x wireproxy.sh && sudo ./wireproxy.sh`)*

### 2. 交互式菜单

直接运行 `./wireproxy.sh` 将唤起终端交互菜单：

```text
==========================================================================
                  WireProxy Linux Multi-Instance Manager        
   Version: 1.0.0 | Author: 哆啦D夢|DuolaD | Bound: 127.0.0.1 (Local Only)
==========================================================================
 WireProxy Status : Installed (v1.1.3)
 Configured Insts : 2 total
--------------------------------------------------------------------------
   NAME            STATUS       SOCKS5 PROXY           HTTP PROXY            
   ---------------------------------------------------------------------
   wg0             active       127.0.0.1:10808        127.0.0.1:18080       
   us_vpn          active       127.0.0.1:10810        127.0.0.1:18082       
==========================================================================
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
==========================================================================
```

---

## 命令行（CLI）自动化用法

你也可以直接使用命令行参数快速执行操作，适合脚本自动化调用：

### 安装/更新 WireProxy
```bash
sudo ./wireproxy.sh install
```

### 创建新实例
指定实例名称和本地已有的 WireGuard 配置文件路径：

```bash
# 自动分配可用本地端口
sudo ./wireproxy.sh add --name proxy1 --wg-conf /etc/wireguard/wg0.conf

# 或指定自定义端口与认证信息
sudo ./wireproxy.sh add \
  --name us_vpn \
  --wg-conf /path/to/us-server.conf \
  --socks5-port 10808 \
  --http-port 18080 \
  --socks5-user myuser \
  --socks5-pass mysecretpassword
```

### 列出所有实例状态
```bash
sudo ./wireproxy.sh list
```
输出示例：
```text
Configured WireProxy Instances:
NAME               STATUS                SOCKS5 (127.0.0.1)   HTTP (127.0.0.1)     UPTIME    
-----------------------------------------------------------------------------------
proxy1             active                127.0.0.1:10808      127.0.0.1:18080      10 min
us_vpn             active                127.0.0.1:10810      127.0.0.1:18082      2 hours
```

### 测试代理连通性
通过 `curl` 测试该实例的实际出口 IP：
```bash
sudo ./wireproxy.sh test proxy1
```

### 服务启停与管理
```bash
# 启动 / 停止 / 重启
sudo ./wireproxy.sh start proxy1
sudo ./wireproxy.sh stop proxy1
sudo ./wireproxy.sh restart proxy1

# 查看运行状态与实时日志
sudo ./wireproxy.sh status proxy1
sudo ./wireproxy.sh logs proxy1
```

### 删除实例
停止服务并清除对应的配置文件：
```bash
sudo ./wireproxy.sh remove proxy1
```

> [!TIP]
> **交互选择**：执行 `test`、`start`、`stop`、`restart`、`status`、`logs`、`remove` 时，若未在命令行指定实例名（例如直接执行 `sudo ./wireproxy.sh restart`），脚本会自动列出所有已配置实例及其运行状态与端口，供你通过输入数字序号或名称快捷选择。


### 彻底卸载
停止所有实例，删除 systemd 模板单元及二进制文件：
```bash
sudo ./wireproxy.sh uninstall
```

---

## 本地使用代理示例

由于代理仅监听在 `127.0.0.1`，可在本机应用中直接调用：

### Curl
```bash
# SOCKS5 代理（使用代理端远端解析 DNS）
curl -x socks5h://127.0.0.1:10808 https://api.ipify.org

# HTTP 代理
curl -x http://127.0.0.1:18080 https://api.ipify.org
```

### 环境变量
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

## 目录与文件结构

```text
/usr/local/bin/wireproxy              # WireProxy 可执行文件
/etc/systemd/system/wireproxy@.service # Systemd 模板服务单元
/etc/wireproxy/                       # 配置文件目录 (权限 700)
  ├── <name>.conf                     # WireProxy 实例配置 (权限 600)
  └── <name>.wg.conf                  # 隔离副本的 WG 配置 (权限 600)
```

---

## 开源协议

本项目采用 [MIT 许可证](LICENSE)。  
WireProxy 采用 [ISC 许可证](https://github.com/windtf/wireproxy/blob/main/LICENSE)。

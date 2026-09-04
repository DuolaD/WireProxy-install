<div align="center">

# WireProxy-install

An automated installer and multi-instance manager for [WireProxy](https://github.com/windtf/wireproxy) on Linux servers.

**English** • [简体中文](README.zh-CN.md) • [繁體中文](README.zh-TW.md)

</div>

---

It turns WireGuard configuration files into lightweight, isolated **SOCKS5 and HTTP proxy instances** running in pure userspace. All proxies are **strictly bound to `127.0.0.1` (loopback only)**, guaranteeing that external machines cannot access or scan your proxy ports.

## Features

- **Strict Local Isolation**: All SOCKS5 and HTTP ports listen exclusively on `127.0.0.1`, preventing external exposure.
- **Multi-Instance Architecture**: Run multiple WireGuard proxies concurrently, each supervised independently via systemd template units (`wireproxy@<name>.service`).
- **Zero Kernel Pollution**: Runs in userspace with `netstack` (gVisor). No root network drivers, no `wg-quick` routing overrides, and no disruption to host traffic.
- **Auto Port Allocation**: Automatically detects and suggests unused local ports for both SOCKS5 and HTTP.
- **Built-in Config Validation**: Validates syntax before activating services (`wireproxy --configtest`).
- **Interactive & Automation Ready**: Full-featured interactive terminal menu or non-interactive CLI flags for scripting and CI/CD.
- **Systemd Hardening**: Services include auto-restart, resource limits, and system protection sandboxing (`ProtectSystem=full`, `ProtectHome=true`, `NoNewPrivileges=true`).

---

## Quick Start

### 1. Download and Run

On your Linux server, download and run the script with root privileges:

```bash
curl -fsSL https://raw.githubusercontent.com/DuolaD/WireProxy-install/main/wireproxy.sh -o wireproxy.sh
chmod +x wireproxy.sh
sudo ./wireproxy.sh
```

*(Alternatively, clone this repository and run `./wireproxy.sh` directly)*

### 2. Interactive Menu

Running `./wireproxy.sh` without arguments launches an interactive interface:

```text
==========================================================================
                 WireProxy Linux Multi-Instance Manager        
             Version: 1.0.0 | Bound: 127.0.0.1 (Local Only)     
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

## CLI & Automation Usage

You can also use command-line arguments to automate deployments without interactive prompts:

### Install WireProxy
```bash
sudo ./wireproxy.sh install
```

### Add a New Instance
Specify an instance name and the path to your existing WireGuard configuration file:

```bash
# Auto-assign available local ports
sudo ./wireproxy.sh add --name proxy1 --wg-conf /etc/wireguard/wg0.conf

# Or specify custom ports and optional authentication
sudo ./wireproxy.sh add \
  --name us_vpn \
  --wg-conf /path/to/us-server.conf \
  --socks5-port 10808 \
  --http-port 18080 \
  --socks5-user myuser \
  --socks5-pass mysecretpassword
```

### List All Instances
```bash
sudo ./wireproxy.sh list
```
Output:
```text
Configured WireProxy Instances:
NAME               STATUS                SOCKS5 (127.0.0.1)   HTTP (127.0.0.1)     UPTIME    
-----------------------------------------------------------------------------------
proxy1             active                127.0.0.1:10808      127.0.0.1:18080      10 min
us_vpn             active                127.0.0.1:10810      127.0.0.1:18082      2 hours
```

### Test Proxy Connectivity
Runs a fast exit IP verification using `curl`:
```bash
sudo ./wireproxy.sh test proxy1
```

### Manage Services
```bash
# Start / Stop / Restart
sudo ./wireproxy.sh start proxy1
sudo ./wireproxy.sh stop proxy1
sudo ./wireproxy.sh restart proxy1

# Service status & real-time logs
sudo ./wireproxy.sh status proxy1
sudo ./wireproxy.sh logs proxy1
```

### Remove an Instance
Stops the service, disables autostart, and cleans up configuration files:
```bash
sudo ./wireproxy.sh remove proxy1
```

### Complete Uninstall
Stops all instances, removes systemd units and binary:
```bash
sudo ./wireproxy.sh uninstall
```

---

## Using the Local Proxies

Since the proxies listen strictly on `127.0.0.1`, you can consume them locally from any tool:

### Curl
```bash
# SOCKS5 (with remote DNS resolution)
curl -x socks5h://127.0.0.1:10808 https://api.ipify.org

# HTTP Proxy
curl -x http://127.0.0.1:18080 https://api.ipify.org
```

### Environment Variables
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

## Directory & File Structure

```text
/usr/local/bin/wireproxy              # WireProxy executable binary
/etc/systemd/system/wireproxy@.service # Systemd template unit
/etc/wireproxy/                       # Config directory (chmod 700)
  ├── <name>.conf                     # WireProxy instance configuration (chmod 600)
  └── <name>.wg.conf                  # Isolated copy of WireGuard config (chmod 600)
```

---

## License

This project is licensed under the [MIT License](LICENSE).  
WireProxy is licensed under the [ISC License](https://github.com/windtf/wireproxy/blob/main/LICENSE).

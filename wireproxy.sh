#!/usr/bin/env bash
# ==============================================================================
# WireProxy One-Click Installer & Multi-Instance Manager for Linux
# Author: 哆啦D夢|DuolaD
# Repository: https://github.com/DuolaD/WireProxy-install
#
# Features:
#   - Automated installation/update of WireProxy binary from GitHub releases
#   - Multi-instance management powered by systemd template units
#   - Creates isolated local-only SOCKS5 & HTTP proxies bound to 127.0.0.1
#   - Interactive menu and complete CLI support for automated deployments
# ==============================================================================

set -o pipefail

# ----------------------------- Global Settings --------------------------------
SCRIPT_VERSION="1.0.0"
SCRIPT_AUTHOR="哆啦D夢|DuolaD"
GITHUB_REPO="windtf/wireproxy"
INSTALL_BIN="/usr/local/bin/wireproxy"
CONF_DIR="/etc/wireproxy"
SYSTEMD_TEMPLATE="/etc/systemd/system/wireproxy@.service"

DEFAULT_SOCKS5_BASE=10808
DEFAULT_HTTP_BASE=18080

# Color codes
COLOR_RESET="\033[0m"
COLOR_RED="\033[1;31m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_BLUE="\033[1;34m"
COLOR_CYAN="\033[1;36m"
COLOR_BOLD="\033[1m"

# ----------------------------- Logging Helpers --------------------------------
log_info() {
    echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} $*"
}

log_ok() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $*"
}

log_warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"
}

log_err() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

# ----------------------------- Pre-flight Checks ------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "This script must be run as root or with sudo."
        exit 1
    fi
}

check_dependencies() {
    local missing_deps=()
    for cmd in curl tar grep awk sed systemctl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_warn "Missing required commands: ${missing_deps[*]}"
        log_info "Attempting to install missing dependencies..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq "${missing_deps[@]}"
        elif command -v dnf &>/dev/null; then
            dnf install -y -q "${missing_deps[@]}"
        elif command -v yum &>/dev/null; then
            yum install -y -q "${missing_deps[@]}"
        elif command -v pacman &>/dev/null; then
            pacman -Sy --noconfirm "${missing_deps[@]}"
        elif command -v apk &>/dev/null; then
            apk add --no-cache "${missing_deps[@]}"
        else
            log_err "Package manager not detected. Please install: ${missing_deps[*]}"
            exit 1
        fi
    fi
}

detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7*|armhf)
            echo "arm"
            ;;
        i386|i686)
            echo "386"
            ;;
        mips64)
            echo "mips64"
            ;;
        mips64el|mips64le)
            echo "mips64le"
            ;;
        mips)
            echo "mips"
            ;;
        mipsel|mipsle)
            echo "mipsle"
            ;;
        *)
            log_err "Unsupported CPU architecture: $arch"
            exit 1
            ;;
    esac
}

# ----------------------------- Port Helpers -----------------------------------
is_port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tuln 2>/dev/null | grep -qE "(:|\])${port}\b"
    elif command -v netstat &>/dev/null; then
        netstat -tuln 2>/dev/null | grep -qE "(:|\])${port}\b"
    elif command -v lsof &>/dev/null; then
        lsof -iTCP:"$port" -sTCP:LISTEN -P -n &>/dev/null
    else
        # Fallback using /dev/tcp if available
        (echo > /dev/tcp/127.0.0.1/"$port") &>/dev/null
    fi
}

find_next_available_port() {
    local start_port="$1"
    local port="$start_port"
    while is_port_in_use "$port"; do
        ((port++))
        if [[ $port -ge 65535 ]]; then
            log_err "No available port found above $start_port."
            exit 1
        fi
    done
    echo "$port"
}

# ----------------------------- Core Installation ------------------------------
install_systemd_template() {
    log_info "Configuring systemd template: ${SYSTEMD_TEMPLATE}..."
    cat > "$SYSTEMD_TEMPLATE" << 'EOF'
[Unit]
Description=WireProxy Userspace WireGuard Proxy Instance (%i)
Documentation=https://github.com/windtf/wireproxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wireproxy --config /etc/wireproxy/%i.conf
Restart=always
RestartSec=5s
LimitNOFILE=65536

# Security Hardening
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

install_wireproxy_binary() {
    check_root
    check_dependencies

    local arch
    arch="$(detect_arch)"
    log_info "Detected architecture: $arch"

    # Fetch latest release tag or asset URL
    log_info "Checking latest release from GitHub (${GITHUB_REPO})..."
    local release_url=""
    local tag=""
    
    # Try fetching latest release info from API
    local api_response
    api_response="$(curl -sSL -H "Accept: application/vnd.github.v3+json" "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null || true)"
    tag="$(echo "$api_response" | grep -m1 '"tag_name":' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/' || true)"

    if [[ -n "$tag" ]]; then
        release_url="https://github.com/${GITHUB_REPO}/releases/download/${tag}/wireproxy_linux_${arch}.tar.gz"
        log_info "Found latest release: ${tag}"
    else
        # Direct fallback URL if GitHub API rate-limited
        release_url="https://github.com/${GITHUB_REPO}/releases/latest/download/wireproxy_linux_${arch}.tar.gz"
        log_warn "GitHub API rate-limited or unavailable. Using direct latest download URL."
    fi

    log_info "Downloading: ${release_url}..."
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local archive_path="${tmp_dir}/wireproxy.tar.gz"

    if ! curl -fsSL "$release_url" -o "$archive_path"; then
        log_err "Failed to download WireProxy archive from: $release_url"
        rm -rf "$tmp_dir"
        exit 1
    fi

    log_info "Extracting WireProxy..."
    if ! tar -xzf "$archive_path" -C "$tmp_dir"; then
        log_err "Failed to extract WireProxy archive."
        rm -rf "$tmp_dir"
        exit 1
    fi

    local extracted_bin="${tmp_dir}/wireproxy"
    if [[ ! -f "$extracted_bin" ]]; then
        # Search if placed inside a subdir
        extracted_bin="$(find "$tmp_dir" -type f -name "wireproxy" | head -n 1)"
    fi

    if [[ ! -f "$extracted_bin" ]]; then
        log_err "Could not find 'wireproxy' binary in downloaded archive."
        rm -rf "$tmp_dir"
        exit 1
    fi

    # Install binary
    mkdir -p "$(dirname "$INSTALL_BIN")"
    mv "$extracted_bin" "$INSTALL_BIN"
    chmod 755 "$INSTALL_BIN"
    rm -rf "$tmp_dir"

    # Create config directory with secure permissions
    mkdir -p "$CONF_DIR"
    chmod 700 "$CONF_DIR"

    # Install systemd template
    install_systemd_template

    local ver_info
    ver_info="$("$INSTALL_BIN" --version 2>&1 || true)"
    log_ok "WireProxy successfully installed at ${INSTALL_BIN}"
    if [[ -n "$ver_info" ]]; then
        log_info "$ver_info"
    fi
}

get_wireproxy_version() {
    local bin_path="$INSTALL_BIN"
    if [[ ! -x "$bin_path" ]] && command -v wireproxy &>/dev/null; then
        bin_path="$(command -v wireproxy)"
    fi

    if [[ -x "$bin_path" ]]; then
        local ver_output
        ver_output="$("$bin_path" --version 2>&1 || true)"
        echo "$ver_output" | grep -ioE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?(-[a-zA-Z0-9.]+)?' | head -n 1 || true
    fi
}

get_instance_port() {
    local conf="$1"
    local section="$2"
    awk -v sec="$section" '
        BEGIN { in_sec=0 }
        /^\[.*\]/ {
            curr = tolower($0)
            gsub(/[][ \t\r]/, "", curr)
            if (curr == tolower(sec)) {
                in_sec = 1
            } else {
                in_sec = 0
            }
            next
        }
        in_sec && /^[ \t]*[Bb][Ii][Nn][Dd][Aa][Dd][Dd][Rr][Ee][Ss][Ss][ \t]*=/ {
            sub(/^[^=]*=[ \t]*/, "")
            sub(/[#;].*$/, "")
            gsub(/[ \t\r\n]/, "")
            print $0
            exit
        }
    ' "$conf" 2>/dev/null
}

format_endpoint() {
    local ep="$1"
    if [[ -z "$ep" || "$ep" == "-" ]]; then
        echo "-"
    elif [[ "$ep" =~ ^[0-9]+$ ]]; then
        echo "127.0.0.1:${ep}"
    elif [[ "$ep" =~ ^:[0-9]+$ ]]; then
        echo "127.0.0.1${ep}"
    else
        echo "$ep"
    fi
}

# ----------------------------- Instance Management ----------------------------
sanitize_name() {
    local raw_name="$1"
    echo "$raw_name" | sed 's/[^a-zA-Z0-9_-]//g'
}

validate_wg_config() {
    local conf_file="$1"
    if [[ ! -f "$conf_file" ]]; then
        log_err "WireGuard config file not found: $conf_file"
        return 1
    fi

    if ! grep -qiE '^\s*\[Interface\]' "$conf_file"; then
        log_err "Invalid WireGuard config: missing [Interface] section in $conf_file"
        return 1
    fi

    if ! grep -qiE '^\s*PrivateKey' "$conf_file"; then
        log_err "Invalid WireGuard config: missing PrivateKey in $conf_file"
        return 1
    fi

    if ! grep -qiE '^\s*\[Peer\]' "$conf_file"; then
        log_err "Invalid WireGuard config: missing [Peer] section in $conf_file"
        return 1
    fi

    return 0
}

add_instance() {
    check_root

    if [[ ! -x "$INSTALL_BIN" ]]; then
        log_warn "WireProxy binary not found. Installing first..."
        install_wireproxy_binary
    fi

    local name="$1"
    local wg_conf="$2"
    local socks5_port="$3"
    local http_port="$4"
    local socks5_user="$5"
    local socks5_pass="$6"
    local http_user="$7"
    local http_pass="$8"

    # Instance Name
    local inst_conf=""
    local inst_wg=""
    while true; do
        if [[ -z "$name" ]]; then
            echo -en "${COLOR_BOLD}Enter instance name (e.g. wg0, proxy1, us_vpn): ${COLOR_RESET}"
            read -r input_name
            if [[ "$input_name" == "q" || "$input_name" == "Q" || "$input_name" == "exit" ]]; then
                log_info "Operation cancelled."
                return 1
            fi
            name="$(sanitize_name "$input_name")"
        else
            name="$(sanitize_name "$name")"
        fi

        if [[ -z "$name" ]]; then
            log_err "Instance name cannot be empty."
            if [[ ! -t 0 ]]; then
                return 1
            fi
            log_warn "Please enter a valid instance name."
            name=""
            continue
        fi

        inst_conf="${CONF_DIR}/${name}.conf"
        inst_wg="${CONF_DIR}/${name}.wg.conf"

        if [[ -f "$inst_conf" ]]; then
            log_err "Instance '${name}' already exists! Choose another name or remove it first."
            if [[ ! -t 0 ]]; then
                return 1
            fi
            log_warn "Please choose a different name."
            name=""
            continue
        fi

        break
    done

    # WireGuard Configuration File
    while true; do
        if [[ -z "$wg_conf" ]]; then
            echo -en "${COLOR_BOLD}Enter full path to local WireGuard .conf file: ${COLOR_RESET}"
            read -r wg_conf
        fi

        # Allow user to abort
        if [[ "$wg_conf" == "q" || "$wg_conf" == "Q" || "$wg_conf" == "exit" ]]; then
            log_info "Operation cancelled."
            return 1
        fi

        # Strip surrounding quotes if pasted
        wg_conf="${wg_conf#\"}"
        wg_conf="${wg_conf%\"}"
        wg_conf="${wg_conf#\'}"
        wg_conf="${wg_conf%\'}"

        if [[ -z "$wg_conf" ]]; then
            log_warn "File path cannot be empty. Please try again."
            if [[ ! -t 0 ]]; then
                return 1
            fi
            continue
        fi

        # Expand tilde and resolve absolute path
        local expanded_wg="${wg_conf/#\~/$HOME}"
        local resolved_wg
        resolved_wg="$(realpath "$expanded_wg" 2>/dev/null || readlink -f "$expanded_wg" 2>/dev/null || echo "$expanded_wg")"

        if validate_wg_config "$resolved_wg"; then
            wg_conf="$resolved_wg"
            break
        fi

        if [[ ! -t 0 ]]; then
            return 1
        fi

        log_warn "Please check the file path and try again (or enter 'q' to cancel)."
        wg_conf=""
    done

    # SOCKS5 Port
    while true; do
        local suggested_socks5
        suggested_socks5="$(find_next_available_port "$DEFAULT_SOCKS5_BASE")"

        if [[ -z "$socks5_port" ]]; then
            echo -en "${COLOR_BOLD}Enter SOCKS5 port (bound to 127.0.0.1) [default: ${suggested_socks5}]: ${COLOR_RESET}"
            read -r input_socks5
            if [[ "$input_socks5" == "q" || "$input_socks5" == "Q" || "$input_socks5" == "exit" ]]; then
                log_info "Operation cancelled."
                return 1
            fi
            socks5_port="${input_socks5:-$suggested_socks5}"
        fi

        # Validate port format and range
        if ! [[ "$socks5_port" =~ ^[0-9]+$ ]] || (( socks5_port < 1 || socks5_port > 65535 )); then
            log_err "Invalid port number: '${socks5_port}'. Port must be between 1 and 65535."
            if [[ ! -t 0 ]]; then
                return 1
            fi
            log_warn "Please try again (or enter 'q' to cancel)."
            socks5_port=""
            continue
        fi

        if is_port_in_use "$socks5_port"; then
            log_err "Port $socks5_port is already in use on this machine."
            if [[ ! -t 0 ]]; then
                return 1
            fi
            log_warn "The specified SOCKS5 port is occupied. Please try another port (or enter 'q' to cancel)."
            socks5_port=""
            continue
        fi

        break
    done

    # HTTP Port
    while true; do
        local suggested_http
        # Ensure suggested http port is distinct from socks5 port
        suggested_http="$(find_next_available_port "$DEFAULT_HTTP_BASE")"
        if [[ "$suggested_http" -eq "$socks5_port" ]]; then
            suggested_http="$(find_next_available_port "$((suggested_http + 1))")"
        fi

        if [[ -z "$http_port" ]]; then
            echo -en "${COLOR_BOLD}Enter HTTP port (bound to 127.0.0.1) [default: ${suggested_http}]: ${COLOR_RESET}"
            read -r input_http
            if [[ "$input_http" == "q" || "$input_http" == "Q" || "$input_http" == "exit" ]]; then
                log_info "Operation cancelled."
                return 1
            fi
            http_port="${input_http:-$suggested_http}"
        fi

        # Validate port format and range
        if ! [[ "$http_port" =~ ^[0-9]+$ ]] || (( http_port < 1 || http_port > 65535 )); then
            log_err "Invalid port number: '${http_port}'. Port must be between 1 and 65535."
            if [[ ! -t 0 ]]; then
                return 1
            fi
            log_warn "Please try again (or enter 'q' to cancel)."
            http_port=""
            continue
        fi

        if [[ "$socks5_port" -eq "$http_port" ]]; then
            log_err "SOCKS5 port and HTTP port cannot be the same ($socks5_port)."
            if [[ ! -t 0 ]]; then
                return 1
            fi
            log_warn "Please enter a different HTTP port (or enter 'q' to cancel)."
            http_port=""
            continue
        fi

        if is_port_in_use "$http_port"; then
            log_err "Port $http_port is already in use on this machine."
            if [[ ! -t 0 ]]; then
                return 1
            fi
            log_warn "The specified HTTP port is occupied. Please try another port (or enter 'q' to cancel)."
            http_port=""
            continue
        fi

        break
    done

    log_info "Creating instance: ${name}"
    mkdir -p "$CONF_DIR"
    chmod 700 "$CONF_DIR"

    # Copy the WireGuard config securely to the instance directory
    cp "$wg_conf" "$inst_wg"
    chmod 600 "$inst_wg"

    # Generate WireProxy config (Strictly binding to 127.0.0.1 for local isolation)
    cat > "$inst_conf" << EOF
# ==============================================================================
# WireProxy Instance: ${name}
# Generated: $(date -u +"%Y-%m-%d %H:%M:%SZ")
# Security Note: All proxy listeners are strictly bound to loopback (127.0.0.1)
# ==============================================================================

WGConfig = ${inst_wg}

[Socks5]
BindAddress = 127.0.0.1:${socks5_port}
EOF

    if [[ -n "$socks5_user" && -n "$socks5_pass" ]]; then
        cat >> "$inst_conf" << EOF
Username = ${socks5_user}
Password = ${socks5_pass}
EOF
    fi

    cat >> "$inst_conf" << EOF

[http]
BindAddress = 127.0.0.1:${http_port}
EOF

    if [[ -n "$http_user" && -n "$http_pass" ]]; then
        cat >> "$inst_conf" << EOF
Username = ${http_user}
Password = ${http_pass}
EOF
    fi

    chmod 600 "$inst_conf"

    # Test configuration with wireproxy -n
    log_info "Testing WireProxy configuration for '${name}'..."
    local test_output
    if ! test_output="$("$INSTALL_BIN" --configtest --config "$inst_conf" 2>&1)"; then
        log_err "Configuration validation failed!"
        echo -e "${COLOR_RED}${test_output}${COLOR_RESET}"
        log_warn "Cleaning up failed instance files..."
        rm -f "$inst_conf" "$inst_wg"
        return 1
    fi
    log_ok "Configuration syntax is valid."

    # Enable and start systemd service
    local service_name="wireproxy@${name}.service"
    log_info "Enabling and starting systemd service: ${service_name}..."
    systemctl enable --now "$service_name"
    sleep 1

    if systemctl is-active --quiet "$service_name"; then
        log_ok "Instance '${name}' is up and running!"
        echo -e "\n==================== Instance Summary ===================="
        echo -e " Instance Name: ${COLOR_GREEN}${name}${COLOR_RESET}"
        echo -e " SOCKS5 Proxy:  ${COLOR_CYAN}127.0.0.1:${socks5_port}${COLOR_RESET}"
        echo -e " HTTP Proxy:    ${COLOR_CYAN}127.0.0.1:${http_port}${COLOR_RESET}"
        echo -e " Service Name:  ${COLOR_BOLD}${service_name}${COLOR_RESET}"
        echo -e " Config Path:   ${inst_conf}"
        echo -e " WG Config:     ${inst_wg}"
        echo -e " Bound To:      ${COLOR_GREEN}127.0.0.1 only (External access blocked)${COLOR_RESET}"
        echo -e "==========================================================\n"
        echo -e "Test commands (run on this machine):"
        echo -e "  curl -x socks5h://127.0.0.1:${socks5_port} https://cloudflare.com/cdn-cgi/trace"
        echo -e "  curl -x http://127.0.0.1:${http_port} https://api.ipify.org"
        echo ""
    else
        log_warn "Instance '${name}' was started, but systemd reports it is not active."
        log_info "Check logs: journalctl -u ${service_name} -e --no-pager"
    fi
}

list_instances() {
    check_root
    local configs=()
    shopt -s nullglob
    configs=("${CONF_DIR}"/*.conf)
    shopt -u nullglob

    local instance_configs=()
    for conf in "${configs[@]}"; do
        # Ignore *.wg.conf
        if [[ "$conf" =~ \.wg\.conf$ ]]; then
            continue
        fi
        instance_configs+=("$conf")
    done

    if [[ ${#instance_configs[@]} -eq 0 ]]; then
        echo -e "${COLOR_YELLOW}No WireProxy instances found in ${CONF_DIR}.${COLOR_RESET}"
        return 0
    fi

    echo -e "\n${COLOR_BOLD}Configured WireProxy Instances:${COLOR_RESET}"
    printf "%-16s %-12s %-22s %-22s %-10s\n" "NAME" "STATUS" "SOCKS5 (127.0.0.1)" "HTTP (127.0.0.1)" "UPTIME"
    echo "-----------------------------------------------------------------------------------------"

    for conf in "${instance_configs[@]}"; do
        local name
        name="$(basename "$conf" .conf)"
        local service="wireproxy@${name}.service"

        local raw_status="inactive"
        local colored_status="${COLOR_YELLOW}inactive${COLOR_RESET}"
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            raw_status="active"
            colored_status="${COLOR_GREEN}active${COLOR_RESET}"
        elif systemctl is-failed --quiet "$service" 2>/dev/null; then
            raw_status="failed"
            colored_status="${COLOR_RED}failed${COLOR_RESET}"
        fi

        local socks5_port
        socks5_port="$(format_endpoint "$(get_instance_port "$conf" "socks5")")"
        local http_port
        http_port="$(format_endpoint "$(get_instance_port "$conf" "http")")"

        # Get service active enter timestamp / duration
        local uptime
        uptime="$(systemctl show "$service" --property=ActiveEnterTimestamp --value 2>/dev/null || echo "")"
        if [[ -z "$uptime" || "$raw_status" == "inactive" ]]; then
            uptime="-"
        else
            uptime="$(echo "$uptime" | awk '{print $2" "$3}' | cut -d: -f1,2)"
        fi

        local vis_len=${#raw_status}
        local pad=$((12 - vis_len))
        local spaces=""
        if (( pad > 0 )); then
            spaces=$(printf '%*s' "$pad" '')
        fi

        printf "%-16s %b%s %-22s %-22s %-10s\n" \
            "$name" "$colored_status" "$spaces" "$socks5_port" "$http_port" "$uptime"
    done
    echo ""
}

select_instance() {
    local _sel_out_var="$1"
    local _sel_prompt_title="${2:-Select an instance}"

    local _sel_configs=()
    if [[ -d "$CONF_DIR" && -r "$CONF_DIR" ]]; then
        shopt -s nullglob
        _sel_configs=("${CONF_DIR}"/*.conf)
        shopt -u nullglob
    fi

    local _sel_instance_names=()
    local _sel_instance_confs=()
    local _sel_c
    for _sel_c in "${_sel_configs[@]}"; do
        if [[ "$_sel_c" =~ \.wg\.conf$ ]]; then
            continue
        fi
        _sel_instance_names+=("$(basename "$_sel_c" .conf)")
        _sel_instance_confs+=("$_sel_c")
    done

    local _sel_count=${#_sel_instance_names[@]}
    if [[ $_sel_count -eq 0 ]]; then
        log_warn "No WireProxy instances found in ${CONF_DIR}."
        log_info "Use option 2 (or 'wireproxy add') to add an instance first."
        return 1
    fi

    echo -e "\n${COLOR_CYAN}--- ${_sel_prompt_title} ---${COLOR_RESET}"
    printf "  %-4s %-16s %-12s %-22s %-22s\n" "#" "NAME" "STATUS" "SOCKS5 PROXY" "HTTP PROXY"
    echo "  -----------------------------------------------------------------------------"

    local _sel_i
    for (( _sel_i=0; _sel_i<_sel_count; _sel_i++ )); do
        local _sel_item_name="${_sel_instance_names[_sel_i]}"
        local _sel_item_conf="${_sel_instance_confs[_sel_i]}"
        local _sel_service="wireproxy@${_sel_item_name}.service"

        local _sel_raw_status="inactive"
        local _sel_colored_status="${COLOR_YELLOW}inactive${COLOR_RESET}"
        if systemctl is-active --quiet "$_sel_service" 2>/dev/null; then
            _sel_raw_status="active"
            _sel_colored_status="${COLOR_GREEN}active${COLOR_RESET}"
        elif systemctl is-failed --quiet "$_sel_service" 2>/dev/null; then
            _sel_raw_status="failed"
            _sel_colored_status="${COLOR_RED}failed${COLOR_RESET}"
        fi

        local _sel_socks5_port
        _sel_socks5_port="$(format_endpoint "$(get_instance_port "$_sel_item_conf" "socks5")")"
        local _sel_http_port
        _sel_http_port="$(format_endpoint "$(get_instance_port "$_sel_item_conf" "http")")"

        local _sel_vis_len=${#_sel_raw_status}
        local _sel_pad=$((12 - _sel_vis_len))
        local _sel_spaces=""
        if (( _sel_pad > 0 )); then
            _sel_spaces=$(printf '%*s' "$_sel_pad" '')
        fi

        printf "  %-4s %-16s %b%s %-22s %-22s\n" \
            "$((_sel_i + 1)))" "$_sel_item_name" "$_sel_colored_status" "$_sel_spaces" "$_sel_socks5_port" "$_sel_http_port"
    done
    echo "  -----------------------------------------------------------------------------"
    echo -e "  0)   Cancel"
    echo ""

    while true; do
        echo -en "${COLOR_BOLD}Select an instance [1-${_sel_count}] (0 to cancel): ${COLOR_RESET}"
        read -r _sel_choice

        # User chooses to cancel
        if [[ "$_sel_choice" == "0" || "$_sel_choice" == "q" || "$_sel_choice" == "Q" || "$_sel_choice" == "cancel" || "$_sel_choice" == "exit" ]]; then
            log_info "Operation cancelled."
            return 1
        fi

        # Check numeric selection
        if [[ "$_sel_choice" =~ ^[0-9]+$ ]] && (( _sel_choice >= 1 && _sel_choice <= _sel_count )); then
            local _sel_chosen="${_sel_instance_names[$((_sel_choice - 1))]}"
            printf -v "$_sel_out_var" '%s' "$_sel_chosen"
            return 0
        fi

        # Check direct instance name match
        local _sel_match=""
        for _sel_c in "${_sel_instance_names[@]}"; do
            if [[ "$_sel_c" == "$_sel_choice" ]]; then
                _sel_match="$_sel_c"
                break
            fi
        done

        if [[ -n "$_sel_match" ]]; then
            printf -v "$_sel_out_var" '%s' "$_sel_match"
            return 0
        fi

        log_warn "Invalid selection '${_sel_choice}'."
        if [[ ! -t 0 ]]; then
            return 1
        fi
        log_warn "Please enter a number between 1 and ${_sel_count} (or 0 to cancel)."
    done
}

# ----------------------------- IP & Connectivity Helpers ----------------------

# Query IP location (Country & City) via ip-api.com
get_ip_location() {
    local target_ip="$1"
    local proxy_url="${2:-}"
    local loc=""
    if [[ -n "$target_ip" ]]; then
        local lang_param=""
        if [[ "${LANG:-}" =~ zh ]]; then
            lang_param="?lang=zh-CN"
        fi
        if [[ -n "$proxy_url" ]]; then
            loc="$(curl -fsSL -k --max-time 3 -x "$proxy_url" "http://ip-api.com/json/${target_ip}${lang_param}" 2>/dev/null | sed -n 's/.*"country":"\([^"]*\)".*"city":"\([^"]*\)".*/\1 \2/p' || true)"
        fi
        if [[ -z "$loc" ]]; then
            loc="$(curl -fsSL -k --max-time 3 "http://ip-api.com/json/${target_ip}${lang_param}" 2>/dev/null | sed -n 's/.*"country":"\([^"]*\)".*"city":"\([^"]*\)".*/\1 \2/p' || true)"
        fi
        loc="$(echo "$loc" | tr -s ' ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        local c1 c2
        c1="$(echo "$loc" | awk '{print $1}')"
        c2="$(echo "$loc" | awk '{print $2}')"
        if [[ -n "$c1" && "$c1" == "$c2" ]]; then
            loc="$c1"
        fi
    fi
    echo "$loc"
}

# Query public IP through a proxy with multi-API failover/fallback
# Arguments:
#   $1 - Proxy URL (e.g. "socks5h://127.0.0.1:10808" or "http://127.0.0.1:18080")
#   $2 - IP version ("4" or "6")
# Returns:
#   Clean IP address on stdout, return code 0 on success, 1 on failure
query_proxy_ip() {
    local proxy_url="$1"
    local ip_version="$2"
    local -a api_list=()

    if [[ "$ip_version" == "4" ]]; then
        api_list=(
            "https://api4.ipify.org"
            "https://ipv4.icanhazip.com"
            "https://checkip.amazonaws.com"
            "https://v4.ident.me"
        )
    else
        api_list=(
            "https://api6.ipify.org"
            "https://ipv6.icanhazip.com"
            "https://api64.ipify.org"
            "https://v6.ident.me"
        )
    fi

    local api
    for api in "${api_list[@]}"; do
        local raw_ip
        raw_ip="$(curl -fsSL -k --max-time 4 -x "$proxy_url" "$api" 2>/dev/null || true)"
        raw_ip="$(echo "$raw_ip" | tr -d '[]' | tr -d '[:space:]')"

        if [[ "$ip_version" == "4" ]]; then
            if [[ "$raw_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "$raw_ip"
                return 0
            fi
        else
            if [[ "$raw_ip" =~ : && "$raw_ip" =~ ^[0-9a-fA-F:]+$ ]]; then
                echo "$raw_ip"
                return 0
            fi
        fi
    done

    return 1
}

test_proxy_endpoint() {
    local proxy_type="$1"
    local endpoint="$2"
    local proxy_url="$3"

    log_info "Testing ${proxy_type} proxy on ${endpoint}..."

    local v4="" v6="" v4_loc="" v6_loc=""
    local v4_display="" v6_display=""

    v4="$(query_proxy_ip "$proxy_url" "4" || true)"
    if [[ -n "$v4" ]]; then
        v4_loc="$(get_ip_location "$v4" "$proxy_url")"
        if [[ -n "$v4_loc" ]]; then
            v4_display="${COLOR_GREEN}${v4}${COLOR_RESET} (${v4_loc})"
        else
            v4_display="${COLOR_GREEN}${v4}${COLOR_RESET}"
        fi
    else
        v4_display="${COLOR_YELLOW}None / Not reachable${COLOR_RESET}"
    fi

    v6="$(query_proxy_ip "$proxy_url" "6" || true)"
    if [[ -n "$v6" ]]; then
        v6_loc="$(get_ip_location "$v6" "$proxy_url")"
        if [[ -n "$v6_loc" ]]; then
            v6_display="${COLOR_GREEN}${v6}${COLOR_RESET} (${v6_loc})"
        else
            v6_display="${COLOR_GREEN}${v6}${COLOR_RESET}"
        fi
    else
        v6_display="${COLOR_YELLOW}None / Not reachable${COLOR_RESET}"
    fi

    echo -e "  ├── IPv4 Exit IP: ${v4_display}"
    echo -e "  └── IPv6 Exit IP: ${v6_display}"

    if [[ -n "$v4" || -n "$v6" ]]; then
        log_ok "${proxy_type} proxy is working properly!"
        return 0
    else
        log_err "${proxy_type} connection test failed or timed out."
        return 1
    fi
}

test_instance() {
    check_root
    local name="$1"
    if [[ -z "$name" ]]; then
        select_instance name "Select an instance to test" || return 0
    fi

    name="$(sanitize_name "$name")"
    local conf="${CONF_DIR}/${name}.conf"
    if [[ ! -f "$conf" ]]; then
        log_err "Instance '${name}' does not exist."
        return 1
    fi

    local service="wireproxy@${name}.service"
    if ! systemctl is-active --quiet "$service" 2>/dev/null; then
        log_warn "Service '${service}' is not active. The connection test may fail."
    fi

    local socks5_port
    socks5_port="$(get_instance_port "$conf" "socks5" | grep -oE '[0-9]+$' || true)"
    local http_port
    http_port="$(get_instance_port "$conf" "http" | grep -oE '[0-9]+$' || true)"

    log_info "Testing connectivity for instance '${name}'..."

    local any_tested=0
    local all_success=1

    if [[ -n "$socks5_port" ]]; then
        any_tested=1
        if ! test_proxy_endpoint "SOCKS5" "127.0.0.1:${socks5_port}" "socks5h://127.0.0.1:${socks5_port}"; then
            all_success=0
        fi
    fi

    if [[ -n "$http_port" ]]; then
        any_tested=1
        if ! test_proxy_endpoint "HTTP" "127.0.0.1:${http_port}" "http://127.0.0.1:${http_port}"; then
            all_success=0
        fi
    fi

    if [[ $any_tested -eq 0 ]]; then
        log_warn "No SOCKS5 or HTTP proxy ports configured in '${conf}'."
        return 1
    fi

    if [[ $all_success -eq 1 ]]; then
        return 0
    else
        return 1
    fi
}

remove_instance() {
    check_root
    local name="$1"
    if [[ -z "$name" ]]; then
        select_instance name "Select an instance to remove" || return 0
    fi

    name="$(sanitize_name "$name")"
    local conf="${CONF_DIR}/${name}.conf"
    local wg_conf="${CONF_DIR}/${name}.wg.conf"
    local service="wireproxy@${name}.service"

    if [[ ! -f "$conf" && ! -f "$wg_conf" ]]; then
        log_err "Instance '${name}' not found."
        return 1
    fi

    echo -en "${COLOR_YELLOW}Are you sure you want to stop and delete instance '${name}'? (y/N): ${COLOR_RESET}"
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Cancelled."
        return 0
    fi

    log_info "Stopping and disabling service ${service}..."
    systemctl stop "$service" 2>/dev/null || true
    systemctl disable "$service" 2>/dev/null || true

    log_info "Removing configuration files..."
    rm -f "$conf" "$wg_conf"

    log_ok "Instance '${name}' has been completely removed."
}

control_service() {
    check_root
    local action="$1"
    local name="$2"

    if [[ -z "$name" ]]; then
        local action_title="Select an instance to ${action}"
        case "$action" in
            logs)
                action_title="Select an instance to view logs"
                ;;
            status)
                action_title="Select an instance to view status"
                ;;
        esac
        select_instance name "$action_title" || return 0
    fi

    name="$(sanitize_name "$name")"
    local conf="${CONF_DIR}/${name}.conf"
    local service="wireproxy@${name}.service"

    if [[ ! -f "$conf" ]]; then
        log_err "Instance '${name}' does not exist."
        return 1
    fi

    case "$action" in
        start|stop|restart|status)
            log_info "Executing: systemctl ${action} ${service}"
            systemctl "$action" "$service"
            ;;
        logs)
            journalctl -u "$service" -n 50 --no-pager -f
            ;;
        *)
            log_err "Unknown service action: $action"
            return 1
            ;;
    esac
}

uninstall_all() {
    check_root
    echo -e "${COLOR_RED}${COLOR_BOLD}WARNING: This will stop all WireProxy instances and uninstall WireProxy!${COLOR_RESET}"
    echo -en "Are you sure you want to proceed? (yes/N): "
    read -r confirm
    if [[ "$confirm" != "yes" ]]; then
        log_info "Uninstall aborted."
        return 0
    fi

    log_info "Stopping and disabling all wireproxy instances..."
    for service in /etc/systemd/system/multi-user.target.wants/wireproxy@*.service; do
        if [[ -e "$service" ]]; then
            local svc_name
            svc_name="$(basename "$service")"
            systemctl stop "$svc_name" 2>/dev/null || true
            systemctl disable "$svc_name" 2>/dev/null || true
        fi
    done

    log_info "Removing systemd template: ${SYSTEMD_TEMPLATE}..."
    rm -f "$SYSTEMD_TEMPLATE"
    systemctl daemon-reload

    log_info "Removing binary: ${INSTALL_BIN}..."
    rm -f "$INSTALL_BIN"

    echo -en "Do you also want to remove all configuration files in ${CONF_DIR}? (y/N): "
    read -r rm_conf
    if [[ "$rm_conf" == "y" || "$rm_conf" == "Y" ]]; then
        rm -rf "$CONF_DIR"
        log_ok "Configurations deleted."
    else
        log_info "Configurations preserved in ${CONF_DIR}."
    fi

    log_ok "WireProxy has been successfully uninstalled."
}

# ----------------------------- Interactive Menu -------------------------------
display_menu_header() {
    local border="=========================================================================="
    local divider="--------------------------------------------------------------------------"

    echo -e "${COLOR_CYAN}${border}${COLOR_RESET}"
    echo -e "                  ${COLOR_BOLD}WireProxy Linux Multi-Instance Manager${COLOR_RESET}"
    echo -e "   Version: ${SCRIPT_VERSION} | Author: ${COLOR_GREEN}${SCRIPT_AUTHOR}${COLOR_RESET} | Bound: 127.0.0.1 (Local Only)"
    echo -e "${COLOR_CYAN}${border}${COLOR_RESET}"

    # WireProxy Installation Status
    local bin_path="$INSTALL_BIN"
    if [[ ! -x "$bin_path" ]] && command -v wireproxy &>/dev/null; then
        bin_path="$(command -v wireproxy)"
    fi

    if [[ -x "$bin_path" ]]; then
        local ver
        ver="$(get_wireproxy_version)"
        if [[ -n "$ver" ]]; then
            if [[ "$ver" =~ ^[0-9] ]]; then
                ver="v${ver}"
            fi
            echo -e " WireProxy Status : ${COLOR_GREEN}Installed${COLOR_RESET} (${COLOR_CYAN}${ver}${COLOR_RESET})"
        else
            echo -e " WireProxy Status : ${COLOR_GREEN}Installed${COLOR_RESET}"
        fi
    else
        echo -e " WireProxy Status : ${COLOR_RED}Not Installed${COLOR_RESET}"
    fi

    # Configured Instances List & Proxy Ports
    local configs=()
    if [[ -d "$CONF_DIR" && -r "$CONF_DIR" ]]; then
        shopt -s nullglob
        configs=("${CONF_DIR}"/*.conf)
        shopt -u nullglob
    fi

    local instance_configs=()
    for conf in "${configs[@]}"; do
        if [[ "$conf" =~ \.wg\.conf$ ]]; then
            continue
        fi
        instance_configs+=("$conf")
    done

    if [[ ${#instance_configs[@]} -eq 0 ]]; then
        echo -e " Configured Insts : ${COLOR_YELLOW}None${COLOR_RESET} (Use option 2 to add an instance)"
    else
        echo -e " Configured Insts : ${COLOR_BOLD}${#instance_configs[@]} total${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${divider}${COLOR_RESET}"
        printf "   ${COLOR_BOLD}%-15s %-12s %-22s %-22s${COLOR_RESET}\n" "NAME" "STATUS" "SOCKS5 PROXY" "HTTP PROXY"
        echo -e "   ---------------------------------------------------------------------"

        for conf in "${instance_configs[@]}"; do
            local name
            name="$(basename "$conf" .conf)"
            local service="wireproxy@${name}.service"

            local raw_status="inactive"
            local colored_status="${COLOR_YELLOW}inactive${COLOR_RESET}"
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                raw_status="active"
                colored_status="${COLOR_GREEN}active${COLOR_RESET}"
            elif systemctl is-failed --quiet "$service" 2>/dev/null; then
                raw_status="failed"
                colored_status="${COLOR_RED}failed${COLOR_RESET}"
            fi

            local s5_ep
            s5_ep="$(format_endpoint "$(get_instance_port "$conf" "socks5")")"
            local http_ep
            http_ep="$(format_endpoint "$(get_instance_port "$conf" "http")")"

            local vis_len=${#raw_status}
            local pad=$((12 - vis_len))
            local spaces=""
            if (( pad > 0 )); then
                spaces=$(printf '%*s' "$pad" '')
            fi

            printf "   %-15s %b%s %-22s %-22s\n" "$name" "$colored_status" "$spaces" "$s5_ep" "$http_ep"
        done
    fi

    echo -e "${COLOR_CYAN}${border}${COLOR_RESET}"
}

interactive_menu() {
    while true; do
        clear
        display_menu_header
        echo -e " 1) Install / Update WireProxy Binary"
        echo -e " 2) Add New Instance from WireGuard Config"
        echo -e " 3) List All Instances & Status"
        echo -e " 4) Test Instance Proxy Connectivity"
        echo -e " 5) Restart an Instance"
        echo -e " 6) Stop an Instance"
        echo -e " 7) Start an Instance"
        echo -e " 8) View Instance Logs"
        echo -e " 9) Remove an Instance"
        echo -e " 10) Uninstall WireProxy & All Instances"
        echo -e " 0) Exit"
        echo -e "${COLOR_CYAN}==========================================================================${COLOR_RESET}"
        echo -en "${COLOR_BOLD}Select an option [0-10]: ${COLOR_RESET}"
        read -r choice

        case "$choice" in
            1)
                install_wireproxy_binary
                ;;
            2)
                add_instance
                ;;
            3)
                list_instances
                ;;
            4)
                test_instance
                ;;
            5)
                control_service "restart"
                ;;
            6)
                control_service "stop"
                ;;
            7)
                control_service "start"
                ;;
            8)
                control_service "logs"
                ;;
            9)
                remove_instance
                ;;
            10)
                uninstall_all
                ;;
            0)
                echo "Goodbye!"
                exit 0
                ;;
            *)
                log_warn "Invalid selection. Please try again."
                ;;
        esac

        echo ""
        echo -en "${COLOR_BOLD}Press Enter to return to main menu...${COLOR_RESET}"
        read -r
    done
}

print_help() {
    cat << EOF
WireProxy Installer & Multi-Instance Manager v${SCRIPT_VERSION}
Author: ${SCRIPT_AUTHOR}

Usage:
  $(basename "$0")                          Launch interactive menu
  $(basename "$0") install                  Install or update WireProxy binary & systemd template
  $(basename "$0") add [options]            Create a new WireProxy instance
  $(basename "$0") list                     List all configured instances and statuses
  $(basename "$0") test [name]              Test SOCKS5/HTTP connectivity for an instance
  $(basename "$0") start [name]             Start instance service
  $(basename "$0") stop [name]              Stop instance service
  $(basename "$0") restart [name]           Restart instance service
  $(basename "$0") status [name]            View instance service status
  $(basename "$0") logs [name]              View instance systemd logs
  $(basename "$0") remove [name]            Remove an instance and delete its configs
  $(basename "$0") uninstall                Uninstall WireProxy and clean up systemd units
  $(basename "$0") version                  Show script version and author
  $(basename "$0") help                     Show this help message

Note:
  For commands taking [name], omitting the instance name in an interactive terminal
  will display an interactive list of configured instances for you to choose from.

Options for 'add' command:
  --name <name>               Instance identifier (e.g. wg0, us_vpn)
  --wg-conf <path>            Path to existing WireGuard .conf file
  --socks5-port <port>        SOCKS5 port to bind on 127.0.0.1 (default: auto)
  --http-port <port>          HTTP port to bind on 127.0.0.1 (default: auto)
  --socks5-user <username>    Optional SOCKS5 authentication username
  --socks5-pass <password>    Optional SOCKS5 authentication password
  --http-user <username>      Optional HTTP authentication username
  --http-pass <password>      Optional HTTP authentication password

Examples:
  # Add instance interactively
  $(basename "$0") add

  # Add instance via command line (strictly on 127.0.0.1)
  $(basename "$0") add --name wg0 --wg-conf /etc/wireguard/wg0.conf --socks5-port 10808 --http-port 18080

  # Test proxy connection
  $(basename "$0") test wg0

EOF
}

# ----------------------------- CLI Dispatcher ---------------------------------
parse_cli_args() {
    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        "")
            interactive_menu
            ;;
        install|update)
            install_wireproxy_binary
            ;;
        add)
            local arg_name=""
            local arg_wg=""
            local arg_s5=""
            local arg_http=""
            local arg_s5_user=""
            local arg_s5_pass=""
            local arg_http_user=""
            local arg_http_pass=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --name)
                        arg_name="$2"
                        shift 2
                        ;;
                    --wg-conf)
                        arg_wg="$2"
                        shift 2
                        ;;
                    --socks5-port)
                        arg_s5="$2"
                        shift 2
                        ;;
                    --http-port)
                        arg_http="$2"
                        shift 2
                        ;;
                    --socks5-user)
                        arg_s5_user="$2"
                        shift 2
                        ;;
                    --socks5-pass)
                        arg_s5_pass="$2"
                        shift 2
                        ;;
                    --http-user)
                        arg_http_user="$2"
                        shift 2
                        ;;
                    --http-pass)
                        arg_http_pass="$2"
                        shift 2
                        ;;
                    *)
                        log_err "Unknown option for 'add': $1"
                        print_help
                        exit 1
                        ;;
                esac
            done
            add_instance "$arg_name" "$arg_wg" "$arg_s5" "$arg_http" "$arg_s5_user" "$arg_s5_pass" "$arg_http_user" "$arg_http_pass"
            ;;
        list|ls)
            list_instances
            ;;
        test)
            test_instance "$1"
            ;;
        start)
            control_service "start" "$1"
            ;;
        stop)
            control_service "stop" "$1"
            ;;
        restart)
            control_service "restart" "$1"
            ;;
        status)
            control_service "status" "$1"
            ;;
        logs|log)
            control_service "logs" "$1"
            ;;
        remove|rm|delete)
            remove_instance "$1"
            ;;
        uninstall)
            uninstall_all
            ;;
        version|--version|-v)
            echo "WireProxy Installer & Multi-Instance Manager v${SCRIPT_VERSION}"
            echo "Author: ${SCRIPT_AUTHOR}"
            ;;
        help|--help|-h)
            print_help
            ;;
        *)
            log_err "Unknown command: $cmd"
            print_help
            exit 1
            ;;
    esac
}

parse_cli_args "$@"

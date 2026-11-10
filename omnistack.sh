#!/bin/bash
################################################################################
#  OmniStack 2.0 - Automated Multi-Protocol 3X-UI Infrastructure Stack
#  Based on 3X-UI v3.11.0 + Nginx + Single-Domain Architecture
#  Protocols: VLESS (Reality, XHTTP, WS), Hysteria 2, WireGuard, AmneziaWG 1.0/3.1
#  Features: Single-Domain Routing, Telegram Backups, Auto-Geodata, Decoy Sites
################################################################################

export DEBIAN_FRONTEND=noninteractive
[[ $EUID -ne 0 ]] && echo "Error: Must be run as root! (use: sudo bash $0)" && exit 1

# Color formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

msg_ok()   { echo -e "${GREEN}✔ $1${NC}"; }
msg_err()  { echo -e "${RED}✖ $1${NC}"; }
msg_inf()  { echo -e "${CYAN}ℹ $1${NC}"; }
msg_warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
msg_step() { echo -e "\n${BOLD}${PURPLE}==> $1${NC}"; }

# Banner
show_banner() {
    clear
    echo -e "${CYAN}"
    echo "  ██████╗ ███╗   ███╗███╗   ██╗██╗███████╗████████╗ █████╗  ██████╗██╗  ██╗"
    echo " ██╔═══██╗████╗ ████║████╗  ██║██║██╔════╝╚══██╔══╝██╔══██╗██╔════╝██║ ██╔╝"
    echo " ██║   ██║██╔████╔██║██╔██╗ ██║██║███████╗   ██║   ███████║██║     █████╔╝ "
    echo " ██║   ██║██║╚██╔╝██║██║╚██╗██║██║╚════██║   ██║   ██╔══██║██║     ██╔═██╗ "
    echo " ╚██████╔╝██║ ╚═╝ ██║██║ ╚████║██║███████║   ██║   ██║  ██║╚██████╗██║  ██╗"
    echo "  ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═══╝╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝"
    echo "             Automated 3X-UI All-in-One Infrastructure Stack            "
    echo -e "${NC}"
}

################################## Variables ##################################
XUIDB="/etc/x-ui/x-ui.db"
DEFAULT_PANEL_VERSION="v3.11.0"
REALITY_DEFAULT_TARGET=""
REALITY_DEFAULT_SNI=""
REALITY_SERVER_NAMES_JSON=""
CHECK_SERVICES="n"
SCAN_REALITY_ONLY="n"
RUN_BACKUP_NOW="n"
RUN_GEODATA_UPDATE_NOW="n"
RUN_BASE_SOFT="n"
CHANGE_FAKE_SITE="n"
FAKE_THEME_CHOICE="0"
ENABLE_TG_BACKUP="y"
TG_BOT_TOKEN=""
TG_CHAT_ID=""
SUB_TITLE=""
DEFAULT_SUB_TITLE=""

# Multi-Cascade (Multiple Exit Nodes) configuration
CASCADE_COUNT=1
CASCADE_URLS=()
CASCADE_TAGS=()
CASCADE_ALIASES=()
DEFAULT_CASCADE_TAG="cascade-out-1"

# Grouped service routing destinations
declare -A GROUP_DEST_TAG
declare -A GROUP_DEST_NAME

GROUP_NAMES=(
    [1]="YouTube (Googlevideo CDN, youtube.com)"
    [2]="Telegram"
    [3]="Discord"
    [4]="Остальные мессенджеры (WhatsApp, Signal, Viber, Skype, Element)"
    [5]="Социальные сети (X/Twitter, Instagram, Facebook, Meta, TikTok, LinkedIn)"
    [6]="Глобальные CDN сети (Cloudflare, Fastly, Akamai, Amazon AWS, Google)"
    [7]="Нейросети и AI (OpenAI, Grok, Claude, Gemini Google AI, Perplexity, DeepSeek)"
)

# Script arguments / defaults
domain=""
SERVER_ROLE=""          # "exit" (EU), "cascade" (RU Ingress), "standalone" (RU standalone)
INSTALL="y"
UNINSTALL="n"
CFALLOW="n"
CASCADE_EU_URL=""
CASCADE_URLS_ARG=""
PANEL_VER="$DEFAULT_PANEL_VERSION"
Pak=$(type apt &>/dev/null && echo "apt" || echo "yum")

################################## Utilities ##################################
arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86)           echo '386' ;;
        armv8* | arm64 | aarch64) echo 'arm64' ;;
        armv7* | arm)         echo 'armv7' ;;
        armv6*)               echo 'armv6' ;;
        armv5*)               echo 'armv5' ;;
        s390x)                echo 's390x' ;;
        *) msg_err "Unsupported CPU architecture: $(uname -m)"; exit 1 ;;
    esac
}

get_port() {
    echo $(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
}

check_free() {
    local port=$1
    nc -z 127.0.0.1 "$port" &>/dev/null
    return $?
}

make_port() {
    while true; do
        local p
        p=$(get_port)
        if ! check_free "$p"; then 
            echo "$p"
            break
        fi
    done
}

gen_random_string() {
    local length="${1:-10}"
    head -c 4096 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$length"
    echo
}

gen_uuid() {
    if [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || gen_random_string 32
    fi
}

gen_wg_keypair() {
    if command -v wg &>/dev/null; then
        local priv=$(wg genkey)
        local pub=$(echo "$priv" | wg pubkey)
        echo "$priv $pub"
    else
        python3 -c '
import base64
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
priv = X25519PrivateKey.generate()
pub = priv.public_key()
print(base64.b64encode(priv.private_bytes_raw()).decode(), base64.b64encode(pub.public_bytes_raw()).decode())
' 2>/dev/null || echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
    fi
}

setup_swap() {
    local swap_total
    swap_total=$(free -m 2>/dev/null | awk '/Swap:/ {print $2}')
    if [[ -n "$swap_total" && "$swap_total" -ge 1024 ]]; then
        msg_ok "Swap is already configured (${swap_total} MB)."
        return 0
    fi

    msg_step "Configuring 2GB Swap file for server stability..."
    local swapfile="/swapfile"
    if [[ -f "$swapfile" ]]; then
        swapoff "$swapfile" 2>/dev/null || true
        rm -f "$swapfile" 2>/dev/null || true
    fi

    if fallocate -l 2G "$swapfile" 2>/dev/null || dd if=/dev/zero of="$swapfile" bs=1M count=2048 status=none 2>/dev/null; then
        chmod 600 "$swapfile"
        mkswap "$swapfile" >/dev/null 2>&1
        if swapon "$swapfile" >/dev/null 2>&1; then
            if ! grep -q "$swapfile" /etc/fstab 2>/dev/null; then
                echo "$swapfile none swap sw 0 0" >> /etc/fstab
            fi
            sysctl -w vm.swappiness=20 >/dev/null 2>&1 || true
            echo "vm.swappiness=20" > /etc/sysctl.d/99-swap.conf 2>/dev/null || true
            msg_ok "2GB Swap successfully configured and activated."
        else
            msg_warn "Unable to activate swap (virtualization restriction/container). Continuing without swap."
            rm -f "$swapfile" 2>/dev/null || true
        fi
    else
        msg_warn "Could not allocate swap space. Continuing."
    fi
}

# Auto-selection of best REALITY Target (Lowest latency & TLS 1.3)
find_best_reality_target() {
    local mode="${1:-normal}"
    msg_step "Scanning suitable REALITY destinations for lowest latency & TLS 1.3..."
    local scan_res
    scan_res=$(python3 -c '
import socket, ssl, time, json, sys

candidates = [
    "gateway.icloud.com",
    "swdist.apple.com",
    "updates.cdn-apple.com",
    "www.apple.com",
    "www.speedtest.net",
    "www.cloudflare.com",
    "www.amazon.com",
    "aws.amazon.com",
    "www.samsung.com",
    "www.nvidia.com",
    "www.adobe.com",
    "www.sony.com",
    "www.oracle.com",
    "www.cisco.com",
    "dl.google.com",
    "www.microsoft.com"
]

results = []
ctx = ssl.create_default_context()
ctx.set_alpn_protocols(["h2", "http/1.1"])

for host in candidates:
    t0 = time.time()
    try:
        s = socket.create_connection((host, 443), timeout=1.8)
        t_tcp = int((time.time() - t0) * 1000)
        t_tls0 = time.time()
        ss = ctx.wrap_socket(s, server_hostname=host)
        t_tls = int((time.time() - t_tls0) * 1000)
        total = int((time.time() - t0) * 1000)
        tls_ver = ss.version()
        alpn = ss.selected_alpn_protocol()
        cert = ss.getpeercert()
        ss.close()
        if tls_ver == "TLSv1.3" and alpn == "h2":
            sans = [item[1] for item in cert.get("subjectAltName", []) if item[0] == "DNS"]
            clean_sans = [s for s in sans if not s.startswith("*") and s != host]
            results.append({"host": host, "total": total, "tcp": t_tcp, "tls": t_tls, "sans": [host] + clean_sans[:3]})
    except Exception:
        continue

if not results:
    w = {"host": "gateway.icloud.com", "total": 0, "sans": ["gateway.icloud.com"]}
else:
    results.sort(key=lambda x: x["total"])
    w = results[0]

mode = sys.argv[1] if len(sys.argv) > 1 else "normal"
if mode == "verbose":
    print("-" * 72)
    print("%-25s | %-8s | %-6s | %-6s | %s" % ("DOMAIN", "TOTAL", "TCP", "TLS", "SANS"))
    print("-" * 72)
    for r in results:
        print("%-25s | %5dms | %4dms | %4dms | %s" % (r["host"], r["total"], r["tcp"], r["tls"], ", ".join(r["sans"][:2])))
    print("-" * 72)

target_str = "%s:443" % w["host"]
print("RESULT:" + json.dumps({"target": target_str, "sni": w["host"], "server_names": w["sans"], "latency": w["total"]}))
' "$mode" 2>/dev/null || echo 'RESULT:{"target": "gateway.icloud.com:443", "sni": "gateway.icloud.com", "server_names": ["gateway.icloud.com"], "latency": 0}')

    local json_part
    json_part=$(echo "$scan_res" | grep '^RESULT:' | sed 's/^RESULT://')
    if [[ "$mode" == "verbose" ]]; then
        echo "$scan_res" | grep -v '^RESULT:'
    fi

    IFS=$'\t' read -r REALITY_DEFAULT_TARGET REALITY_DEFAULT_SNI REALITY_SERVER_NAMES_JSON latency < <(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
sys.stdout.write("\t".join([data["target"], data["sni"], json.dumps(data["server_names"]), str(data.get("latency", 0))]) + "\n")
' "$json_part" 2>/dev/null || echo -e "gateway.icloud.com:443\tgateway.icloud.com\t[\"gateway.icloud.com\"]\t0")

    msg_ok "Selected REALITY Target: ${REALITY_DEFAULT_TARGET} (Latency: ${latency}ms, SNI: ${REALITY_DEFAULT_SNI})"
}

# ==============================================================================
# Telegram Weekly Backup & Telemetry Reporting Setup
# ==============================================================================
setup_telegram_backup() {
    msg_step "Настройка автоматического еженедельного бэкапа и статистики в Telegram..."
    
    mkdir -p /etc/x-ui
    cat > "/etc/x-ui/telegram_backup.conf" << EOF
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
SUB_TITLE="${SUB_TITLE}"
EOF
    chmod 600 /etc/x-ui/telegram_backup.conf

    cat > "/usr/local/bin/x-ui-backup.sh" << 'EOF'
#!/bin/bash
# ==============================================================================
# Weekly x-ui database backup & system telemetry report to Telegram
# Scheduled: Every Sunday at 21:00
# ==============================================================================
set -e

CONFIG_FILE="/etc/x-ui/telegram_backup.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
    exit 0
fi

source "$CONFIG_FILE"

if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
    exit 0
fi

# 1. System Metrics
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
IP=$(curl -s4 -m 4 ipv4.icanhazip.com || echo "N/A")
UPTIME=$(uptime -p 2>/dev/null || uptime | awk '{print $3,$4}' | tr -d ',')
LOAD_AVG=$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null || echo "N/A")
RAM_USAGE=$(free -m | awk '/Mem:/ { printf("%.1f / %.1f GB (%.0f%%)", $3/1024, $2/1024, $3*100/$2) }')
DISK_USAGE=$(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}' 2>/dev/null || echo "N/A")
BBR_STATUS=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "N/A")

# 2. X-UI Database Metrics
CLIENT_COUNT=0
TOTAL_UP_BYTES=0
TOTAL_DOWN_BYTES=0

if [[ -f "/etc/x-ui/x-ui.db" ]]; then
    STATS=$(sqlite3 /etc/x-ui/x-ui.db "SELECT count(*), coalesce(sum(up), 0), coalesce(sum(down), 0) FROM client_traffics;" 2>/dev/null || echo "0|0|0")
    CLIENT_COUNT=$(echo "$STATS" | cut -d'|' -f1)
    TOTAL_UP_BYTES=$(echo "$STATS" | cut -d'|' -f2)
    TOTAL_DOWN_BYTES=$(echo "$STATS" | cut -d'|' -f3)
fi

# Format bytes to GB
UP_GB=$(awk "BEGIN {printf \"%.2f\", ${TOTAL_UP_BYTES}/1073741824}")
DOWN_GB=$(awk "BEGIN {printf \"%.2f\", ${TOTAL_DOWN_BYTES}/1073741824}")
TOTAL_GB=$(awk "BEGIN {printf \"%.2f\", (${TOTAL_UP_BYTES}+${TOTAL_DOWN_BYTES})/1073741824}")

# 3. Create Backup
BACKUP_DIR="/tmp/x-ui-backups"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/x-ui_backup_$(date +%Y%m%d_%H%M%S).db"

if [[ -f "/etc/x-ui/x-ui.db" ]]; then
    sqlite3 /etc/x-ui/x-ui.db ".backup '${BACKUP_FILE}'"
fi

# 4. Compose Report
REPORT="📊 *Еженедельный отчет: ${SUB_TITLE:-OmniStack}*
━━━━━━━━━━━━━━━━━━
🗓 *Дата:* $(date '+%d.%m.%Y %H:%M %Z')
🌐 *Сервер:* \`${IP}\` (${HOSTNAME})
⏱ *Аптайм:* ${UPTIME}
⚙️ *BBR Congestion:* \`${BBR_STATUS}\`

📈 *Нагрузка:*
• CPU Load: \`${LOAD_AVG}\`
• RAM: \`${RAM_USAGE}\`
• Диск (/): \`${DISK_USAGE}\`

👥 *X-UI Клиенты и трафик:*
• Активных клиентов: *${CLIENT_COUNT}*
• Исходящий (Upload): *${UP_GB} GB*
• Входящий (Download): *${DOWN_GB} GB*
• Всего передано: *${TOTAL_GB} GB*
━━━━━━━━━━━━━━━━━━
💾 _Файл резервной копии базы данных x-ui.db прикреплен ниже._"

# 5. Send message
curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TG_CHAT_ID}" \
    -d parse_mode="Markdown" \
    -d text="${REPORT}" >/dev/null 2>&1 || true

# 6. Send document
if [[ -f "$BACKUP_FILE" ]]; then
    curl -s -F chat_id="${TG_CHAT_ID}" \
        -F document=@"${BACKUP_FILE}" \
        -F caption="📦 Резервная копия x-ui.db от $(date '+%d.%m.%Y %H:%M')" \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" >/dev/null 2>&1 || true
    rm -f "$BACKUP_FILE"
fi
EOF
    chmod +x /usr/local/bin/x-ui-backup.sh

    # Setup weekly cron (Sunday at 21:00)
    cat > "/etc/cron.d/x-ui-backup" << EOF
# Weekly x-ui database backup & statistics to Telegram (Sunday 21:00)
0 21 * * 0 root /usr/local/bin/x-ui-backup.sh >/dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/x-ui-backup

    # Test sending if bot token is provided
    if [[ -n "$TG_BOT_TOKEN" ]]; then
        local me_check
        me_check=$(curl -s "https://api.telegram.org/bot${TG_BOT_TOKEN}/getMe" 2>/dev/null || echo "")
        if echo "$me_check" | grep -q '"ok":true'; then
            curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
                -d chat_id="${TG_CHAT_ID}" \
                -d parse_mode="Markdown" \
                -d text="🎉 *Уведомления X-UI активированы!* Резервная копия базы и статистика будут приходить каждое воскресенье в 21:00." >/dev/null 2>&1 || true
            msg_ok "Telegram-бот успешно подключен и протестирован!"
        else
            msg_warn "Токен Telegram-бота не прошел проверку. Проверьте правильность токена в /etc/x-ui/telegram_backup.conf."
        fi
    else
        msg_inf "Токен Telegram-бота не указан. Вы сможете добавить его позже в /etc/x-ui/telegram_backup.conf."
    fi

    msg_ok "Telegram-бэкап настроен (расписание: каждое воскресенье в 21:00)"
}

# ==============================================================================
# Telegram Bot Interactive Management Submenu
# ==============================================================================
interactive_telegram_bot_menu() {
    while true; do
        show_banner
        echo -e "${BOLD}${CYAN}=== 🤖 Управление Telegram-ботом и оповещениями ===${NC}\n"
        
        local conf="/etc/x-ui/telegram_backup.conf"
        local curr_token=""
        local curr_chat=""
        local curr_title=""
        local cron_active="n"
        
        if [[ -f "$conf" ]]; then
            curr_token=$(grep -m1 '^TG_BOT_TOKEN=' "$conf" 2>/dev/null | cut -d'"' -f2)
            curr_chat=$(grep -m1 '^TG_CHAT_ID=' "$conf" 2>/dev/null | cut -d'"' -f2)
            curr_title=$(grep -m1 '^SUB_TITLE=' "$conf" 2>/dev/null | cut -d'"' -f2)
        fi
        
        if [[ -f /etc/cron.d/x-ui-backup ]] && ! grep -q "^#" /etc/cron.d/x-ui-backup 2>/dev/null; then
            cron_active="y"
        fi
        
        echo -e "${BOLD}Текущее состояние:${NC}"
        if [[ -n "$curr_token" && -n "$curr_chat" ]]; then
            local masked_token="${curr_token:0:8}...${curr_token: -6}"
            echo -e "  • Статус бота:       ${GREEN}✔ Настроен${NC}"
            echo -e "  • Токен бота:        ${CYAN}${masked_token}${NC}"
            echo -e "  • Chat ID:           ${CYAN}${curr_chat}${NC}"
        else
            echo -e "  • Статус бота:       ${YELLOW}⚠ Не настроен${NC}"
        fi
        
        if [[ "$cron_active" == "y" ]]; then
            echo -e "  • Расписание (Cron): ${GREEN}✔ Активно (каждое воскресенье в 21:00)${NC}"
        else
            echo -e "  • Расписание (Cron): ${RED}✖ Отключено${NC}"
        fi
        
        echo ""
        echo -e "${BOLD}Действия:${NC}"
        echo -e "  [1] ⚙️  Включить / настроить бота (ввод токена и Chat ID)"
        echo -e "  [2] 📤 Отправить тестовый отчет и бэкап в Telegram прямо сейчас"
        echo -e "  [3] ⏱️  Переключить автобэкап по расписанию (Вкл / Выкл)"
        echo -e "  [4] 🛑 Полностью отключить и деактивировать Telegram-бота"
        echo -e "  [0] 🚪 Назад в главное меню"
        echo ""
        read -rp "Ваш выбор [0-4]: " tg_choice
        
        case "$tg_choice" in
            1)
                echo ""
                echo -e "${BOLD}${CYAN}Настройка Telegram-бота:${NC}"
                echo -e "1. Создайте бота через @BotFather в Telegram и скопируйте HTTP API токен."
                echo -e "2. Узнайте свой Chat ID через бота @userinfobot или @myidbot."
                echo ""
                read -rp "Введите токен Telegram-бота: " input_token
                input_token=$(echo "$input_token" | tr -d '[:space:]')
                read -rp "Введите ваш Telegram Chat ID: " input_chat
                input_chat=$(echo "$input_chat" | tr -d '[:space:]')
                
                if [[ -z "$input_token" || -z "$input_chat" ]]; then
                    msg_err "Токен и Chat ID не могут быть пустыми!"
                    sleep 2
                    continue
                fi
                
                msg_step "Проверка токена через Telegram API..."
                local me_res
                me_res=$(curl -s -m 5 "https://api.telegram.org/bot${input_token}/getMe" 2>/dev/null || echo "")
                if echo "$me_res" | grep -q '"ok":true'; then
                    local bot_name
                    bot_name=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('result', {}).get('username', 'Bot'))" "$me_res" 2>/dev/null || echo "Bot")
                    msg_ok "Бот найден: @${bot_name}!"
                    
                    TG_BOT_TOKEN="$input_token"
                    TG_CHAT_ID="$input_chat"
                    setup_telegram_backup
                    msg_ok "Telegram-бот успешно настроен и активирован!"
                else
                    msg_err "Ошибка валидации токена! Telegram API вернул ошибку."
                    msg_warn "Ответ API: ${me_res:0:100}"
                fi
                echo ""
                read -rp "Нажмите Enter для продолжения..." _
                ;;
            2)
                echo ""
                if [[ ! -x /usr/local/bin/x-ui-backup.sh ]]; then
                    if [[ -n "$curr_token" ]]; then
                        setup_telegram_backup
                    else
                        msg_err "Сначала настройте токен и Chat ID (пункт 1)."
                        read -rp "Нажмите Enter для продолжения..." _
                        continue
                    fi
                fi
                msg_step "Отправка тестового отчета и резервной копии базы в Telegram..."
                /usr/local/bin/x-ui-backup.sh
                msg_ok "Готово! Проверьте входящие сообщения от бота в Telegram."
                echo ""
                read -rp "Нажмите Enter для продолжения..." _
                ;;
            3)
                echo ""
                if [[ "$cron_active" == "y" ]]; then
                    rm -f /etc/cron.d/x-ui-backup
                    msg_ok "Автоматический бэкап по расписанию отключен."
                else
                    if [[ -z "$curr_token" || -z "$curr_chat" ]]; then
                        msg_err "Сначала настройте бота (пункт 1), чтобы включить расписание."
                    else
                        cat > "/etc/cron.d/x-ui-backup" << EOF
0 21 * * 0 root /usr/local/bin/x-ui-backup.sh >/dev/null 2>&1
EOF
                        chmod 644 /etc/cron.d/x-ui-backup
                        msg_ok "Автоматический еженедельный бэкап включен (каждое воскресенье в 21:00)."
                    fi
                fi
                echo ""
                read -rp "Нажмите Enter для продолжения..." _
                ;;
            4)
                echo ""
                read -rp "Вы действительно хотите полностью отключить Telegram-бота? [y/N]: " confirm_del
                if [[ "$confirm_del" =~ ^[Yy]$ ]]; then
                    rm -f /etc/cron.d/x-ui-backup
                    rm -f /etc/x-ui/telegram_backup.conf
                    msg_ok "Telegram-бот полностью отключен и деактивирован."
                fi
                echo ""
                read -rp "Нажмите Enter для продолжения..." _
                ;;
            0|q|exit)
                break
                ;;
            *)
                msg_warn "Неверный выбор."
                sleep 1
                ;;
        esac
    done
}

# ==============================================================================
# WireGuard & MikroTik Client Management Submenu
# ==============================================================================
# ==============================================================================
# Weekly GeoIP & Geosite Auto-Update Setup
# ==============================================================================
setup_geodata_cron() {
    msg_step "Настройка автоматического обновления баз GeoIP и Geosite..."
    
    cat > "/usr/local/bin/x-ui-geodata-update.sh" << 'EOF'
#!/bin/bash
# ==============================================================================
# Weekly GeoIP & Geosite update for x-ui/Xray
# Scheduled: Every Sunday at 04:00
# ==============================================================================
set -e

TMP_DIR=$(mktemp -d)
GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

curl -fsSL -o "${TMP_DIR}/geoip.dat" "${GEOIP_URL}" || true
curl -fsSL -o "${TMP_DIR}/geosite.dat" "${GEOSITE_URL}" || true

if [[ -s "${TMP_DIR}/geoip.dat" && $(stat -c%s "${TMP_DIR}/geoip.dat") -gt 1000000 && \
      -s "${TMP_DIR}/geosite.dat" && $(stat -c%s "${TMP_DIR}/geosite.dat") -gt 1000000 ]]; then
    
    if [[ -d "/usr/local/x-ui/bin" ]]; then
        cp -f "${TMP_DIR}/geoip.dat" /usr/local/x-ui/bin/geoip.dat
        cp -f "${TMP_DIR}/geosite.dat" /usr/local/x-ui/bin/geosite.dat
    fi
    if [[ -d "/usr/local/share/xray" ]]; then
        cp -f "${TMP_DIR}/geoip.dat" /usr/local/share/xray/geoip.dat
        cp -f "${TMP_DIR}/geosite.dat" /usr/local/share/xray/geosite.dat
    fi
    systemctl restart x-ui 2>/dev/null || true
fi

rm -rf "${TMP_DIR}"
EOF
    chmod +x /usr/local/bin/x-ui-geodata-update.sh

    cat > "/etc/cron.d/x-ui-geodata" << EOF
# Weekly GeoIP & Geosite update for Xray (Sunday 04:00)
0 4 * * 0 root /usr/local/bin/x-ui-geodata-update.sh >/dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/x-ui-geodata

    msg_ok "Автообновление GeoIP и Geosite настроено (расписание: каждое воскресенье в 04:00)"
}

# Service Accessibility & TSPU Block Auditor
check_services_accessibility() {
    python3 -c '
import urllib.request
import ssl
import time

CATEGORIES = {
    "💬 Мессенджеры и коммуникации": [
        ("Telegram Web", "https://web.telegram.org"),
        ("Telegram API", "https://api.telegram.org"),
        ("Discord Web", "https://discord.com"),
        ("Discord Gateway API", "https://discord.com/api/v10/gateway"),
        ("WhatsApp Web", "https://web.whatsapp.com"),
    ],
    "🎬 Видеохостинги и соцсети": [
        ("YouTube (Web)", "https://www.youtube.com"),
        ("YouTube (Googlevideo CDN)", "https://redirector.googlevideo.com/report_mapping"),
        ("Instagram", "https://www.instagram.com"),
        ("Twitter / X", "https://x.com"),
        ("Facebook", "https://www.facebook.com"),
    ],
    "🤖 Искусственный интеллект (AI)": [
        ("OpenAI (ChatGPT)", "https://chatgpt.com"),
        ("OpenAI API", "https://api.openai.com/v1/models"),
        ("Claude AI (Anthropic)", "https://claude.ai"),
    ],
    "🌐 Глобальные CDN-провайдеры": [
        ("Cloudflare CDN", "https://www.cloudflare.com"),
        ("Amazon AWS / CloudFront", "https://aws.amazon.com"),
        ("Akamai CDN", "https://www.akamai.com"),
        ("CDN77", "https://www.cdn77.com"),
        ("Fastly CDN", "https://www.fastly.com"),
    ],
    "🇷🇺 Российские ресурсы (Direct Check)": [
        ("Gosuslugi.ru", "https://gosuslugi.ru"),
        ("Yandex", "https://ya.ru"),
        ("VKontakte", "https://vk.com"),
    ]
}

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

total_tested = 0
total_accessible = 0
total_blocked = 0

print("\n" + "=" * 76)
print("      🔍 АУДИТ СЕТЕВОЙ ДОСТУПНОСТИ СЕРВИСОВ С ЭТОГО СЕРВЕРА")
print("=" * 76)

for cat_name, items in CATEGORIES.items():
    print(f"\n\033[1m{cat_name}\033[0m")
    print("-" * 76)
    for name, url in items:
        total_tested += 1
        t0 = time.time()
        try:
            req = urllib.request.Request(
                url,
                headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
            )
            with urllib.request.urlopen(req, timeout=3.0, context=ctx) as resp:
                elapsed = int((time.time() - t0) * 1000)
                code = resp.getcode()
                total_accessible += 1
                status = "\033[32m✔ ДОСТУПЕН\033[0m"
                details = f"HTTP {code} OK"
        except urllib.error.HTTPError as e:
            elapsed = int((time.time() - t0) * 1000)
            total_accessible += 1
            status = "\033[32m✔ ДОСТУПЕН\033[0m"
            if e.code in [401, 403]:
                details = f"HTTP {e.code} (Сервер ответил)"
            else:
                details = f"HTTP {e.code}"
        except Exception as e:
            elapsed = int((time.time() - t0) * 1000)
            err_str = str(e).lower()
            total_blocked += 1
            if "timed out" in err_str:
                status = "\033[31m✖ НЕДОСТУПЕН (Timeout)\033[0m"
                details = "Connection Timeout"
            elif "reset" in err_str or "eof" in err_str:
                status = "\033[31m✖ НЕДОСТУПЕН (Reset)\033[0m"
                details = "Connection Reset"
            else:
                status = "\033[33m⚠ ОШИБКА\033[0m"
                details = str(e)[:25]

        print(f"  {name:<28} | {status:<34} | {elapsed:>5}ms | {details}")

print("\n" + "=" * 76)
pct = int((total_accessible / total_tested) * 100) if total_tested else 0
print(f"📊 ИТОГИ АУДИТА: Доступно {total_accessible} из {total_tested} сервисов ({pct}%).")

if total_blocked > 0:
    print("\n💡 РЕКОМЕНДАЦИЯ ПО МАРШРУТИЗАЦИИ:")
    print("  • Обнаружены недоступные напрямую внешние сервисы.")
    print("  • Для оптимального доступа рекомендуется настроить Каскад (Cascade Ingress):")
    print("    - Быстрые сервисы пускать напрямую (direct) с максимальной скоростью;")
    print("    - Недоступные сервисы заворачивать через внешний туннель.")
else:
    print("\n💡 РЕКОМЕНДАЦИЯ ПО МАРШРУТИЗАЦИИ:")
    print("  • Все протестированные сервисы полностью доступны напрямую с этого сервера.")
    print("  • Сервер отлично подходит в качестве автономного узла (Exit Node).")
print("=" * 76 + "\n")
'
}

################################## Autonomous Decoy Website Generator ##########
generate_fake_website() {
    local target_domain="$1"
    local theme_choice="${2:-0}"
    local dest_file="${3:-/var/www/html/index.html}"

    if [[ -z "$target_domain" ]]; then
        target_domain=$(grep -m1 "^Domain:" /root/omnistack-credentials.txt 2>/dev/null | awk '{print $2}')
    fi
    if [[ -z "$target_domain" ]]; then
        target_domain=$(grep -m1 "^Domain:" /root/x-ui-pro-credentials.txt 2>/dev/null | awk '{print $2}')
    fi
    if [[ -z "$target_domain" ]]; then
        target_domain=$(ls -1 /etc/nginx/sites-available/ 2>/dev/null | grep -v '80.conf' | head -n1)
    fi
    if [[ -z "$target_domain" ]]; then
        target_domain=$(hostname -f 2>/dev/null || echo "example.com")
    fi

    mkdir -p "$(dirname "$dest_file")"

    local gen_output
    gen_output=$(python3 - "$target_domain" "$theme_choice" "$dest_file" << 'PY_DECOY_EOF'
import sys
import random
import datetime

domain = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else "my-server.com"
try:
    chosen_id = int(sys.argv[2]) if len(sys.argv) > 2 else 0
except ValueError:
    chosen_id = 0
dest_file = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else "/var/www/html/index.html"

THEMES = [
    {
        "id": 1,
        "name": "Архитектурное бюро «Форма и Пространство»",
        "tag": "Архитектура & Проектирование",
        "title": "Архитектурное проектирование и дизайн среды",
        "subtitle": "Создаем загородные резиденции, современные общественные пространства и концептуальные интерьеры. Наш новый сайт находится в процессе разработки.",
        "badge": "Сайт в разработке",
        "color_bg": "#0b0f19",
        "color_card": "#131b2e",
        "color_border": "#1e293b",
        "color_accent": "#38bdf8",
        "color_text": "#e2e8f0",
        "color_muted": "#94a3b8",
        "cards": [
            ("Архитектура резиденций", "Индивидуальные проекты премиум-класса с интеграцией в естественный ландшафт."),
            ("Общественные пространства", "Урбанистика, офисные хабы, парки и ревитализация исторических объектов."),
            ("Инженерный надзор", "Комплексное ведение проекта от фундамента до сдачи в эксплуатацию.")
        ],
        "progress": 82,
        "contact_note": "По вопросам сотрудничества и предпроектных консультаций свяжитесь с нами."
    },
    {
        "id": 2,
        "name": "Студия разработки «Код & Пиксель»",
        "tag": "Цифровые технологии & Web",
        "title": "Разработка сложных веб-сервисов и мобильных приложений",
        "subtitle": "Инженерный подход к созданию масштабируемых цифровых платформ и корпоративного ПО. Мы обновляем витрину кейсов и портфолио.",
        "badge": "Технические работы",
        "color_bg": "#090d16",
        "color_card": "#111827",
        "color_border": "#1f2937",
        "color_accent": "#6366f1",
        "color_text": "#f3f4f6",
        "color_muted": "#9ca3af",
        "cards": [
            ("Веб-сервисы и SaaS", "Высоконагруженные платформы на современной микросервисной архитектуре."),
            ("Мобильные приложения", "Нативная и кроссплатформенная разработка для iOS и Android."),
            ("UI/UX & Прототипирование", "Продуманный пользовательский опыт и дизайн-системы для бизнеса.")
        ],
        "progress": 78,
        "contact_note": "Принимаем новые заявки на проектирование и аудит существующих систем."
    },
    {
        "id": 3,
        "name": "Кофейная лаборатория «Зерно & Пламя»",
        "tag": "Спешелти кофе & Обжарка",
        "title": "Свежая обжарка спешелти кофе и поставки для заведений",
        "subtitle": "Отбираем микролоты арабики с высокогорных плантаций Эфиопии, Кении и Колумбии. Готовим к запуску онлайн-магазин и B2B-портал.",
        "badge": "Скоро открытие",
        "color_bg": "#151110",
        "color_card": "#211a18",
        "color_border": "#332824",
        "color_accent": "#d97706",
        "color_text": "#fef3c7",
        "color_muted": "#a8a29e",
        "cards": [
            ("Свежая обжарка", "Еженедельные профильные партии на экологичном ростере Giesen."),
            ("Оптовые поставки", "Комплексное снабжение кофеен, офисов и ресторанов свежим зерном."),
            ("Обучение бариста", "Семинары по каппингу, органолептике и настройке экстракции.")
        ],
        "progress": 88,
        "contact_note": "Заказ пробных партий и образцов для кофеен доступен по запросу."
    },
    {
        "id": 4,
        "name": "Юридическое бюро «Вердикт & Партнеры»",
        "tag": "Право & Арбитраж",
        "title": "Корпоративное право, арбитражные споры и защита активов",
        "subtitle": "Обеспечиваем надежную правовую безопасность предпринимателей и юридическую поддержку инвестиционных сделок. Сайт находится на обновлении.",
        "badge": "Обновление портала",
        "color_bg": "#0b1326",
        "color_card": "#121d38",
        "color_border": "#1e2f56",
        "color_accent": "#3b82f6",
        "color_text": "#f1f5f9",
        "color_muted": "#94a3b8",
        "cards": [
            ("Корпоративная защита", "M&A сделки, разрешение акционерных конфликтов и защита от поглощений."),
            ("Арбитражные споры", "Комплексное ведение сложных судебных процессов во всех инстанциях."),
            ("Налоговый консалтинг", "Анализ рисков, структурирование холдингов и досудебное урегулирование.")
        ],
        "progress": 72,
        "contact_note": "Консультации доверителей проводятся в штатном режиме по предварительной записи."
    },
    {
        "id": 5,
        "name": "Студия дизайна «Аура Интерьер»",
        "tag": "Интерьерный дизайн & Декор",
        "title": "Авторский дизайн жилых и коммерческих пространств",
        "subtitle": "Чистые линии, естественный свет и натуральные текстуры. Создаем пространства, где хочется жить и творить. Скоро здесь появится галерея проектов.",
        "badge": "Сайт в разработке",
        "color_bg": "#141312",
        "color_card": "#1f1d1a",
        "color_border": "#332f2b",
        "color_accent": "#eab308",
        "color_text": "#fef9c3",
        "color_muted": "#a8a29e",
        "cards": [
            ("Полный дизайн-проект", "3D-визуализация, обмерные plans, спецификации и схемы коммуникаций."),
            ("Комплектация объектов", "Прямой подбор мебели, сантехники и отделочных материалов от фабрик."),
            ("Авторский надзор", "Строгий контроль совпадения строительного процесса с дизайн-проектом.")
        ],
        "progress": 85,
        "contact_note": "Записаться на встречу с ведущим архитектором студии можно через контакты ниже."
    },
    {
        "id": 6,
        "name": "Продакшн-студия «Кадр & Свет»",
        "tag": "Видео & Фотопродакшн",
        "title": "Рекламный продакшн, визуальный контент и видеосъемка",
        "subtitle": "Создаем имиджевые ролики, рекламные кампании и арт-проекты. Наш сайт готовится к презентации нового шоурила сезона.",
        "badge": "Скоро премьера",
        "color_bg": "#111111",
        "color_card": "#1c1c1c",
        "color_border": "#2e2e2e",
        "color_accent": "#ef4444",
        "color_text": "#f5f5f5",
        "color_muted": "#a3a3a3",
        "cards": [
            ("Имиджевые ролики", "Концептуальные видеоистории для брендов, бизнеса и корпораций."),
            ("Рекламная фотография", "Предметная съемка, фуд-стайлинг и модельные кампейны для ритейла."),
            ("Постпродакшн", "Монтаж, цветокоррекция, саунд-дизайн и компьютерная графика.")
        ],
        "progress": 90,
        "contact_note": "Для отправки брифа и запроса сметы воспользуйтесь электронной почтой."
    },
    {
        "id": 7,
        "name": "Лингвистический центр «Лингва Сфера»",
        "tag": "Иностранные языки & Образование",
        "title": "Интенсивное обучение языкам и профессиональный перевод",
        "subtitle": "Обучаем европейским и восточным языкам по коммуникативной методике с аккредитованными преподавателями. Мы переносим платформу на новый движок.",
        "badge": "Запуск платформы",
        "color_bg": "#061715",
        "color_card": "#0c2622",
        "color_border": "#133d36",
        "color_accent": "#10b981",
        "color_text": "#ecfdf5",
        "color_muted": "#86efac",
        "cards": [
            ("Корпоративное обучение", "Языковые курсы для компаний с фокусом на деловые переговоры."),
            ("Подготовка к экзаменам", "Интенсивы по сдаче международных сертификаций IELTS, TOEFL, HSK."),
            ("Письменный перевод", "Перевод технической, финансовой и академической документации.")
        ],
        "progress": 80,
        "contact_note": "Запись на бесплатное онлайн-тестирование уровня открыта через координаторов."
    },
    {
        "id": 8,
        "name": "Ландшафтное бюро «ГринЛэнд»",
        "tag": "Ландшафтный дизайн & Озеленение",
        "title": "Проектирование садов и комплексное благоустройство территорий",
        "subtitle": "Превращаем частные участки и общественные парки в цветущие природные оазисы. Сайт находится в разработке к открытию весеннего сезона.",
        "badge": "Сезонная подготовка",
        "color_bg": "#0a160f",
        "color_card": "#122419",
        "color_border": "#1b3827",
        "color_accent": "#22c55e",
        "color_text": "#f0fdf4",
        "color_muted": "#86efac",
        "cards": [
            ("Генеральный план сада", "Дендроплан, баланс освещения, зонирование отдыха и дорожные сети."),
            ("Автоматический полив", "Проектирование и монтаж надежных систем капельного и дождевого орошения."),
            ("Посадка крупномеров", "Отбор взрослых деревьев в европейских и отечественных питомниках.")
        ],
        "progress": 76,
        "contact_note": "Выезд ландшафтного архитектора на замер участка осуществляется по согласованию."
    },
    {
        "id": 9,
        "name": "Консалтинговая группа «Стратегия Роста»",
        "tag": "Бизнес-консалтинг & Аудит",
        "title": "Управленческий консалтинг, аудит и повышение эффективности",
        "subtitle": "Оптимизируем операционные цепочки, перестраиваем бизнес-модели и внедряем аналитические панели управления. Сайт обновляется.",
        "badge": "В процессе обновления",
        "color_bg": "#120e1a",
        "color_card": "#1c1629",
        "color_border": "#2c2240",
        "color_accent": "#a855f7",
        "color_text": "#faf5ff",
        "color_muted": "#c084fc",
        "cards": [
            ("Аудит процессов", "Выявление узких мест, устранение кассовых разрывов и снижение издержек."),
            ("Финансовая модель", "Построение динамических моделей Unit-экономики и сценарного прогнозирования."),
            ("Трансформация продаж", "Внедрение CRM, регламентов, мотивации и аналитики конверсий.")
        ],
        "progress": 84,
        "contact_note": "Заказ первичного экспресс-аудита компании доступен через наших аналитиков."
    },
    {
        "id": 10,
        "name": "Фитнес-клуб «Импульс»",
        "tag": "Спорт & Функциональный фитнес",
        "title": "Персональный тренинг, биомеханика и здоровое тело",
        "subtitle": "Инновационное пространство для тренировок без перегрузок под контролем сертифицированных тренеров. Готовимся к открытию нового филиала.",
        "badge": "Скоро открытие",
        "color_bg": "#101314",
        "color_card": "#181d1f",
        "color_border": "#262e30",
        "color_accent": "#84cc16",
        "color_text": "#f7fee7",
        "color_muted": "#bef264",
        "cards": [
            ("Функциональные тренировки", "Развитие выносливости, координации и взрывной силы без травм."),
            ("Восстановление и ЛФК", "Коррекция осанки, мобильность суставов и снятие мышечных зажимов."),
            ("Нутрициология", "Индивидуальный план сбалансированного питания под ваши цели.")
        ],
        "progress": 89,
        "contact_note": "Предварительное бронирование клубных карт со скидкой открыто для первых клиентов."
    },
    {
        "id": 11,
        "name": "Стоматологический центр «Дента Арт»",
        "tag": "Медицина & Стоматология",
        "title": "Высокоточная цифровая стоматология и эстетика улыбки",
        "subtitle": "Бережная имплантация, лечение под дентальным микроскопом и виниры ручной работы. Мы обновляем онлайн-запись и личный кабинет пациента.",
        "badge": "Сайт в разработке",
        "color_bg": "#09141c",
        "color_card": "#10202d",
        "color_border": "#193245",
        "color_accent": "#06b6d4",
        "color_text": "#ecfeff",
        "color_muted": "#67e8f9",
        "cards": [
            ("Лечение под микроскопом", "Максимальное сохранение здоровых тканей зуба при лечении каналов."),
            ("Эстетические виниры", "Индивидуальное моделирование естественной формы и прозрачности эмали."),
            ("Дентальная имплантация", "Использование швейцарских систем Straumann и щадящих протоколов.")
        ],
        "progress": 86,
        "contact_note": "Запись пациентов ведется через регистратуру клиники по телефону."
    },
    {
        "id": 12,
        "name": "Столярная мастерская «Массив & Сталь»",
        "tag": "Крафтовая мебель & Массив",
        "title": "Авторская мебель из слэбов ценных пород и металла",
        "subtitle": "Создаем долговечные обеденные столы, мебель для гостиных и авторские предметы интерьера из векового дуба и карагача. Заполняем онлайн-каталог.",
        "badge": "Наполнение каталога",
        "color_bg": "#14100c",
        "color_card": "#211a14",
        "color_border": "#362a21",
        "color_accent": "#f97316",
        "color_text": "#fff7ed",
        "color_muted": "#fdba74",
        "cards": [
            ("Обеденные столы", "Массив дуба и ясеня с заливкой полимерной смолой и финишным эко-маслом."),
            ("Мебель в стиле лофт", "Сочетание теплого натурального дерева и порошковой стали ручной гибки."),
            ("Индивидуальные заказы", "Изготовление нестандартных барных стоек, стеллажей и витрин по эскизам.")
        ],
        "progress": 74,
        "contact_note": "Ознакомиться с образцами древесины и спилов можно в нашем шоуруме."
    },
    {
        "id": 13,
        "name": "Логистическая группа «Северный Транзит»",
        "tag": "Логистика & Грузоперевозки",
        "title": "Мультимодальные грузоперевозки и экспедирование",
        "subtitle": "Надежная доставка сборных и генеральных грузов автомобильным, железнодорожным и морским транспортом. Ведутся работы по запуску трекинг-системы.",
        "badge": "Технические работы",
        "color_bg": "#0c131f",
        "color_card": "#142033",
        "color_border": "#1e304d",
        "color_accent": "#0284c7",
        "color_text": "#f0f9ff",
        "color_muted": "#7dd3fc",
        "cards": [
            ("Сборные грузы", "Регулярные рейсы между региональными хабами с гарантией сроков."),
            ("Складская обработка", "Ответственное хранение, маркировка, паллетирование и кросс-докинг."),
            ("Таможенное оформление", "Полное сопровождение ВЭД, декларирование и сертификация товаров.")
        ],
        "progress": 81,
        "contact_note": "Для оперативного расчета ставки фрахта направьте спецификацию груза на email."
    },
    {
        "id": 14,
        "name": "Студия осознанности «Шанти Пространство»",
        "tag": "Йога & Ментальное здоровье",
        "title": "Практики осознанности, хатха-йога и телесная терапия",
        "subtitle": "Уютное городское убежище от шума мегаполиса. Пространство для восстановления сил, глубокого дыхания и душевного равновесия. Скоро старт занятий.",
        "badge": "Скоро открытие",
        "color_bg": "#141312",
        "color_card": "#1f1d1a",
        "color_border": "#312d29",
        "color_accent": "#fb923c",
        "color_text": "#fff7ed",
        "color_muted": "#fed7aa",
        "cards": [
            ("Хатха и Виньяса йога", "Утренние и вечерние практики разного уровня подготовки с опытными мастерами."),
            ("Звукотерапия (Гонг)", "Медитации с тибетскими поющими чашами для глубокой релаксации нервной системы."),
            ("Дыхательные сессии", "Пранаяма и техники осознанного дыхания для снятия тревожности и стресса.")
        ],
        "progress": 92,
        "contact_note": "Расписание занятий и абонементы раннего доступа будут доступны совсем скоро."
    },
    {
        "id": 15,
        "name": "Инженерная лаборатория «ТехноЛаб»",
        "tag": "Электроника & Высокоточный ремонт",
        "title": "Компонентный ремонт сложной электроники и микропайка",
        "subtitle": "Профессиональное лабораторное оборудование, тепловизионная диагностика и восстановление печатных плат промышленной техники. Обновляем сайт.",
        "badge": "Сайт в разработке",
        "color_bg": "#0a1017",
        "color_card": "#111b26",
        "color_border": "#1b2c3d",
        "color_accent": "#38bdf8",
        "color_text": "#f0f9ff",
        "color_muted": "#7dd3fc",
        "cards": [
            ("BGA-пайка и реболлинг", "Замена процессоров, контроллеров питания и графических чипов под микроскопом."),
            ("Промышленная автоматика", "Диагностика и ремонт плат станков с ЧПУ, частотных преобразователей и ИБП."),
            ("Восстановление топологии", "Устранение последствий коротких замыканий, влаги и межслойных обрывов.")
        ],
        "progress": 77,
        "contact_note": "Прием оборудования на сложную диагностику осуществляется инженерами в рабочие дни."
    }
]

if chosen_id > 0 and chosen_id <= len(THEMES):
    theme = next(t for t in THEMES if t["id"] == chosen_id)
else:
    theme = random.choice(THEMES)

cards_html = ""
for title, desc in theme["cards"]:
    cards_html += f"""
        <div class="card">
            <h3>{title}</h3>
            <p>{desc}</p>
        </div>"""

now_year = datetime.datetime.now().year

html = f"""<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{theme['name']} — {theme['tag']}</title>
    <meta name="description" content="{theme['subtitle']}">
    <style>
        :root {{
            --bg: {theme['color_bg']};
            --card-bg: {theme['color_card']};
            --border: {theme['color_border']};
            --accent: {theme['color_accent']};
            --text: {theme['color_text']};
            --muted: {theme['color_muted']};
        }}
        * {{ box-sizing: border-box; margin: 0; padding: 0; }}
        body {{
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            background-color: var(--bg);
            color: var(--text);
            line-height: 1.6;
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            justify-content: space-between;
        }}
        header {{
            border-bottom: 1px solid var(--border);
            padding: 18px 24px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            max-width: 1100px;
            margin: 0 auto;
            width: 100%;
        }}
        .brand {{
            font-weight: 700;
            font-size: 1.15rem;
            color: var(--text);
            letter-spacing: -0.01em;
            display: flex;
            align-items: center;
            gap: 10px;
        }}
        .brand-dot {{
            width: 10px;
            height: 10px;
            border-radius: 50%;
            background-color: var(--accent);
            display: inline-block;
        }}
        .badge {{
            display: inline-flex;
            align-items: center;
            gap: 6px;
            padding: 5px 12px;
            border-radius: 20px;
            font-size: 0.8rem;
            font-weight: 600;
            background: rgba(255,255,255,0.05);
            border: 1px solid var(--border);
            color: var(--accent);
        }}
        .pulse {{
            width: 7px;
            height: 7px;
            border-radius: 50%;
            background-color: var(--accent);
            animation: pulse-anim 2s infinite;
        }}
        @keyframes pulse-anim {{
            0% {{ transform: scale(0.95); box-shadow: 0 0 0 0 rgba(255,255,255,0.5); }}
            70% {{ transform: scale(1); box-shadow: 0 0 0 6px rgba(255,255,255,0); }}
            100% {{ transform: scale(0.95); box-shadow: 0 0 0 0 rgba(255,255,255,0); }}
        }}
        main {{
            max-width: 1000px;
            margin: 0 auto;
            padding: 60px 24px;
            width: 100%;
            text-align: center;
        }}
        .tag-label {{
            color: var(--accent);
            text-transform: uppercase;
            font-size: 0.82rem;
            font-weight: 700;
            letter-spacing: 0.08em;
            margin-bottom: 16px;
            display: inline-block;
        }}
        h1 {{
            font-size: 2.5rem;
            font-weight: 800;
            letter-spacing: -0.03em;
            line-height: 1.2;
            margin-bottom: 20px;
            color: #ffffff;
        }}
        @media (max-width: 640px) {{
            h1 {{ font-size: 1.85rem; }}
        }}
        p.subtitle {{
            font-size: 1.15rem;
            color: var(--muted);
            max-width: 720px;
            margin: 0 auto 40px;
        }}
        .progress-box {{
            background: var(--card-bg);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 20px 24px;
            max-width: 580px;
            margin: 0 auto 50px;
            text-align: left;
        }}
        .progress-header {{
            display: flex;
            justify-content: space-between;
            font-size: 0.85rem;
            font-weight: 600;
            margin-bottom: 10px;
            color: var(--text);
        }}
        .progress-bar-bg {{
            background: rgba(255,255,255,0.08);
            border-radius: 6px;
            height: 8px;
            overflow: hidden;
            margin-bottom: 10px;
        }}
        .progress-bar-fill {{
            background: var(--accent);
            height: 100%;
            border-radius: 6px;
            width: {theme['progress']}%;
        }}
        .progress-subtext {{
            font-size: 0.8rem;
            color: var(--muted);
        }}
        .grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
            gap: 20px;
            margin-bottom: 40px;
            text-align: left;
        }}
        .card {{
            background: var(--card-bg);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 24px;
            transition: transform 0.2s, border-color 0.2s;
        }}
        .card:hover {{
            transform: translateY(-3px);
            border-color: var(--accent);
        }}
        .card h3 {{
            color: #ffffff;
            font-size: 1.15rem;
            margin-bottom: 10px;
            font-weight: 700;
        }}
        .card p {{
            color: var(--muted);
            font-size: 0.92rem;
            line-height: 1.55;
        }}
        .contact-box {{
            padding: 24px;
            background: rgba(255,255,255,0.02);
            border: 1px dashed var(--border);
            border-radius: 12px;
            font-size: 0.92rem;
            color: var(--muted);
            max-width: 700px;
            margin: 0 auto;
        }}
        footer {{
            border-top: 1px solid var(--border);
            padding: 24px;
            text-align: center;
            font-size: 0.85rem;
            color: var(--muted);
            margin-top: 40px;
        }}
    </style>
</head>
<body>
    <header>
        <div class="brand">
            <span class="brand-dot"></span>
            <span>{theme['name']}</span>
        </div>
        <div class="badge">
            <span class="pulse"></span>
            <span>{theme['badge']}</span>
        </div>
    </header>
    <main>
        <div class="tag-label">{theme['tag']}</div>
        <h1>{theme['title']}</h1>
        <p class="subtitle">{theme['subtitle']}</p>
        
        <div class="progress-box">
            <div class="progress-header">
                <span>Готовность новой версии платформы</span>
                <span style="color: var(--accent);">{theme['progress']}%</span>
            </div>
            <div class="progress-bar-bg">
                <div class="progress-bar-fill"></div>
            </div>
            <div class="progress-subtext">Ведутся завершающие пусконаладочные работы и оптимизация интерфейса.</div>
        </div>

        <div class="grid">
            {cards_html}
        </div>

        <div class="contact-box">
            <p>{theme['contact_note']}</p>
            <p style="margin-top: 8px; font-weight: 600; color: var(--text);">Связь с администрацией: contact@{domain}</p>
        </div>
    </main>
    <footer>
        &copy; {now_year} {theme['name']}. Все права защищены. Доменное имя {domain} зарегистрировано и обслуживается законным владельцем.
    </footer>
</body>
</html>"""

with open(dest_file, "w", encoding="utf-8") as f:
    f.write(html)

print(f"{theme['id']}|{theme['name']}|{theme['tag']}")
PY_DECOY_EOF
)
    local t_id t_name t_tag
    t_id=$(echo "$gen_output" | cut -d'|' -f1)
    t_name=$(echo "$gen_output" | cut -d'|' -f2)
    t_tag=$(echo "$gen_output" | cut -d'|' -f3)
    msg_ok "Установлена тема-заглушка #$t_id: '${t_name}' (${t_tag})"
    echo -e "   ↳ Файл: ${dest_file} | Домен: ${target_domain}"
}

interactive_choose_fake_theme() {
    clear
    echo -e "${BOLD}${CYAN}================================================================================${NC}"
    echo -e "${BOLD}${CYAN}            🎨 ВЫБОР ТЕМАТИКИ САЙТА-ЗАГЛУШКИ ДЛЯ ДОМЕНА${NC}"
    echo -e "${BOLD}${CYAN}================================================================================${NC}"
    echo -e "Все темы оформлены на русском языке с пометкой о разработке/скором открытии:"
    echo ""
    echo -e "  ${GREEN}[0]  🎲 Случайная тема (автовыбор)${NC}"
    echo -e "  [1]  🏛️  Архитектурное бюро «Форма и Пространство» (Архитектура & Проектирование)"
    echo -e "  [2]  💻 Студия разработки «Код & Пиксель» (Цифровые технологии & Web)"
    echo -e "  [3]  ☕ Кофейная лаборатория «Зерно & Пламя» (Спешелти кофе & Обжарка)"
    echo -e "  [4]  ⚖️  Юридическое бюро «Вердикт & Партнеры» (Право & Арбитраж)"
    echo -e "  [5]  🛋️  Студия дизайна «Аура Интерьер» (Интерьерный дизайн & Декор)"
    echo -e "  [6]  🎬 Продакшн-студия «Кадр & Свет» (Видео & Фотопродакшн)"
    echo -e "  [7]  🌍 Лингвистический центр «Лингва Сфера» (Иностранные языки & Образование)"
    echo -e "  [8]  🌿 Ландшафтное бюро «ГринЛэнд» (Ландшафтный дизайн & Озеленение)"
    echo -e "  [9]  📈 Консалтинговая группа «Стратегия Роста» (Бизнес-консалтинг & Аудит)"
    echo -e "  [10] 🏋️  Фитнес-клуб «Импульс» (Спорт & Функциональный фитнес)"
    echo -e "  [11] 🦷 Стоматологический центр «Дента Арт» (Медицина & Стоматология)"
    echo -e "  [12] 🪵 Столярная мастерская «Массив & Сталь» (Крафтовая мебель & Массив)"
    echo -e "  [13] 🚛 Логистическая группа «Северный Транзит» (Логистика & Грузоперевозки)"
    echo -e "  [14] 🧘 Студия осознанности «Шанти Пространство» (Йога & Ментальное здоровье)"
    echo -e "  [15] 🔬 Инженерная лаборатория «ТехноЛаб» (Электроника & Высокоточный ремонт)"
    echo ""
    read -rp "Выберите номер темы [0-15, Enter=случайная]: " selected_theme
    selected_theme="${selected_theme:-0}"
    generate_fake_website "$domain" "$selected_theme" "/var/www/html/index.html"
    systemctl reload nginx 2>/dev/null || true
}

################################## Argument Parsing ###########################
while [ "$#" -gt 0 ]; do
    case "$1" in
        -role)             SERVER_ROLE="$2"; shift 2;;
        -domain)           domain="$2"; shift 2;;
        -cascade_url)
            CASCADE_EU_URL="$2"
            CASCADE_COUNT=1
            CASCADE_URLS[1]="$2"
            CASCADE_TAGS[1]="cascade-out-1"
            CASCADE_ALIASES[1]="Exit-1"
            shift 2;;
        -cascade_urls)     CASCADE_URLS_ARG="$2"; shift 2;;
        -tg-menu|--tg-menu|-tg)
            interactive_telegram_bot_menu
            exit 0;;
        -reality_target)   REALITY_DEFAULT_TARGET="$2"; shift 2;;
        -reality_sni)      REALITY_DEFAULT_SNI="$2"; shift 2;;
        -version)          PANEL_VER="$2"; shift 2;;
        -ONLY_CF_IP_ALLOW) CFALLOW="$2"; shift 2;;
        -tg_token)         TG_BOT_TOKEN="$2"; shift 2;;
        -tg_id)            TG_CHAT_ID="$2"; shift 2;;
        -no_tg_backup|-no-tg-backup) ENABLE_TG_BACKUP="n"; shift 1;;
        -enable_tg_backup) ENABLE_TG_BACKUP="$2"; shift 2;;
        -sub_title|-sub-title|--sub-title) SUB_TITLE="$2"; shift 2;;
        -check|--check)    CHECK_SERVICES="y"; shift 1;;
        -scan|--scan)      SCAN_REALITY_ONLY="y"; shift 1;;
        -backup|--backup)  RUN_BACKUP_NOW="y"; shift 1;;
        -update-geodata|--update-geodata) RUN_GEODATA_UPDATE_NOW="y"; shift 1;;
        -fake|--fake)
            CHANGE_FAKE_SITE="y"
            if [[ -n "$2" && "$2" != -* ]]; then
                FAKE_THEME_CHOICE="$2"
                shift 2
            else
                FAKE_THEME_CHOICE=""
                shift 1
            fi
            ;;
        -random-fake|--random-fake)
            CHANGE_FAKE_SITE="y"
            FAKE_THEME_CHOICE="0"
            shift 1
            ;;
        -base-soft|--base-soft) RUN_BASE_SOFT="y"; shift 1;;
        -uninstall)        UNINSTALL="$2"; shift 2;;
        *) shift 1;;
    esac
done

if [[ -n "$CASCADE_URLS_ARG" ]]; then
    CASCADE_URLS=()
    CASCADE_TAGS=()
    CASCADE_ALIASES=()
    CASCADE_COUNT=0
    IFS=',' read -ra CU_ARR <<< "$CASCADE_URLS_ARG"
    for cu in "${CU_ARR[@]}"; do
        cu=$(echo "$cu" | tr -d '[:space:]')
        if [[ -n "$cu" ]]; then
            CASCADE_COUNT=$((CASCADE_COUNT + 1))
            CASCADE_URLS[$CASCADE_COUNT]="$cu"
            CASCADE_TAGS[$CASCADE_COUNT]="cascade-out-$CASCADE_COUNT"
            CASCADE_ALIASES[$CASCADE_COUNT]="Exit-$CASCADE_COUNT"
        fi
    done
    [[ "$CASCADE_COUNT" -gt 0 ]] && CASCADE_EU_URL="${CASCADE_URLS[1]}"
fi

if [[ "$CHECK_SERVICES" == "y" ]]; then
    check_services_accessibility
    exit 0
fi

if [[ "$SCAN_REALITY_ONLY" == "y" ]]; then
    find_best_reality_target "verbose"
    exit 0
fi

if [[ "$RUN_BACKUP_NOW" == "y" ]]; then
    if [[ -x /usr/local/bin/x-ui-backup.sh ]]; then
        exec /usr/local/bin/x-ui-backup.sh
    else
        msg_err "Скрипт бэкапа /usr/local/bin/x-ui-backup.sh не найден!"
        exit 1
    fi
fi

if [[ "$RUN_GEODATA_UPDATE_NOW" == "y" ]]; then
    if [[ -x /usr/local/bin/x-ui-geodata-update.sh ]]; then
        exec /usr/local/bin/x-ui-geodata-update.sh
    else
        msg_err "Скрипт обновления баз /usr/local/bin/x-ui-geodata-update.sh не найден!"
        exit 1
    fi
fi

if [[ "$CHANGE_FAKE_SITE" == "y" ]]; then
    if [[ -z "$FAKE_THEME_CHOICE" && -t 0 ]]; then
        interactive_choose_fake_theme
    else
        generate_fake_website "$domain" "${FAKE_THEME_CHOICE:-0}" "/var/www/html/index.html"
        systemctl reload nginx 2>/dev/null || true
    fi
    exit 0
fi

if [[ "$RUN_BASE_SOFT" == "y" ]]; then
    msg_step "Запуск установки базового ПО с github.com/TViN-X/base-vps-soft-install..."
    bash <(curl -fsSL https://raw.githubusercontent.com/TViN-X/base-vps-soft-install/master/install.sh)
    exit 0
fi

################################## Uninstall ##################################
UNINSTALL_XUI() {
    msg_step "Removing OmniStack, Nginx and related services..."
    if command -v x-ui &>/dev/null; then
        printf 'y\n' | x-ui uninstall &>/dev/null || true
    fi
    systemctl stop x-ui sub2sing-box nginx &>/dev/null || true
    systemctl disable x-ui sub2sing-box nginx &>/dev/null || true
    
    rm -rf "/etc/x-ui/" "/usr/local/x-ui/" "/usr/bin/x-ui/" "/usr/bin/sub2sing-box" "/usr/local/omnistack" "/usr/local/x-ui-pro" "/usr/local/bin/omnistack" "/usr/bin/omnistack" "/usr/local/bin/x-ui-setup" "/usr/bin/x-ui-setup"
    rm -rf "/var/www/html/" "/var/www/subpage/" "/etc/nginx/" "/usr/share/nginx/" "/root/cert/"
    rm -f /etc/systemd/system/x-ui.service /etc/systemd/system/sub2sing-box.service
    rm -f /etc/cron.d/x-ui-backup /etc/cron.d/x-ui-geodata /usr/local/bin/x-ui-backup.sh /usr/local/bin/x-ui-geodata-update.sh /etc/sysctl.d/99-x-ui-tuning.conf
    rm -f /root/omnistack-credentials.txt /root/x-ui-pro-credentials.txt
    
    $Pak -y remove nginx nginx-common nginx-core nginx-full python3-certbot-nginx certbot &>/dev/null || true
    $Pak -y purge nginx nginx-common nginx-core nginx-full &>/dev/null || true
    $Pak -y autoremove &>/dev/null || true
    
    # Clean cronjobs
    crontab -l 2>/dev/null | grep -v -E "certbot|x-ui|sub2sing-box|cloudflareips|x-ui-backup|x-ui-geodata" | crontab - || true
    msg_ok "Completely uninstalled!"
    exit 0
}

if [[ ${UNINSTALL} == "y" || ${UNINSTALL} == "yes" ]]; then
    UNINSTALL_XUI
fi

################################## Cleanup Previous Install ###################
CLEANUP_PREVIOUS_INSTALL() {
    local detected="n"
    if command -v x-ui &>/dev/null || [[ -d /usr/local/x-ui ]] || [[ -f /etc/systemd/system/x-ui.service ]] || [[ -f /usr/local/bin/x-ui-setup ]] || [[ -d /usr/local/x-ui-pro ]] || [[ -d /etc/x-ui ]] || [[ -f /etc/nginx/sites-available/panel.whiteturn.ru ]] || ls /etc/nginx/sites-available/sub.* 1>/dev/null 2>&1; then
        detected="y"
    fi

    if [[ "$detected" == "y" ]]; then
        msg_step "Обнаружена предыдущая установка (x-ui-pro / x-ui / старый стек)..."
        msg_inf "Выполняем безопасную очистку старых компонентов перед установкой OmniStack..."
        
        # 1. Остановка старых служб
        systemctl stop x-ui sub2sing-box nginx 2>/dev/null || true
        systemctl disable sub2sing-box 2>/dev/null || true
        killall -9 sub2sing-box 2>/dev/null || true
        fuser -k 80/tcp 443/tcp 443/udp 7443/tcp 8443/tcp 8080/tcp 2>/dev/null || true

        # 2. Резервная копия базы x-ui на случай необходимости отката
        if [[ -f /etc/x-ui/x-ui.db ]]; then
            local bkp_dir="/var/backups/x-ui-pre-omnistack"
            mkdir -p "$bkp_dir"
            local bkp_file="$bkp_dir/x-ui.db.$(date +%Y%m%d_%H%M%S)"
            cp -f /etc/x-ui/x-ui.db "$bkp_file" 2>/dev/null || true
            msg_ok "Резервная копия старой базы X-UI сохранена: $bkp_file"
        fi

        # 3. Полная очистка старой базы данных и бинарников панели для чистой установки
        if [[ -f /etc/x-ui/x-ui.db ]]; then
            sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '' WHERE key IN ('subCertFile', 'subKeyFile');" 2>/dev/null || true
        fi
        rm -f /etc/x-ui/x-ui.db* /etc/x-ui/system_metrics.gob /etc/x-ui/update-status.json 2>/dev/null || true
        rm -rf /usr/local/x-ui
        rm -rf /etc/systemd/system/x-ui.service.d/

        # 4. Очистка старых виртуальных хостов и stream Nginx
        rm -f /etc/nginx/sites-enabled/*
        rm -f /etc/nginx/sites-available/sub.* /etc/nginx/sites-available/panel.* /etc/nginx/sites-available/80.conf
        rm -rf /etc/nginx/stream-enabled/*
        rm -f /etc/nginx/snippets/includes.conf /etc/nginx/cloudflareips.sh

        # 5. Очистка старых страниц подписки
        rm -rf /var/www/subpage/*

        # 6. Очистка старых cron-задач (x-ui, sub2sing-box, cloudflareips)
        # Сохраняются сторонние cron-задачи (бэкапы, боты, ipset и т.д.)
        if crontab -l &>/dev/null; then
            crontab -l 2>/dev/null | grep -v -E "x-ui|sub2sing-box|cloudflareips|x-ui-backup|x-ui-geodata" | crontab - || true
        fi
        rm -f /etc/cron.d/x-ui-backup /etc/cron.d/x-ui-geodata

        # 7. Очистка старых алиасов x-ui-pro
        rm -f /usr/local/bin/x-ui-setup /usr/bin/x-ui-setup
        rm -f /usr/local/bin/x-ui-backup.sh /usr/local/bin/x-ui-geodata-update.sh
        rm -rf /usr/local/x-ui-pro

        msg_ok "Очистка предыдущей установки завершена успешно."
    fi
}

################################## Interactive Menu ###########################
if [[ -z "$SERVER_ROLE" ]]; then
    while true; do
        show_banner
        echo -e "${BOLD}Выберите действие или режим работы сервера:${NC}"
        echo -e "  ${GREEN}[1] Внешний / Зарубежный сервер (Exit Node)${NC}"
        echo -e "      ↳ Прямой выход в интернет. Изоляция .RU-зоны в Blackhole (защита локального сетевого адреса)."
        echo ""
        echo -e "  ${CYAN}[2] Сервер в РФ с каскадом на внешние серверы (Cascade Ingress)${NC}"
        echo -e "      ↳ Сплит-маршрутизация: ресурсы РФ напрямую, остальной трафик -> в каскад на Exit-ноды (поддержка нескольких серверов)."
        echo ""
        echo -e "  ${YELLOW}[3] Сервер в РФ автономный (Standalone)${NC}"
        echo -e "      ↳ Полный сервер внутри РФ без исходящего каскадного туннеля."
        echo ""
        echo -e "  ${PURPLE}[4] 🔍 Проверить доступность сервисов (Telegram, Discord, YouTube, CDN...)${NC}"
        echo -e "      ↳ Экспресс-тест сетевой доступности внешних сервисов с сервера."
        echo ""
        echo -e "  ${BLUE}[5] 🎨 Сменить тему сайта-заглушки (выбор из 15 русскоязычных тем)${NC}"
        echo -e "      ↳ Установить тему сайта-маскировки (в разработке / скорое открытие) и обновить Nginx."
        echo ""
        echo -e "  ${CYAN}[6] 🤖 Управление Telegram-ботом и оповещениями (Вкл / Выкл / Токен)${NC}"
        echo -e "      ↳ Активация, настройка токена, тест отправки, еженедельные бэкапы и отключение бота."
        echo ""
        echo -e "  ${GREEN}[7] 🛡️  Клиентские конфиги WireGuard & MikroTik (.conf / QR / RouterOS)${NC}"
        echo -e "      ↳ Экспорт валидных WireGuard .conf файлов, QR-кодов и готовых команд для роутеров MikroTik."
        echo ""
        echo -e "  ${YELLOW}[8] 🔄 Обновить базы GeoIP и Geosite${NC}"
        echo -e "      ↳ Скачать свежие базы правил маршрутизации (Loyalsoldier / v2fly) для Xray."
        echo ""
        echo -e "  ${BLUE}[8] 🛠️  Установка базового ПО сервера (base-vps-soft-install)${NC}"
        echo -e "      ↳ Системные утилиты, безопасность и базовый софт с github.com/TViN-X/base-vps-soft-install."
        echo ""
        echo -e "  ${RED}[9] ❌ Удалить OmniStack полностью${NC}"
        echo -e "      ↳ Полная очистка: Nginx, 3X-UI, бэкапы, сертификаты и конфигурации."
        echo ""
        echo -e "  ${NC}[0] 🚪 Выход${NC}"
        echo ""
        read -rp "Ваш выбор [0-9]: " menu_choice

        case "$menu_choice" in
            1) SERVER_ROLE="exit"; break ;;
            2) SERVER_ROLE="cascade"; break ;;
            3) SERVER_ROLE="standalone"; break ;;
            4) 
                check_services_accessibility
                echo ""
                read -rp "Нажмите Enter для возврата в главное меню..." _
                ;;
            5)
                interactive_choose_fake_theme
                echo ""
                read -rp "Нажмите Enter для возврата в главное меню..." _
                ;;
            6)
                interactive_telegram_bot_menu
                ;;
            7)
                if [[ -x /usr/local/bin/x-ui-geodata-update.sh ]]; then
                    /usr/local/bin/x-ui-geodata-update.sh
                else
                    msg_err "Скрипт обновления баз /usr/local/bin/x-ui-geodata-update.sh не найден! Возможно сервер еще не установлен."
                fi
                echo ""
                read -rp "Нажмите Enter для возврата в главное меню..." _
                ;;
            8)
                msg_step "Запуск установки базового ПО с github.com/TViN-X/base-vps-soft-install..."
                bash <(curl -fsSL https://raw.githubusercontent.com/TViN-X/base-vps-soft-install/master/install.sh)
                echo ""
                read -rp "Нажмите Enter для возврата в главное меню..." _
                ;;
            9)
                echo ""
                read -rp "Вы действительно хотите полностью удалить OmniStack? [y/N]: " confirm_un
                if [[ "$confirm_un" =~ ^[Yy]$ ]]; then
                    UNINSTALL_XUI
                fi
                ;;
            0|q|exit)
                echo "Выход."
                exit 0
                ;;
            *)
                msg_warn "Неверный выбор. Повторите ввод."
                sleep 1
                ;;
        esac
    done
fi

if [[ "$SERVER_ROLE" == "cascade" ]]; then
    if [[ -n "$CASCADE_EU_URL" && "$CASCADE_COUNT" -gt 0 ]]; then
        : # Already populated from argument
    elif [[ -t 0 ]]; then
        echo ""
        echo -e "${BOLD}${CYAN}Настройка каскада (Ingress РФ ➔ Зарубежные Exit-ноды):${NC}"
        echo -e "Вы можете подключить один или несколько зарубежных серверов (Exit Nodes)."
        echo -e "Если серверов несколько, трафик разных сервисов (YouTube, AI, CDN...) можно распределить между ними."
        read -rp "Сколько зарубежных серверов планируется использовать? [1-9, Enter = 1]: " cascade_count_in
        CASCADE_COUNT="${cascade_count_in:-1}"
        if ! [[ "$CASCADE_COUNT" =~ ^[1-9]$ ]]; then
            CASCADE_COUNT=1
        fi

        for ((i=1; i<=CASCADE_COUNT; i++)); do
            echo ""
            default_alias="Exit-$i"
            if [[ "$CASCADE_COUNT" -gt 1 ]]; then
                read -rp "Имя/локация сервера #$i (например: Финляндия, Германия) [Exit-$i]: " alias_in
                CASCADE_ALIASES[$i]="${alias_in:-$default_alias}"
                echo -e "Введите ссылку подключения к серверу #$i (${CASCADE_ALIASES[$i]}):"
            else
                CASCADE_ALIASES[$i]="Exit-1"
                echo -e "Введите ссылку подключения к внешнему серверу (vless://..., trojan://..., ss://..., socks5://...):"
            fi
            read -rp "Ссылка подключения: " link_in
            while [[ -z "$link_in" ]]; do
                msg_warn "Ссылка подключения не может быть пустой!"
                read -rp "Повторите ввод ссылки подключения: " link_in
            done
            CASCADE_URLS[$i]="$link_in"
            CASCADE_TAGS[$i]="cascade-out-$i"
        done

        if [[ "$CASCADE_COUNT" -gt 1 ]]; then
            echo ""
            echo -e "Какой сервер использовать по умолчанию для остального интернет-трафика?"
            for ((i=1; i<=CASCADE_COUNT; i++)); do
                echo -e "  [$i] ${CASCADE_ALIASES[$i]} (${CASCADE_TAGS[$i]})"
            done
            read -rp "Выбор сервера по умолчанию [1-$CASCADE_COUNT, Enter = 1]: " def_choice
            def_choice="${def_choice:-1}"
            if [[ "$def_choice" =~ ^[1-9]$ ]] && [[ "$def_choice" -le "$CASCADE_COUNT" ]]; then
                DEFAULT_CASCADE_TAG="cascade-out-$def_choice"
            else
                DEFAULT_CASCADE_TAG="cascade-out-1"
            fi
        else
            DEFAULT_CASCADE_TAG="cascade-out-1"
        fi
        CASCADE_EU_URL="${CASCADE_URLS[1]}"
    else
        msg_warn "Ссылка не указана! Сервер будет настроен как обычный автономный в РФ."
        SERVER_ROLE="standalone"
    fi
fi

# Выборочная групповая маршрутизация сервисов
if [[ "$SERVER_ROLE" == "cascade" || "$SERVER_ROLE" == "standalone" ]]; then
    echo ""
    echo -e "${BOLD}${CYAN}Групповая маршрутизация сервисов:${NC}"
    echo -e "Каждая категория сервисов будет оформлена отдельным изолированным правилом маршрутизации:"
    echo -e "  [1] YouTube (Googlevideo CDN, youtube.com)"
    echo -e "  [2] Telegram"
    echo -e "  [3] Discord"
    echo -e "  [4] Остальные мессенджеры (WhatsApp, Signal, Viber, Skype, Element)"
    echo -e "  [5] Социальные сети (X/Twitter, Instagram, Facebook, Meta, TikTok, LinkedIn)"
    echo -e "  [6] Глобальные CDN сети (Cloudflare, Fastly, Akamai, Amazon AWS, Google)"
    echo -e "  [7] Нейросети и AI (OpenAI, Grok, Claude, Gemini Google AI, Perplexity, DeepSeek)"
    echo ""
    echo -e "${YELLOW}Примечание:${NC} Ресурсы РФ (.RU, geoip:ru) ВСЕГДА идут напрямую (DIRECT), а реклама блокируется."
    echo ""

    if [[ "$SERVER_ROLE" == "cascade" ]]; then
        echo -e "Доступные направления:"
        echo -e "  ${GREEN}[D]${NC} Напрямую через РФ (DIRECT)"
        for ((i=1; i<=CASCADE_COUNT; i++)); do
            echo -e "  ${CYAN}[$i]${NC} ${CASCADE_ALIASES[$i]} (${CASCADE_TAGS[$i]})"
        done
        if [[ -t 0 ]]; then
            echo ""
            echo -e "Выберите профиль настройки:"
            echo -e "  [1] Рекомендуемый профиль (Все группы 1-7 направляются на ${CASCADE_ALIASES[1]})"
            echo -e "  [2] Индивидуальное распределение каждой группы"
            read -rp "Ваш выбор [1/2, Enter = 1]: " grp_mode_in
            grp_mode_in="${grp_mode_in:-1}"
        else
            grp_mode_in="1"
        fi

        if [[ "$grp_mode_in" == "2" ]]; then
            for g in 1 2 3 4 5 6 7; do
                gname="${GROUP_NAMES[$g]}"
                read -rp "Направление для '${gname}' [D/1-${CASCADE_COUNT}, Enter = 1]: " g_dest
                g_dest=$(echo "$g_dest" | tr -d '[:space:]')
                if [[ "$g_dest" =~ ^[Dd0]$ ]]; then
                    GROUP_DEST_TAG[$g]="direct"
                elif [[ "$g_dest" =~ ^[1-9]$ ]] && [[ "$g_dest" -le "$CASCADE_COUNT" ]]; then
                    GROUP_DEST_TAG[$g]="cascade-out-$g_dest"
                else
                    GROUP_DEST_TAG[$g]="${DEFAULT_CASCADE_TAG}"
                fi
            done
        else
            for g in 1 2 3 4 5 6 7; do
                GROUP_DEST_TAG[$g]="${DEFAULT_CASCADE_TAG}"
            done
        fi
    else
        # Standalone (RU)
        if [[ -t 0 ]]; then
            echo -e "Направление для сервисов: по умолчанию все разрешены напрямую (DIRECT)."
            echo -e "Хотите заблокировать конкретные сервисы? [y/N]: "
            read -rp "Выбор [y/N, Enter = N]: " block_in
        else
            block_in="n"
        fi
        if [[ "$block_in" =~ ^[Yy]$ ]]; then
            for g in 1 2 3 4 5 6 7; do
                gname="${GROUP_NAMES[$g]}"
                read -rp "Направление для '${gname}' [D=Direct / B=Block, Enter = D]: " g_dest
                if [[ "$g_dest" =~ ^[Bb]$ ]]; then
                    GROUP_DEST_TAG[$g]="blocked"
                else
                    GROUP_DEST_TAG[$g]="direct"
                fi
            done
        else
            for g in 1 2 3 4 5 6 7; do
                GROUP_DEST_TAG[$g]="direct"
            done
        fi
    fi
fi

# Настройка еженедельного Telegram-бэкапа и информирования
if [[ "$ENABLE_TG_BACKUP" == "n" ]]; then
    msg_inf "Telegram-бэкап отключен."
elif [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]; then
    ENABLE_TG_BACKUP="y"
    msg_ok "Telegram-бэкап настроен из аргументов."
elif [[ -t 0 ]]; then
    echo ""
    echo -e "${BOLD}${CYAN}Автоматический еженедельный бэкап и статистика в Telegram (Вс 21:00):${NC}"
    read -rp "Включить автоматический бэкап базы и отправку статистики в Telegram? [Y/n]: " enable_tg_input
    if [[ "$enable_tg_input" =~ ^[Nn]$ ]]; then
        ENABLE_TG_BACKUP="n"
        msg_inf "Telegram-бэкап отключен."
    else
        ENABLE_TG_BACKUP="y"
        read -rp "Введите токен вашего Telegram-бота (от @BotFather): " tg_token_input
        TG_BOT_TOKEN="${tg_token_input:-$TG_BOT_TOKEN}"
        read -rp "Введите ваш Telegram Chat ID: " user_chat_id
        TG_CHAT_ID="${user_chat_id:-$TG_CHAT_ID}"
    fi
else
    ENABLE_TG_BACKUP="n"
    msg_inf "Неинтерактивный режим: Telegram-бэкап пропущен."
fi

# Domain input
while [[ -z "$domain" ]]; do
    echo ""
    read -rp "Введите ваш домен (например: sub.domain.com): " domain
    domain=$(echo "$domain" | tr -d '[:space:]')
done

msg_inf "Режим: ${SERVER_ROLE^^} | Домен: ${domain}"

################################## Get Server IPs #############################
IP4_REGEX="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*' || true)
[[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s4 --max-time 4 ipv4.icanhazip.com || echo "127.0.0.1")
msg_ok "Server Public IPv4: $IP4"

# Detect Server Country and Location Flag
detect_server_country_code() {
    local cc
    cc=$(curl -s4 -m 3 https://ipinfo.io/country 2>/dev/null || curl -s4 -m 3 https://ifconfig.co/country-iso 2>/dev/null || echo "RU")
    cc=$(echo "$cc" | tr -d ' \r\n' | tr '[:lower:]' '[:upper:]')
    if [[ ${#cc} -eq 2 && "$cc" =~ ^[A-Z]{2}$ ]]; then
        echo "$cc"
    else
        echo "RU"
    fi
}
SERVER_COUNTRY=$(detect_server_country_code)
SERVER_FLAG=$(python3 -c "import sys; print(''.join(chr(127397 + ord(c)) for c in sys.argv[1]))" "$SERVER_COUNTRY" 2>/dev/null || echo "🌐")
msg_ok "Server Location: ${SERVER_FLAG} [${SERVER_COUNTRY}]"

DEFAULT_SUB_TITLE="[${SERVER_COUNTRY}] - VPS - OmniStack"

if [[ -z "$SUB_TITLE" ]]; then
    if [[ -t 0 ]]; then
        echo ""
        echo -e "${BOLD}${CYAN}Настройка названия подписки и профиля клиента:${NC}"
        echo -e "Будет отображаться в приложениях (Happ, Incy, Clash/Mihomo) и на веб-портале."
        read -rp "Введите название подписки [Enter = '${DEFAULT_SUB_TITLE}']: " user_sub_title
        SUB_TITLE="${user_sub_title:-$DEFAULT_SUB_TITLE}"
    else
        SUB_TITLE="$DEFAULT_SUB_TITLE"
    fi
fi
msg_ok "Название подписки: ${SUB_TITLE}"

# Configure Swap if missing
setup_swap

# Optimize Linux Network Stack & Enable TCP BBR
setup_bbr_and_sysctl() {
    msg_step "Оптимизация сетевого стека Linux и включение TCP BBR..."
    modprobe tcp_bbr 2>/dev/null || true
    
    cat > "/etc/sysctl.d/99-x-ui-tuning.conf" << 'EOF'
# TCP BBR Congestion Control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Socket Buffers & Memory Limits (High Throughput & Low Latency)
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# Network Performance & Anti-Stall
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 32768

# IP Forwarding for WireGuard & AmneziaWG
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-x-ui-tuning.conf >/dev/null 2>&1 || true
    
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$cc" == "bbr" ]]; then
        msg_ok "TCP BBR успешно активирован (net.ipv4.tcp_congestion_control = bbr, fq)"
    else
        msg_warn "Текущий алгоритм TCP: $cc"
    fi
}
setup_bbr_and_sysctl

# Clean up any previous x-ui-pro / x-ui / omnistack installations before starting
CLEANUP_PREVIOUS_INSTALL

# Package Installation
msg_step "Installing required dependencies..."
$Pak -y update
$Pak -y install curl wget jq tar gzip certbot python3-certbot-nginx sqlite3 ufw openssl coreutils nginx-full wireguard-tools qrencode

# Stop existing web/proxy services to free ports
systemctl stop nginx x-ui 2>/dev/null || true
fuser -k 80/tcp 443/tcp 443/udp 2>/dev/null || true

################################## Generated Ports & Paths ####################
sub_port=$(make_port)
panel_port=$(make_port)
ws_port=$(make_port)
xhttp_port=$(make_port)
trojan_port=$(make_port)

# Non-standard random high ports in the 30000 range for WG, AWG and SS
make_high_port() {
    while true; do
        local p=$(( 30000 + RANDOM % 10000 ))
        if ! nc -z -u 127.0.0.1 "$p" &>/dev/null && ! nc -z 127.0.0.1 "$p" &>/dev/null; then
            echo "$p"
            break
        fi
    done
}
WG_PORT=$(make_high_port)
AWG1_PORT=$(make_high_port)
while [[ "$AWG1_PORT" == "$WG_PORT" ]]; do AWG1_PORT=$(make_high_port); done
AWG3_PORT=$(make_high_port)
while [[ "$AWG3_PORT" == "$WG_PORT" || "$AWG3_PORT" == "$AWG1_PORT" ]]; do AWG3_PORT=$(make_high_port); done

web_path=$(gen_random_string 12)
sub2singbox_path=$(gen_random_string 12)
sub_path=$(gen_random_string 12)
json_path=$(gen_random_string 12)
panel_path=$(gen_random_string 12)
ws_path=$(gen_random_string 10)
xhttp_path=$(gen_random_string 10)
trojan_path=$(gen_random_string 10)

config_username=$(gen_random_string 10)
config_password=$(gen_random_string 14)

# Unified Single Client Credentials across all protocols
CLIENT_UUID=$(gen_uuid)
CLIENT_EMAIL="first"
CLIENT_SUB_ID="first"

# Secure password for unified client (Hysteria, Trojan)
CLIENT_PASSWORD=$(openssl rand -base64 16 2>/dev/null | tr -d '\n\r' || gen_random_string 16)

# Generate Random AmneziaWG Obfuscation Parameters
AWG_JC=$(( (RANDOM % 4) + 3 ))       # 3 to 6
AWG_JMIN=$(( (RANDOM % 20) + 30 ))   # 30 to 50
AWG_JMAX=$(( (RANDOM % 30) + 60 ))   # 60 to 90
AWG_S1=$(( (RANDOM % 30) + 15 ))
AWG_S2=$(( (RANDOM % 30) + 15 ))
AWG_H1=$(( (RANDOM << 16) | RANDOM ))
AWG_H2=$(( (RANDOM << 16) | RANDOM ))
AWG_H3=$(( (RANDOM << 16) | RANDOM ))
AWG_H4=$(( (RANDOM << 16) | RANDOM ))

AWG_HPK=$(openssl rand -base64 32 2>/dev/null || (head -c 32 /dev/urandom | base64 | tr -d '\n\r'))
AWG_S3=$(( (RANDOM % 30) + 15 ))
AWG_S4=$(( (RANDOM % 30) + 15 ))

short_ids=()
for _ in {1..4}; do
    short_ids+=( "$(openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')" )
done

################################## SSL Setup (Let's Encrypt / Mock) ###########
msg_step "Configuring SSL Certificates..."
mkdir -p "/root/cert/${domain}"
mkdir -p "/var/www/html"

    # Configure basic Nginx on port 80 to pass ACME challenges cleanly
    cat > "/etc/nginx/sites-available/80.conf" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
    rm -f /etc/nginx/sites-enabled/default
    ln -sf "/etc/nginx/sites-available/80.conf" "/etc/nginx/sites-enabled/80.conf"
    systemctl restart nginx 2>/dev/null || true

    # Issue certificate using webroot
    certbot certonly --webroot -w /var/www/html --non-interactive --agree-tos \
        --register-unsafely-without-email -d "$domain" || {
        # Fallback to standalone if webroot had issues
        systemctl stop nginx 2>/dev/null || true
        certbot certonly --standalone --non-interactive --agree-tos \
            --register-unsafely-without-email -d "$domain"
    }

    if [[ -d "/etc/letsencrypt/live/${domain}/" ]]; then
        ln -sf "/etc/letsencrypt/live/${domain}/fullchain.pem" "/root/cert/${domain}/fullchain.pem"
        ln -sf "/etc/letsencrypt/live/${domain}/privkey.pem" "/root/cert/${domain}/privkey.pem"
        msg_ok "SSL certificate successfully obtained for ${domain}!"
    else
        msg_warn "Let's Encrypt failed! Generating self-signed fallback cert..."
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "/root/cert/${domain}/privkey.pem" \
            -out "/root/cert/${domain}/fullchain.pem" \
            -subj "/CN=${domain}" 2>/dev/null
    fi
chmod 755 /root/cert/*

################################## 3X-UI Installation #########################
msg_step "Installing 3X-UI panel (${PANEL_VER})..."
cd /usr/local/
    
    # Try fetching latest version dynamically if available, otherwise fallback to PANEL_VER
    tag_version=$(curl -Ls --max-time 4 "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || echo "")
    [[ -z "$tag_version" ]] && tag_version="$PANEL_VER"
    
    DOWNLOAD_URL="https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz"
    msg_inf "Downloading 3X-UI from: ${DOWNLOAD_URL}"
    
    if ! wget -q -O "/usr/local/x-ui-linux-$(arch).tar.gz" "${DOWNLOAD_URL}"; then
        msg_warn "Failed to download ${tag_version}, falling back to ${DEFAULT_PANEL_VERSION}..."
        DOWNLOAD_URL="https://github.com/MHSanaei/3x-ui/releases/download/${DEFAULT_PANEL_VERSION}/x-ui-linux-$(arch).tar.gz"
        wget -q -O "/usr/local/x-ui-linux-$(arch).tar.gz" "${DOWNLOAD_URL}" || {
            msg_err "Fatal: Failed to download 3X-UI archive."
            exit 1
        }
    fi

    rm -rf /usr/local/x-ui
    tar -xzf "x-ui-linux-$(arch).tar.gz"
    rm -f "x-ui-linux-$(arch).tar.gz"
    
    cd x-ui
    chmod +x x-ui bin/*
    
    # Download CLI management script
    wget -q -O /usr/bin/x-ui https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh 2>/dev/null || true
    chmod +x /usr/bin/x-ui 2>/dev/null || true

    # Service setup
    cp -f x-ui.service.debian /etc/systemd/system/x-ui.service 2>/dev/null || true
    systemctl daemon-reload
    
    # Run initial migration and set credentials
    /usr/local/x-ui/x-ui setting -username "${config_username}" -password "${config_password}" -port "${panel_port}" -webBasePath "${panel_path}" >/dev/null 2>&1 || true
    /usr/local/x-ui/x-ui migrate >/dev/null 2>&1 || true

################################## Keys Generation (X25519 & WireGuard) #######
msg_step "Generating cryptographic keys for Reality and WireGuard..."

# X25519 for Reality
XRAY_BIN="/usr/local/x-ui/bin/xray-linux-$(arch)"
[[ ! -f "$XRAY_BIN" ]] && XRAY_BIN="/usr/local/x-ui/bin/xray-linux-amd64"

REALITY_PRIV_KEY=""
REALITY_PUB_KEY=""

if [[ -x "$XRAY_BIN" ]]; then
    x25519_output=$("$XRAY_BIN" x25519 2>&1)
    # Robust multi-format parsing for Xray x25519 (PrivateKey: ... Password (PublicKey): ...)
    REALITY_PRIV_KEY=$(echo "$x25519_output" | grep -iE 'private' | head -n1 | awk '{print $NF}')
    REALITY_PUB_KEY=$(echo "$x25519_output" | grep -iE '(public|password)' | head -n1 | awk '{print $NF}')
fi

if [[ -z "$REALITY_PRIV_KEY" || -z "$REALITY_PUB_KEY" ]]; then
    msg_warn "Xray binary unavailable for x25519; generating keys via Python fallback..."
    read -r REALITY_PRIV_KEY REALITY_PUB_KEY < <(python3 -c '
import base64
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
priv = X25519PrivateKey.generate()
pub = priv.public_key()
print(base64.urlsafe_b64encode(priv.private_bytes_raw()).decode().rstrip("="), base64.urlsafe_b64encode(pub.public_bytes_raw()).decode().rstrip("="))
' 2>/dev/null || echo "kF7S4XpZ8... pA2B3C...")
fi

# Optimal REALITY Target auto-selection
if [[ -z "$REALITY_DEFAULT_TARGET" ]]; then
    find_best_reality_target
fi

# WireGuard & AmneziaWG Keys (Server & Client pairs)
gen_wg_keypair() {
    if command -v wg &>/dev/null; then
        local priv=$(wg genkey)
        local pub=$(echo "$priv" | wg pubkey)
        echo "$priv $pub"
    else
        python3 -c '
import base64
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
priv = X25519PrivateKey.generate()
pub = priv.public_key()
print(base64.b64encode(priv.private_bytes_raw()).decode(), base64.b64encode(pub.public_bytes_raw()).decode())
' 2>/dev/null || echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
    fi
}

read -r WG_SERVER_PRIV_KEY WG_SERVER_PUB_KEY < <(gen_wg_keypair)
read -r WG_CLIENT_PRIV_KEY WG_CLIENT_PUB_KEY < <(gen_wg_keypair)

read -r AWG1_SERVER_PRIV_KEY AWG1_SERVER_PUB_KEY < <(gen_wg_keypair)
read -r AWG1_CLIENT_PRIV_KEY AWG1_CLIENT_PUB_KEY < <(gen_wg_keypair)

read -r AWG3_SERVER_PRIV_KEY AWG3_SERVER_PUB_KEY < <(gen_wg_keypair)
read -r AWG3_CLIENT_PRIV_KEY AWG3_CLIENT_PUB_KEY < <(gen_wg_keypair)

msg_ok "Reality Private Key: ${REALITY_PRIV_KEY:0:10}... Public Key: ${REALITY_PUB_KEY:0:10}..."

################################## Database & Inbounds Setup ##################
msg_step "Configuring 3X-UI Database & Protocols..."

# Generator for Grouped Routing Rules, Clash Rules, and Happ/Incy Subscription
GROUP_MAP_STR=""
for k in "${!GROUP_DEST_TAG[@]}"; do
    GROUP_MAP_STR+="${k}=${GROUP_DEST_TAG[$k]} "
done

GENERATED_CONFIGS=$(python3 - "$GROUP_MAP_STR" "$SUB_TITLE" << 'PY_ROUTING_EOF'
import sys, json, base64

map_str = sys.argv[1] if len(sys.argv) > 1 else ""
sub_title = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else "OmniStack"

group_dest_map = {}
for pair in map_str.split():
    if "=" in pair:
        k, v = pair.split("=", 1)
        group_dest_map[k] = v

GOOGLE_AI_DOMAINS = [
    "deepmind.com", "deepmind.google", "geller-pa.googleapis.com",
    "generativelanguage.googleapis.com", "proactivebackend-pa.googleapis.com",
    "ai.google.dev", "generativeai.google", "makersuite.google.com",
    "aistudio.google.com", "bard.google.com", "gemini.google",
    "gemini.google.com", "notebooklm.google.com", "clients6.google.com",
    "notebooklm.google", "jules.google", "jules.google.com", "labs.google",
    "aisandbox-pa.googleapis.com", "stitch.withgoogle.com",
    "robinfrontend-pa.googleapis.com", "aida.googleapis.com",
    "antigravity-pa.googleapis.com", "antigravity.googleapis.com",
    "antigravity.google", "antigravity-unleash.goog",
    "firebaseinstallations.googleapis.com", "speechs3proto2-pa.googleapis.com"
]

GROUPS = {
    "1": {
        "name": "YouTube",
        "geosites": ["geosite:youtube", "geosite:googlevideo"],
        "domains": ["googlevideo.com", "youtube.com", "youtu.be", "ytimg.com"]
    },
    "2": {
        "name": "Telegram",
        "geosites": ["geosite:telegram"],
        "domains": []
    },
    "3": {
        "name": "Discord",
        "geosites": ["geosite:discord"],
        "domains": []
    },
    "4": {
        "name": "Other Messengers (WhatsApp, Signal, Viber, Skype, Element)",
        "geosites": ["geosite:whatsapp", "geosite:signal", "geosite:viber", "geosite:skype"],
        "domains": ["matrix.org", "element.io"]
    },
    "5": {
        "name": "Social Networks (X/Twitter, Instagram, Facebook, Meta, TikTok, LinkedIn)",
        "geosites": ["geosite:twitter", "geosite:instagram", "geosite:facebook", "geosite:meta", "geosite:linkedin", "geosite:tiktok"],
        "domains": ["x.com", "twitter.com", "t.co", "instagram.com", "cdninstagram.com", "facebook.com", "fbcdn.net", "threads.net"]
    },
    "6": {
        "name": "CDN Networks (Cloudflare, Fastly, Akamai, AWS, Google)",
        "geosites": ["geosite:cloudflare", "geosite:fastly", "geosite:akamai", "geosite:amazon", "geosite:aws", "geosite:google"],
        "domains": []
    },
    "7": {
        "name": "AI & LLMs (OpenAI, Grok, Claude, Gemini Google AI, Perplexity, DeepSeek)",
        "geosites": ["geosite:openai", "geosite:anthropic"],
        "domains": ["chatgpt.com", "oaistatic.com", "oaiusercontent.com", "claude.ai", "x.ai", "grok.com", "perplexity.ai", "deepseek.com"] + GOOGLE_AI_DOMAINS
    }
}

xray_rules = []
clash_rules = []
direct_sites = [
    "geosite:ru", "domain:ru", "domain:su", "domain:xn--p1ai",
    "geosite:category-gov-ru", "domain:gosuslugi.ru", "domain:sberbank.ru",
    "domain:tinkoff.ru", "domain:t-bank.ru", "domain:vtb.ru",
    "domain:alfabank.ru", "domain:yandex.ru", "domain:ya.ru",
    "domain:vk.com", "domain:vk.ru", "domain:mail.ru", "domain:avito.ru",
    "domain:ozon.ru", "domain:wildberries.ru", "domain:kinopoisk.ru",
    "geosite:private"
]
proxy_sites = []

for gid in sorted(GROUPS.keys(), key=int):
    tag = group_dest_map.get(gid)
    if not tag:
        continue
    g = GROUPS[gid]
    
    domain_list = list(g["geosites"])
    for d in g["domains"]:
        domain_list.append(f"domain:{d}")
    
    rule = {
        "type": "field",
        "domain": domain_list,
        "outboundTag": tag
    }
    xray_rules.append(rule)

    clash_target = "DIRECT" if tag == "direct" else "PROXY"
    for gs in g["geosites"]:
        c_name = gs.replace("geosite:", "")
        clash_rules.append(f"- GEOSITE,{c_name},{clash_target}")
    for d in g["domains"]:
        clash_rules.append(f"- DOMAIN-SUFFIX,{d},{clash_target}")

    if tag == "direct":
        for item in domain_list:
            if item not in direct_sites:
                direct_sites.append(item)
    else:
        for item in domain_list:
            if item not in proxy_sites:
                proxy_sites.append(item)

rules_json_str = ""
for r in xray_rules:
    rules_json_str += json.dumps(r, indent=6) + ",\n"

routing_obj = {
    "Name": f"{sub_title} - Smart Routing",
    "GlobalProxy": "true",
    "RouteOrder": "block-direct-proxy",
    "DomainStrategy": "IPIfNonMatch",
    "DomesticDNSType": "DoH",
    "DomesticDNSDomain": "https://dns.yandex.ru/dns-query",
    "DomesticDNSIP": "77.88.8.8",
    "RemoteDNSType": "DoH",
    "RemoteDNSDomain": "https://cloudflare-dns.com/dns-query",
    "RemoteDNSIP": "1.1.1.1",
    "DnsHosts": {
        "dns.yandex.ru": "77.88.8.8",
        "cloudflare-dns.com": "1.1.1.1"
    },
    "DirectSites": direct_sites,
    "DirectIp": [
        "geoip:ru", "geoip:private", "127.0.0.0/8", "10.0.0.0/8",
        "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
        "224.0.0.0/4", "255.255.255.255"
    ],
    "ProxySites": proxy_sites,
    "ProxyIp": [],
    "BlockSites": ["geosite:category-ads-all"],
    "BlockIp": []
}
raw_json = json.dumps(routing_obj, separators=(",", ":"), ensure_ascii=False)
happ_b64 = base64.b64encode(raw_json.encode("utf-8")).decode("utf-8")

output = {
    "xray_rules": rules_json_str.rstrip(",\n"),
    "clash_rules": "\n".join(clash_rules),
    "happ_b64": happ_b64
}
print(json.dumps(output))
PY_ROUTING_EOF
)

GROUP_ROUTING_RULES_JSON=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('xray_rules', ''))" "$GENERATED_CONFIGS" 2>/dev/null || echo "")
ADDITIONAL_CLASH_RULES=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('clash_rules', ''))" "$GENERATED_CONFIGS" 2>/dev/null || echo "")
ROUTING_B64=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('happ_b64', ''))" "$GENERATED_CONFIGS" 2>/dev/null || echo "")

if [[ -n "$GROUP_ROUTING_RULES_JSON" ]]; then
    GROUP_ROUTING_RULES_JSON="${GROUP_ROUTING_RULES_JSON},"
fi
# Helper to parse external proxy share link (VLESS, Trojan, SS, SOCKS5) into Xray outbound JSON
parse_cascade_outbound() {
    local url="$1"
    python3 -c '
import sys, json, urllib.parse, base64

def parse_link(link, tag="cascade-out"):
    link = link.strip()
    u = urllib.parse.urlparse(link)
    scheme = u.scheme.lower()
    
    if scheme == "vless":
        uuid = u.username
        host = u.hostname
        port = u.port or 443
        params = dict(urllib.parse.parse_qsl(u.query))
        
        security = params.get("security", "none").lower()
        network = params.get("type", params.get("network", "tcp")).lower()
        flow = params.get("flow", "")
        sni = params.get("sni", params.get("host", host))
        fp = params.get("fp", "chrome")
        path = params.get("path", "/")
        
        stream_settings = {
            "network": network,
            "security": security
        }
        
        if security == "tls":
            stream_settings["tlsSettings"] = {
                "serverName": sni,
                "allowInsecure": False
            }
            if fp:
                stream_settings["tlsSettings"]["fingerprint"] = fp
            if "alpn" in params:
                stream_settings["tlsSettings"]["alpn"] = params["alpn"].split(",")
        elif security == "reality":
            stream_settings["realitySettings"] = {
                "serverName": sni,
                "publicKey": params.get("pbk", ""),
                "shortId": params.get("sid", ""),
                "spiderX": params.get("spx", "/"),
                "fingerprint": fp
            }
            
        if network == "ws":
            stream_settings["wsSettings"] = {
                "path": path,
                "headers": {"Host": params.get("host", sni)}
            }
        elif network == "grpc":
            stream_settings["grpcSettings"] = {
                "serviceName": params.get("serviceName", params.get("path", "")),
                "authority": params.get("authority", sni)
            }
        elif network in ["xhttp", "splithttp"]:
            stream_settings["network"] = "xhttp"
            x_mode = params.get("mode", "auto")
            extra_raw = params.get("extra", "")
            x_padding = params.get("x_padding_bytes", params.get("xPaddingBytes", ""))
            if extra_raw:
                try:
                    extra_obj = json.loads(urllib.parse.unquote(extra_raw))
                    if "mode" in extra_obj:
                        x_mode = extra_obj["mode"]
                    if "xPaddingBytes" in extra_obj:
                        x_padding = extra_obj["xPaddingBytes"]
                except:
                    pass
            xhttp_cfg = {
                "path": path,
                "host": params.get("host", sni),
                "mode": x_mode
            }
            if x_padding:
                xhttp_cfg["xPaddingBytes"] = x_padding
            stream_settings["xhttpSettings"] = xhttp_cfg

        return {
            "tag": tag,
            "protocol": "vless",
            "settings": {
                "vnext": [{
                    "address": host,
                    "port": int(port),
                    "users": [{
                        "id": uuid,
                        "encryption": params.get("encryption", "none"),
                        "flow": flow
                    }]
                }]
            },
            "streamSettings": stream_settings
        }

    elif scheme == "trojan":
        password = u.username or u.password
        host = u.hostname
        port = u.port or 443
        params = dict(urllib.parse.parse_qsl(u.query))
        security = params.get("security", "tls").lower()
        network = params.get("type", "tcp").lower()
        sni = params.get("sni", host)
        
        stream_settings = {
            "network": network,
            "security": security
        }
        if security == "tls":
            stream_settings["tlsSettings"] = {
                "serverName": sni,
                "allowInsecure": False
            }
        if network == "ws":
            stream_settings["wsSettings"] = {
                "path": params.get("path", "/"),
                "headers": {"Host": sni}
            }
        elif network == "grpc":
            stream_settings["grpcSettings"] = {
                "serviceName": params.get("serviceName", "")
            }
            
        return {
            "tag": tag,
            "protocol": "trojan",
            "settings": {
                "servers": [{
                    "address": host,
                    "port": int(port),
                    "password": password
                }]
            },
            "streamSettings": stream_settings
        }

    elif scheme == "ss":
        raw = link[5:]
        if "#" in raw:
            raw, _ = raw.split("#", 1)
        if "@" in raw:
            userinfo, hostport = raw.split("@", 1)
            try:
                userinfo = base64.b64decode(userinfo + "==").decode()
            except:
                pass
            method, password = userinfo.split(":", 1)
            host, port = hostport.split(":", 1)
        else:
            decoded = base64.b64decode(raw + "==").decode()
            userinfo, hostport = decoded.split("@", 1)
            method, password = userinfo.split(":", 1)
            host, port = hostport.split(":", 1)
            
        return {
            "tag": tag,
            "protocol": "shadowsocks",
            "settings": {
                "servers": [{
                    "address": host,
                    "port": int(port),
                    "method": method,
                    "password": password
                }]
            }
        }

    elif scheme in ["socks", "socks5"]:
        host = u.hostname
        port = u.port or 1080
        servers_obj = {"address": host, "port": int(port)}
        if u.username and u.password:
            servers_obj["users"] = [{"user": u.username, "pass": u.password}]
        return {
            "tag": tag,
            "protocol": "socks",
            "settings": {
                "servers": [servers_obj]
            }
        }

    return {"protocol": "freedom", "settings": {}, "tag": tag}

res = parse_link(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "cascade-out-1")
print(json.dumps(res))
' "$url" "${tag:-cascade-out-1}" 2>/dev/null || echo "{\"protocol\": \"freedom\", \"settings\": {}, \"tag\": \"${tag:-cascade-out-1}\"}"
}

CASCADE_OUTBOUNDS=()
if [[ "$SERVER_ROLE" == "cascade" ]]; then
    for ((i=1; i<=CASCADE_COUNT; i++)); do
        link="${CASCADE_URLS[$i]}"
        tag="${CASCADE_TAGS[$i]:-cascade-out-$i}"
        if [[ -n "$link" ]]; then
            ob_json
            ob_json=$(parse_cascade_outbound "$link" "$tag")
            if [[ -n "$ob_json" && "$ob_json" != "null" ]]; then
                CASCADE_OUTBOUNDS+=("$ob_json")
                msg_ok "Каскад #${i} (${CASCADE_ALIASES[$i]:-Exit-$i} -> ${tag}) успешно подключен!"
            fi
        fi
    done
fi

if [[ ${#CASCADE_OUTBOUNDS[@]} -eq 0 ]]; then
    CASCADE_OUTBOUNDS_JSON='{"protocol": "freedom", "settings": {}, "tag": "cascade-out-1"}'
else
    CASCADE_OUTBOUNDS_JSON=$(IFS=,; echo "${CASCADE_OUTBOUNDS[*]}")
fi

# Build complete xrayTemplateConfig JSON according to server role
if [[ "$SERVER_ROLE" == "exit" ]]; then
    # Europe Exit Node: Block .RU zone, Russian IPs and torrents to prevent foreign IP de-anonymization
    XRAY_TEMPLATE_CONFIG='{
  "api": {
    "services": [
      "HandlerService",
      "LoggerService",
      "StatsService",
      "RoutingService"
    ],
    "tag": "api"
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "statsUserDownlink": true,
        "statsUserUplink": true
      }
    },
    "system": {
      "statsInboundDownlink": true,
      "statsInboundUplink": true,
      "statsOutboundDownlink": false,
      "statsOutboundUplink": false
    }
  },
  "metrics": {
    "listen": "127.0.0.1:11111",
    "tag": "metrics_out"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 62789,
      "protocol": "tunnel",
      "settings": {
        "rewriteAddress": "127.0.0.1"
      },
      "tag": "api"
    }
  ],
  "log": {"loglevel": "warning"},
  "dns": {
    "servers": [
      "https://1.1.1.1/dns-query",
      "https://8.8.8.8/dns-query",
      "1.1.1.1",
      "8.8.8.8"
    ],
    "queryStrategy": "UseIPv4"
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"},
      {"type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "blocked"},
      {
        "type": "field",
        "domain": [
          "geosite:category-ru",
          "regexp:.*\\.ru$",
          "regexp:.*\\.xn--p1ai$",
          "regexp:.*\\.su$"
        ],
        "outboundTag": "blocked"
      },
      {"type": "field", "ip": ["geoip:ru"], "outboundTag": "blocked"},
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "blocked"},
      {"type": "field", "network": "tcp,udp", "outboundTag": "direct"}
    ]
  },
  "outbounds": [
    {"protocol": "freedom", "settings": {}, "tag": "direct"},
    {"protocol": "blackhole", "settings": {}, "tag": "blocked"}
  ]
}'
elif [[ "$SERVER_ROLE" == "cascade" ]]; then
    # Russia Cascade Node: Split-Routing
    # .RU and Russian IPs go DIRECT. Everything else tunnels to EU exit node!
    XRAY_TEMPLATE_CONFIG="{
  \"api\": {
    \"services\": [
      \"HandlerService\",
      \"LoggerService\",
      \"StatsService\",
      \"RoutingService\"
    ],
    \"tag\": \"api\"
  },
  \"stats\": {},
  \"policy\": {
    \"levels\": {
      \"0\": {
        \"statsUserDownlink\": true,
        \"statsUserUplink\": true
      }
    },
    \"system\": {
      \"statsInboundDownlink\": true,
      \"statsInboundUplink\": true,
      \"statsOutboundDownlink\": false,
      \"statsOutboundUplink\": false
    }
  },
  \"metrics\": {
    \"listen\": \"127.0.0.1:11111\",
    \"tag\": \"metrics_out\"
  },
  \"inbounds\": [
    {
      \"listen\": \"127.0.0.1\",
      \"port\": 62789,
      \"protocol\": \"tunnel\",
      \"settings\": {
        \"rewriteAddress\": \"127.0.0.1\"
      },
      \"tag\": \"api\"
    }
  ],
  \"log\": {\"loglevel\": \"warning\"},
  \"dns\": {
    \"servers\": [
      {
        \"address\": \"77.88.8.8\",
        \"domains\": [\"geosite:category-ru\", \"domain:ru\", \"domain:su\", \"domain:xn--p1ai\"]
      },
      \"https://1.1.1.1/dns-query\",
      \"1.1.1.1\"
    ],
    \"queryStrategy\": \"UseIP\"
  },
  \"routing\": {
    \"domainStrategy\": \"IPIfNonMatch\",
    \"rules\": [
      {\"type\": \"field\", \"inboundTag\": [\"api\"], \"outboundTag\": \"api\"},
      {\"type\": \"field\", \"ip\": [\"geoip:private\"], \"outboundTag\": \"blocked\"},
      {\"type\": \"field\", \"domain\": [\"geosite:category-ads-all\"], \"outboundTag\": \"blocked\"},
      ${GROUP_ROUTING_RULES_JSON}
      {
        \"type\": \"field\",
        \"domain\": [
          \"geosite:category-ru\",
          \"regexp:.*\\\\.ru$\",
          \"regexp:.*\\\\.xn--p1ai$\",
          \"regexp:.*\\\\.su$\"
        ],
        \"outboundTag\": \"direct\"
      },
      {\"type\": \"field\", \"ip\": [\"geoip:ru\"], \"outboundTag\": \"direct\"},
      {\"type\": \"field\", \"protocol\": [\"bittorrent\"], \"outboundTag\": \"blocked\"},
      {\"type\": \"field\", \"network\": \"tcp,udp\", \"outboundTag\": \"cascade-out\"}
    ]
  },
  \"outbounds\": [
    {\"protocol\": \"freedom\", \"settings\": {}, \"tag\": \"direct\"},
    {\"protocol\": \"blackhole\", \"settings\": {}, \"tag\": \"blocked\"},
    ${CASCADE_OUTBOUNDS_JSON}
  ]
}"
else
    # Standalone Russia Node: Direct routing for RU and general traffic
    XRAY_TEMPLATE_CONFIG="{
  \"api\": {
    \"services\": [
      \"HandlerService\",
      \"LoggerService\",
      \"StatsService\",
      \"RoutingService\"
    ],
    \"tag\": \"api\"
  },
  \"stats\": {},
  \"policy\": {
    \"levels\": {
      \"0\": {
        \"statsUserDownlink\": true,
        \"statsUserUplink\": true
      }
    },
    \"system\": {
      \"statsInboundDownlink\": true,
      \"statsInboundUplink\": true,
      \"statsOutboundDownlink\": false,
      \"statsOutboundUplink\": false
    }
  },
  \"metrics\": {
    \"listen\": \"127.0.0.1:11111\",
    \"tag\": \"metrics_out\"
  },
  \"inbounds\": [
    {
      \"listen\": \"127.0.0.1\",
      \"port\": 62789,
      \"protocol\": \"tunnel\",
      \"settings\": {
        \"rewriteAddress\": \"127.0.0.1\"
      },
      \"tag\": \"api\"
    }
  ],
  \"log\": {\"loglevel\": \"warning\"},
  \"dns\": {
    \"servers\": [
      {
        \"address\": \"77.88.8.8\",
        \"domains\": [\"geosite:category-ru\", \"domain:ru\", \"domain:su\", \"domain:xn--p1ai\"]
      },
      \"https://1.1.1.1/dns-query\",
      \"https://8.8.8.8/dns-query\",
      \"1.1.1.1\",
      \"8.8.8.8\"
    ],
    \"queryStrategy\": \"UseIP\"
  },
  \"routing\": {
    \"domainStrategy\": \"IPIfNonMatch\",
    \"rules\": [
      {\"type\": \"field\", \"inboundTag\": [\"api\"], \"outboundTag\": \"api\"},
      {\"type\": \"field\", \"ip\": [\"geoip:private\"], \"outboundTag\": \"blocked\"},
      {\"type\": \"field\", \"domain\": [\"geosite:category-ads-all\"], \"outboundTag\": \"blocked\"},
      ${GROUP_ROUTING_RULES_JSON}
      {
        \"type\": \"field\",
        \"domain\": [
          \"geosite:category-ru\",
          \"regexp:.*\\\\.ru$\",
          \"regexp:.*\\\\.xn--p1ai$\",
          \"regexp:.*\\\\.su$\"
        ],
        \"outboundTag\": \"direct\"
      },
      {\"type\": \"field\", \"ip\": [\"geoip:ru\"], \"outboundTag\": \"direct\"},
      {\"type\": \"field\", \"protocol\": [\"bittorrent\"], \"outboundTag\": \"blocked\"},
      {\"type\": \"field\", \"network\": \"tcp,udp\", \"outboundTag\": \"direct\"}
    ]
  },
  \"outbounds\": [
    {\"protocol\": \"freedom\", \"settings\": {}, \"tag\": \"direct\"},
    {\"protocol\": \"blackhole\", \"settings\": {}, \"tag\": \"blocked\"}
  ]
}"
fi

# Insert into settings and inbounds
sub_uri="https://${domain}/${sub_path}/"
json_uri="https://${domain}/${web_path}?name="

HAPP_ROUTING_RULE="happ://routing/onadd/${ROUTING_B64}"
INCY_ROUTING_RULE="incy://routing/onadd/${ROUTING_B64}"

if [[ -f "$XUIDB" ]]; then
    mkdir -p "$(dirname "$XUIDB")"
    
    sqlite3 "$XUIDB" <<EOF
-- Clean duplicate keys from settings and insert fresh config
DELETE FROM "settings" WHERE "key" IN ('xrayTemplateConfig','subPort','subPath','subURI','subJsonPath','subJsonURI','subEnable','subEncrypt','subCertFile','subKeyFile','webCertFile','webKeyFile','timeLocation','subTitle','subAnnounce','subClashEnable','subClashPath','subClashURI','subClashAutoDetect','subClashEnableRouting','subClashRules','subEnableRouting','subRoutingRules','subHappAutoDetect','subHappAutoConnect','subHappAutoConnectType','subHappSubInfoText','subHappSubInfoColor','subHappColorProfile','subHappTunMode','subIncyAppAutoDetect','subIncyProfileDescription','subIncyBannerText','subIncyBannerBgColor','subIncyBannerButtonText','subIncyBannerButtonColor','subIncyEnableRouting','subIncyRoutingRules','subJsonEnable','subJsonAutoDetect','subJsonRoutingRules');
INSERT INTO "settings" ("key", "value") VALUES ('xrayTemplateConfig', '${XRAY_TEMPLATE_CONFIG}');
INSERT INTO "settings" ("key", "value") VALUES ("subPort", '${sub_port}');
INSERT INTO "settings" ("key", "value") VALUES ("subCertFile", '');
INSERT INTO "settings" ("key", "value") VALUES ("subKeyFile", '');
INSERT INTO "settings" ("key", "value") VALUES ("subPath", '/${sub_path}/');
INSERT INTO "settings" ("key", "value") VALUES ("subURI", '${sub_uri}');
INSERT INTO "settings" ("key", "value") VALUES ("subJsonPath", '${json_path}');
INSERT INTO "settings" ("key", "value") VALUES ("subJsonURI", '${json_uri}');
INSERT INTO "settings" ("key", "value") VALUES ("subEnable", 'true');
INSERT INTO "settings" ("key", "value") VALUES ("subEncrypt", 'true');
INSERT INTO "settings" ("key", "value") VALUES ("subTitle", '${SUB_TITLE}');
INSERT INTO "settings" ("key", "value") VALUES ("subAnnounce", '${SUB_TITLE}');
INSERT INTO "settings" ("key", "value") VALUES ("subClashEnable", 'true');
INSERT INTO "settings" ("key", "value") VALUES ("subClashPath", '/clash/');
INSERT INTO "settings" ("key", "value") VALUES ("subClashURI", 'https://${domain}/clash/');
INSERT INTO "settings" ("key", "value") VALUES ("subClashAutoDetect", 'true');
INSERT INTO "settings" ("key", "value") VALUES ("subClashEnableRouting", 'true');
INSERT INTO "settings" ("key", "value") VALUES ("subClashRules", '- GEOSITE,category-ads-all,REJECT${ADDITIONAL_CLASH_RULES}
- DOMAIN-SUFFIX,ru,DIRECT
- DOMAIN-SUFFIX,su,DIRECT
- DOMAIN-SUFFIX,xn--p1ai,DIRECT
- DOMAIN-SUFFIX,gosuslugi.ru,DIRECT
- DOMAIN-SUFFIX,sberbank.ru,DIRECT
- DOMAIN-SUFFIX,tinkoff.ru,DIRECT
- DOMAIN-SUFFIX,t-bank.ru,DIRECT
- DOMAIN-SUFFIX,vtb.ru,DIRECT
- DOMAIN-SUFFIX,alfabank.ru,DIRECT
- DOMAIN-SUFFIX,yandex.ru,DIRECT
- DOMAIN-SUFFIX,ya.ru,DIRECT
- DOMAIN-SUFFIX,vk.com,DIRECT
- DOMAIN-SUFFIX,vk.ru,DIRECT
- DOMAIN-SUFFIX,mail.ru,DIRECT
- DOMAIN-SUFFIX,avito.ru,DIRECT
- DOMAIN-SUFFIX,ozon.ru,DIRECT
- DOMAIN-SUFFIX,wildberries.ru,DIRECT
- DOMAIN-SUFFIX,kinopoisk.ru,DIRECT
- GEOIP,RU,DIRECT
- GEOIP,private,DIRECT
- MATCH,PROXY');
INSERT INTO "settings" ("key", "value") VALUES ("subEnableRouting", 'true');
INSERT INTO "settings" ("key", "value") VALUES ("subRoutingRules", '${HAPP_ROUTING_RULE}');
INSERT INTO "settings" ("key", "value") VALUES ("subHappAutoDetect", 'true');
INSERT INTO "settings" ("key", "value") VALUES ("subHappAutoConnect", 'lowest_delay');
INSERT INTO "settings" ("key", "value") VALUES ("subHappAutoConnectType", 'tcp');
INSERT INTO "settings" ("key", "value") VALUES ("subHappSubInfoText", '${SUB_TITLE}');
INSERT INTO "settings" ("key", "value") VALUES ("subHappSubInfoColor", 'blue');
INSERT INTO "settings" ("key", "value") VALUES ("subHappColorProfile", 'blue');
INSERT INTO "settings" ("key", "value") VALUES ("subHappTunMode", 'system');
INSERT INTO "settings" ("key", "value") VALUES ("subIncyAppAutoDetect", 'true');
INSERT INTO "settings" ("key", "value") VALUES ("subIncyProfileDescription", '${SUB_TITLE}');
INSERT INTO "settings" ("key", "value") VALUES ("subIncyBannerText", '${SUB_TITLE}');
INSERT INTO "settings" ("key", "value") VALUES ("subIncyBannerBgColor", '#1e293b');
INSERT INTO "settings" ("key", "value") VALUES ("subIncyBannerButtonText", 'Подключено');
INSERT INTO "settings" ("key", "value") VALUES ("subIncyBannerButtonColor", '#3b82f6');
INSERT INTO "settings" ("key", "value") VALUES ("subIncyEnableRouting", 'true');
INSERT INTO "settings" ("key", "value") VALUES ("subIncyRoutingRules", '${INCY_ROUTING_RULE}');
INSERT INTO "settings" ("key", "value") VALUES ("subJsonEnable", 'true');
INSERT INTO "settings" ("key", "value") VALUES ("subJsonAutoDetect", 'true');
INSERT INTO "settings" ("key", "value") VALUES ("subJsonRoutingRules", '${HAPP_ROUTING_RULE}');
INSERT INTO "settings" ("key", "value") VALUES ("webCertFile", '/root/cert/${domain}/fullchain.pem');
INSERT INTO "settings" ("key", "value") VALUES ("webKeyFile", '/root/cert/${domain}/privkey.pem');
INSERT INTO "settings" ("key", "value") VALUES ("timeLocation", 'Europe/Moscow');

-- Clean tables
DELETE FROM "inbounds";
DELETE FROM "clients";
DELETE FROM "client_inbounds";
DELETE FROM "client_traffics";

-- 1. VLESS REALITY (Port 8443, XTLS-Vision, Single-Domain Masking)
INSERT INTO "inbounds" ("id","user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES (
    1,'1','0','0','0','${SERVER_FLAG} VLESS Reality','1','0','','8443','vless',
    '{
        "clients": [
            {
                "id": "${CLIENT_UUID}",
                "flow": "xtls-rprx-vision",
                "email": "${CLIENT_EMAIL}",
                "limitIp": 0,
                "totalGB": 0,
                "expiryTime": 0,
                "enable": true,
                "subId": "${CLIENT_SUB_ID}",
                "reset": 0
            }
        ],
        "decryption": "none",
        "fallbacks": []
    }',
    '{
        "network": "tcp",
        "security": "reality",
        "externalProxy": [
            {
                "forceTls": "same",
                "dest": "${IP4}",
                "port": 443,
                "remark": ""
            }
        ],
        "realitySettings": {
            "show": false,
            "xver": 0,
            "target": "${REALITY_DEFAULT_TARGET}",
            "serverNames": ${REALITY_SERVER_NAMES_JSON:-["${REALITY_DEFAULT_SNI}"]},
            "privateKey": "${REALITY_PRIV_KEY}",
            "shortIds": ["${short_ids[0]}","${short_ids[1]}","${short_ids[2]}","${short_ids[3]}"],
            "settings": {
                "publicKey": "${REALITY_PUB_KEY}",
                "fingerprint": "chrome",
                "serverName": "${REALITY_DEFAULT_SNI}",
                "spiderX": "/"
            }
        },
        "tcpSettings": {
            "acceptProxyProtocol": true,
            "header": {"type": "none"}
        }
    }',
    'inbound-8443',
    '{"enabled": true, "destOverride": ["http","tls","quic","fakedns"], "metadataOnly": false, "routeOnly": false}'
);

-- 2. Hysteria 2 (UDP Port 443, QUIC Brutal Congestion)
INSERT INTO "inbounds" ("id","user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES (
    2,'1','0','0','0','${SERVER_FLAG} Hysteria 2','1','0','','443','hysteria',
    '{
        "version": 2,
        "ignoreClientBandwidth": false,
        "clients": [
            {
                "id": "${CLIENT_UUID}",
                "auth": "${CLIENT_PASSWORD}",
                "password": "${CLIENT_PASSWORD}",
                "email": "${CLIENT_EMAIL}",
                "limitIp": 0,
                "totalGB": 0,
                "expiryTime": 0,
                "enable": true,
                "tgId": 0,
                "subId": "${CLIENT_SUB_ID}",
                "comment": "",
                "reset": 0
            }
        ],
        "auth": {"type": "userpass"},
        "users": [{"username": "${CLIENT_EMAIL}", "password": "${CLIENT_PASSWORD}"}],
        "accounts": [{"user": "${CLIENT_EMAIL}", "pass": "${CLIENT_PASSWORD}"}]
    }',
    '{
        "network": "hysteria",
        "security": "tls",
        "externalProxy": [{"forceTls": "tls", "dest": "${domain}", "port": 443, "remark": ""}],
        "tlsSettings": {
            "serverName": "${domain}",
            "certificates": [
                {
                    "certificateFile": "/root/cert/${domain}/fullchain.pem",
                    "keyFile": "/root/cert/${domain}/privkey.pem"
                }
            ]
        },
        "hysteriaSettings": {
            "version": 2,
            "udpIdleTimeout": 60
        }
    }',
    'inbound-443-hy2',
    '{"enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false, "routeOnly": false}'
);

-- 3. VLESS XHTTP (SplitHTTP - Cloudflare CDN friendly)
INSERT INTO "inbounds" ("id","user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES (
    3,'1','0','0','0','${SERVER_FLAG} VLESS XHTTP','1','0','127.0.0.1','${xhttp_port}','vless',
    '{
        "clients": [{"id": "${CLIENT_UUID}", "flow": "", "email": "${CLIENT_EMAIL}", "limitIp": 0, "totalGB": 0, "expiryTime": 0, "enable": true, "subId": "${CLIENT_SUB_ID}", "reset": 0}],
        "decryption": "none",
        "fallbacks": []
    }',
    '{
        "network": "xhttp",
        "security": "none",
        "externalProxy": [{"forceTls": "tls", "dest": "${domain}", "port": 443, "remark": ""}],
        "xhttpSettings": {"path": "/${xhttp_path}", "host": "${domain}", "mode": "auto"}
    }',
    'inbound-${xhttp_port}',
    '{"enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false, "routeOnly": false}'
);

-- 4. VLESS WebSocket (Legacy CDN compatible)
INSERT INTO "inbounds" ("id","user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES (
    4,'1','0','0','0','${SERVER_FLAG} VLESS WebSocket','1','0','127.0.0.1','${ws_port}','vless',
    '{
        "clients": [{"id": "${CLIENT_UUID}", "flow": "", "email": "${CLIENT_EMAIL}", "limitIp": 0, "totalGB": 0, "expiryTime": 0, "enable": true, "subId": "${CLIENT_SUB_ID}", "reset": 0}],
        "decryption": "none",
        "fallbacks": []
    }',
    '{
        "network": "ws",
        "security": "none",
        "externalProxy": [{"forceTls": "tls", "dest": "${domain}", "port": 443, "remark": ""}],
        "wsSettings": {"path": "/${ws_port}/${ws_path}", "host": "${domain}"}
    }',
    'inbound-${ws_port}',
    '{"enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false, "routeOnly": false}'
);

-- 5. Trojan gRPC
INSERT INTO "inbounds" ("id","user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES (
    5,'1','0','0','0','${SERVER_FLAG} Trojan gRPC','1','0','127.0.0.1','${trojan_port}','trojan',
    '{
        "clients": [{"password": "${CLIENT_PASSWORD}", "email": "${CLIENT_EMAIL}", "limitIp": 0, "totalGB": 0, "expiryTime": 0, "enable": true, "subId": "${CLIENT_SUB_ID}", "reset": 0}],
        "fallbacks": []
    }',
    '{
        "network": "grpc",
        "security": "none",
        "externalProxy": [{"forceTls": "tls", "dest": "${domain}", "port": 443, "remark": ""}],
        "grpcSettings": {"serviceName": "${trojan_path}", "authority": "${domain}"}
    }',
    'inbound-${trojan_port}',
    '{"enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false, "routeOnly": false}'
);

-- 7. WireGuard (UDP ${WG_PORT})
INSERT INTO "inbounds" ("id","user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES (
    7,'1','0','0','0','${SERVER_FLAG} WireGuard','1','0','','${WG_PORT}','wireguard',
    '{
        "secretKey": "${WG_SERVER_PRIV_KEY}",
        "peers": [{"publicKey": "${WG_CLIENT_PUB_KEY}", "allowedIPs": ["10.0.0.2/32"], "email": "${CLIENT_EMAIL}", "keepAlive": 0}],
        "clients": [{"email": "${CLIENT_EMAIL}", "enable": true, "privateKey": "${WG_CLIENT_PRIV_KEY}", "publicKey": "${WG_CLIENT_PUB_KEY}", "allowedIPs": ["10.0.0.2/32"], "subId": "${CLIENT_SUB_ID}", "limitIp": 0, "totalGB": 0, "expiryTime": 0, "reset": 0}]
    }',
    '{}',
    'inbound-${WG_PORT}',
    '{"enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false, "routeOnly": false}'
);

-- 8. AmneziaWG 1.0 (Obfuscated UDP ${AWG1_PORT})
INSERT INTO "inbounds" ("id","user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES (
    8,'1','0','0','0','${SERVER_FLAG} AmneziaWG 1.0','1','0','','${AWG1_PORT}','amneziawg',
    '{
        "server": {
            "privateKey": "${AWG1_SERVER_PRIV_KEY}",
            "publicKey": "${AWG1_SERVER_PUB_KEY}",
            "subnetIp": "10.8.1.0",
            "subnetCidr": 24,
            "mtu": 1420,
            "primaryDns": "1.1.1.1",
            "secondaryDns": "8.8.8.8",
            "jc": ${AWG_JC},
            "jmin": ${AWG_JMIN},
            "jmax": ${AWG_JMAX},
            "s1": ${AWG_S1},
            "s2": ${AWG_S2},
            "s3": 0,
            "s4": 0,
            "h1": "${AWG_H1}",
            "h2": "${AWG_H2}",
            "h3": "${AWG_H3}",
            "h4": "${AWG_H4}",
            "headerProtectionKey": "",
            "randomTrailers": false,
            "disableCookies": false
        },
        "clients": [
            {
                "email": "${CLIENT_EMAIL}",
                "enable": true,
                "privateKey": "${AWG1_CLIENT_PRIV_KEY}",
                "publicKey": "${AWG1_CLIENT_PUB_KEY}",
                "allowedIPs": ["10.8.1.2/32"],
                "subId": "${CLIENT_SUB_ID}",
                "limitIp": 0,
                "totalGB": 0,
                "expiryTime": 0,
                "reset": 0
            }
        ]
    }',
    '{}',
    'inbound-${AWG1_PORT}',
    '{"enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false, "routeOnly": false}'
);

-- 9. AmneziaWG 3.1 (DPI-Shield UDP ${AWG3_PORT})
INSERT INTO "inbounds" ("id","user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES (
    9,'1','0','0','0','${SERVER_FLAG} AmneziaWG 3.1','1','0','','${AWG3_PORT}','amneziawg',
    '{
        "server": {
            "privateKey": "${AWG3_SERVER_PRIV_KEY}",
            "publicKey": "${AWG3_SERVER_PUB_KEY}",
            "subnetIp": "10.8.3.0",
            "subnetCidr": 24,
            "mtu": 1420,
            "primaryDns": "1.1.1.1",
            "secondaryDns": "8.8.8.8",
            "jc": ${AWG_JC},
            "jmin": ${AWG_JMIN},
            "jmax": ${AWG_JMAX},
            "s1": ${AWG_S1},
            "s2": ${AWG_S2},
            "s3": ${AWG_S3},
            "s4": ${AWG_S4},
            "h1": "${AWG_H1}",
            "h2": "${AWG_H2}",
            "h3": "${AWG_H3}",
            "h4": "${AWG_H4}",
            "headerProtectionKey": "${AWG_HPK}",
            "randomTrailers": false,
            "disableCookies": false
        },
        "clients": [
            {
                "email": "${CLIENT_EMAIL}",
                "enable": true,
                "privateKey": "${AWG3_CLIENT_PRIV_KEY}",
                "publicKey": "${AWG3_CLIENT_PUB_KEY}",
                "allowedIPs": ["10.8.3.2/32"],
                "subId": "${CLIENT_SUB_ID}",
                "limitIp": 0,
                "totalGB": 0,
                "expiryTime": 0,
                "reset": 0
            }
        ]
    }',
    '{}',
    'inbound-${AWG3_PORT}',
    '{"enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false, "routeOnly": false}'
);

-- Single Master Client in 3X-UI Clients Table
INSERT INTO "clients" (
    "id", "email", "sub_id", "uuid", "password", "auth", "flow", "enable",
    "total_gb", "expiry_time", "traffic_reset", "wg_private_key", "wg_public_key", "wg_allowed_ips",
    "created_at", "updated_at"
) VALUES (
    1, '${CLIENT_EMAIL}', '${CLIENT_SUB_ID}', '${CLIENT_UUID}', '${CLIENT_PASSWORD}',
    '${CLIENT_PASSWORD}', 'xtls-rprx-vision', 1, 0, 0, 'never',
    '${WG_CLIENT_PRIV_KEY}', '${WG_CLIENT_PUB_KEY}', '10.0.0.2/32',
    strftime('%s','now')*1000, strftime('%s','now')*1000
);

-- Client Traffics Initial Mapping
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('1','1','${CLIENT_EMAIL}','0','0','0','0','0');

-- Link ALL Inbounds to this Single Client in client_inbounds
INSERT INTO "client_inbounds" ("client_id", "inbound_id", "flow_override", "created_at") VALUES
(1, 1, 'xtls-rprx-vision', strftime('%s','now')*1000),
(1, 2, '', strftime('%s','now')*1000),
(1, 3, '', strftime('%s','now')*1000),
(1, 4, '', strftime('%s','now')*1000),
(1, 5, '', strftime('%s','now')*1000),
(1, 7, '', strftime('%s','now')*1000),
(1, 8, '', strftime('%s','now')*1000),
(1, 9, '', strftime('%s','now')*1000);
EOF
fi

################################## Nginx Architecture #########################
msg_step "Configuring Nginx Single-Domain Architecture & SNI Preread..."

mkdir -p /etc/nginx/stream-enabled
mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled
mkdir -p /etc/nginx/snippets

# 1. Nginx Stream (Port 443 TCP multiplexer)
cat > "/etc/nginx/stream-enabled/stream.conf" << EOF
map \$ssl_preread_server_name \$sni_name {
    hostnames;
    ${domain}      web_local;
    default        xray_reality;
}

upstream web_local {
    server 127.0.0.1:7443;
}

upstream xray_reality {
    server 127.0.0.1:8443;
}

server {
    listen          443;
    listen         [::]:443;
    proxy_pass      \$sni_name;
    ssl_preread     on;
    proxy_protocol  on;
    proxy_timeout   1d;
    proxy_connect_timeout 10s;
}
EOF

# Ensure stream module is included in nginx.conf
if ! grep -q "stream {" /etc/nginx/nginx.conf 2>/dev/null; then
    echo "stream { include /etc/nginx/stream-enabled/*.conf; }" >> /etc/nginx/nginx.conf
fi
grep -xqFR "load_module modules/ngx_stream_module.so;" /etc/nginx/* || sed -i '1s/^/load_module \/usr\/lib\/nginx\/modules\/ngx_stream_module.so; /' /etc/nginx/nginx.conf 2>/dev/null || true

# 2. Main HTTPS Server (Port 7443)
cat > "/etc/nginx/sites-available/${domain}" << EOF
server {
    server_tokens off;
    server_name ${domain};
    listen 7443 ssl http2 proxy_protocol;
    listen [::]:7443 ssl http2 proxy_protocol;

    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;
    real_ip_header proxy_protocol;

    ssl_certificate /root/cert/${domain}/fullchain.pem;
    ssl_certificate_key /root/cert/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    root /var/www/html;
    index index.html index.htm;

    # Protect against scanning
    if (\$host !~* ^(.+\.)?${domain}\$) {
        return 444;
    }

    # 3X-UI Admin Panel
    location /${panel_path}/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass https://127.0.0.1:${panel_port};
    }
    location /${panel_path} {
        rewrite ^ /${panel_path}/ permanent;
    }

    include /etc/nginx/snippets/includes.conf;

    # Realistic Mask Site
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

# 3. Includes Snippets for Subscriptions & Proxy Forwarding
cat > "/etc/nginx/snippets/includes.conf" << EOF
    # Sub2sing-box Converter
    location /${sub2singbox_path}/ {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:8080/;
    }

    # Clash / Mihomo Templates
    location ~ ^/${web_path}/clashmeta/(.+)\$ {
        default_type text/plain;
        ssi on;
        ssi_types text/plain;
        set \$subid \$1;
        root /var/www/subpage;
        try_files /clash.yaml =404;
    }

    # Web Sub Page
    location ~ ^/${web_path} {
        root /var/www/subpage;
        index index.html;
        try_files \$uri \$uri/ /index.html =404;
    }

    # 3X-UI Base Subscription
    location /${sub_path} {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:${sub_port};
    }
    location /${sub_path}/ {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:${sub_port};
    }

    # 3X-UI JSON Subscription
    location /${json_path} {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:${sub_port};
    }
    location /${json_path}/ {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:${sub_port};
    }

    # 3X-UI Clash Subscription
    location /clash {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:${sub_port};
    }
    location /clash/ {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:${sub_port};
    }

    # VLESS XHTTP Path
    location /${xhttp_path} {
        client_max_body_size 0;
        client_body_timeout 1d;
        grpc_read_timeout 1d;
        grpc_send_timeout 1d;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        rewrite ^/${xhttp_path}\$ /${xhttp_path}/ break;
        proxy_pass http://127.0.0.1:${xhttp_port};
    }

    # Trojan gRPC Path
    location /${trojan_path} {
        client_max_body_size 0;
        client_body_timeout 1d;
        grpc_read_timeout 1d;
        grpc_send_timeout 1d;
        grpc_socket_keepalive on;
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_pass grpc://127.0.0.1:${trojan_port};
    }

    # Dynamic Port/Path Forwarding for WebSocket & gRPC
    location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)\$ {
        client_max_body_size 0;
        client_body_timeout 1d;
        grpc_read_timeout 1d;
        grpc_socket_keepalive on;
        proxy_read_timeout 1d;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        
        if (\$content_type ~* "GRPC") {
            grpc_pass grpc://127.0.0.1:\$fwdport;
            break;
        }
        if (\$http_upgrade ~* "(WEBSOCKET|WS)") {
            proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
        if (\$request_method ~* ^(PUT|POST|GET)\$) {
            proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
    }
EOF

ln -sf "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/${domain}"
ln -sf "/etc/nginx/sites-available/80.conf" "/etc/nginx/sites-enabled/80.conf"
rm -f /etc/nginx/sites-enabled/default

################################## Masking Fake Website #######################
msg_step "Installing realistic fake website mask (15 Russian themes available)..."
mkdir -p /var/www/html
generate_fake_website "$domain" 0 "/var/www/html/index.html"

################################## Sub2Sing-Box & SubPage #####################
msg_step "Configuring subscription pages and converters..."
mkdir -p /var/www/subpage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
GITHUB_RAW="https://raw.githubusercontent.com/TViN-X/omnistack/master"

# Sub Page Template
if [[ -f "$SCRIPT_DIR/sub-3x-ui.html" ]]; then
    cp -f "$SCRIPT_DIR/sub-3x-ui.html" "/var/www/subpage/index.html"
else
    wget -q -O "/var/www/subpage/index.html" "${GITHUB_RAW}/sub-3x-ui.html" 2>/dev/null || true
fi
sed -i "s|Мой сервер|${SUB_TITLE}|g" "/var/www/subpage/index.html" 2>/dev/null || true

if [[ ! -s "/var/www/subpage/index.html" ]]; then
    cat > "/var/www/subpage/index.html" << EOF
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Client Subscription Portal</title></head>
<body style="font-family:sans-serif;text-align:center;padding:50px;">
<h2>User Subscription Active</h2>
<p>Paste this link into your Sing-Box / Clash / V2Ray / Happ client.</p>
</body></html>
EOF
fi

# Clash YAML Template
if [[ -f "$SCRIPT_DIR/clash/clash.yaml" ]]; then
    cp -f "$SCRIPT_DIR/clash/clash.yaml" "/var/www/subpage/clash.yaml"
else
    wget -q -O "/var/www/subpage/clash.yaml" "${GITHUB_RAW}/clash/clash.yaml" 2>/dev/null || true
fi

sed -i "s/\${DOMAIN}/$domain/g" /var/www/subpage/* 2>/dev/null || true
sed -i "s#\${SUB_PATH}#$sub_path#g" /var/www/subpage/* 2>/dev/null || true
sed -i "s#\${SUB_JSON_PATH}#$json_path#g" /var/www/subpage/* 2>/dev/null || true
sed -i "s|sub.legiz.ru|$domain/$sub2singbox_path|g" /var/www/subpage/* 2>/dev/null || true

# Sub2sing-box binary & service
msg_step "Installing sub2sing-box subscription converter..."
SUB2SB_ARCH="$(arch)"
[[ "$SUB2SB_ARCH" == "386" ]] && SUB2SB_ARCH="i386"
SUB2SB_URL="https://github.com/legiz-ru/sub2sing-box/releases/download/v0.0.9/sub2sing-box_0.0.9_linux_${SUB2SB_ARCH}.tar.gz"

if wget -q -O /tmp/sub2sing-box.tar.gz "$SUB2SB_URL" 2>/dev/null; then
    tar -xzf /tmp/sub2sing-box.tar.gz -C /tmp/ --strip-components=1 "sub2sing-box_0.0.9_linux_${SUB2SB_ARCH}/sub2sing-box" 2>/dev/null || tar -xzf /tmp/sub2sing-box.tar.gz -C /tmp/
    if [[ -f /tmp/sub2sing-box ]]; then
        mv -f /tmp/sub2sing-box /usr/bin/sub2sing-box
        chmod +x /usr/bin/sub2sing-box
    fi
    rm -f /tmp/sub2sing-box* 2>/dev/null || true
fi

if [[ -x /usr/bin/sub2sing-box ]]; then
    cat > /etc/systemd/system/sub2sing-box.service << EOF
[Unit]
Description=sub2sing-box Subscription Converter Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/sub2sing-box server --bind 127.0.0.1 --port 8080
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sub2sing-box >/dev/null 2>&1 || true
    systemctl restart sub2sing-box >/dev/null 2>&1 || true
    msg_ok "sub2sing-box service started on 127.0.0.1:8080"
fi

################################## System Tuning (BBR & TCP) ##################
msg_step "Enabling BBR Congestion Control & Kernel Network Optimization..."
cat > /etc/sysctl.d/99-xui-tuning.conf << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
fs.file-max=2097152
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF
sysctl --system >/dev/null 2>&1 || true

################################## Firewall (UFW) #############################
msg_step "Configuring UFW Firewall..."
if command -v ufw &>/dev/null; then
    # TCP Ports
    ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1 || true
    ufw allow 80/tcp comment 'HTTP' >/dev/null 2>&1 || true
    ufw allow 443/tcp comment 'HTTPS/Reality/XHTTP/WS/Trojan' >/dev/null 2>&1 || true
    
    # UDP Ports
    ufw allow 443/udp comment 'Hysteria2 QUIC' >/dev/null 2>&1 || true
    ufw allow ${WG_PORT}/udp comment 'WireGuard High Port' >/dev/null 2>&1 || true
    ufw allow ${AWG1_PORT}/udp comment 'AmneziaWG 1.0 High Port' >/dev/null 2>&1 || true
    ufw allow ${AWG3_PORT}/udp comment 'AmneziaWG 3.1 High Port' >/dev/null 2>&1 || true
    
    # Safely enable or reload without breaking active Docker/custom rules
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw reload >/dev/null 2>&1 || true
    else
        ufw default allow outgoing >/dev/null 2>&1 || true
        ufw --force enable >/dev/null 2>&1 || true
    fi
    msg_ok "Firewall configured: TCP(22, 80, 443), UDP(443, ${WG_PORT}, ${AWG1_PORT}, ${AWG3_PORT})"
fi

# Enable IP forwarding and NAT Masquerade for VPN tunnels (WireGuard, AmneziaWG)
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-vpn-forwarding.conf << 'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE || true

################################## Crontab (Auto-renewal) #####################
crontab -l 2>/dev/null | grep -v "certbot\|x-ui\|sub2sing-box" | crontab - || true
(crontab -l 2>/dev/null; echo '@daily x-ui restart >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1') | crontab -
(crontab -l 2>/dev/null; echo '0 3 * * 1 certbot renew --quiet --post-hook "nginx -s reload" >/dev/null 2>&1') | crontab -

# Setup Weekly GeoData Auto-Update (Sunday 04:00)
setup_geodata_cron

# Setup Weekly Telegram Backup & Telemetry (Sunday 21:00)
if [[ "$ENABLE_TG_BACKUP" == "y" ]]; then
    setup_telegram_backup
fi

################################## Start Services #############################
msg_step "Starting Services..."
systemctl daemon-reload
systemctl enable nginx x-ui 2>/dev/null || true
systemctl restart nginx 2>/dev/null || true
systemctl restart x-ui 2>/dev/null || true

################################## CLI Shortcut omnistack #####################
msg_step "Installing omnistack CLI command..."
mkdir -p /usr/local/omnistack
if [[ -f "$0" && "$0" != "/dev/fd/"* ]]; then
    cp -f "$0" /usr/local/omnistack/omnistack.sh
else
    curl -Ls https://raw.githubusercontent.com/TViN-X/omnistack/master/omnistack.sh -o /usr/local/omnistack/omnistack.sh 2>/dev/null || true
fi
chmod +x /usr/local/omnistack/omnistack.sh 2>/dev/null || true
ln -sf /usr/local/omnistack /usr/local/x-ui-pro 2>/dev/null || true

cat > /usr/local/bin/omnistack << 'EOF'
#!/bin/bash
if [[ -f /usr/local/omnistack/omnistack.sh ]]; then
    exec bash /usr/local/omnistack/omnistack.sh "$@"
elif [[ -f /usr/local/x-ui-pro/omnistack.sh ]]; then
    exec bash /usr/local/x-ui-pro/omnistack.sh "$@"
else
    exec bash <(curl -Ls https://raw.githubusercontent.com/TViN-X/omnistack/master/omnistack.sh) "$@"
fi
EOF
chmod +x /usr/local/bin/omnistack
ln -sf /usr/local/bin/omnistack /usr/bin/omnistack 2>/dev/null || true
ln -sf /usr/local/bin/omnistack /usr/local/bin/x-ui-setup 2>/dev/null || true
ln -sf /usr/local/bin/omnistack /usr/bin/x-ui-setup 2>/dev/null || true
ln -sf /usr/local/bin/omnistack /usr/local/bin/omnistack-tg 2>/dev/null || true
ln -sf /usr/local/bin/omnistack /usr/bin/omnistack-tg 2>/dev/null || true
msg_ok "Installed 'omnistack', 'omnistack-tg' commands (/usr/local/bin/omnistack)"

################################## Standalone WireGuard / AWG Client Configs ###
CLIENT_CONFIGS_DIR="/root/client_configs"
mkdir -p "$CLIENT_CONFIGS_DIR"

# 2. AmneziaWG 1.0 Client Configuration
cat > "$CLIENT_CONFIGS_DIR/amneziawg1_client.conf" << EOF
[Interface]
PrivateKey = ${AWG1_CLIENT_PRIV_KEY}
Address = 10.8.1.2/32
DNS = 1.1.1.1, 8.8.8.8
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}

[Peer]
PublicKey = ${AWG1_SERVER_PUB_KEY}
Endpoint = ${domain}:${AWG1_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

# 3. AmneziaWG 3.1 Client Configuration
cat > "$CLIENT_CONFIGS_DIR/amneziawg3_client.conf" << EOF
[Interface]
PrivateKey = ${AWG3_CLIENT_PRIV_KEY}
Address = 10.8.3.2/32
DNS = 1.1.1.1, 8.8.8.8
HeaderProtectionKey = ${AWG_HPK}
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
S3 = ${AWG_S3}
S4 = ${AWG_S4}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}

[Peer]
PublicKey = ${AWG3_SERVER_PUB_KEY}
Endpoint = ${domain}:${AWG3_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
chmod 600 "$CLIENT_CONFIGS_DIR"/*

################################## Client Configs & Credentials Output ########
VLESS_REALITY_LINK="vless://${CLIENT_UUID}@${IP4}:443?type=tcp&security=reality&pbk=${REALITY_PUB_KEY}&fp=chrome&sni=${REALITY_DEFAULT_SNI}&sid=${short_ids[0]}&spx=%2F&flow=xtls-rprx-vision#${domain}-Reality"
HYSTERIA2_LINK="hysteria2://${CLIENT_PASSWORD}@${domain}:443/?sni=${domain}&insecure=0#${domain}-Hy2"

CREDENTIALS_FILE="/root/omnistack-credentials.txt"
cat > "$CREDENTIALS_FILE" << EOF
================================================================================
                    OMNISTACK 2.0 CREDENTIALS & CONNECTIONS
================================================================================
Generated: $(date)
Server IPv4: ${IP4}
Domain:      ${domain}
Server Role: ${SERVER_ROLE^^}

--- 1. 3X-UI ADMIN WEB PANEL ---
URL:      https://${domain}/${panel_path}/
Username: ${config_username}
Password: ${config_password}

--- 2. UNIFIED CLIENT SUBSCRIPTIONS (${CLIENT_EMAIL} - ${SUB_TITLE}) ---
Web Portal: https://${domain}/${web_path}?name=${CLIENT_SUB_ID}
Base Sub:   https://${domain}/${sub_path}/${CLIENT_SUB_ID}
Clash Meta: https://${domain}/${web_path}/clashmeta/${CLIENT_SUB_ID}

--- 3. DIRECT CONNECTION PROXY LINKS ---
• VLESS REALITY (XTLS-Vision):
${VLESS_REALITY_LINK}

• HYSTERIA 2 (QUIC UDP-443):
${HYSTERIA2_LINK}

--- 4. STANDALONE WIREGUARD & AMNEZIAWG CONFIGURATIONS ---
(Excluded from web subscription, assigned high ports 30000+)
• WireGuard (Port ${WG_PORT} UDP):
  File: ${CLIENT_CONFIGS_DIR}/wireguard_client.conf
• AmneziaWG 1.0 (Port ${AWG1_PORT} UDP):
  File: ${CLIENT_CONFIGS_DIR}/amneziawg1_client.conf
• AmneziaWG 3.1 (Port ${AWG3_PORT} UDP):
  File: ${CLIENT_CONFIGS_DIR}/amneziawg3_client.conf
================================================================================
EOF
chmod 600 "$CREDENTIALS_FILE"
ln -sf "$CREDENTIALS_FILE" "/root/x-ui-pro-credentials.txt" 2>/dev/null || true

# Display Summary
clear
echo -e "${GREEN}================================================================================${NC}"
echo -e "${BOLD}${GREEN}               OMNISTACK 2.0 SUCCESSFULLY INSTALLED!${NC}"
echo -e "${GREEN}================================================================================${NC}"
echo -e "${BOLD}Server Role:${NC}      ${CYAN}${SERVER_ROLE^^}${NC}"
echo -e "${BOLD}Domain:${NC}           ${CYAN}${domain}${NC}"
echo -e "${BOLD}Server IPv4:${NC}      ${CYAN}${IP4}${NC}"
echo -e "${BOLD}Unified Client:${NC}   ${CYAN}${CLIENT_EMAIL}${NC}"
echo -e "${BOLD}Subscription:${NC}     ${CYAN}${SUB_TITLE}${NC}"
echo -e ""
echo -e "${BOLD}${YELLOW}🔒 3X-UI Admin Web Panel:${NC}"
echo -e "   URL:      ${BOLD}https://${domain}/${panel_path}/${NC}"
echo -e "   Username: ${BOLD}${config_username}${NC}"
echo -e "   Password: ${BOLD}${config_password}${NC}"
echo -e ""
echo -e "${BOLD}${BLUE}📋 Client Subscriptions (All Proxy Protocols Connected):${NC}"
echo -e "   Client Portal: https://${domain}/${web_path}?name=${CLIENT_SUB_ID}"
echo -e "   Base Sub:      https://${domain}/${sub_path}/${CLIENT_SUB_ID}"
echo -e "   Clash / Sing:  https://${domain}/${web_path}/clashmeta/${CLIENT_SUB_ID}"
echo -e ""
echo -e "${BOLD}${PURPLE}⚡ Quick Connect Links:${NC}"
echo -e "   • VLESS-Reality: ${VLESS_REALITY_LINK}"
echo -e "   • Hysteria 2:    ${HYSTERIA2_LINK}"
echo -e ""
echo -e "${BOLD}${CYAN}🛡️ Standalone WireGuard / AmneziaWG (High Ports 30000+):${NC}"
echo -e "   • AmneziaWG 1.0 (Port ${AWG1_PORT}):  ${CLIENT_CONFIGS_DIR}/amneziawg1_client.conf"
echo -e "   • AmneziaWG 3.1 (Port ${AWG3_PORT}):  ${CLIENT_CONFIGS_DIR}/amneziawg3_client.conf"
echo -e ""
if [[ "$SERVER_ROLE" == "exit" ]]; then
    echo -e "${YELLOW}🛡️ Security Active:${NC} .RU / .SU / Russian IP traffic is routed to ${BOLD}Blackhole${NC} (EU IP will never touch Russian servers)."
elif [[ "$SERVER_ROLE" == "cascade" ]]; then
    echo -e "${GREEN}⚡ Cascade Active:${NC} Russian traffic (.ru, Gosuslugi, Banks) routed ${BOLD}Directly${NC}; foreign traffic routed to ${BOLD}внешний сервер (Exit-нода)${NC}."
fi
echo -e ""
echo -e "${BOLD}${YELLOW}⚙️ Управление и меню OmniStack:${NC}"
echo -e "   Меню:     ${BOLD}${GREEN}omnistack${NC}           (вызов главного меню)"
echo -e "   Аудит:    ${GREEN}omnistack -check${NC}    (проверка доступности сервисов и CDN)"
echo -e "   Заглушка: ${GREEN}omnistack -fake${NC}     (сменить тему сайта-маскировки [1-15])"
echo -e "   Reality:  ${GREEN}omnistack -scan${NC}     (замер RTT и автоподбор доменов)"
echo -e "   Бэкап:    ${GREEN}omnistack -backup${NC}   (создать бэкап и отправить в Telegram)"
echo -e "   Базы:     ${GREEN}omnistack -update-geodata${NC} (обновить базы GeoIP и Geosite)"
echo -e "   Баз. ПО:  ${GREEN}omnistack -base-soft${NC}  (установка системных утилит)"
echo -e "   Панель:   ${GREEN}x-ui${NC}                 (управление службой 3X-UI)"
echo -e ""
echo -e "${CYAN}💾 All credentials and configs saved to: ${BOLD}${CREDENTIALS_FILE}${NC}"
echo -e "${GREEN}================================================================================${NC}"

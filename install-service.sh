#!/usr/bin/env bash
#
# install-service.sh — Install telegram-agent.py as a systemd service.
#
# Usage:
#   ./install-service.sh              # install as user service (no sudo)
#   ./install-service.sh --system     # install as system service (needs sudo)
#   ./install-service.sh --uninstall  # stop, disable, and remove the service
#   ./install-service.sh --status     # show service status
#

set -euo pipefail

SERVICE_NAME="open-pulsar-telegram"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON="$(command -v python3 2>/dev/null || true)"
CURRENT_USER="${USER:-$(id -un)}"
CURRENT_GROUP="$(id -gn)"
HOME_DIR="${HOME:-$(eval echo ~"$CURRENT_USER")}"
SYSTEM_MODE=false
UNINSTALL=false
STATUS=false

# --- Colors ---------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}▸${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}▸${NC} $*"; }
die()   { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

# --- Argument parsing ------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --system)    SYSTEM_MODE=true; shift ;;
        --uninstall) UNINSTALL=true; shift ;;
        --status)    STATUS=true; shift ;;
        --help|-h)
            echo "Usage: $0 [--system] [--uninstall] [--status] [--help]"
            echo ""
            echo "  (default)     Install as a user service (no sudo needed)"
            echo "  --system      Install as a system service (requires sudo)"
            echo "  --uninstall   Stop, disable, and remove the service"
            echo "  --status      Show current service status"
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

# If running as root without --system, assume system mode
if [[ "$(id -u)" -eq 0 ]] && ! $SYSTEM_MODE; then
    warn "Running as root — switching to --system mode"
    SYSTEM_MODE=true
fi

# --- Derived paths ---------------------------------------------------------

if $SYSTEM_MODE; then
    UNIT_DIR="/etc/systemd/system"
    SYSTEMCTL="systemctl"
    JOURNALCTL="journalctl -u $SERVICE_NAME"
    TARGET="multi-user.target"
else
    UNIT_DIR="$HOME_DIR/.config/systemd/user"
    SYSTEMCTL="systemctl --user"
    JOURNALCTL="journalctl --user -u $SERVICE_NAME"
    TARGET="default.target"
fi

UNIT_FILE="$UNIT_DIR/$SERVICE_NAME.service"

# --- Status ----------------------------------------------------------------

if $STATUS; then
    echo -e "${BOLD}Service:${NC} $SERVICE_NAME"
    echo -e "${BOLD}Unit file:${NC} $UNIT_FILE"
    echo ""
    if [[ -f "$UNIT_FILE" ]]; then
        $SYSTEMCTL status "$SERVICE_NAME" 2>&1 || true
        echo ""
        info "Logs: $JOURNALCTL -f"
    else
        warn "Service is not installed."
    fi
    exit 0
fi

# --- Uninstall -------------------------------------------------------------

if $UNINSTALL; then
    info "Uninstalling $SERVICE_NAME..."

    if [[ ! -f "$UNIT_FILE" ]]; then
        warn "Unit file not found at $UNIT_FILE — nothing to uninstall."
        exit 0
    fi

    $SYSTEMCTL stop "$SERVICE_NAME" 2>/dev/null || true
    $SYSTEMCTL disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$UNIT_FILE"
    $SYSTEMCTL daemon-reload

    ok "Service stopped, disabled, and removed."
    exit 0
fi

# --- Prerequisites ---------------------------------------------------------

info "Checking prerequisites..."

[[ -n "$PYTHON" ]] || die "python3 not found in PATH"
ok "Python: $PYTHON ($($PYTHON --version 2>&1))"

[[ -f "$PROJECT_DIR/telegram-agent.py" ]] || die "telegram-agent.py not found in $PROJECT_DIR"
ok "Script: $PROJECT_DIR/telegram-agent.py"

[[ -f "$PROJECT_DIR/.agent-loop/telegram.json" ]] || die ".agent-loop/telegram.json not found — run: cp .agent-loop/telegram.json.example .agent-loop/telegram.json"
ok "Config: .agent-loop/telegram.json"

[[ -f "$PROJECT_DIR/.env" ]] || die ".env not found — add telegram_token and telegram_allowed_ids"
ok "Env:    .env"

# Check Python dependencies
$PYTHON -c "import requests" 2>/dev/null || die "Python package 'requests' not installed — run: pip install -r requirements.txt"
$PYTHON -c "import dotenv" 2>/dev/null || die "Python package 'python-dotenv' not installed — run: pip install -r requirements.txt"
ok "Deps:   requests, dotenv"

echo ""

# --- Generate unit file ----------------------------------------------------

info "Generating systemd unit file..."

# User= and Group= are only valid for system services
if $SYSTEM_MODE; then
    USER_GROUP_LINES="User=$CURRENT_USER
Group=$CURRENT_GROUP"
else
    USER_GROUP_LINES=""
fi

UNIT_CONTENT="[Unit]
Description=Open Pulsar Telegram Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
${USER_GROUP_LINES}
WorkingDirectory=$PROJECT_DIR
ExecStart=$PYTHON $PROJECT_DIR/telegram-agent.py
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=300
StartLimitBurst=5

EnvironmentFile=$PROJECT_DIR/.env
Environment=HOME=$HOME_DIR
Environment=PATH=$PATH

StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME

NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=$TARGET"

# --- Install ---------------------------------------------------------------

info "Installing to $UNIT_FILE..."

mkdir -p "$UNIT_DIR"
echo "$UNIT_CONTENT" > "$UNIT_FILE"
ok "Unit file written."

$SYSTEMCTL daemon-reload
$SYSTEMCTL enable "$SERVICE_NAME"
$SYSTEMCTL start "$SERVICE_NAME"

# Enable linger for user services so they survive logout
if ! $SYSTEM_MODE; then
    if command -v loginctl &>/dev/null; then
        loginctl enable-linger "$CURRENT_USER" 2>/dev/null || warn "Could not enable linger — service may stop on logout"
        ok "Linger enabled for $CURRENT_USER"
    fi
fi

echo ""
ok "Service installed and started!"
echo ""
$SYSTEMCTL status "$SERVICE_NAME" --no-pager 2>&1 || true
echo ""
info "View logs:  $JOURNALCTL -f"
info "Stop:       $SYSTEMCTL stop $SERVICE_NAME"
info "Restart:    $SYSTEMCTL restart $SERVICE_NAME"
info "Uninstall:  $0 --uninstall"

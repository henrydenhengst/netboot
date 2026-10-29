#!/usr/bin/env bash
#
# Installeert de Quomodo Agent + IceWM/Firefox ESR op Debian 13 (Trixie).
# Geschikt voor een headless VM met 8 GB RAM (bijv. via virt-manager).
#
# Gebruik: sudo ./install-quomodo-agent-desktop-debian13.sh <CORE_WSS_URL> <SERVER_NAAM>
# Voorbeeld: sudo ./install-quomodo-agent-desktop-debian13.sh wss://quomodo.example.com web-01
#
set -euo pipefail

# --- Configuratie ---
QUOMODO_VERSION="v0.4.2"
AGENT_BIN="/usr/local/bin/quomodo-agent"
CONFIG_DIR="/etc/quomodo"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
SERVICE_FILE="/etc/systemd/system/quomodo-agent.service"
DESKTOP_USER="${SUDO_USER:-$USER}"

# --- Argumentcontrole ---
if [ "$#" -ne 2 ]; then
    echo "Gebruik: $0 <CORE_WSS_URL> <SERVER_NAAM>" >&2
    echo "Voorbeeld: $0 wss://quomodo.example.com web-01" >&2
    exit 1
fi
CORE_URL="$1"
SERVER_NAME="$2"

if [ "$(id -u)" -ne 0 ]; then
    echo "Dit script moet als root worden uitgevoerd (gebruik sudo)." >&2
    exit 1
fi

if [[ "$CORE_URL" != wss://* ]]; then
    echo "FOUT: De Core URL moet met 'wss://' beginnen. De agent weigert onbeveiligde verbindingen." >&2
    exit 1
fi

trap 'echo "FOUT: Script gestopt op regel $LINENO." >&2' ERR

echo "=== Quomodo Agent + Desktop installeren (Debian 13) ==="
echo "Core URL:      $CORE_URL"
echo "Server naam:   $SERVER_NAME"
echo "Desktop user:  $DESKTOP_USER"
echo

# --- Stap 1: Basispakketten en Podman (Debian 13 = 5.4.x native) ---
echo "[1/6] Pakketten installeren (curl, openssl, git, podman)..."
apt-get update -qq
apt-get install -y -qq curl openssl git podman

PODMAN_MAJOR=$(podman --version | awk '{print $3}' | cut -d. -f1)
if [ "$PODMAN_MAJOR" -lt 5 ]; then
    echo "FOUT: Podman is ouder dan 5.0 ($(podman --version))." >&2
    echo "Debian 13 (Trixie) hoort Podman 5.4.x te leveren. Controleer je sources.list." >&2
    exit 1
fi
echo "  -> Podman $(podman --version) geïnstalleerd (Quadlet-ondersteund)."

# --- Stap 2: Subordinate ID's (idempotent, met back-up) ---
echo "[2/6] Subordinate UID/GID ranges configureren..."
for f in /etc/subuid /etc/subgid; do
    if [ ! -f "$f" ]; then
        touch "$f"
    fi
    cp "$f" "${f}.bak.$(date +%F-%H%M%S)"
done

if ! grep -q '^containers:' /etc/subuid; then
    echo 'containers:2147483647:2147483648' >> /etc/subuid
    echo "  -> /etc/subuid bijgewerkt."
else
    echo "  -> /etc/subuid bevat al een 'containers'-entry."
fi

if ! grep -q '^containers:' /etc/subgid; then
    echo 'containers:2147483647:2147483648' >> /etc/subgid
    echo "  -> /etc/subgid bijgewerkt."
else
    echo "  -> /etc/subgid bevat al een 'containers'-entry."
fi

# --- Stap 3: Agent binary downloaden (exacte assets voor v0.4.2) ---
echo "[3/6] Quomodo Agent ${QUOMODO_VERSION} downloaden..."
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ASSET="quomodo-agent-x86_64" ;;
    aarch64) ASSET="quomodo-agent-aarch64" ;;
    *) echo "Onbekende architectuur: $ARCH" >&2; exit 1 ;;
esac

BASE_URL="https://github.com/LoganRupe/quomodo/releases/download/${QUOMODO_VERSION}"
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"

curl -fLO "${BASE_URL}/${ASSET}"
curl -fLO "${BASE_URL}/${ASSET}.sha256"
sha256sum -c "${ASSET}.sha256"
install -m 0755 "$ASSET" "$AGENT_BIN"

cd - > /dev/null
rm -rf "$TMP_DIR"
echo "  -> Geïnstalleerd als $AGENT_BIN."

# --- Stap 4: Agent configuratie ---
echo "[4/6] Agent configuratie aanmaken in $CONFIG_FILE..."
mkdir -p "$CONFIG_DIR/keys"
cat > "$CONFIG_FILE" <<EOF
core_addresses = ["${CORE_URL}"]
connect_as = "${SERVER_NAME}"
EOF
echo "  -> Configuratie weggeschreven."

# --- Stap 5: Systemd service + IceWM/Firefox ---
echo "[5/6] Systemd service en desktop-pakketten installeren..."

if [ -f "$SERVICE_FILE" ]; then
    cp "$SERVICE_FILE" "${SERVICE_FILE}.bak.$(date +%F-%H%M%S)"
fi

cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Quomodo Agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/quomodo-agent --config-path /etc/quomodo/config.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

apt-get install -y -qq icewm xorg firefox-esr xauth

# .xinitrc voor de desktopgebruiker (start IceWM betrouwbaar)
USER_HOME=$(getent passwd "$DESKTOP_USER" | cut -d: -f6)
if [ -n "$USER_HOME" ] && [ -d "$USER_HOME" ]; then
    cat > "${USER_HOME}/.xinitrc" <<'EOF'
#!/bin/sh
exec icewm-session
EOF
    chown "$DESKTOP_USER":"$DESKTOP_USER" "${USER_HOME}/.xinitrc"
    chmod +x "${USER_HOME}/.xinitrc"
fi

# --- Stap 6: Agent starten ---
echo "[6/6] Quomodo Agent starten..."
systemctl daemon-reload
systemctl enable --now quomodo-agent.service

echo
echo "=== Installatie voltooid ==="
echo
echo "Controleer de status:"
echo "  systemctl status quomodo-agent.service"
echo
echo "Toon de publieke sleutel van de agent:"
echo "  sudo quomodo-agent --config-path $CONFIG_FILE public-key"
echo
echo "Kopieer deze sleutel naar Core:"
echo "  1. Maak een 'Server' resource aan met de naam: $SERVER_NAME"
echo "  2. Plak de publieke sleutel in de configuratie van die Server."
echo
echo "--- Desktop starten met virt-manager ---"
echo "Open de grafische console van de VM in virt-manager, log in als $DESKTOP_USER en typ:"
echo "  startx"
echo
echo "Of gebruik X11-forwarding via SSH vanaf je laptop:"
echo "  ssh -X ${DESKTOP_USER}@$(hostname -I | awk '{print $1}')"
echo "  startx"
echo
echo "Firefox start je binnen IceWM vanuit het menu of met: firefox-esr"
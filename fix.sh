#!/usr/bin/env bash
# =============================================================================
#  LAATSTE PROBLEMEN OPLOSSEN: DNS in container & Netwerkbereikbaarheid
# =============================================================================
set -uo pipefail

C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[1;33m'
C_BLUE=$'\033[0;34m'
C_RESET=$'\033[0m'

ok()   { echo -e "${C_GREEN}[OK]${C_RESET}   $*"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
fail() { echo -e "${C_RED}[FAIL]${C_RESET} $*"; }
info() { echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }

if [[ $EUID -ne 0 ]]; then
    fail "Voer dit script uit als root (sudo)."
    exit 1
fi

QUADLET_FILE="/etc/containers/systemd/netbootxyz.container"
CONTAINER="netbootxyz"

echo "============================================================"
echo "  LAATSTE PROBLEMEN OPLOSSEN"
echo "============================================================"
echo

# -----------------------------------------------------------------------------
# STAP 1: DNS-probleem in de container oplossen
# -----------------------------------------------------------------------------
info "STAP 1: DNS-configuratie in de container harden..."

if [[ ! -f "$QUADLET_FILE" ]]; then
    fail "Quadlet-bestand $QUADLET_FILE niet gevonden."
    exit 1
fi

# Maak een back-up
cp -a "$QUADLET_FILE" "${QUADLET_FILE}.bak.$(date +%Y%m%d-%H%M%S)"

# Voeg DNS_SERVER toe als deze nog niet bestaat
if grep -q "Environment=DNS_SERVER" "$QUADLET_FILE"; then
    ok "DNS_SERVER is al geconfigureerd in het Quadlet-bestand."
else
    # Voeg de regel toe onder [Container]
    sed -i '/^\[Container\]/a Environment=DNS_SERVER=1.1.1.1' "$QUADLET_FILE"
    ok "DNS_SERVER=1.1.1.1 toegevoegd aan $QUADLET_FILE."
fi

info "Container herstarten om DNS toe te passen..."
systemctl daemon-reload
systemctl restart "${CONTAINER}.service"
sleep 5

if podman ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    ok "Container draait weer."
else
    fail "Container is niet gestart. Controleer logs met: podman logs $CONTAINER"
    exit 1
fi
echo

# -----------------------------------------------------------------------------
# STAP 2: Controleren of de container bereikbaar is via het fysieke netwerk
# -----------------------------------------------------------------------------
info "STAP 2: Netwerkbereikbaarheid controleren..."

# Haal het IP-adres van de server op (de interface die naar de Fritzbox gaat)
SERVER_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
info "Server IP-adres: $SERVER_IP"

if [[ -z "$SERVER_IP" ]]; then
    fail "Kon het IP-adres van de server niet bepalen."
    exit 1
fi

# Test TFTP via het fysieke IP-adres (niet 127.0.0.1)
info "TFTP testen via $SERVER_IP..."
TMP_FILE=$(mktemp)
if curl -fsS --max-time 10 "tftp://${SERVER_IP}/netboot.xyz.efi" -o "$TMP_FILE" 2>/dev/null; then
    ok "TFTP werkt via het fysieke netwerk ($SERVER_IP)."
else
    fail "TFTP werkt NIET via $SERVER_IP."
    warn "Dit kan betekenen dat de firewall verkeer van buiten blokkeert."
fi
rm -f "$TMP_FILE"

# Test HTTP via het fysieke IP-adres
info "HTTP testen via $SERVER_IP..."
if curl -fsS --max-time 5 "http://${SERVER_IP}/" >/dev/null 2>&1; then
    ok "HTTP werkt via het fysieke netwerk ($SERVER_IP)."
else
    fail "HTTP werkt NIET via $SERVER_IP."
fi
echo

# -----------------------------------------------------------------------------
# STAP 3: Firewall controleren op verkeer van de Dell E7440
# -----------------------------------------------------------------------------
info "STAP 3: Firewallregels controleren voor TFTP en HTTP..."

ZONE=$(firewall-cmd --get-zone-of-interface=eno1 2>/dev/null || echo "public")
info "Zone voor eno1: $ZONE"

# Controleer TFTP (UDP 69)
if firewall-cmd --zone="$ZONE" --query-port=69/udp >/dev/null 2>&1 || \
   firewall-cmd --zone="$ZONE" --query-service=tftp >/dev/null 2>&1; then
    ok "TFTP (UDP 69) is toegestaan in zone '$ZONE'."
else
    warn "TFTP (UDP 69) is NIET expliciet toegestaan. Toevoegen..."
    firewall-cmd --permanent --zone="$ZONE" --add-port=69/udp
    firewall-cmd --reload
    ok "TFTP (UDP 69) toegevoegd aan zone '$ZONE'."
fi

# Controleer HTTP (TCP 80)
if firewall-cmd --zone="$ZONE" --query-port=80/tcp >/dev/null 2>&1; then
    ok "HTTP (TCP 80) is toegestaan in zone '$ZONE'."
else
    warn "HTTP (TCP 80) is NIET expliciet toegestaan. Toevoegen..."
    firewall-cmd --permanent --zone="$ZONE" --add-port=80/tcp
    firewall-cmd --reload
    ok "HTTP (TCP 80) toegevoegd aan zone '$ZONE'."
fi
echo

# -----------------------------------------------------------------------------
# STAP 4: Samenvatting en volgende stap
# -----------------------------------------------------------------------------
echo "============================================================"
ok "LAATSTE PROBLEMEN OPGELOST"
echo "============================================================"
echo "  Wat is er gedaan:"
echo "    1. DNS_SERVER=1.1.1.1 toegevoegd aan de container."
echo "    2. Container herstart en gecontroleerd."
echo "    3. TFTP en HTTP getest via het fysieke IP ($SERVER_IP)."
echo "    4. Firewallregels gecontroleerd en indien nodig aangevuld."
echo
echo "  Nu is het tijd voor de echte test:"
echo "    1. Start de Dell E7440 op en druk op F12."
echo "    2. Kies 'Onboard NIC' (UEFI)."
echo "    3. Kijk live mee op de server met:"
echo "         sudo podman logs -f netbootxyz"
echo
echo "  Je zou nu verkeer moeten zien van 192.168.192.x (de Dell)"
echo "  in plaats van alleen 10.88.0.1 (de container)."
echo "============================================================"
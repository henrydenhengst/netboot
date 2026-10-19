#!/usr/bin/env bash
# =============================================================================
#  NETBOOTXYZ FIX — Network=host → PublishPort
# =============================================================================
#  Diagnosticeert waarom poort 69/80 niet luisteren, past de Quadlet-config
#  aan, herstart de container en verifieert.
#
#  Gebruik:  sudo ./fix-netbootxyz.sh
# =============================================================================

set -uo pipefail

QUADLET_FILE="/etc/containers/systemd/netbootxyz.container"
BACKUP="${QUADLET_FILE}.bak.$(date +%Y%m%d-%H%M%S)"

if [[ $EUID -ne 0 ]]; then
    echo "Root vereist: sudo $0" >&2
    exit 1
fi

if [[ ! -f "$QUADLET_FILE" ]]; then
    echo "Niet gevonden: $QUADLET_FILE" >&2
    echo "Is de installatie wel uitgevoerd?" >&2
    exit 1
fi

echo "============================================================"
echo "  STAP 1 — DIAGNOSE"
echo "============================================================"
echo

echo "--- Huidige Quadlet-config ---"
grep -E '^(Network|PublishPort|Environment|Image)' "$QUADLET_FILE" | sed 's/^/  /'
echo

echo "--- Draaiende containers ---"
podman ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | sed 's/^/  /'
echo

echo "--- Poort 80 (TCP) ---"
ss -tlnp 2>/dev/null | grep -E ':(80|12080) ' | sed 's/^/  /' || echo "  (niets)"
echo

echo "--- Poort 69 (UDP) ---"
ss -ulnp 2>/dev/null | grep -E ':(69) ' | sed 's/^/  /' || echo "  (niets)"
echo

echo "--- Container-logs (laatste 25 regels) ---"
podman logs netbootxyz 2>&1 | tail -25 | sed 's/^/  /' || echo "  (geen logs)"
echo

echo "--- Container inspect: poortbindingen ---"
podman inspect netbootxyz --format '{{json .HostConfig.PortBindings}}' 2>/dev/null | sed 's/^/  /' || echo "  (niet beschikbaar)"
echo

echo "--- Container inspect: netwerkmodus ---"
podman inspect netbootxyz --format '{{.HostConfig.NetworkMode}}' 2>/dev/null | sed 's/^/  /' || echo "  (niet beschikbaar)"
echo

echo "============================================================"
echo "  STAP 2 — FIX TOEPASSEN"
echo "============================================================"

if ! grep -q '^Network=host' "$QUADLET_FILE"; then
    echo "Network=host staat niet in de file — de fix is mogelijk al toegepast."
    echo "Wil je de configuratie alsnog overschrijven met de PublishPort-versie?"
    read -rp "Doorgaan? (j/n): " cont
    [[ "$cont" =~ ^[jJ]$ ]] || { echo "Afgebroken."; exit 0; }
else
    echo "Network=host gevonden — fix wordt toegepast."
    read -rp "Doorgaan? (j/n): " cont
    [[ "$cont" =~ ^[jJ]$ ]] || { echo "Afgebroken."; exit 0; }
fi

echo
echo "Back-up: $BACKUP"
cp -a "$QUADLET_FILE" "$BACKUP"

echo "Nieuwe configuratie schrijven..."
cat > "$QUADLET_FILE" <<'EOF'
[Unit]
Description=netboot.xyz (TFTP + HTTP)
Documentation=https://netboot.xyz
After=network-online.target
Wants=network-online.target

[Container]
Image=ghcr.io/netbootxyz/netbootxyz:latest
ContainerName=netbootxyz
PublishPort=69:69/udp
PublishPort=80:80
PublishPort=12080:3000
Volume=/srv/tftp:/assets:Z
Volume=/srv/netboot-config:/config:Z
Environment=TFTPD_OPTS=--tftp-single-port

[Service]
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

echo "Container stoppen en verwijderen..."
systemctl stop netbootxyz.service 2>/dev/null || true
podman rm -f netbootxyz 2>/dev/null || true

echo "Systemd herladen..."
systemctl daemon-reload

echo "Container starten..."
systemctl start netbootxyz.service

echo
echo "Wachten tot de container is opgestart (15s)..."
sleep 15

echo
echo "============================================================"
echo "  STAP 3 — VERIFICATIE"
echo "============================================================"
echo

echo "--- Container-status ---"
podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | sed 's/^/  /'
echo

echo "--- Poort 80 (TCP) ---"
if ss -tlnp 2>/dev/null | grep -qE ':80 '; then
    echo "  ✓ poort 80 luistert"
    ss -tlnp | grep ':80 ' | sed 's/^/  /'
else
    echo "  ✗ poort 80 luistert NIET"
fi
echo

echo "--- Poort 69 (UDP) ---"
if ss -ulnp 2>/dev/null | grep -qE ':69 '; then
    echo "  ✓ poort 69 luistert"
    ss -ulnp | grep ':69 ' | sed 's/^/  /'
else
    echo "  ✗ poort 69 luistert NIET"
fi
echo

echo "--- HTTP-test ---"
if curl -fsS --max-time 5 "http://127.0.0.1/" >/dev/null 2>&1; then
    echo "  ✓ HTTP root antwoordt"
else
    echo "  ✗ HTTP root antwoordt NIET"
fi
echo

echo "--- TFTP-test ---"
if curl -fsS --max-time 10 "tftp://127.0.0.1/netboot.xyz.kpxe" -o /tmp/test.kpxe 2>/dev/null \
    && [[ -s /tmp/test.kpxe ]]; then
    echo "  ✓ netboot.xyz.kpxe opgehaald ($(stat -c%s /tmp/test.kpxe) bytes)"
    rm -f /tmp/test.kpxe
else
    echo "  ✗ netboot.xyz.kpxe niet opgehaald"
fi
echo

echo "--- Container-logs (laatste 15 regels) ---"
podman logs netbootxyz 2>&1 | tail -15 | sed 's/^/  /'
echo

echo "============================================================"
if ss -tlnp 2>/dev/null | grep -qE ':80 ' && ss -ulnp 2>/dev/null | grep -qE ':69 '; then
    echo "  RESULTAAT: GESLAAGD — poort 69 en 80 luisteren."
    echo "============================================================"
    exit 0
else
    echo "  RESULTAAT: MISLUKT — poort 69 en/of 80 luisteren niet."
    echo "  Plak de output hierboven; de containerlogs wijzen de oorzaak aan."
    echo "============================================================"
    exit 1
fi
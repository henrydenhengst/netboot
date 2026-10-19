#!/usr/bin/env bash
# =============================================================================
#  FIX DOKUWIKI — poortmapping 12081:80 → 12081:8080
# =============================================================================
#  Past de Quadlet-configuratie van DokuWiki aan zodat de container op de
#  juiste interne poort (8080) wordt gepubliceerd, herstart de container en
#  verifieert dat de webinterface bereikbaar is.
#
#  Gebruik:  sudo ./fix-dokuwiki.sh
# =============================================================================

set -uo pipefail

QUADLET_FILE="/etc/containers/systemd/dokuwiki.container"
BACKUP="${QUADLET_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
HOST_PORT=12081
CONTAINER="dokuwiki"
DATA_DIR="/srv/dokuwiki/data"

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
echo "  FIX DOKUWIKI — $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo

# -----------------------------------------------------------------------------
# 1. Huidige staat
# -----------------------------------------------------------------------------
echo "--- Huidige Quadlet-config (poortregel) ---"
grep -E '^PublishPort' "$QUADLET_FILE" | sed 's/^/  /'
echo

echo "--- Huidige poortmapping in Podman ---"
podman port "$CONTAINER" 2>/dev/null | sed 's/^/  /' || echo "  (container niet actief of geen mapping)"
echo

# -----------------------------------------------------------------------------
# 2. Bepaal of fix nodig is
# -----------------------------------------------------------------------------
if grep -q '^PublishPort=12081:8080' "$QUADLET_FILE"; then
    echo "Configuratie is al correct (12081:8080). Alleen herstarten."
    NEEDS_PATCH=0
else
    echo "Configuratie moet worden aangepast naar 12081:8080."
    NEEDS_PATCH=1
fi
echo

read -rp "Doorgaan met de fix? (j/n): " cont
[[ "$cont" =~ ^[jJ]$ ]] || { echo "Afgebroken."; exit 0; }
echo

# -----------------------------------------------------------------------------
# 3. Back-up en patch
# -----------------------------------------------------------------------------
if (( NEEDS_PATCH == 1 )); then
    echo "Back-up: $BACKUP"
    cp -a "$QUADLET_FILE" "$BACKUP"

    echo "Poortregel aanpassen..."
    sed -i 's|^PublishPort=12081:80$|PublishPort=12081:8080|' "$QUADLET_FILE"

    if ! grep -q '^PublishPort=12081:8080' "$QUADLET_FILE"; then
        echo "✗ Aanpassen mislukt. Herstel de back-up handmatig:" >&2
        echo "  cp -a '$BACKUP' '$QUADLET_FILE'" >&2
        exit 1
    fi
    echo "✓ Configuratie aangepast."
else
    echo "Geen patch nodig."
fi
echo

# -----------------------------------------------------------------------------
# 4. Container verwijderen en opnieuw aanmaken
# -----------------------------------------------------------------------------
echo "Container stoppen..."
systemctl stop dokuwiki.service 2>/dev/null || true

echo "Container verwijderen (data blijft behouden)..."
podman rm -f "$CONTAINER" 2>/dev/null || true

echo "Data-map eigenaar corrigeren..."
if [[ -d "$DATA_DIR" ]]; then
    chown -R 33:33 "$DATA_DIR"
    echo "  ✓ $DATA_DIR → 33:33"
else
    echo "  ⚠ $DATA_DIR bestaat niet — wordt aangemaakt bij eerste start."
fi
echo

echo "Systemd herladen en container starten..."
systemctl daemon-reload
systemctl start dokuwiki.service

echo
echo "Wachten tot DokuWiki is geïnitialiseerd (25s)..."
sleep 25

# -----------------------------------------------------------------------------
# 5. Verifiëren
# -----------------------------------------------------------------------------
echo
echo "============================================================"
echo "  VERIFICATIE"
echo "============================================================"
echo

echo "--- Container-status ---"
podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E "^(NAMES|${CONTAINER})" | sed 's/^/  /'
echo

echo "--- Poortmapping ---"
podman port "$CONTAINER" 2>/dev/null | sed 's/^/  /' || echo "  (geen mapping)"
echo

echo "--- Poort luistert op host ---"
if ss -tlnp 2>/dev/null | grep -q ":${HOST_PORT} "; then
    echo "  ✓ poort ${HOST_PORT} luistert"
else
    echo "  ✗ poort ${HOST_PORT} luistert NIET"
fi
echo

echo "--- Lokale HTTP-test ---"
if curl -fsS --max-time 5 "http://127.0.0.1:${HOST_PORT}/" >/dev/null 2>&1; then
    echo "  ✓ HTTP op 127.0.0.1:${HOST_PORT} antwoordt"
    HTTP_OK=1
else
    echo "  ✗ HTTP op 127.0.0.1:${HOST_PORT} antwoordt NIET"
    HTTP_OK=0
fi
echo

# -----------------------------------------------------------------------------
# 6. Resultaat
# -----------------------------------------------------------------------------
if (( HTTP_OK == 1 )); then
    echo "============================================================"
    echo "  RESULTAAT: GESLAAGD"
    echo "============================================================"
    echo "  DokuWiki is bereikbaar op:"
    echo "    http://<server-ip>:${HOST_PORT}/"
    echo
    echo "  Open in je browser en rond de installatie-wizard af."
    echo "============================================================"
    exit 0
else
    echo "============================================================"
    echo "  RESULTAAT: MISLUKT"
    echo "============================================================"
    echo "  Poort luistert niet of HTTP antwoordt niet."
    echo
    echo "  Container-logs (laatste 30 regels):"
    podman logs "$CONTAINER" 2>&1 | tail -30 | sed 's/^/    /'
    echo
    echo "  Onderzoek:"
    echo "    sudo podman inspect $CONTAINER --format '{{json .Config.ExposedPorts}}'"
    echo "    sudo cat $QUADLET_FILE"
    echo "    sudo ss -tlnp | grep :${HOST_PORT}"
    echo
    echo "  Handmatig terugrollen:"
    echo "    cp -a '$BACKUP' '$QUADLET_FILE'"
    echo "    sudo systemctl daemon-reload"
    echo "============================================================"
    exit 1
fi
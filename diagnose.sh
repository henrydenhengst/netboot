#!/usr/bin/env bash
# =============================================================================
#  DOKUWIKI DIAGNOSE
# =============================================================================
#  Onderzoekt waarom de DokuWiki-container niet bereikbaar is op de
#  verwachte host-poort (standaard 12081).
#
#  Gebruik:  sudo ./diagnose-dokuwiki.sh
# =============================================================================

set -uo pipefail

HOST_PORT="${1:-12081}"
CONTAINER="dokuwiki"

if [[ $EUID -ne 0 ]]; then
    echo "Root vereist: sudo $0" >&2
    exit 1
fi

echo "============================================================"
echo "  DOKUWIKI DIAGNOSE — host-poort ${HOST_PORT}"
echo "============================================================"
echo

# -----------------------------------------------------------------------------
# 1. Draait de container?
# -----------------------------------------------------------------------------
echo "--- 1. Container-status ---"
if ! podman ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "  ✗ Container '${CONTAINER}' draait NIET."
    echo "  Start hem met: sudo systemctl start ${CONTAINER}.service"
    echo
    echo "--- Logs van de laatste poging (indien beschikbaar) ---"
    podman logs "$CONTAINER" 2>&1 | tail -30 | sed 's/^/  /'
    exit 1
fi
echo "  ✓ Container '${CONTAINER}' draait."
echo

# -----------------------------------------------------------------------------
# 2. Poortmapping: wat publiceert Podman?
# -----------------------------------------------------------------------------
echo "--- 2. Poortmapping (podman) ---"
MAPPING=$(podman port "$CONTAINER" 2>/dev/null)
if [[ -z "$MAPPING" ]]; then
    echo "  ✗ Geen poortmapping gevonden. De container luistert niet op een host-poort."
else
    echo "$MAPPING" | sed 's/^/  /'
fi
echo

# -----------------------------------------------------------------------------
# 3. Interne poort van de image
# -----------------------------------------------------------------------------
echo "--- 3. Interne poort (image-inspectie) ---"
EXPOSED=$(podman inspect "$CONTAINER" --format '{{json .Config.ExposedPorts}}' 2>/dev/null)
echo "  Image verwacht intern: ${EXPOSED:-<geen>}"
echo

# -----------------------------------------------------------------------------
# 4. Luistert de host-poort?
# -----------------------------------------------------------------------------
echo "--- 4. Host-poort ${HOST_PORT} ---"
if ss -tlnp 2>/dev/null | grep -q ":${HOST_PORT} "; then
    echo "  ✓ Poort ${HOST_PORT} luistert op de host."
    ss -tlnp | grep ":${HOST_PORT} " | sed 's/^/  /'
else
    echo "  ✗ Poort ${HOST_PORT} luistert NIET op de host."
    echo "  Dit betekent dat de poortmapping niet actief is of de container"
    echo "  de poort niet kan binden."
fi
echo

# -----------------------------------------------------------------------------
# 5. Lokale HTTP-test
# -----------------------------------------------------------------------------
echo "--- 5. Lokale HTTP-test ---"
if curl -fsS --max-time 5 "http://127.0.0.1:${HOST_PORT}/" >/dev/null 2>&1; then
    echo "  ✓ HTTP op 127.0.0.1:${HOST_PORT} antwoordt."
else
    echo "  ✗ HTTP op 127.0.0.1:${HOST_PORT} antwoordt NIET."
fi
echo

# -----------------------------------------------------------------------------
# 6. Container-logs
# -----------------------------------------------------------------------------
echo "--- 6. Container-logs (laatste 30 regels) ---"
podman logs "$CONTAINER" 2>&1 | tail -30 | sed 's/^/  /'
echo

# -----------------------------------------------------------------------------
# 7. Data-map rechten
# -----------------------------------------------------------------------------
echo "--- 7. Data-map rechten ---"
DATA_DIR="/srv/dokuwiki/data"
if [[ -d "$DATA_DIR" ]]; then
    OWNER=$(stat -c '%u:%g' "$DATA_DIR" 2>/dev/null)
    echo "  ${DATA_DIR} eigenaar: ${OWNER}"
    echo "  Verwachte eigenaar: 33:33 (www-data in de image)"
    if [[ "$OWNER" != "33:33" ]]; then
        echo "  ⚠ Eigenaar wijkt af. Dit kan de initialisatie blokkeren."
        echo "    Fix: sudo chown -R 33:33 ${DATA_DIR}"
    fi
else
    echo "  ✗ ${DATA_DIR} bestaat niet."
fi
echo

echo "============================================================"
echo "  EINDE DIAGNOSE"
echo "============================================================"
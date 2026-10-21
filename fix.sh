#!/usr/bin/env bash
# =============================================================================
#  FIX SCRIPT VOOR NETBOOT.XYZ TFTP-PAD PROBLEEM (openSUSE Leap)
# =============================================================================
#  Probleem: De netbootxyz-container zoekt TFTP-bestanden in /config/menus/
#            terwijl het installatiescript /srv/tftp aan /assets koppelt.
#  Oplossing: Kopieer de bootbestanden naar /srv/netboot-config/menus/ en
#             herstart de container. Daarna wordt de werking geverifieerd.
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
    fail "Dit script moet als root worden uitgevoerd (sudo)."
    exit 1
fi

# Paden (pas aan indien jouw script andere paden gebruikt)
TFTP_DIR="/srv/tftp"
CONFIG_DIR="/srv/netboot-config"
MENUS_DIR="${CONFIG_DIR}/menus"
CONTAINER="netbootxyz"

# Te kopiëren bestanden
FILES=("netboot.xyz.efi" "netboot.xyz.kpxe")

echo "============================================================"
echo "  NETBOOT TFTP-PAD FIX"
echo "  Datum: $(date)"
echo "============================================================"
echo

# -----------------------------------------------------------------------------
# STAP 1: Controleer of de benodigde mappen en bestanden bestaan
# -----------------------------------------------------------------------------
info "STAP 1: Controleren van mappen en bronbestanden..."

if [[ ! -d "$TFTP_DIR" ]]; then
    fail "TFTP-map $TFTP_DIR bestaat niet. Is het installatiescript uitgevoerd?"
    exit 1
fi
ok "TFTP-map $TFTP_DIR bestaat."

if [[ ! -d "$MENUS_DIR" ]]; then
    warn "Doelmap $MENUS_DIR bestaat nog niet. Deze wordt aangemaakt."
    mkdir -p "$MENUS_DIR" || { fail "Kon $MENUS_DIR niet aanmaken."; exit 1; }
fi
ok "Doelmap $MENUS_DIR bestaat."

for f in "${FILES[@]}"; do
    if [[ -f "${TFTP_DIR}/${f}" ]]; then
        ok "Bronbestand gevonden: ${TFTP_DIR}/${f}"
    else
        fail "Bronbestand ONTBREEKT: ${TFTP_DIR}/${f}"
        warn "  Haal dit bestand eerst op, bijvoorbeeld via:"
        warn "    sudo podman cp ${CONTAINER}:/assets/${f} ${TFTP_DIR}/"
        MISSING=1
    fi
done

if [[ "${MISSING:-0}" -eq 1 ]]; then
    fail "Niet alle bronbestanden zijn aanwezig. Fix afgebroken."
    exit 1
fi
echo

# -----------------------------------------------------------------------------
# STAP 2: Kopieer de bestanden naar de map die de container gebruikt
# -----------------------------------------------------------------------------
info "STAP 2: Bootbestanden kopiëren naar ${MENUS_DIR}..."
for f in "${FILES[@]}"; do
    cp -f "${TFTP_DIR}/${f}" "${MENUS_DIR}/${f}" \
        && ok "  Gekopieerd: ${f}" \
        || { fail "  Kopiëren mislukt: ${f}"; exit 1; }
done
echo

# -----------------------------------------------------------------------------
# STAP 3: Container herstarten
# -----------------------------------------------------------------------------
info "STAP 3: Container '${CONTAINER}' herstarten..."
if systemctl restart "${CONTAINER}.service"; then
    ok "Container herstart aangevraagd."
else
    fail "Herstarten van ${CONTAINER}.service mislukt."
    exit 1
fi

# Wacht tot de container weer draait (max 60 s)
info "Wachten tot de container actief is..."
for i in {1..20}; do
    if podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
        ok "Container draait weer."
        break
    fi
    sleep 3
    if [[ $i -eq 20 ]]; then
        fail "Container is niet binnen 60 seconden actief geworden."
        podman logs --tail 30 "$CONTAINER" 2>&1 || true
        exit 1
    fi
done
echo

# -----------------------------------------------------------------------------
# STAP 4: TFTP lokaal testen
# -----------------------------------------------------------------------------
info "STAP 4: TFTP lokaal testen (via 127.0.0.1)..."
TMP_FILE=$(mktemp)
TFTP_OK=0
for f in "${FILES[@]}"; do
    if curl -fsS --max-time 15 "tftp://127.0.0.1/${f}" -o "$TMP_FILE" 2>/dev/null; then
        SIZE=$(stat -c%s "$TMP_FILE")
        ok "  TFTP: ${f} succesvol opgehaald (${SIZE} bytes)."
        TFTP_OK=1
    else
        fail "  TFTP: ${f} kon NIET worden opgehaald."
    fi
done
rm -f "$TMP_FILE"
echo

# -----------------------------------------------------------------------------
# STAP 5: Eindconclusie
# -----------------------------------------------------------------------------
if [[ "$TFTP_OK" -eq 1 ]]; then
    ok "TFTP werkt nu lokaal. De Dell E7440 zou nu moeten kunnen booten."
    echo
    info "Als de Dell E7440 nog steeds een fout geeft, is dat de bekende"
    info "UEFI 0xFF-bug. Maak dan de workaround aan met:"
    info "  sudo cp ${MENUS_DIR}/netboot.xyz.efi \"${MENUS_DIR}/netboot.xyz.efi$(printf '\\xff')\""
    echo
    info "Start nu de Dell E7440 op en bekijk de live logs met:"
    info "  sudo podman logs -f ${CONTAINER}"
else
    fail "TFTP werkt nog niet lokaal. Bekijk de containerlogs voor details:"
    echo
    podman logs --tail 30 "$CONTAINER" 2>&1 || true
    exit 1
fi
#!/usr/bin/env bash
# =============================================================================
#  VOLLEDIGE OPLOSSING VOOR NETBOOT.XYZ TFTP-PROBLEEM
# =============================================================================
#  Dit script lost het probleem in één keer op:
#    1. Downloadt de ontbrekende bootbestanden van de officiële server.
#    2. Plaatst ze in /srv/tftp (host) én in /srv/netboot-config/menus
#       (de map die de container daadwerkelijk gebruikt voor TFTP).
#    3. Herstart de netbootxyz-container.
#    4. Verifieert dat TFTP lokaal werkt.
#    5. Maakt optioneel de 0xFF-workaround aan voor de Dell E7440.
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

# -----------------------------------------------------------------------------
# Configuratie
# -----------------------------------------------------------------------------
TFTP_DIR="/srv/tftp"
CONFIG_DIR="/srv/netboot-config"
MENUS_DIR="${CONFIG_DIR}/menus"
CONTAINER="netbootxyz"

# Officiële download-URL's (rolling release)
declare -A DOWNLOADS=(
    ["netboot.xyz.efi"]="https://boot.netboot.xyz/ipxe/netboot.xyz.efi"
    ["netboot.xyz.kpxe"]="https://boot.netboot.xyz/ipxe/netboot.xyz.kpxe"
)

echo "============================================================"
echo "  NETBOOT.XYZ VOLLEDIGE OPLOSSING"
echo "  Datum: $(date)"
echo "============================================================"
echo

# -----------------------------------------------------------------------------
# STAP 1: Mappen aanmaken
# -----------------------------------------------------------------------------
info "STAP 1: Mappen controleren/aanmaken..."
mkdir -p "$TFTP_DIR" "$MENUS_DIR" || { fail "Kon mappen niet aanmaken."; exit 1; }
ok "Mappen gereed: $TFTP_DIR en $MENUS_DIR"
echo

# -----------------------------------------------------------------------------
# STAP 2: Bootbestanden downloaden (indien nog niet aanwezig)
# -----------------------------------------------------------------------------
info "STAP 2: Bootbestanden downloaden..."
for f in "${!DOWNLOADS[@]}"; do
    if [[ -s "${TFTP_DIR}/${f}" ]]; then
        ok "  ${f} bestaat al ($(stat -c%s "${TFTP_DIR}/${f}") bytes). Overslaan."
        continue
    fi
    info "  Downloaden: ${f}..."
    if curl -fL --retry 3 --connect-timeout 15 -o "${TFTP_DIR}/${f}" "${DOWNLOADS[$f]}"; then
        SIZE=$(stat -c%s "${TFTP_DIR}/${f}")
        ok "  ${f} gedownload (${SIZE} bytes)."
    else
        fail "  Downloaden van ${f} mislukt."
        exit 1
    fi
done
echo

# -----------------------------------------------------------------------------
# STAP 3: Bestanden kopiëren naar de map die de container gebruikt
# -----------------------------------------------------------------------------
info "STAP 3: Bestanden kopiëren naar ${MENUS_DIR}..."
for f in "${!DOWNLOADS[@]}"; do
    cp -f "${TFTP_DIR}/${f}" "${MENUS_DIR}/${f}" \
        && ok "  Gekopieerd: ${f}" \
        || { fail "  Kopiëren mislukt: ${f}"; exit 1; }
done

# 0xFF-workaround voor de Dell E7440 meteen aanmaken
info "  Workaround aanmaken voor Dell E7440 (0xFF-teken)..."
python3 - "${MENUS_DIR}/netboot.xyz.efi" <<'PYEOF'
import sys, shutil
src = sys.argv[1]
dst = src + '\xff'
shutil.copyfile(src, dst)
print(f"[OK]   Workaround aangemaakt: {dst.encode('utf-8', 'backslashreplace').decode()}")
PYEOF

echo

# -----------------------------------------------------------------------------
# STAP 4: Container herstarten
# -----------------------------------------------------------------------------
info "STAP 4: Container '${CONTAINER}' herstarten..."
if ! systemctl restart "${CONTAINER}.service"; then
    fail "Herstarten van ${CONTAINER}.service mislukt."
    exit 1
fi

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
# STAP 5: TFTP lokaal verifiëren
# -----------------------------------------------------------------------------
info "STAP 5: TFTP lokaal verifiëren..."
TMP_FILE=$(mktemp)
TFTP_OK=0
for f in "${!DOWNLOADS[@]}"; do
    if curl -fsS --max-time 20 "tftp://127.0.0.1/${f}" -o "$TMP_FILE" 2>/dev/null; then
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
# STAP 6: Eindconclusie
# -----------------------------------------------------------------------------
if [[ "$TFTP_OK" -eq 1 ]]; then
    echo "============================================================"
    ok "OPLOSSING VOLTOOID"
    echo "============================================================"
    echo "  De TFTP-server werkt nu correct en de bestanden zijn"
    echo "  aanwezig, inclusief de 0xFF-workaround voor de Dell E7440."
    echo
    echo "  Volgende stap:"
    echo "    1. Start de Dell E7440 op via PXE (F12 → Onboard NIC)."
    echo "    2. Bekijk live logs met:"
    echo "         sudo podman logs -f ${CONTAINER}"
    echo "============================================================"
    exit 0
else
    fail "TFTP werkt nog niet lokaal. Containerlogs:"
    echo
    podman logs --tail 40 "$CONTAINER" 2>&1 || true
    exit 1
fi
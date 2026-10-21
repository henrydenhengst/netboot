#!/usr/bin/env bash
# =============================================================================
#  DIAGNOSE SCRIPT VOOR NETBOOT.XYZ STACK (openSUSE Leap)
# =============================================================================
#  Dit script test alle lagen van de netboot-stack om te achterhalen
#  waarom een PXE-client (zoals een Dell Latitude E7440) faalt met
#  een PXE-E23 fout.
# =============================================================================

set -uo pipefail

# Kleuren voor output
C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[1;33m'
C_BLUE=$'\033[0;34m'
C_RESET=$'\033[0m'

ok()   { echo -e "${C_GREEN}[OK]${C_RESET}   $*"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
fail() { echo -e "${C_RED}[FAIL]${C_RESET} $*"; }
info() { echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }

# Controleer root
if [[ $EUID -ne 0 ]]; then
    fail "Dit script moet als root worden uitgevoerd (sudo)."
    exit 1
fi

echo "============================================================"
echo "  NETBOOT STACK DIAGNOSE"
echo "  Datum: $(date)"
echo "============================================================"
echo

# -----------------------------------------------------------------------------
# STAP 1: HOST SERVICES
# -----------------------------------------------------------------------------
info "STAP 1: Controleren van host-services (dnsmasq, firewalld, cockpit)..."
for svc in dnsmasq firewalld cockpit.socket; do
    if systemctl is-active --quiet "$svc"; then
        ok "$svc is actief."
    else
        fail "$svc is NIET actief. (systemctl status $svc)"
    fi
done
echo

# -----------------------------------------------------------------------------
# STAP 2: CONTAINER STATUS
# -----------------------------------------------------------------------------
info "STAP 2: Controleren van Podman containers..."
if ! command -v podman >/dev/null 2>&1; then
    fail "Podman is niet geïnstalleerd."
else
    for ctr in netbootxyz dokuwiki forgejo; do
        if podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^${ctr}$"; then
            ok "Container '$ctr' draait."
        else
            fail "Container '$ctr' draait NIET. (podman ps -a)"
        fi
    done
fi
echo

# -----------------------------------------------------------------------------
# STAP 3: POORTEN EN LUISTEREN
# -----------------------------------------------------------------------------
info "STAP 3: Controleren of poorten 69/UDP en 80/TCP luisteren..."
if ss -ulnp 2>/dev/null | grep -qE '(:|\])69[[:space:]]'; then
    ok "Poort 69/UDP (TFTP) luistert."
else
    fail "Poort 69/UDP luistert NIET. TFTP-server is niet bereikbaar."
fi

if ss -tlnp 2>/dev/null | grep -qE '(:|\])80[[:space:]]'; then
    ok "Poort 80/TCP (HTTP) luistert."
else
    fail "Poort 80/TCP luistert NIET. HTTP-server is niet bereikbaar."
fi
echo

# -----------------------------------------------------------------------------
# STAP 4: FIREWALL REGELS
# -----------------------------------------------------------------------------
info "STAP 4: Controleren van firewalld regels..."
# Zoek de zone van de interface met het standaard gateway IP
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
if [[ -n "$DEFAULT_IFACE" ]]; then
    ZONE=$(firewall-cmd --get-zone-of-interface="$DEFAULT_IFACE" 2>/dev/null || true)
    info "Standaard interface: $DEFAULT_IFACE (Zone: ${ZONE:-geen})"
    
    if [[ -n "$ZONE" && "$ZONE" != "no zone" ]]; then
        # Check TFTP (UDP 69)
        if firewall-cmd --zone="$ZONE" --query-port=69/udp >/dev/null 2>&1 || \
           firewall-cmd --zone="$ZONE" --query-service=tftp >/dev/null 2>&1; then
            ok "Firewall staat TFTP (poort 69/UDP) toe in zone '$ZONE'."
        else
            fail "Firewall blokkeert mogelijk TFTP (poort 69/UDP) in zone '$ZONE'."
        fi
        
        # Check DHCP (UDP 67)
        if firewall-cmd --zone="$ZONE" --query-service=dhcp >/dev/null 2>&1; then
            ok "Firewall staat DHCP (poort 67/UDP) toe in zone '$ZONE'."
        else
            fail "Firewall blokkeert mogelijk DHCP (poort 67/UDP) in zone '$ZONE'."
        fi
    fi
else
    warn "Kon de standaard netwerkinterface niet bepalen."
fi
echo

# -----------------------------------------------------------------------------
# STAP 5: TFTP BESTANDEN TESTEN (Lokaal)
# -----------------------------------------------------------------------------
info "STAP 5: Lokaal testen van TFTP-bestanden..."
# We gebruiken curl met tftp protocol voor de test
TMP_FILE=$(mktemp)
for f in netboot.xyz.efi netboot.xyz.kpxe; do
    if curl -fsS --max-time 10 "tftp://127.0.0.1/${f}" -o "$TMP_FILE" 2>/dev/null; then
        SIZE=$(stat -c%s "$TMP_FILE")
        ok "TFTP: $f succesvol opgehaald ($SIZE bytes)."
    else
        fail "TFTP: $f kon NIET worden opgehaald."
    fi
done
rm -f "$TMP_FILE"
echo

# -----------------------------------------------------------------------------
# STAP 6: DELL E7440 UEFI 0xFF BUG TEST
# -----------------------------------------------------------------------------
info "STAP 6: Specifieke test voor de Dell E7440 UEFI 0xFF bug..."
# De Dell E7440 vraagt soms om 'netboot.xyz.efi\xFF' (met een onzichtbaar teken)
# We testen of dit bestand bestaat of aangemaakt kan worden.
TFTP_MOUNT="/srv/tftp"
EFI_FILE="netboot.xyz.efi"
# Bash kan geen 0xFF in een variabele opslaan voor bestandsnamen, dus we
# gebruiken Python of printf om de exacte bytes te maken.
EFI_FILE_FF=$(printf "netboot.xyz.efi\xff")

info "Controleren of de TFTP-map ($TFTP_MOUNT) is gekoppeld..."
if [[ -d "$TFTP_MOUNT" ]]; then
    ok "TFTP-map bestaat."
    
    if [[ -f "$TFTP_MOUNT/$EFI_FILE" ]]; then
        ok "Standaard bestand '$EFI_FILE' bestaat in $TFTP_MOUNT."
    else
        fail "Standaard bestand '$EFI_FILE' ontbreekt in $TFTP_MOUNT."
    fi

    # Test op het 0xFF bestand
    if [[ -f "$TFTP_MOUNT/$EFI_FILE_FF" ]]; then
        ok "Workaround bestand met 0xFF teken bestaat al!"
    else
        warn "Workaround bestand met 0xFF teken ontbreekt."
        info "  Dit is waarschijnlijk de oorzaak van de PXE-E23 fout op de Dell E7440."
        info "  Oplossing: maak een kopie met het 0xFF teken aan:"
        info "    sudo cp $TFTP_MOUNT/$EFI_FILE \"$TFTP_MOUNT/$EFI_FILE_FF\""
        info "  Of gebruik het Python commando uit de handleiding."
    fi
else
    fail "TFTP-map $TFTP_MOUNT bestaat niet. Controleer de Quadlet configuratie."
fi
echo

# -----------------------------------------------------------------------------
# STAP 7: DNSMASQ CONFIGURATIE
# -----------------------------------------------------------------------------
info "STAP 7: Controleren van dnsmasq PXE-configuratie..."
DNSMASQ_CONF="/etc/dnsmasq.d/netboot.conf"
if [[ -f "$DNSMASQ_CONF" ]]; then
    ok "Configuratiebestand $DNSMASQ_CONF bestaat."
    
    if grep -q "pxe-service=X86-64_EFI" "$DNSMASQ_CONF"; then
        ok "UEFI PXE-service is geconfigureerd."
        grep "pxe-service=X86-64_EFI" "$DNSMASQ_CONF" | sed 's/^/       /'
    else
        fail "UEFI PXE-service ontbreekt in dnsmasq configuratie."
    fi

    if grep -q "interface=" "$DNSMASQ_CONF"; then
        IFACE_CONF=$(grep "interface=" "$DNSMASQ_CONF" | cut -d= -f2)
        if ip link show "$IFACE_CONF" &>/dev/null; then
            ok "Geconfigureerde interface '$IFACE_CONF' bestaat."
        else
            fail "Geconfigureerde interface '$IFACE_CONF' bestaat NIET."
        fi
    else
        warn "Geen 'interface=' regel gevonden in dnsmasq configuratie."
    fi
else
    fail "Configuratiebestand $DNSMASQ_CONF ontbreekt."
fi
echo

# -----------------------------------------------------------------------------
# STAP 8: LIVE LOG MEELUISTEREN (OPTIONEEL)
# -----------------------------------------------------------------------------
info "STAP 8: Live logs van de netbootxyz container..."
echo "  (Druk op Ctrl+C om te stoppen met meekijken)"
echo "  Start nu de Dell E7440 op om te zien wat er gebeurt..."
echo "------------------------------------------------------------"
# Toon de laatste 10 regels en volg dan de logs (timeout na 60 seconden om script niet oneindig te laten hangen)
timeout 60 podman logs -f --tail 10 netbootxyz || true
echo "------------------------------------------------------------"
echo

info "Diagnose voltooid."
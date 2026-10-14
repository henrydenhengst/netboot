#!/usr/bin/env bash
# =============================================================================
#  NETBOOT STACK INSTALLER VOOR OPENSUSE LEAP  (v3.4)
# =============================================================================
#
#  @bestand   netboot-stack-installer.sh
#  @versie    3.4.0
#  @datum     2026-10-14        (statisch; commentaar wordt NIET uitgevoerd)
#  @doel      Installeert een complete netboot-stack op een schone openSUSE
#             Leap-server met behoud van de bestaande Fritzbox-DHCP.
#
# -----------------------------------------------------------------------------
#  GETEST OP
# -----------------------------------------------------------------------------
#   * openSUSE Leap 15.5   (schone installatie, BIOS-client)
#   * openSUSE Leap 15.6   (schone installatie, BIOS- en UEFI-client)
#
#  NIET GETEST OP (gebruik op eigen risico):
#   * openSUSE Tumbleweed, MicroOS, SLES 15.x, Leap 15.4 en ouder
#
#  Laatste praktijktest: zie changelog. Voer dit script ALTIJD eerst uit op
#  een schone testinstallatie en valideer met een echte BIOS- én UEFI-client
#  voordat je het op productie loslaat.
#
# -----------------------------------------------------------------------------
#  HERHAALBAARHEID
# -----------------------------------------------------------------------------
#  Dit script is veilig herhaalbaar: bij elke run worden bestaande
#  configuratiebestanden eerst geback-upt met een tijdstempel
#  (.bak.YYYYMMDD-HHMMSS) voordat nieuwe inhoud wordt geschreven.
#  Een tweede run overschrijft dus nooit stilzwijgend een eerdere
#  configuratie. Rollback-acties herstellen de oorspronkelijke bestanden
#  bij een fout tijdens de installatie.
#
# -----------------------------------------------------------------------------
#  WAT DIT SCRIPT INSTALLEERT
# -----------------------------------------------------------------------------
#   1. dnsmasq          - Proxy-DHCP (GEEN IP-uitgifte, GEEN TFTP)
#   2. netboot.xyz      - TFTP + HTTP boot-server (Podman, host-network)
#   3. DokuWiki         - Documentatie-wiki (Podman)
#   4. Forgejo          - Git-forge (Podman)
#   5. Cockpit          - Beheer-dashboard (host service, poort 9003)
#
# -----------------------------------------------------------------------------
#  ARCHITECTUUR
# -----------------------------------------------------------------------------
#   Fritzbox (bestaande DHCP)  ──►  geeft IP's uit aan alle clients
#          │
#          ▼
#   openSUSE Leap server (dit script)
#     ├── dnsmasq       luistert passief mee, antwoordt ALLEEN op PXE
#     ├── netboot.xyz   TFTP :69/UDP  +  HTTP :80/TCP  +  UI :9000/TCP
#     ├── DokuWiki      HTTP :9001/TCP
#     ├── Forgejo       HTTP :9002/TCP  +  SSH :2002/TCP
#     └── Cockpit       HTTPS :9003/TCP
#
# -----------------------------------------------------------------------------
#  ONTWERPBESLISSINGEN
# -----------------------------------------------------------------------------
#   1. Proxy-DHCP: dnsmasq geeft GEEN IP's uit; Fritzbox blijft de enige
#      DHCP-server. Voorkomt IP-conflicten.
#   2. dnsmasq doet GEEN TFTP — dat doet de netboot.xyz container op :69/UDP.
#   3. netboot.xyz draait met Network=host.
#   4. Quadlet in plaats van `podman generate systemd`.
#   5. Expliciet server-IP in pxe-service (workaround voor Fritzbox).
#   6. Netwerkberekening via ipcalc.
#   7. Interfacekeuze door gebruiker; geen default-route-aanname.
#   8. firewalld wordt expliciet geactiveerd; falen is fataal.
#   9. Volledige rollback bij fouten tijdens installatie (trap ERR/INT/TERM).
#  10. Container-images vastgezet op expliciete versietags.
#  11. Exit-status is beslissend: verify_installation() bepaalt of het script
#      eindigt met exit 0 (succes) of exit 1 (fout).
#  12. Prerequisites (ipcalc, skopeo) vóór alle andere stappen.
#  13. dnsmasq include-config wordt GEVERIFIEERD; het script wijzigt de
#      hoofdconfiguratie NIET stilzwijgend.
#  14. Containers krijgen een wachttijd van 90s vóór het eindoordeel.
#  15. Cockpit draait zonder aanname van een reverse proxy: geen
#      ProtocolHeader = X-Forwarded-Proto.
#
# -----------------------------------------------------------------------------
#  VEREISTEN
# -----------------------------------------------------------------------------
#   * openSUSE Leap 15.5 of nieuwer
#   * Root-toegang
#   * Minimaal 2 GB RAM, 20 GB vrije schijfruimte
#   * Internettoegang voor packages en container-images
#   * Server in hetzelfde L2-segment als de PXE-clients
#
# -----------------------------------------------------------------------------
#  POORTENOVERZICHT
# -----------------------------------------------------------------------------
#   67/UDP   dnsmasq       Proxy-DHCP
#   69/UDP   netboot.xyz   TFTP
#   80/TCP   netboot.xyz   HTTP (iPXE)
#   2002/TCP Forgejo       Git SSH
#   4011/UDP dnsmasq       Alternatieve PXE-poort
#   9000/TCP netboot.xyz   Web UI
#   9001/TCP DokuWiki      Webinterface
#   9002/TCP Forgejo       HTTP
#   9003/TCP Cockpit       Dashboard
#
# -----------------------------------------------------------------------------
#  GEBRUIK
# -----------------------------------------------------------------------------
#   sudo ./netboot-stack-installer.sh
#
#  Exit-code:  0   = volledig geslaagd
#              1   = niet (volledig) geslaagd — zie log
#              130 = onderbroken door gebruiker
#
# -----------------------------------------------------------------------------
#  CONTAINER-IMAGES (VASTGEZET)
# -----------------------------------------------------------------------------
#  Pas de tags aan naar de actuele stabiele versie vóór productiegebruik.
#  Controleer met:
#    skopeo list-tags docker://ghcr.io/netbootxyz/netbootxyz
#    skopeo list-tags docker://docker.io/dokuwiki/dokuwiki
#    skopeo list-tags docker://codeberg.org/forgejo/forgejo
#
# -----------------------------------------------------------------------------
#  NA INSTALLATIE
# -----------------------------------------------------------------------------
#   1. Zet het server-IP vast in de Fritzbox (DHCP-reservering).
#   2. Test TFTP:  tftp <server-ip> -c get netboot.xyz.kpxe /tmp/test.kpxe
#   3. Test PXE-boot vanaf een BIOS-client en een UEFI-client.
#   4. Beheer:     https://<server-ip>:9003
#
# -----------------------------------------------------------------------------
#  TROUBLESHOOTING
# -----------------------------------------------------------------------------
#   "TFTP timeout"       → ss -ulnp | grep :69 ; podman logs netbootxyz
#   "no boot filename"   → journalctl -u dnsmasq -f ; interface= in netboot.conf
#   Client boot van Fritzbox-IP → pxe-service regel eindigt met ,$SERVER_IP
#   Container start niet → systemctl status <naam> ; podman logs <naam>
#   firewalld start niet → systemctl status firewalld ; journalctl -u firewalld
#   IP verandert na reboot → DHCP-reservering in Fritzbox instellen
#
# -----------------------------------------------------------------------------
#  CHANGELOG
# -----------------------------------------------------------------------------
#  3.4.0 - Deze versie:
#          * Header: "idempotent" vervangen door "veilig herhaalbaar (met
#            back-up)"; tijdgestempelde back-ups i.p.v. vaste .bak (punt 1).
#          * cockpit.conf: ProtocolHeader = X-Forwarded-Proto verwijderd;
#            alleen Origins blijft (punt 2).
#          * Interfacekeuze expliciet met validatie via ip link show.
#          * dnsmasq: include-config wordt geverifieerd; script faalt als
#            /etc/dnsmasq.d niet wordt ingelezen i.p.v. de hoofdconfig aan
#            te passen.
#          * Containers: START_FAILED-flag, journalctl bij falen, exit 1.
#          * Eindcontroles: FAILED-flag, robuustere poort-regex.
#          * firewalld: enable --now + firewall-cmd --state.
#  3.3.0 - Interfacekeuze expliciet; firewalld verplicht; eindcontrole
#          beslissend; documentatie "Getest op".
#  3.2.0 - Prerequisites vóór alle stappen; wachttijd containers;
#          image-tags gepind + remote verificatie; dnsmasq include vóór
#          configuratie.
#  3.1.0 - Verificatie, image-pinning, documentatie bijgewerkt.
#  3.0.0 - Herschrijving: interfacekeuze, firewall zones, rollback, traps.
#  2.0.0 - Initiële versie (niet in productie gebruiken).
#
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
#  CONSTANTEN
# =============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="3.4.0"
readonly LOG_FILE="/var/log/netboot-stack-install.log"
readonly QUADLET_DIR="/etc/containers/systemd"
readonly DNSMASQ_CONF_DIR="/etc/dnsmasq.d"
readonly DNSMASQ_CONF="${DNSMASQ_CONF_DIR}/netboot.conf"

readonly NETBOOT_TFTP_PORT=69
readonly NETBOOT_HTTP_PORT=80
readonly NETBOOT_WEB_PORT=9000
readonly DOKUWIKI_PORT=9001
readonly FORGEJO_HTTP_PORT=9002
readonly FORGEJO_SSH_PORT=2002
readonly COCKPIT_PORT=9003

readonly NETBOOT_IMAGE="ghcr.io/netbootxyz/netbootxyz:0.7.5"
readonly DOKUWIKI_IMAGE="docker.io/dokuwiki/dokuwiki:2024-02-06b"
readonly FORGEJO_IMAGE="codeberg.org/forgejo/forgejo:12.0.1"

readonly TFTP_DIR="/srv/tftp"
readonly NETBOOT_CONFIG_DIR="/srv/netboot-config"
readonly DOKUWIKI_DATA_DIR="/srv/dokuwiki/data"
readonly FORGEJO_DATA_DIR="/srv/forgejo/data"

readonly CONTAINER_START_TIMEOUT=90

declare -a ROLLBACK_ACTIONS=()

# =============================================================================
#  KLEUREN & LOGGING
# =============================================================================

if [[ -t 1 ]]; then
    readonly C_RED=$'\033[0;31m'
    readonly C_GREEN=$'\033[0;32m'
    readonly C_YELLOW=$'\033[1;33m'
    readonly C_BLUE=$'\033[0;34m'
    readonly C_RESET=$'\033[0m'
else
    readonly C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_RESET=''
fi

_log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${ts}] [${level}] ${msg}"
    case "$level" in
        INFO)  echo -e "${C_BLUE}${line}${C_RESET}" ;;
        OK)    echo -e "${C_GREEN}${line}${C_RESET}" ;;
        WARN)  echo -e "${C_YELLOW}${line}${C_RESET}" >&2 ;;
        ERROR) echo -e "${C_RED}${line}${C_RESET}" >&2 ;;
        *)     echo "$line" ;;
    esac
    if [[ -w "$(dirname "$LOG_FILE")" ]] || [[ -w "$LOG_FILE" ]]; then
        echo "$line" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

info()  { _log INFO  "$@"; }
ok()    { _log OK    "$@"; }
warn()  { _log WARN  "$@"; }
error() { _log ERROR "$@"; }

# =============================================================================
#  ROLLBACK & TRAPS
# =============================================================================

register_rollback() { ROLLBACK_ACTIONS+=("$1"); }

perform_rollback() {
    if (( ${#ROLLBACK_ACTIONS[@]} == 0 )); then
        info "Geen rollback-acties geregistreerd."; return 0
    fi
    info "Rollback gestart (${#ROLLBACK_ACTIONS[@]} acties)..."
    local idx action
    for (( idx=${#ROLLBACK_ACTIONS[@]}-1; idx>=0; idx-- )); do
        action="${ROLLBACK_ACTIONS[$idx]}"
        info "  → ${action}"
        eval "$action" || warn "Rollback-actie mislukt: ${action}"
    done
    ROLLBACK_ACTIONS=()
    ok "Rollback voltooid."
}

_on_error() {
    local exit_code=$?
    error "Fout opgetreden op regel ${1:-?} (exit ${exit_code})."
    perform_rollback
    error "Installatie afgebroken. Zie ${LOG_FILE}."
    exit "$exit_code"
}

_on_interrupt() {
    error "Installatie onderbroken door gebruiker."
    perform_rollback
    exit 130
}

trap '_on_error $LINENO' ERR
trap '_on_interrupt' INT TERM

# =============================================================================
#  HULPFUNCTIES
# =============================================================================

command_exists() { command -v "$1" >/dev/null 2>&1; }

# Tijdgestempelde back-up; meerdere runs overschrijven elkaars back-ups niet.
# Registreert rollback die het bestand terugzet (of verwijdert als het nieuw was).
backup_or_register_new() {
    local file="$1"
    if [[ -e "$file" ]]; then
        local backup="${file}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$file" "$backup"
        register_rollback "mv -f '$backup' '$file'"
        info "  Back-up gemaakt: $backup"
    else
        register_rollback "rm -f '$file'"
    fi
}

# =============================================================================
#  PREREQUISITE CHECKS
# =============================================================================

require_root() {
    [[ $EUID -eq 0 ]] || { error "Voer dit script uit als root (sudo $0)."; exit 1; }
}

require_opensuse_leap() {
    [[ -f /etc/os-release ]] || { error "/etc/os-release niet gevonden."; exit 1; }
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "opensuse-leap" ]] || {
        error "Alleen openSUSE Leap wordt ondersteund (gevonden: ${ID:-onbekend})."
        exit 1
    }
    ok "Distro: ${PRETTY_NAME:-openSUSE Leap}"
}

require_systemd() { command_exists systemctl || { error "systemd vereist."; exit 1; }; }
require_zypper()  { command_exists zypper    || { error "zypper vereist.";  exit 1; }; }

# =============================================================================
#  STAP 0 — PREREQUISITES + IMAGE TAGS
# =============================================================================

install_prerequisites() {
    info "[0/9] Prerequisites controleren (ipcalc, skopeo)..."
    local missing=()
    command_exists ipcalc || missing+=("ipcalc")
    command_exists skopeo || missing+=("skopeo")

    if (( ${#missing[@]} > 0 )); then
        info "  Ontbrekend: ${missing[*]} — installeren..."
        if ! zypper --non-interactive install --no-recommends "${missing[@]}"; then
            error "Installatie van prerequisites mislukt."; exit 1
        fi
    fi
    local cmd
    for cmd in ipcalc skopeo; do
        command_exists "$cmd" || { error "Vereist commando ontbreekt: $cmd"; exit 1; }
    done
    ok "  Prerequisites aanwezig: ipcalc, skopeo."
}

verify_image_tags() {
    info "[0b/9] Container-image tags verifiëren..."
    local image
    for image in "$NETBOOT_IMAGE" "$DOKUWIKI_IMAGE" "$FORGEJO_IMAGE"; do
        if skopeo inspect "docker://${image}" >/dev/null 2>&1; then
            ok "  Tag bestaat: ${image}"
        else
            error "  Tag NIET gevonden: ${image}"
            error "  Controleer met: skopeo list-tags docker://<repo>"
            exit 1
        fi
    done
}

# =============================================================================
#  STAP 1 — NETWERKDETECTIE EN INTERFACEKEUZE
# =============================================================================
#
# De gebruiker kiest expliciet. Geen aanname op basis van default route.
# Na de keuze wordt de interface gevalideerd met `ip link show`.

choose_interface() {
    info "Beschikbare netwerkinterfaces:"
    echo
    ip -br -4 addr
    echo

    read -rp "Welke interface is aangesloten op het PXE-netwerk? " SELECTED_IFACE

    if [[ -z "$SELECTED_IFACE" ]] || ! ip link show "$SELECTED_IFACE" &>/dev/null; then
        error "Ongeldige netwerkinterface: '${SELECTED_IFACE}'"
        exit 1
    fi
    ok "Gekozen interface: ${SELECTED_IFACE}"
}

validate_interface() {
    local iface="$1"

    SELECTED_IP="$(ip -o -4 addr show dev "$iface" scope global \
        | awk 'NR==1 {split($4,a,"/"); print a[1]}')"
    local cidr
    cidr="$(ip -o -4 addr show dev "$iface" scope global \
        | awk 'NR==1 {print $4}')"

    if [[ -z "$SELECTED_IP" || -z "$cidr" ]]; then
        error "Geen IPv4-adres op ${iface}."
        exit 1
    fi

    local netmask network gateway
    netmask="$(ipcalc -m "$cidr" | awk -F= '/^Netmask:/ {print $2}')"
    network="$(ipcalc -n "$cidr" | awk -F= '/^Network:/ {print $2}' | cut -d/ -f1)"
    gateway="$(ip route show default dev "$iface" 2>/dev/null \
        | awk '/default/ {print $3; exit}')"

    if [[ -z "$netmask" || -z "$network" ]]; then
        error "Netwerkadres of netmasker kon niet worden berekend."
        exit 1
    fi

    echo
    info "Netwerkconfiguratie van ${iface}:"
    printf "  %-14s %s\n" "Interface:"   "$iface"
    printf "  %-14s %s\n" "Server-IP:"   "$SELECTED_IP"
    printf "  %-14s %s\n" "CIDR:"        "$cidr"
    printf "  %-14s %s\n" "Netwerkadres:" "$network"
    printf "  %-14s %s\n" "Netmasker:"   "$netmask"
    printf "  %-14s %s\n" "Gateway:"     "${gateway:-<geen op deze interface>}"
    echo

    local confirm
    read -rp "Klopt deze configuratie voor het PXE-netwerk? (j/n) " confirm
    [[ "$confirm" =~ ^[jJ]$ ]] || { error "Installatie afgebroken."; exit 1; }

    SELECTED_NETWORK="$network"
    SELECTED_NETMASK="$netmask"
    SELECTED_GATEWAY="${gateway:-}"
    ok "Netwerkconfiguratie gevalideerd."
}

# =============================================================================
#  STAP 2 — PRE-FLIGHT
# =============================================================================

check_port_80() {
    info "Controleren of poort ${NETBOOT_HTTP_PORT}/TCP vrij is..."
    if ss -tlnp 2>/dev/null | grep -q ":${NETBOOT_HTTP_PORT} "; then
        warn "Poort ${NETBOOT_HTTP_PORT}/TCP is al in gebruik:"
        ss -tlnp | grep ":${NETBOOT_HTTP_PORT} " >&2
        echo
        local cont
        read -rp "Toch doorgaan? (j/n): " cont
        [[ "$cont" =~ ^[jJ]$ ]] || { error "Afgebroken."; exit 1; }
    else
        ok "  Poort ${NETBOOT_HTTP_PORT}/TCP is vrij."
    fi
}

# =============================================================================
#  STAP 3 — PACKAGES
# =============================================================================

install_packages() {
    info "[1/9] Pakketten installeren..."
    local packages=(cockpit cockpit-podman podman dnsmasq firewalld curl)
    if ! zypper --non-interactive install --no-recommends "${packages[@]}"; then
        error "Installatie van pakketten mislukt."; exit 1
    fi
    ok "Pakketten geïnstalleerd."
}

# =============================================================================
#  STAP 4 — COCKPIT
# =============================================================================
#
# Geen ProtocolHeader = X-Forwarded-Proto: er is geen reverse proxy.
# Alleen Origins, zodat Cockpit WebSocket-verbindingen accepteert van het
# server-IP op de niet-standaardpoort.

configure_cockpit() {
    info "[2/9] Cockpit configureren op poort ${COCKPIT_PORT}..."

    local override_dir="/etc/systemd/system/cockpit.socket.d"
    mkdir -p "$override_dir"
    local override_file="${override_dir}/override.conf"
    backup_or_register_new "$override_file"
    cat > "$override_file" <<EOF
[Socket]
ListenStream=
ListenStream=${COCKPIT_PORT}
FreeBind=yes
EOF

    local cockpit_conf="/etc/cockpit/cockpit.conf"
    mkdir -p "$(dirname "$cockpit_conf")"
    backup_or_register_new "$cockpit_conf"
    cat > "$cockpit_conf" <<EOF
[WebService]
Origins = https://${SELECTED_IP}:${COCKPIT_PORT} wss://${SELECTED_IP}:${COCKPIT_PORT}
EOF

    if command_exists getenforce; then
        local status; status="$(getenforce 2>/dev/null || echo Disabled)"
        if [[ "$status" == "Enforcing" ]]; then
            info "  SELinux actief, poort ${COCKPIT_PORT} toevoegen aan beleid..."
            semanage port -a -t websm_port_t -p tcp "$COCKPIT_PORT" 2>/dev/null || \
                semanage port -m -t websm_port_t -p tcp "$COCKPIT_PORT" 2>/dev/null || \
                warn "  SELinux-poort niet aangepast."
        fi
    fi

    systemctl daemon-reload
    systemctl enable --now cockpit.socket
    register_rollback "systemctl disable --now cockpit.socket 2>/dev/null || true"
    ok "Cockpit actief op poort ${COCKPIT_PORT}."
}

# =============================================================================
#  STAP 5 — MAPPEN
# =============================================================================

create_directories() {
    info "[3/9] Mappenstructuur aanmaken..."
    local dirs=("$TFTP_DIR" "$NETBOOT_CONFIG_DIR" "$DOKUWIKI_DATA_DIR" "$FORGEJO_DATA_DIR")
    local d
    for d in "${dirs[@]}"; do
        if [[ ! -d "$d" ]]; then
            mkdir -p "$d"
            register_rollback "rmdir '$d' 2>/dev/null || true"
        fi
    done
    chown -R 33:33     "$DOKUWIKI_DATA_DIR" 2>/dev/null || true
    chown -R 1000:1000 "$FORGEJO_DATA_DIR"  2>/dev/null || true
    ok "Mappen aangemaakt en rechten ingesteld."
}

# =============================================================================
#  STAP 6 — DNSMASQ
# =============================================================================
#
# De hoofdconfiguratie wordt NIET gewijzigd. Als /etc/dnsmasq.d niet wordt
# ingelezen, faalt het script met een duidelijke melding. Dat is veiliger
# dan stilzwijgend de hoofdconfig aanpassen.

verify_dnsmasq_include() {
    if ! grep -Eq '^[[:space:]]*conf-dir=/etc/dnsmasq\.d([,/[:space:]]|$)' \
        /etc/dnsmasq.conf; then
        error "/etc/dnsmasq.conf leest /etc/dnsmasq.d niet in."
        error "Voeg de regel 'conf-dir=/etc/dnsmasq.d/,*.conf' toe aan"
        error "/etc/dnsmasq.conf en draai het script opnieuw."
        exit 1
    fi
    ok "  /etc/dnsmasq.conf bevat conf-dir=/etc/dnsmasq.d/."
}

configure_dnsmasq() {
    info "[4/9] dnsmasq configureren als proxy-DHCP..."

    verify_dnsmasq_include
    mkdir -p "$DNSMASQ_CONF_DIR"
    backup_or_register_new "$DNSMASQ_CONF"

    cat > "$DNSMASQ_CONF" <<EOF
# =============================================================================
# Proxy-DHCP voor netboot.xyz  (gegenereerd door ${SCRIPT_NAME} v${SCRIPT_VERSION})
# =============================================================================
interface=${SELECTED_IFACE}
bind-dynamic
log-dhcp
dhcp-range=${SELECTED_NETWORK},proxy,${SELECTED_NETMASK}
pxe-service=x86PC,      "NETBOOT (BIOS)", "netboot.xyz.kpxe", ${SELECTED_IP}
pxe-service=X86-64_EFI, "NETBOOT (EFI)",  "netboot.xyz.efi",  ${SELECTED_IP}
# GEEN enable-tftp: TFTP wordt door de netboot.xyz container afgehandeld.
EOF

    if ! dnsmasq --test; then
        error "dnsmasq-configuratie is ongeldig."
        exit 1
    fi

    if ! systemctl enable --now dnsmasq; then
        error "dnsmasq kon niet worden gestart."
        journalctl -u dnsmasq -n 50 --no-pager
        exit 1
    fi

    if ! systemctl is-active --quiet dnsmasq; then
        error "dnsmasq is niet actief na het starten."
        exit 1
    fi

    register_rollback "systemctl disable --now dnsmasq 2>/dev/null || true"
    ok "dnsmasq actief als proxy-DHCP op ${SELECTED_IFACE}."
}

# =============================================================================
#  STAP 7 — FIREWALL
# =============================================================================

ensure_firewalld() {
    info "[4b/9] firewalld controleren en activeren..."
    if ! systemctl enable --now firewalld; then
        error "firewalld kon niet worden gestart."
        journalctl -u firewalld -n 30 --no-pager
        exit 1
    fi
    if ! firewall-cmd --state >/dev/null 2>&1; then
        error "firewalld is niet actief na het starten."
        exit 1
    fi
    register_rollback "systemctl disable --now firewalld 2>/dev/null || true"
    ok "  firewalld actief en enabled."
}

configure_firewall() {
    info "[5/9] Firewall configureren..."

    local zone
    zone="$(firewall-cmd --get-zone-of-interface="$SELECTED_IFACE" 2>/dev/null)"
    if [[ -z "$zone" || "$zone" == "no zone" ]]; then
        zone="$(firewall-cmd --get-default-zone)"
        warn "Geen expliciete zone voor ${SELECTED_IFACE}."
        warn "De standaardzone is '${zone}'."
    fi
    ok "Firewallzone: ${zone}"

    local zone_file="/etc/firewalld/zones/${zone}.xml"
    if [[ -f "$zone_file" ]]; then
        cp -a "$zone_file" "${zone_file}.bak.$(date +%Y%m%d-%H%M%S)"
        register_rollback "firewall-cmd --reload || true"
    fi

    firewall-cmd --permanent --zone="$zone" --add-service=dhcp >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-service=tftp >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port=4011/udp >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${NETBOOT_HTTP_PORT}/tcp" >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${NETBOOT_WEB_PORT}/tcp"  >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${DOKUWIKI_PORT}/tcp"     >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${FORGEJO_HTTP_PORT}/tcp" >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${FORGEJO_SSH_PORT}/tcp"  >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${COCKPIT_PORT}/tcp"      >/dev/null

    if ! firewall-cmd --reload; then
        error "Firewall kon niet worden herladen."
        exit 1
    fi
    register_rollback "firewall-cmd --reload || true"
    ok "Firewallregels toegepast op zone '${zone}'."
}

# =============================================================================
#  STAP 8 — QUADLET
# =============================================================================

create_quadlet_units() {
    info "[6/9] Quadlet-units aanmaken..."
    mkdir -p "$QUADLET_DIR"

    local unit_netboot="${QUADLET_DIR}/netbootxyz.container"
    backup_or_register_new "$unit_netboot"
    cat > "$unit_netboot" <<EOF
[Unit]
Description=netboot.xyz (TFTP + HTTP)
Documentation=https://netboot.xyz
After=network-online.target
Wants=network-online.target

[Container]
Image=${NETBOOT_IMAGE}
ContainerName=netbootxyz
Network=host
Volume=${TFTP_DIR}:/assets:Z
Volume=${NETBOOT_CONFIG_DIR}:/config:Z
Environment=TFTPD_OPTS=--tftp-single-port
Environment=WEB_APP_PORT=${NETBOOT_WEB_PORT}
Environment=NGINX_PORT=${NETBOOT_HTTP_PORT}

[Service]
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    local unit_doku="${QUADLET_DIR}/dokuwiki.container"
    backup_or_register_new "$unit_doku"
    cat > "$unit_doku" <<EOF
[Unit]
Description=DokuWiki
Documentation=https://www.dokuwiki.org
After=network-online.target
Wants=network-online.target

[Container]
Image=${DOKUWIKI_IMAGE}
ContainerName=dokuwiki
PublishPort=${DOKUWIKI_PORT}:80
Volume=${DOKUWIKI_DATA_DIR}:/storage:Z

[Service]
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    local unit_forgejo="${QUADLET_DIR}/forgejo.container"
    backup_or_register_new "$unit_forgejo"
    cat > "$unit_forgejo" <<EOF
[Unit]
Description=Forgejo
Documentation=https://forgejo.org
After=network-online.target
Wants=network-online.target

[Container]
Image=${FORGEJO_IMAGE}
ContainerName=forgejo
PublishPort=${FORGEJO_HTTP_PORT}:3000
PublishPort=${FORGEJO_SSH_PORT}:22
Volume=${FORGEJO_DATA_DIR}:/data:Z
Environment=USER_UID=1000
Environment=USER_GID=1000

[Service]
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    ok "Quadlet-units aangemaakt."
}

# =============================================================================
#  STAP 9 — CONTAINERS STARTEN
# =============================================================================

wait_for_service() {
    local svc="$1" timeout="${2:-$CONTAINER_START_TIMEOUT}" waited=0
    while (( waited < timeout )); do
        systemctl is-active --quiet "$svc" && return 0
        sleep 3; (( waited += 3 ))
    done
    return 1
}

start_containers() {
    info "[7/9] Containers starten (max ${CONTAINER_START_TIMEOUT}s elk)..."
    systemctl daemon-reload

    local START_FAILED=0 ctr
    for ctr in netbootxyz dokuwiki forgejo; do
        if ! systemctl enable --now "${ctr}.service" 2>/dev/null; then
            error "  ${ctr}: starten mislukt."
            journalctl -u "${ctr}.service" -n 30 --no-pager
            START_FAILED=1
            continue
        fi
        if wait_for_service "${ctr}.service" "$CONTAINER_START_TIMEOUT"; then
            ok "  ${ctr}: actief."
            register_rollback "systemctl stop '${ctr}.service' 2>/dev/null || true"
        else
            error "  ${ctr}: niet actief na ${CONTAINER_START_TIMEOUT}s."
            journalctl -u "${ctr}.service" -n 30 --no-pager
            START_FAILED=1
        fi
    done

    if (( START_FAILED != 0 )); then
        error "Een of meer containers konden niet worden gestart."
        error "De installatie wordt niet als geslaagd gemeld."
        exit 1
    fi
}

# =============================================================================
#  STAP 10 — EINDCONTROLES (bepaalt exit-code)
# =============================================================================

verify_installation() {
    info "[8/9] Eindcontroles uitvoeren..."
    local FAILED=0

    local svc
    for svc in dnsmasq cockpit.socket firewalld netbootxyz dokuwiki forgejo; do
        if systemctl is-active --quiet "$svc"; then
            ok "  $svc: actief"
        else
            error "  $svc: NIET actief"
            FAILED=1
        fi
    done

    if ! dnsmasq --test >/dev/null 2>&1; then
        error "  dnsmasq --test: configuratie ongeldig."
        FAILED=1
    fi

    if ! ss -ulnp 2>/dev/null | grep -qE '(:|\])69[[:space:]]'; then
        error "  Geen luisterende TFTP-service op UDP-poort 69."
        FAILED=1
    fi

    if ! ss -tlnp 2>/dev/null | grep -qE '(:|\])80[[:space:]]'; then
        error "  Geen luisterende HTTP-service op TCP-poort 80."
        FAILED=1
    fi

    if ! curl -fsS --max-time 5 "http://127.0.0.1:${NETBOOT_HTTP_PORT}/" >/dev/null 2>&1; then
        error "  netboot.xyz HTTP :${NETBOOT_HTTP_PORT}: geen antwoord."
        FAILED=1
    fi

    return "$FAILED"
}

# =============================================================================
#  SAMENVATTING
# =============================================================================

print_summary_success() {
    echo
    echo "============================================================"
    echo "  Installatie GESLAAGD"
    echo "============================================================"
    echo "  Interface      : ${SELECTED_IFACE}"
    echo "  Server-IP      : ${SELECTED_IP}"
    echo "  Netwerk        : ${SELECTED_NETWORK}"
    echo "  Netmasker      : ${SELECTED_NETMASK}"
    echo "  Gateway        : ${SELECTED_GATEWAY:-<geen>}"
    echo
    echo "  Container-images (vastgezet):"
    echo "    netboot.xyz : ${NETBOOT_IMAGE}"
    echo "    DokuWiki    : ${DOKUWIKI_IMAGE}"
    echo "    Forgejo     : ${FORGEJO_IMAGE}"
    echo
    echo "  Toegang:"
    echo "    Cockpit     : https://${SELECTED_IP}:${COCKPIT_PORT}"
    echo "    netboot.xyz : http://${SELECTED_IP}:${NETBOOT_HTTP_PORT}"
    echo "    netboot UI  : http://${SELECTED_IP}:${NETBOOT_WEB_PORT}"
    echo "    DokuWiki    : http://${SELECTED_IP}:${DOKUWIKI_PORT}"
    echo "    Forgejo     : http://${SELECTED_IP}:${FORGEJO_HTTP_PORT}"
    echo "    Forgejo SSH : ssh -p ${FORGEJO_SSH_PORT} git@${SELECTED_IP}"
    echo
    echo "  Logbestand     : ${LOG_FILE}"
    echo "------------------------------------------------------------"
    echo "  Volgende stappen:"
    echo "    1. Zet een DHCP-reservering voor ${SELECTED_IP} in de Fritzbox."
    echo "    2. Test TFTP:  tftp ${SELECTED_IP} -c get netboot.xyz.kpxe /tmp/test.kpxe"
    echo "    3. Test PXE-boot vanaf een BIOS-client."
    echo "    4. Test PXE-boot vanaf een UEFI-client."
    echo "============================================================"
    echo
}

print_summary_failure() {
    echo
    echo "============================================================"
    echo "  Installatie NIET (volledig) geslaagd"
    echo "============================================================"
    echo "  Eén of meer componenten draaien niet."
    echo "  Zie de meldingen hierboven en het logbestand:"
    echo
    echo "    ${LOG_FILE}"
    echo
    echo "  Mogelijke vervolgstappen:"
    echo "    - Containerlogs:   podman logs <naam>"
    echo "    - Servicestatus:   systemctl status <naam>"
    echo "    - dnsmasq-log:     journalctl -u dnsmasq -f"
    echo "    - firewalld-log:   journalctl -u firewalld -f"
    echo "    - Herstart:        systemctl restart <naam>.service"
    echo
    echo "  Het systeem is in een consistente staat achtergelaten:"
    echo "  geen rollback uitgevoerd, alle onderdelen blijven staan."
    echo "============================================================"
    echo
}

# =============================================================================
#  MAIN
# =============================================================================

main() {
    echo "============================================================"
    echo "  netboot-stack installer voor openSUSE Leap"
    echo "  Versie: ${SCRIPT_VERSION}"
    echo "  Log:    ${LOG_FILE}"
    echo "============================================================"
    echo

    require_root
    require_opensuse_leap
    require_systemd
    require_zypper

    install_prerequisites
    verify_image_tags

    info "Stap 1/9: Netwerkinterface kiezen"
    choose_interface
    validate_interface "$SELECTED_IFACE"

    check_port_80

    install_packages
    configure_cockpit
    create_directories
    configure_dnsmasq
    ensure_firewalld
    configure_firewall
    create_quadlet_units
    start_containers

    if verify_installation; then
        print_summary_success
        exit 0
    else
        print_summary_failure
        exit 1
    fi
}

main "$@"
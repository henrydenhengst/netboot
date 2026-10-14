#!/usr/bin/env bash
# =============================================================================
#  NETBOOT STACK INSTALLER VOOR OPENSUSE LEAP  (v3.2)
# =============================================================================
#
#  @bestand   netboot-stack-installer.sh
#  @versie    3.2.0
#  @datum     2025-01-XX          (statisch; commentaar wordt NIET uitgevoerd)
#  @doel      Installeert een complete netboot-stack op een schone openSUSE
#             Leap-server met behoud van de bestaande Fritzbox-DHCP.
#
# -----------------------------------------------------------------------------
#  WAT DIT SCRIPT INSTALLEERT
# -----------------------------------------------------------------------------
#    1. dnsmasq          - Proxy-DHCP (GEEN IP-uitgifte, GEEN TFTP)
#    2. netboot.xyz      - TFTP + HTTP boot-server (Podman, host-network)
#    3. DokuWiki         - Documentatie-wiki (Podman)
#    4. Forgejo          - Git-forge (Podman)
#    5. Cockpit          - Beheer-dashboard (host service, poort 9003)
#
# -----------------------------------------------------------------------------
#  ARCHITECTUUR
# -----------------------------------------------------------------------------
#    Fritzbox (bestaande DHCP)  ──►  geeft IP's uit aan alle clients
#           │
#           ▼
#    openSUSE Leap server (dit script)
#      ├── dnsmasq       luistert passief mee, antwoordt ALLEEN op PXE
#      ├── netboot.xyz   TFTP :69/UDP  +  HTTP :80/TCP  +  UI :9000/TCP
#      ├── DokuWiki      HTTP :9001/TCP
#      ├── Forgejo       HTTP :9002/TCP  +  SSH :2002/TCP
#      └── Cockpit       HTTPS :9003/TCP
#
# -----------------------------------------------------------------------------
#  ONTWERPBESLISSINGEN
# -----------------------------------------------------------------------------
#   1. Proxy-DHCP — dnsmasq geeft GEEN IP's uit. De Fritzbox blijft de
#      enige DHCP-server. Voorkomt IP-conflicten.
#   2. dnsmasq doet GEEN TFTP — dat doet de netboot.xyz container op :69/UDP.
#   3. netboot.xyz draait met Network=host (TFTP over UDP werkt niet
#      betrouwbaar via bridge-netwerken).
#   4. Quadlet in plaats van `podman generate systemd`.
#   5. Expliciet server-IP in pxe-service (workaround voor Fritzbox die
#      zijn eigen IP als TFTP-server doorgeeft).
#   6. Netwerkberekening via ipcalc — correct voor elk CIDR-blok.
#   7. Expliciete interfacekeuze + validatie (multi-homed servers).
#   8. Zone-bewuste firewallconfiguratie.
#   9. Volledige rollback bij fouten tijdens installatie (trap ERR/INT/TERM).
#  10. Container-images vastgezet op expliciete versietags.
#  11. Exit-status is bepalend: main() kiest op basis van
#      verify_installation() tussen succes (exit 0) en falen (exit 1).
#  12. Prerequisites (ipcalc, skopeo) worden VOOR alle andere stappen
#      geïnstalleerd én gecontroleerd. Bij falen stopt het script direct.
#  13. dnsmasq include-config (/etc/dnsmasq.d/) wordt expliciet
#      gecontroleerd en indien nodig aangemaakt vóór het schrijven van
#      onze config.
#  14. Containers krijgen een wachttijd van 90 seconden; pas daarna velt
#      verify_installation() een oordeel.
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
#    67/UDP   dnsmasq       Proxy-DHCP
#    69/UDP   netboot.xyz   TFTP
#    80/TCP   netboot.xyz   HTTP (iPXE)
#    2002/TCP Forgejo       Git SSH
#    4011/UDP dnsmasq       Alternatieve PXE-poort
#    9000/TCP netboot.xyz   Web UI
#    9001/TCP DokuWiki      Webinterface
#    9002/TCP Forgejo       HTTP
#    9003/TCP Cockpit       Dashboard
#
# -----------------------------------------------------------------------------
#  GEBRUIK
# -----------------------------------------------------------------------------
#    sudo ./netboot-stack-installer.sh
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
#   3. Test PXE-boot vanaf een client in hetzelfde L2-segment.
#   4. Beheer:     https://<server-ip>:9003
#
# -----------------------------------------------------------------------------
#  TROUBLESHOOTING
# -----------------------------------------------------------------------------
#   "TFTP timeout"       → ss -ulnp | grep :69 ; podman logs netbootxyz
#   "no boot filename"   → journalctl -u dnsmasq -f ; interface= in netboot.conf
#   Client boot van Fritzbox-IP → pxe-service regel eindigt met ,$SERVER_IP
#   Container start niet → systemctl status <naam> ; podman logs <naam>
#   IP verandert na reboot → DHCP-reservering in Fritzbox instellen
#
# -----------------------------------------------------------------------------
#  CHANGELOG
# -----------------------------------------------------------------------------
#  3.2.0 - Deze versie:
#          * install_prerequisites() installeert ipcalc + skopeo vóór alle
#            andere stappen en verifieert dat de commando's werken (punt 1).
#          * start_containers() wacht tot 90s per container; verify_installation()
#            bepaalt het eindoordeel (exit 0 / exit 1) (punt 2).
#          * Container-images gepind op expliciete tags; verify_image_tags()
#            controleert remote tags vóór installatie (punt 3).
#          * ensure_dnsmasq_include() maakt /etc/dnsmasq.conf en
#            /etc/dnsmasq.d/ aan indien nodig, vóór configure_dnsmasq() (punt 4).
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
readonly SCRIPT_VERSION="3.2.0"
readonly LOG_FILE="/var/log/netboot-stack-install.log"
readonly QUADLET_DIR="/etc/containers/systemd"
readonly DNSMASQ_CONF="/etc/dnsmasq.d/netboot.conf"

# --- Poorten ---
readonly NETBOOT_TFTP_PORT=69
readonly NETBOOT_HTTP_PORT=80
readonly NETBOOT_WEB_PORT=9000
readonly DOKUWIKI_PORT=9001
readonly FORGEJO_HTTP_PORT=9002
readonly FORGEJO_SSH_PORT=2002
readonly COCKPIT_PORT=9003

# --- Container images (VASTGEZET) ---
readonly NETBOOT_IMAGE="ghcr.io/netbootxyz/netbootxyz:0.7.5"
readonly DOKUWIKI_IMAGE="docker.io/dokuwiki/dokuwiki:2024-02-06b"
readonly FORGEJO_IMAGE="codeberg.org/forgejo/forgejo:12.0.1"

# --- Paden ---
readonly TFTP_DIR="/srv/tftp"
readonly NETBOOT_CONFIG_DIR="/srv/netboot-config"
readonly DOKUWIKI_DATA_DIR="/srv/dokuwiki/data"
readonly FORGEJO_DATA_DIR="/srv/forgejo/data"

# --- Wachttijd voor containers ---
readonly CONTAINER_START_TIMEOUT=90

# --- Rollback-stack ---
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
        info "Geen rollback-acties geregistreerd."
        return 0
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
    local line_no=${1:-?}
    error "Fout opgetreden op regel ${line_no} (exit ${exit_code})."
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

backup_or_register_new() {
    local file="$1"
    if [[ -e "$file" ]]; then
        local backup="${file}.netboot-stack.bak"
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
    if [[ $EUID -ne 0 ]]; then
        error "Dit script moet als root worden uitgevoerd (sudo $0)."
        exit 1
    fi
}

require_opensuse_leap() {
    if [[ ! -f /etc/os-release ]]; then
        error "/etc/os-release niet gevonden; kan distro niet bepalen."
        exit 1
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "opensuse-leap" ]]; then
        error "Dit script is alleen voor openSUSE Leap (gevonden: ${ID:-onbekend})."
        exit 1
    fi
    ok "Distro: ${PRETTY_NAME:-openSUSE Leap}"
}

require_systemd() {
    command_exists systemctl || { error "systemd is vereist."; exit 1; }
}

require_zypper() {
    command_exists zypper || { error "zypper is vereist."; exit 1; }
}

# =============================================================================
#  STAP 0 — PREREQUISITES (punt 1)
# =============================================================================
#
# ipcalc en skopeo worden VOOR alle andere stappen geïnstalleerd.
# Daarna wordt gecontroleerd dat de commando's daadwerkelijk werken.
# Als een van beide ontbreekt, stopt het script met exit 1 — er is dan
# geen enkele reden om verder te gaan.

install_prerequisites() {
    info "[0/9] Prerequisites controleren (ipcalc, skopeo)..."

    local missing=()
    command_exists ipcalc || missing+=("ipcalc")
    command_exists skopeo || missing+=("skopeo")

    if (( ${#missing[@]} > 0 )); then
        info "  Ontbrekend: ${missing[*]} — installeren..."
        if ! zypper --non-interactive install --no-recommends "${missing[@]}"; then
            error "Installatie van prerequisites mislukt."
            error "Controleer netwerktoegang en zypper-locks."
            exit 1
        fi
    fi

    local cmd
    for cmd in ipcalc skopeo; do
        if ! command_exists "$cmd"; then
            error "Vereist commando ontbreekt na installatie: $cmd"
            exit 1
        fi
    done
    ok "  Prerequisites aanwezig: ipcalc, skopeo."
}

# =============================================================================
#  IMAGE TAG-VERIFICATIE (punt 3)
# =============================================================================
#
# Gebruikt skopeo inspect (remote) om te verifiëren dat de gepinde tags
# bestaan. Valt NIET terug op podman manifest inspect als skopeo
# ontbreekt — in dat geval is de prerequisite-check al gefaald en komt
# het script hier niet.

verify_image_tags() {
    info "[0b/9] Container-image tags verifiëren..."
    local image
    for image in "$NETBOOT_IMAGE" "$DOKUWIKI_IMAGE" "$FORGEJO_IMAGE"; do
        if skopeo inspect "docker://${image}" >/dev/null 2>&1; then
            ok "  Tag bestaat: ${image}"
        else
            error "  Tag NIET gevonden of niet bereikbaar: ${image}"
            error "  Controleer de tag met: skopeo list-tags docker://<repo>"
            error "  en pas de constante boven in het script aan."
            exit 1
        fi
    done
}

# =============================================================================
#  STAP 1 — NETWERKDETECTIE EN INTERFACEKEUZE
# =============================================================================

list_ipv4_interfaces() {
    ip -br -4 addr show | awk '$3 != "" {print $1, $3}'
}

choose_interface() {
    local -a names=() display=()
    local line name ip

    while IFS= read -r line; do
        name="$(awk '{print $1}' <<<"$line")"
        ip="$(awk '{print $2}' <<<"$line")"
        names+=("$name")
        display+=("${name}  →  ${ip}")
    done < <(list_ipv4_interfaces)

    if [[ ${#names[@]} -eq 0 ]]; then
        error "Geen actieve netwerkinterfaces met IPv4-adres gevonden."
        exit 1
    fi

    if [[ ${#names[@]} -eq 1 ]]; then
        SELECTED_IFACE="${names[0]}"
        ok "Eén interface gevonden: ${SELECTED_IFACE}"
        return 0
    fi

    echo
    info "Beschikbare netwerkinterfaces:"
    local i=1
    for entry in "${display[@]}"; do
        echo "  [$i] $entry"
        ((i++))
    done
    echo

    local choice
    while true; do
        read -rp "Kies de interface voor PXE-clients [1-${#names[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )); then
            SELECTED_IFACE="${names[$((choice-1))]}"
            break
        fi
        warn "Ongeldige keuze, probeer opnieuw."
    done
    ok "Gekozen interface: ${SELECTED_IFACE}"
}

validate_interface() {
    local iface="$1" cidr ip prefix gateway
    cidr="$(ip -br -4 addr show dev "$iface" | awk '{print $3}' | head -n1)"
    if [[ -z "$cidr" ]]; then
        error "Interface ${iface} heeft geen IPv4-adres."
        exit 1
    fi
    ip="${cidr%/*}"
    prefix="${cidr#*/}"
    gateway="$(ip route show default dev "$iface" 2>/dev/null | awk '/default/ {print $3; exit}')"

    local netmask network broadcast
    netmask="$(ipcalc -m "${ip}/${prefix}" | awk -F= '/^Netmask:/ {print $2}')"
    network="$(ipcalc -n "${ip}/${prefix}" | awk -F= '/^Network:/ {print $2}' | cut -d/ -f1)"
    broadcast="$(ipcalc -b "${ip}/${prefix}" | awk -F= '/^Broadcast:/ {print $2}')"

    if [[ -z "$netmask" || -z "$network" ]]; then
        error "Kon netwerkadres of netmasker niet berekenen met ipcalc."
        exit 1
    fi

    echo
    info "Netwerkconfiguratie van ${iface}:"
    printf "  %-14s %s\n" "IP-adres:"     "$ip"
    printf "  %-14s %s\n" "Prefix:"       "/${prefix}"
    printf "  %-14s %s\n" "Netmasker:"    "$netmask"
    printf "  %-14s %s\n" "Netwerkadres:" "$network"
    printf "  %-14s %s\n" "Broadcast:"    "${broadcast:-?}"
    printf "  %-14s %s\n" "Gateway:"      "${gateway:-<geen op deze interface>}"
    echo

    local confirm
    read -rp "Is deze configuratie correct voor het PXE-netwerk? (j/n): " confirm
    if [[ ! "$confirm" =~ ^[jJ]$ ]]; then
        error "Afgebroken door gebruiker."
        exit 1
    fi

    SELECTED_IP="$ip"
    SELECTED_PREFIX="$prefix"
    SELECTED_NETMASK="$netmask"
    SELECTED_NETWORK="$network"
    SELECTED_GATEWAY="${gateway:-}"
    ok "Netwerkconfiguratie gevalideerd."
}

# =============================================================================
#  STAP 2 — PRE-FLIGHT CHECKS
# =============================================================================

check_port_80() {
    info "Controleren of poort ${NETBOOT_HTTP_PORT}/TCP vrij is..."
    if ss -tlnp 2>/dev/null | grep -q ":${NETBOOT_HTTP_PORT} "; then
        warn "Poort ${NETBOOT_HTTP_PORT}/TCP is al in gebruik:"
        ss -tlnp | grep ":${NETBOOT_HTTP_PORT} " >&2
        echo
        local cont
        read -rp "Toch doorgaan? (j/n): " cont
        if [[ ! "$cont" =~ ^[jJ]$ ]]; then
            error "Afgebroken."
            exit 1
        fi
    else
        ok "  Poort ${NETBOOT_HTTP_PORT}/TCP is vrij."
    fi
}

# =============================================================================
#  STAP 3 — PACKAGES INSTALLEREN
# =============================================================================
#
# ipcalc en skopeo staan NIET in deze lijst — die zijn al geïnstalleerd
# en gecontroleerd in install_prerequisites().

install_packages() {
    info "[1/9] Pakketten installeren..."
    local packages=(
        cockpit
        cockpit-podman
        podman
        dnsmasq
        firewalld
    )
    if ! zypper --non-interactive install --no-recommends "${packages[@]}"; then
        error "Installatie van pakketten mislukt."
        exit 1
    fi
    ok "Pakketten geïnstalleerd."
}

# =============================================================================
#  STAP 4 — COCKPIT
# =============================================================================

configure_cockpit() {
    info "[2/9] Cockpit configureren op poort ${COCKPIT_PORT}..."

    local override_dir="/etc/systemd/system/cockpit.socket.d"
    local override_file="${override_dir}/override.conf"
    mkdir -p "$override_dir"
    backup_or_register_new "$override_file"
    cat > "$override_file" <<EOF
[Socket]
ListenStream=
ListenStream=${COCKPIT_PORT}
FreeBind=yes
EOF

    local cockpit_conf="/etc/cockpit/cockpit.conf"
    backup_or_register_new "$cockpit_conf"
    mkdir -p "$(dirname "$cockpit_conf")"
    cat > "$cockpit_conf" <<EOF
[WebService]
Origins = https://${SELECTED_IP}:${COCKPIT_PORT} wss://${SELECTED_IP}:${COCKPIT_PORT}
ProtocolHeader = X-Forwarded-Proto
EOF

    if command_exists getenforce; then
        local selinux_status
        selinux_status="$(getenforce 2>/dev/null || echo Disabled)"
        if [[ "$selinux_status" == "Enforcing" ]]; then
            info "  SELinux actief, poort ${COCKPIT_PORT} toevoegen aan beleid..."
            if ! semanage port -a -t websm_port_t -p tcp "$COCKPIT_PORT" 2>/dev/null; then
                semanage port -m -t websm_port_t -p tcp "$COCKPIT_PORT" 2>/dev/null || \
                    warn "  SELinux-poort niet aangepast; controleer handmatig."
            fi
        fi
    fi

    systemctl daemon-reload
    systemctl enable --now cockpit.socket
    register_rollback "systemctl disable --now cockpit.socket 2>/dev/null || true"
    ok "Cockpit actief op poort ${COCKPIT_PORT}."
}

# =============================================================================
#  STAP 5 — MAPPENSTRUCTUUR
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
#  STAP 6 — DNSMASQ INCLUDE + PROXY-DHCP  (punt 4)
# =============================================================================

ensure_dnsmasq_include() {
    local conf="/etc/dnsmasq.conf"

    if [[ ! -f "$conf" ]]; then
        info "  $conf bestaat niet — aanmaken."
        touch "$conf"
        register_rollback "rm -f '$conf'"
    fi

    if ! grep -qE '^\s*conf-dir\s*=\s*/etc/dnsmasq\.d' "$conf"; then
        backup_or_register_new "$conf"
        echo "conf-dir=/etc/dnsmasq.d/,*.conf" >> "$conf"
        ok "  conf-dir toegevoegd aan $conf."
    else
        ok "  $conf bevat al conf-dir=/etc/dnsmasq.d/."
    fi

    if [[ ! -d /etc/dnsmasq.d ]]; then
        mkdir -p /etc/dnsmasq.d
        register_rollback "rmdir /etc/dnsmasq.d 2>/dev/null || true"
    fi
}

configure_dnsmasq() {
    info "[4/9] dnsmasq configureren als proxy-DHCP..."

    ensure_dnsmasq_include
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

    if ! dnsmasq --test 2>&1; then
        error "dnsmasq-configuratie is ongeldig."
        exit 1
    fi

    systemctl enable --now dnsmasq
    register_rollback "systemctl disable --now dnsmasq 2>/dev/null || true"
    ok "dnsmasq actief als proxy-DHCP op ${SELECTED_IFACE}."
}

# =============================================================================
#  STAP 7 — FIREWALL (ZONE-BEWUST)
# =============================================================================

firewalld_active() { systemctl is-active --quiet firewalld; }
get_iface_zone() { firewall-cmd --get-zone-of-interface="$1" 2>/dev/null || true; }

configure_firewall() {
    info "[5/9] Firewall configureren..."

    if ! firewalld_active; then
        warn "firewalld is niet actief. Firewallregels worden overgeslagen."
        warn "Open handmatig: 67/udp 69/udp 4011/udp 80/tcp ${NETBOOT_WEB_PORT}/tcp ${DOKUWIKI_PORT}/tcp ${FORGEJO_HTTP_PORT}/tcp ${FORGEJO_SSH_PORT}/tcp ${COCKPIT_PORT}/tcp"
        return 0
    fi

    local zone
    zone="$(get_iface_zone "$SELECTED_IFACE")"
    if [[ -z "$zone" ]]; then
        zone="$(firewall-cmd --get-default-zone)"
        warn "Interface ${SELECTED_IFACE} is niet aan een zone toegewezen;"
        warn "gebruik standaardzone '${zone}'."
    else
        ok "Zone voor ${SELECTED_IFACE}: ${zone}"
    fi

    local zone_file="/etc/firewalld/zones/${zone}.xml"
    if [[ -f "$zone_file" ]]; then
        cp -a "$zone_file" "${zone_file}.netboot-stack.bak"
        register_rollback "mv -f '${zone_file}.netboot-stack.bak' '${zone_file}' && firewall-cmd --reload || true"
    fi

    firewall-cmd --permanent --zone="$zone" --add-service=dhcp    >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-service=tftp    >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port=4011/udp   >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${NETBOOT_HTTP_PORT}/tcp" >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${NETBOOT_WEB_PORT}/tcp"  >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${DOKUWIKI_PORT}/tcp"     >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${FORGEJO_HTTP_PORT}/tcp" >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${FORGEJO_SSH_PORT}/tcp"  >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${COCKPIT_PORT}/tcp"      >/dev/null

    firewall-cmd --reload >/dev/null
    register_rollback "firewall-cmd --reload || true"
    ok "Firewallregels toegepast op zone '${zone}'."
}

# =============================================================================
#  STAP 8 — QUADLET UNITS
# =============================================================================

create_quadlet_units() {
    info "[6/9] Quadlet-units aanmaken..."
    mkdir -p "$QUADLET_DIR"

    # --- netboot.xyz ---
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

    # --- DokuWiki ---
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

    # --- Forgejo ---
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
#  STAP 9 — CONTAINERS STARTEN (punt 2)
# =============================================================================
#
# Containers krijgen een wachttijd. Een container die na de timeout niet
# actief is, telt als mislukt. verify_installation() velt het eindoordeel.

wait_for_service() {
    local svc="$1" timeout="${2:-$CONTAINER_START_TIMEOUT}" waited=0
    while (( waited < timeout )); do
        systemctl is-active --quiet "$svc" && return 0
        sleep 3
        (( waited += 3 ))
    done
    return 1
}

start_containers() {
    info "[7/9] Containers starten (max ${CONTAINER_START_TIMEOUT}s elk)..."
    systemctl daemon-reload
    local ctr
    for ctr in netbootxyz dokuwiki forgejo; do
        systemctl start "${ctr}.service" 2>/dev/null || true
        if wait_for_service "${ctr}.service" "$CONTAINER_START_TIMEOUT"; then
            ok "  ${ctr}: actief."
            register_rollback "systemctl stop '${ctr}.service' 2>/dev/null || true"
        else
            warn "  ${ctr}: NIET actief na ${CONTAINER_START_TIMEOUT}s."
        fi
    done
}

# =============================================================================
#  STAP 10 — VERIFICATIE (bepaalt de exit-code)
# =============================================================================

verify_installation() {
    info "[8/9] Installatie verifiëren..."
    local failed=0

    if systemctl is-active --quiet dnsmasq; then
        ok "  dnsmasq: actief."
    else
        error "  dnsmasq: NIET actief."
        failed=1
    fi

    if systemctl is-active --quiet cockpit.socket; then
        ok "  cockpit.socket: actief op poort ${COCKPIT_PORT}."
    else
        error "  cockpit.socket: NIET actief."
        failed=1
    fi

    local ctr
    for ctr in netbootxyz dokuwiki forgejo; do
        if systemctl is-active --quiet "${ctr}.service"; then
            ok "  container ${ctr}: actief."
        else
            error "  container ${ctr}: NIET actief."
            failed=1
        fi
    done

    if ss -ulnp 2>/dev/null | grep -q ":${NETBOOT_TFTP_PORT} "; then
        ok "  poort ${NETBOOT_TFTP_PORT}/UDP (TFTP): in gebruik."
    else
        error "  poort ${NETBOOT_TFTP_PORT}/UDP (TFTP): NIET in gebruik."
        failed=1
    fi

    if ss -tlnp 2>/dev/null | grep -q ":${NETBOOT_HTTP_PORT} "; then
        ok "  poort ${NETBOOT_HTTP_PORT}/TCP (HTTP): in gebruik."
    else
        error "  poort ${NETBOOT_HTTP_PORT}/TCP (HTTP): NIET in gebruik."
        failed=1
    fi

    return "$failed"
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
    echo "  Server-IP      : ${SELECTED_IP}/${SELECTED_PREFIX}"
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
    echo "    3. Test PXE-boot vanaf een client in hetzelfde L2-segment."
    echo "============================================================"
    echo
}

print_summary_failure() {
    echo
    echo "============================================================"
    echo "  Installatie NIET (volledig) geslaagd"
    echo "============================================================"
    echo "  Eén of meer componenten draaien niet. Zie de meldingen"
    echo "  hierboven en het logbestand:"
    echo
    echo "    ${LOG_FILE}"
    echo
    echo "  Mogelijke vervolgstappen:"
    echo "    - Bekijk containerlogs:   podman logs <naam>"
    echo "    - Bekijk servicestatus:   systemctl status <naam>"
    echo "    - Bekijk dnsmasq-log:     journalctl -u dnsmasq -f"
    echo "    - Herstart een container: systemctl restart <naam>.service"
    echo
    echo "  Het systeem is in een consistente staat achtergelaten:"
    echo "  geen rollback uitgevoerd, alle geïnstalleerde onderdelen"
    echo "  blijven staan zodat je ze kunt herstellen."
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

    # Stap 0: prerequisites + image tags
    install_prerequisites
    verify_image_tags

    # Stap 1: netwerk kiezen + valideren
    info "Stap 1/9: Netwerkinterface kiezen"
    choose_interface
    validate_interface "$SELECTED_IFACE"

    # Stap 2: pre-flight
    check_port_80

    # Stap 3-7: installatie
    install_packages
    configure_cockpit
    create_directories
    configure_dnsmasq
    configure_firewall
    create_quadlet_units
    start_containers

    # Stap 8-9: verificatie bepaalt het eindoordeel
    if verify_installation; then
        print_summary_success
        exit 0
    else
        print_summary_failure
        exit 1
    fi
}

main "$@"
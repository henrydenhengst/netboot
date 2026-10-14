#!/bin/bash
# ============================================================================
#
#  NETBOOT STACK INSTALLER VOOR OPENSUSE LEAP
#  ===========================================================================
#
#  Beschrijving
#  ------------
#  Dit script installeert en configureert een complete netboot-omgeving op
#  een schone openSUSE Leap-server. De stack bestaat uit de volgende
#  componenten:
#
#    1. dnsmasq          - Proxy-DHCP server (GEEN TFTP, GEEN IP-uitgifte)
#    2. netboot.xyz      - TFTP + HTTP boot-server (in Podman container)
#    3. DokuWiki         - Documentatie/wiki (in Podman container)
#    4. Forgejo          - Git-forge (in Podman container)
#    5. Cockpit          - Grafisch beheer dashboard voor Podman
#
#  Alle containers worden beheerd via Quadlet (systemd-integratie voor
#  Podman), zodat ze automatisch starten bij het opstarten van de server
#  en eenvoudig te beheren zijn via systemctl of Cockpit.
#
#
#  Architectuur
#  ------------
#
#    ┌─────────────────────────────────────────────────────────────────┐
#    │  Fritzbox (bestaande DHCP-server)                               │
#    │  - Deelt IP-adressen uit aan ALLE apparaten                     │
#    │  - Ondersteunt GEEN PXE-opties (next-server / filename)         │
#    └──────────────────┬──────────────────────────────────────────────┘
#                       │
#                       │  (bestaand netwerk)
#                       │
#    ┌──────────────────▼──────────────────────────────────────────────┐
#    │  openSUSE Leap server (dit script)                              │
#    │                                                                 │
#    │  ┌───────────────────────────────────────────────────────────┐  │
#    │  │  dnsmasq (host service)                                   │  │
#    │  │  - Luistert passief mee op DHCP-broadcasts                │  │
#    │  │  - Antwoordt ALLEEN op PXE-verzoeken                      │  │
#    │  │  - Geeft GEEN IP-adressen uit                            │  │
#    │  │  - Verwijst clients naar netboot.xyz container            │  │
#    │  └───────────────────────────────────────────────────────────┘  │
#    │                                                                 │
#    │  ┌───────────────────────────────────────────────────────────┐  │
#    │  │  netboot.xyz container (host networking)                  │  │
#    │  │  - TFTP-server op poort 69/UDP                            │  │
#    │  │  - HTTP-server op poort 80/TCP                            │  │
#    │  │  - Web UI op poort 9000/TCP                               │  │
#    │  └───────────────────────────────────────────────────────────┘  │
#    │                                                                 │
#    │  ┌───────────────────────────────────────────────────────────┐  │
#    │  │  DokuWiki container                                       │  │
#    │  │  - Webinterface op poort 9001/TCP                         │  │
#    │  └───────────────────────────────────────────────────────────┘  │
#    │                                                                 │
#    │  ┌───────────────────────────────────────────────────────────┐  │
#    │  │  Forgejo container                                        │  │
#    │  │  - HTTP op poort 9002/TCP                                 │  │
#    │  │  - SSH op poort 2002/TCP                                  │  │
#    │  └───────────────────────────────────────────────────────────┘  │
#    │                                                                 │
#    │  ┌───────────────────────────────────────────────────────────┐  │
#    │  │  Cockpit (host service)                                   │  │
#    │  │  - Beheerinterface op poort 9003/TCP                      │  │
#    │  └───────────────────────────────────────────────────────────┘  │
#    └─────────────────────────────────────────────────────────────────┘
#
#
#  Waarom deze architectuur?
#  -------------------------
#
#  De Fritzbox is een prima DHCP-server voor normale apparaten, maar heeft
#  een fundamentele beperking: hij kan PXE-clients niet vertellen WAAR ze
#  moeten booten. Er is geen optie voor "next-server" of "boot-filename".
#
#  Een tweede DHCP-server op hetzelfde netwerk draaien is GEEN optie:
#  dat veroorzaakt IP-conflicten en is een van de meest gevreesde
#  netwerkproblemen. Daarom gebruiken we Proxy-DHCP.
#
#  Proxy-DHCP is een speciale modus van dnsmasq die:
#    - GEEN IP-adressen uitgeeft (dat blijft de Fritzbox doen)
#    - ALLEEN antwoordt op PXE-verzoeken (herkenbaar aan specifieke flags)
#    - De client vertelt waar de boot-bestanden te vinden zijn
#
#  Hierdoor werken Fritzbox en dnsmasq naadloos samen zonder conflicten.
#  Deze modus wordt geactiveerd met het keyword "proxy" in de dhcp-range
#  regel.[reference:0][reference:1]
#
#
#  Belangrijke ontwerpbeslissingen
#  -------------------------------
#
#  1. dnsmasq doet ALLEEN proxy-DHCP, GEEN TFTP
#     De netboot.xyz container heeft een ingebouwde TFTP-server. Als
#     dnsmasq ook TFTP zou aanbieden, ontstaat een poortconflict op
#     poort 69/UDP. De container draait met --net=host, dus hij luistert
#     direct op de host-poort.
#
#  2. netboot.xyz draait met --net=host
#     Dit is noodzakelijk voor TFTP, omdat TFTP gebruikmaakt van UDP en
#     broadcast-achtig gedrag dat niet goed werkt met Docker/Podman
#     bridge-netwerken. Host networking is de enige betrouwbare optie.
#
#  3. Quadlet in plaats van podman generate systemd
#     Quadlet is de moderne, door systemd aanbevolen manier om containers
#     te beheren. Het is declaratief, overzichtelijk en wordt volledig
#     ondersteund door Cockpit. Quadlet-bestanden worden geplaatst in
#     /etc/containers/systemd/ en door systemd omgezet in services.[reference:2]
#
#  4. Expliciet server-IP in pxe-service
#     De Fritzbox heeft de neiging om zijn eigen IP-adres als TFTP-server
#     door te geven aan PXE-clients. Door expliciet het server-IP op te
#     geven in de pxe-service regel, omzeilen we dit probleem. De
#     pxe-service syntaxis ondersteunt dit via de optionele parameter
#     [,<server address>].[reference:3]
#
#  5. TFTPD_OPTS='--tftp-single-port'
#     TFTP gebruikt normaal gesproken een willekeurige UDP-poort voor de
#     daadwerkelijke dataoverdracht. Dit maakt firewalls complex. Met
#     deze optie forceert netboot.xyz al het verkeer over poort 69.
#
#  6. Dynamische netwerkberekening via ipcalc
#     In plaats van het netwerkadres handmatig te berekenen (wat fout
#     gaat bij subnetten groter dan /24), gebruiken we het ipcalc
#     commando. Dit commando is beschikbaar op openSUSE Leap en berekent
#     het netwerkadres en netmasker correct voor elk CIDR-blok.[reference:4]
#
#
#  Vereisten
#  ---------
#
#  - openSUSE Leap 15.5 of nieuwer (getest op 15.6)
#  - Minimaal 2 GB RAM, 20 GB vrije schijfruimte
#  - Een schone installatie (geen conflicterende services)
#  - Root-toegang (sudo)
#  - Netwerkverbinding met internet voor het ophalen van container-images
#  - De server moet in hetzelfde L2-netwerk staan als de PXE-clients
#
#
#  Poortenoverzicht
#  ----------------
#
#    Poort   Protocol   Service              Doel
#    -----   --------   -----------------    ----------------------------------
#    67/UDP  UDP        dnsmasq              Proxy-DHCP
#    69/UDP  UDP        netboot.xyz          TFTP (boot-bestanden)
#    80/TCP  TCP        netboot.xyz          HTTP (iPXE scripts)
#    2002    TCP        Forgejo              SSH voor Git
#    4011    UDP        dnsmasq              PXE proxy (alternatieve poort)
#    9000    TCP        netboot.xyz          Web UI
#    9001    TCP        DokuWiki             Webinterface
#    9002    TCP        Forgejo              HTTP webinterface
#    9003    TCP        Cockpit              Beheer-dashboard
#
#
#  Gebruik
#  -------
#
#    sudo ./netboot-stack-installer.sh
#
#  Het script is idempotent: je kunt het meerdere keren draaien zonder
#  problemen. Bestaande configuratie wordt overschreven, containers worden
#  herstart indien nodig.
#
#
#  Na installatie
#  --------------
#
#  1. Zet het IP-adres van de server vast in de Fritzbox:
#     Heimnetz → Netzwerk → Netzwerkeinstellungen → IPv4
#     Vink aan: "Diesem Netzwerkgerät immer die gleiche IPv4-Adresse zuweisen"
#
#  2. Test TFTP lokaal:
#     tftp localhost -c get netboot.xyz.kpxe /tmp/test.kpxe
#
#  3. Test PXE-boot vanaf een client in hetzelfde netwerk.
#
#  4. Beheer containers via Cockpit: https://<server-ip>:9003
#
#
#  Troubleshooting
#  ---------------
#
#  Probleem: PXE-client krijgt "TFTP timeout"
#  Oorzaak:  Firewall blokkeert poort 69/UDP, of de container draait niet.
#  Oplossing:
#     sudo ss -ulnp | grep :69        # Moet de container tonen
#     sudo podman logs netbootxyz     # Bekijk container-logs
#     sudo firewall-cmd --list-all    # Controleer firewall
#
#  Probleem: PXE-client krijgt "no boot filename"
#  Oorzaak:  dnsmasq geeft geen PXE-informatie, of verkeerde interface.
#  Oplossing:
#     sudo journalctl -u dnsmasq -f   # Bekijk live logs
#     Controleer of 'interface=' in /etc/dnsmasq.d/netboot.conf klopt.
#
#  Probleem: Client probeert te booten van Fritzbox IP
#  Oorzaak:  Expliciet server-IP ontbreekt in pxe-service regel.
#  Oplossing:
#     Controleer /etc/dnsmasq.d/netboot.conf
#     De regel moet eindigen met het server-IP: ..., $SERVER_IP
#
#  Probleem: Container start niet
#  Oorzaak:  Poortconflict of SELinux-probleem.
#  Oplossing:
#     sudo systemctl status <container>.service
#     sudo podman logs <container>
#     Controleer of poorten niet al in gebruik zijn: ss -tlnp
#
#  Probleem: IP-adres is veranderd na reboot
#  Oorzaak:  Geen DHCP-reservering in Fritzbox.
#  Oplossing:
#     Stel de reservering in via de Fritzbox interface (zie "Na installatie").
#
#
#  Auteur   : Gegenereerd op verzoek
#  Versie   : 2.0
#  Datum    : $(date +%Y-%m-%d)
#
# ============================================================================

set -euo pipefail

# ============================================================================
# SECTIE 0: HULPFUNCTIES
# ============================================================================
#
# Kleurgecodeerde output voor betere leesbaarheid tijdens installatie.
# De kleuren werken alleen in terminals die ANSI-escape-codes ondersteunen.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ============================================================================
# SECTIE 1: ROOT-CONTROLE
# ============================================================================
#
# Alle installatiestappen vereisen root-toegang. We controleren dit direct
# aan het begin, zodat we niet halverwege het script vastlopen.

if [[ $EUID -ne 0 ]]; then
    error "Dit script moet als root worden uitgevoerd. Gebruik: sudo $0"
    exit 1
fi

# ============================================================================
# SECTIE 2: NETWERKDETECTIE MET IPCALC
# ============================================================================
#
# We detecteren automatisch:
#   - De netwerkinterface met de standaard route (default gateway)
#   - Het bijbehorende IPv4-adres en CIDR-notatie
#   - Het netwerkadres en netmasker via ipcalc
#
# WAAROM IPCALC?
# ---------------
# De vorige versie van dit script berekende het netwerkadres door simpelweg
# het laatste octet op 0 te zetten. Dat werkt ALLEEN voor /24-netwerken.
# Voor een /18-netwerk (zoals 192.168.192.0/18) is dat onjuist. Door ipcalc
# te gebruiken, wordt het netwerkadres correct berekend voor elk subnet.
#
# ipcalc is beschikbaar in de standaard openSUSE repositories en wordt
# meegeïnstalleerd in stap 4.[reference:5]

info "Netwerkconfiguratie detecteren..."

# Installeer ipcalc tijdelijk als het nog niet aanwezig is
if ! command -v ipcalc &>/dev/null; then
    info "ipcalc installeren (nodig voor netwerkberekening)..."
    zypper --non-interactive install ipcalc &>/dev/null || true
fi

DEFAULT_ROUTE_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
if [[ -z "$DEFAULT_ROUTE_IFACE" ]]; then
    error "Geen standaard netwerkinterface gevonden."
    error "Controleer of de server een default gateway heeft: ip route"
    exit 1
fi

SERVER_IP=$(ip -4 addr show "$DEFAULT_ROUTE_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
if [[ -z "$SERVER_IP" ]]; then
    error "Geen IPv4-adres gevonden op interface $DEFAULT_ROUTE_IFACE."
    error "Controleer de netwerkconfiguratie met: ip addr show $DEFAULT_ROUTE_IFACE"
    exit 1
fi

NETWORK_CIDR=$(ip -4 addr show "$DEFAULT_ROUTE_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -n1)

# Gebruik ipcalc om het netwerkadres en netmasker correct te berekenen.
# ipcalc -n geeft het netwerkadres, ipcalc -m geeft het netmasker.
NETWORK_ADDR=$(ipcalc -n "$NETWORK_CIDR" 2>/dev/null | grep '^Network:' | awk '{print $2}' | cut -d'/' -f1)
NETMASK=$(ipcalc -m "$NETWORK_CIDR" 2>/dev/null | grep '^Netmask:' | awk '{print $2}')

# Fallback als ipcalc geen output geeft (zou niet moeten gebeuren)
if [[ -z "$NETWORK_ADDR" || -z "$NETMASK" ]]; then
    error "Kon netwerkadres of netmasker niet berekenen met ipcalc."
    error "Controleer handmatig: ipcalc -n $NETWORK_CIDR"
    exit 1
fi

info "Interface:       $DEFAULT_ROUTE_IFACE"
info "Server-IP:       $SERVER_IP"
info "Netwerk:         $NETWORK_CIDR"
info "Netwerkadres:    $NETWORK_ADDR"
info "Netmasker:       $NETMASK"
echo ""

read -rp "Is dit correct? (j/n) " CONFIRM
if [[ ! "$CONFIRM" =~ ^[jJ]$ ]]; then
    warn "Afgebroken. Pas de netwerkdetectie aan of configureer het netwerk correct."
    exit 1
fi

# ============================================================================
# SECTIE 3: CONFIGURATIE
# ============================================================================
#
# Hier definiëren we alle variabelen op één plek, zodat je ze eenvoudig kunt
# aanpassen zonder door het hele script te hoeven zoeken.

# --- Poorten ---
#
# We gebruiken bewust hoge poorten (>9000) voor de webinterfaces om
# conflicten met bestaande services te vermijden.
#
# Poort 80 wordt gebruikt door netboot.xyz voor HTTP (iPXE scripts).
# Poort 69 wordt gebruikt door netboot.xyz voor TFTP.
# Deze twee poorten kunnen NIET worden aangepast, omdat PXE-clients
# deze standaardpoorten verwachten.

NETBOOT_TFTP_PORT=69     # TFTP (vast, niet aanpasbaar)
NETBOOT_HTTP_PORT=80     # HTTP voor iPXE (vast, niet aanpasbaar)
NETBOOT_WEB_PORT=9000    # Web UI netboot.xyz
DOKUWIKI_PORT=9001       # DokuWiki webinterface
FORGEJO_HTTP_PORT=9002   # Forgejo HTTP
FORGEJO_SSH_PORT=2002    # Forgejo SSH voor git+ssh
COCKPIT_PORT=9003        # Cockpit beheerinterface

# --- Container images ---
#
# We gebruiken officiële images waar mogelijk:
#   - netboot.xyz: officiële image van de ontwikkelaars
#   - DokuWiki: officiële image op Docker Hub
#   - Forgejo: officiële image via Codeberg

NETBOOT_IMAGE="ghcr.io/netbootxyz/netbootxyz"
DOKUWIKI_IMAGE="docker.io/dokuwiki/dokuwiki:stable"
FORGEJO_IMAGE="codeberg.org/forgejo/forgejo:12"

# --- Bestandslocaties ---

QUADLET_DIR="/etc/containers/systemd"

# ============================================================================
# SECTIE 4: CONTROLE OP POORT 80
# ============================================================================
#
# De netboot.xyz container draait met Network=host en gebruikt poort 80 voor
# HTTP (iPXE scripts). Als er al een andere webserver op poort 80 draait,
# kan de container niet starten. We controleren dit voordat we verdergaan.

info "Controleren of poort 80 vrij is..."

if ss -tlnp 2>/dev/null | grep -q ':80 '; then
    warn "Poort 80/TCP is al in gebruik door een andere service!"
    warn "De netboot.xyz container kan hierdoor niet starten."
    echo ""
    ss -tlnp | grep ':80 '
    echo ""
    read -rp "Wil je doorgaan? (j/n) " CONTINUE
    if [[ ! "$CONTINUE" =~ ^[jJ]$ ]]; then
        error "Afgebroken. Stop de service die poort 80 gebruikt en probeer opnieuw."
        exit 1
    fi
else
    info "  Poort 80/TCP is vrij."
fi

# ============================================================================
# SECTIE 5: PAKKETTEN INSTALLEREN
# ============================================================================
#
# We installeren:
#   - cockpit + cockpit-podman: grafisch beheer dashboard
#   - podman: container runtime
#   - dnsmasq: proxy-DHCP server
#   - firewalld: firewall-beheer (standaard op openSUSE)
#   - ipcalc: netwerkberekening (voor correcte CIDR-verwerking)
#
# De --non-interactive flag zorgt dat zypper niet om bevestiging vraagt.

info "[1/9] Pakketten installeren..."

zypper --non-interactive install \
    cockpit \
    cockpit-podman \
    podman \
    dnsmasq \
    firewalld \
    ipcalc \
    || { error "Installatie van pakketten mislukt."; exit 1; }

# ============================================================================
# SECTIE 6: COCKPIT CONFIGUREREN
# ============================================================================
#
# Cockpit luistert standaard op poort 9090. We wijzigen dit naar 9003 om
# een consistente poortnummering te krijgen.
#
# De wijziging gebeurt via een systemd socket override. Dit is nodig omdat
# Cockpit gebruikmaakt van systemd socket activation: systemd luistert op
# de poort en start Cockpit pas wanneer er een verbinding binnenkomt.
#
# De lege "ListenStream=" regel is essentieel: die wist de standaardpoort
# (9090) voordat de nieuwe poort wordt toegevoegd. Zonder deze regel
# blijven beide poorten actief. Dit wordt bevestigd in de Cockpit-
# documentatie: "The first line with an empty value is intentional."[reference:6]

info "[2/9] Cockpit configureren op poort $COCKPIT_PORT..."

mkdir -p /etc/systemd/system/cockpit.socket.d/
cat > /etc/systemd/system/cockpit.socket.d/override.conf <<EOF
[Socket]
ListenStream=
ListenStream=$COCKPIT_PORT
FreeBind=yes
EOF

# De Origins-regel vertelt Cockpit welke URLs geldig zijn voor WebSocket
# verbindingen. Zonder deze regel kan Cockpit verbindingen weigeren.
#
# ProtocolHeader vertelt Cockpit dat hij achter een reverse proxy draait
# (nu niet het geval, maar handig voor toekomstige uitbreiding).

mkdir -p /etc/cockpit/
cat > /etc/cockpit/cockpit.conf <<EOF
[WebService]
Origins = https://$SERVER_IP:$COCKPIT_PORT wss://$SERVER_IP:$COCKPIT_PORT
ProtocolHeader = X-Forwarded-Proto
EOF

# SELINUX-CONFIGURATIE
# --------------------
# Op systemen waar SELinux actief is (enforcing), moet de nieuwe poort
# ook worden toegestaan in het SELinux-beleid. Zonder deze stap kan
# Cockpit niet starten of geen verbindingen accepteren, zelfs niet als
# de firewall correct is ingesteld.
#
# De Cockpit-documentatie beveelt aan om semanage te gebruiken:
#   semanage port -a -t websm_port_t -p tcp <poort>
#
# Op openSUSE Leap is SELinux vaak niet actief (AppArmor is de
# standaard). We controleren eerst of SELinux actief is.

if command -v getenforce &>/dev/null; then
    SELINUX_STATUS=$(getenforce 2>/dev/null || echo "Disabled")
    if [[ "$SELINUX_STATUS" == "Enforcing" ]]; then
        info "  SELinux is actief ($SELINUX_STATUS). Poort $COCKPIT_PORT toevoegen aan beleid..."
        if ! semanage port -a -t websm_port_t -p tcp "$COCKPIT_PORT" 2>/dev/null; then
            semanage port -m -t websm_port_t -p tcp "$COCKPIT_PORT" 2>/dev/null || \
                warn "  Kon SELinux-poort niet aanpassen. Controleer handmatig."
        fi
    else
        info "  SELinux is niet actief ($SELINUX_STATUS). Geen aanpassing nodig."
    fi
else
    info "  SELinux is niet geïnstalleerd. Geen aanpassing nodig."
fi

systemctl daemon-reload
systemctl enable --now cockpit.socket
systemctl restart cockpit.socket \
    || { error "Cockpit kon niet worden gestart."; exit 1; }

# ============================================================================
# SECTIE 7: MAPPENSTRUCTUUR
# ============================================================================
#
# We gebruiken /srv als basis omdat dit de FHS-standaard is voor
# "site-specific data served by this system".
#
# Structuur:
#   /srv/tftp              - TFTP-bestanden (wordt gevuld door netboot.xyz)
#   /srv/netboot-config    - netboot.xyz configuratie
#   /srv/dokuwiki/data     - DokuWiki data (pagina's, media)
#   /srv/forgejo/data      - Forgejo data (repos, database, config)
#
# DokuWiki en Forgejo draaien als UID 1000 in hun containers. De mappen
# moeten eigendom zijn van deze UID, anders kunnen de containers niet
# schrijven (wat leidt tot cryptische foutmeldingen).

info "[3/9] Mappenstructuur aanmaken..."

mkdir -p /srv/tftp
mkdir -p /srv/netboot-config
mkdir -p /srv/dokuwiki/data
mkdir -p /srv/forgejo/data

chown -R 1000:1000 /srv/dokuwiki/data
chown -R 1000:1000 /srv/forgejo/data

# ============================================================================
# SECTIE 8: DNSMASQ CONFIGUREREN ALS PROXY-DHCP
# ============================================================================
#
# Dit is het hart van de netboot-oplossing. We configureren dnsmasq om:
#
#   1. GEEN IP-adressen uit te delen (dat doet de Fritzbox al)
#   2. ALLEEN te antwoorden op PXE-verzoeken
#   3. Clients te verwijzen naar de netboot.xyz container
#
# De sleutel is de "dhcp-range" regel met de ",proxy" suffix. Dit vertelt
# dnsmasq om in proxy-modus te draaien. In deze modus is een andere
# DHCP-server (de Fritzbox) verantwoordelijk voor IP-allocatie, en geeft
# dnsmasq alleen de PXE-informatie door.[reference:7][reference:8]
#
# BELANGRIJK: We configureren hier GEEN TFTP. De netboot.xyz container
# heeft een ingebouwde TFTP-server en luistert op poort 69/UDP via host
# networking. Als dnsmasq ook TFTP zou aanbieden, krijgen we een conflict.
#
# De pxe-service regels bevatten een expliciet server-IP. Dit is een
# workaround voor een bekend Fritzbox-probleem waarbij de Fritzbox zijn
# eigen IP-adres als TFTP-server doorgeeft aan PXE-clients. De syntaxis
# is: pxe-service=<CSA>,<menu text>[,<basename>][,<server address>][reference:9]

info "[4/9] dnsmasq configureren als proxy-DHCP..."

cat > /etc/dnsmasq.d/netboot.conf <<EOF
# ============================================================================
# Proxy-DHCP configuratie voor netboot.xyz
# ============================================================================
#
# Deze dnsmasq-instantie doet ALLEEN proxy-DHCP. Hij deelt geen
# IP-adressen uit (dat blijft de Fritzbox doen), maar antwoordt
# uitsluitend op PXE-verzoeken van clients die via het netwerk willen
# booten.
#
# TFTP wordt NIET door dnsmasq afgehandeld, maar door de netboot.xyz
# container op poort 69/UDP. Dit voorkomt een poortconflict.
#
# Gegenereerd door netboot-stack-installer.sh op $(date)
# ============================================================================

# Luister alleen op de interface die naar de clients wijst.
# Dit voorkomt dat dnsmasq antwoordt op onverwachte interfaces.
interface=$DEFAULT_ROUTE_IFACE

# bind-dynamic zorgt ervoor dat dnsmasq zich aanpast wanneer interfaces
# op- of afgaan. Dit is robuuster dan bind-interfaces.
bind-dynamic

# log-dhcp schrijft alle DHCP-verkeer naar syslog. Handig voor debugging,
# maar kan veel logregels produceren op drukke netwerken.
log-dhcp

# DHCP proxy-modus: GEEN IP-uitgifte, alleen PXE-informatie.
# De ",proxy" suffix activeert deze speciale modus.
# Het netmasker wordt dynamisch berekend via ipcalc (correct voor elk subnet).
dhcp-range=$NETWORK_ADDR,proxy,$NETMASK

# PXE-opties voor BIOS-clients (legacy x86).
# Syntaxis: pxe-service=<architectuur>, "<label>", "<bestand>", <server-ip>
# Het expliciete server-IP is essentieel om het Fritzbox-probleem te omzeilen.
pxe-service=x86PC, "NETBOOT (BIOS)", "netboot.xyz.kpxe", $SERVER_IP

# PXE-opties voor moderne UEFI-clients (x86-64).
# Dit is de meest voorkomende architectuur tegenwoordig.
pxe-service=X86-64_EFI, "NETBOOT (EFI)", "netboot.xyz.efi", $SERVER_IP

# GEEN enable-tftp / tftp-root hier!
# De netboot.xyz container serveert de TFTP-bestanden op poort 69/UDP.
# Het toevoegen van TFTP hier zou een poortconflict veroorzaken.
EOF

# Valideer de configuratie voordat we dnsmasq starten.
# dnsmasq --test controleert de syntax en geeft een exit code terug.
if ! dnsmasq --test; then
    error "dnsmasq configuratie is ongeldig. Controleer /etc/dnsmasq.d/netboot.conf"
    exit 1
fi

systemctl enable --now dnsmasq \
    || { error "dnsmasq kon niet worden gestart."; exit 1; }

# ============================================================================
# SECTIE 9: FIREWALL CONFIGUREREN
# ============================================================================
#
# firewalld is de standaard firewall op openSUSE. We openen de volgende
# poorten:
#
#   - dhcp (67/UDP):  voor proxy-DHCP verkeer
#   - tftp (69/UDP):  voor TFTP-bestandsoverdracht
#   - 4011/UDP:       alternatieve PXE-poort (sommige clients gebruiken deze)
#   - 80/TCP:         netboot.xyz HTTP (iPXE scripts)
#   - 9000-9003/TCP:  webinterfaces (netboot UI, DokuWiki, Forgejo, Cockpit)
#   - 2002/TCP:       Forgejo SSH
#
# De --permanent flag zorgt dat de regels bewaard blijven na een reboot.
# --reload activeert de nieuwe regels zonder de firewall te herstarten.

info "[5/9] Firewall configureren..."

firewall-cmd --permanent --add-service=dhcp
firewall-cmd --permanent --add-service=tftp
firewall-cmd --permanent --add-port=4011/udp
firewall-cmd --permanent --add-port=${COCKPIT_PORT}/tcp
firewall-cmd --permanent --add-port=${NETBOOT_HTTP_PORT}/tcp
firewall-cmd --permanent --add-port=${NETBOOT_WEB_PORT}/tcp
firewall-cmd --permanent --add-port=${DOKUWIKI_PORT}/tcp
firewall-cmd --permanent --add-port=${FORGEJO_HTTP_PORT}/tcp
firewall-cmd --permanent --add-port=${FORGEJO_SSH_PORT}/tcp
firewall-cmd --reload \
    || { error "Firewall kon niet worden herladen."; exit 1; }

# ============================================================================
# SECTIE 10: QUADLET UNITS AANMAKEN
# ============================================================================
#
# Quadlet is de moderne manier om Podman-containers te beheren via systemd.
# In plaats van "podman run" commando's schrijven we .container bestanden
# in /etc/containers/systemd/. systemd genereert hieruit automatisch
# service units.
#
# Voordelen:
#   - Declaratieve configuratie
#   - Automatisch starten bij boot
#   - Beheer via systemctl (start/stop/status/logs)
#   - Volledige integratie met Cockpit
#
# Voor meer informatie: man podman-systemd.unit[reference:10]

info "[6/9] Quadlet units aanmaken..."

mkdir -p "$QUADLET_DIR"

# ----------------------------------------------------------------------------
# netboot.xyz container
# ----------------------------------------------------------------------------
#
# Deze container draait met Network=host. Dit is noodzakelijk omdat:
#   - TFTP gebruikmaakt van UDP en broadcast-achtig gedrag
#   - TFTP werkt niet betrouwbaar via bridge-netwerken
#   - De container moet luisteren op poort 69, 80 en 9000
#
# De SecurityOpt=label=disable is nodig op systemen met SELinux. Zonder
# deze optie kan de container niet bij de host-netwerkinterfaces.
#
# TFTPD_OPTS='--tftp-single-port' forceert al het TFTP-verkeer over poort 69,
# wat firewallconfiguratie enorm vereenvoudigt.

cat > "$QUADLET_DIR/netbootxyz.container" <<EOF
[Unit]
Description=netboot.xyz container (TFTP + HTTP)
Documentation=https://netboot.xyz
After=network-online.target
Wants=network-online.target

[Container]
Image=$NETBOOT_IMAGE
ContainerName=netbootxyz
Network=host
Volume=/srv/tftp:/assets:Z
Volume=/srv/netboot-config:/config:Z
Environment=TFTPD_OPTS=--tftp-single-port
Environment=WEB_APP_PORT=$NETBOOT_WEB_PORT
Environment=NGINX_PORT=$NETBOOT_HTTP_PORT
SecurityOpt=label=disable

[Service]
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# ----------------------------------------------------------------------------
# DokuWiki container
# ----------------------------------------------------------------------------
#
# DokuWiki heeft geen database nodig (het slaat data op in platte bestanden).
# De container draait als UID 1000, dus de volume-mount moet de juiste
# permissies hebben.
#
# De :Z suffix op het volume zorgt voor correcte SELinux-labeling.

cat > "$QUADLET_DIR/dokuwiki.container" <<EOF
[Unit]
Description=DokuWiki container
Documentation=https://www.dokuwiki.org
After=network-online.target
Wants=network-online.target

[Container]
Image=$DOKUWIKI_IMAGE
ContainerName=dokuwiki
PublishPort=$DOKUWIKI_PORT:8080
Volume=/srv/dokuwiki/data:/storage:Z
User=1000:1000

[Service]
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# ----------------------------------------------------------------------------
# Forgejo container
# ----------------------------------------------------------------------------
#
# Forgejo is een community fork van Gitea. Het biedt Git-hosting, issue
# tracking, CI/CD en meer.
#
# Poort 3000 (intern) is de HTTP-poort, poort 22 (intern) is de SSH-poort.
# We mappen deze naar 9002 en 2002 op de host.
#
# USER_UID en USER_GID zorgen dat de container-bestanden eigendom zijn van
# UID 1000 op de host, wat overeenkomt met de /srv/forgejo/data rechten.

cat > "$QUADLET_DIR/forgejo.container" <<EOF
[Unit]
Description=Forgejo container
Documentation=https://forgejo.org
After=network-online.target
Wants=network-online.target

[Container]
Image=$FORGEJO_IMAGE
ContainerName=forgejo
PublishPort=$FORGEJO_HTTP_PORT:3000
PublishPort=$FORGEJO_SSH_PORT:22
Volume=/srv/forgejo/data:/data:Z
Environment=USER_UID=1000
Environment=USER_GID=1000

[Service]
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# ============================================================================
# SECTIE 11: CONTAINERS STARTEN
# ============================================================================
#
# We herladen systemd zodat het de nieuwe Quadlet units oppikt. Daarna
# starten we elke container via systemctl.
#
# De "|| warn" constructie zorgt dat een mislukte start het script niet
# voortijdig afbreekt. De gebruiker kan de container later handmatig
# starten via Cockpit.

info "[7/9] Containers starten..."

systemctl daemon-reload

for ctr in netbootxyz dokuwiki forgejo; do
    if systemctl enable --now "$ctr.service" 2>/dev/null; then
        info "  $ctr gestart."
    else
        warn "  $ctr kon niet direct worden gestart. Start deze later via Cockpit."
    fi
done

# ============================================================================
# SECTIE 12: STATUSCONTROLE
# ============================================================================
#
# We controleren of alle services draaien en tonen een samenvatting.
# Dit is het eerste aanknopingspunt bij problemen.

info "[8/9] Status controleren..."
echo ""

echo "--- dnsmasq (proxy-DHCP) ---"
systemctl is-active dnsmasq && echo "  actief" || echo "  NIET actief"

echo ""
echo "--- Cockpit ---"
systemctl is-active cockpit.socket && echo "  actief op poort $COCKPIT_PORT" || echo "  NIET actief"

echo ""
echo "--- Containers ---"
for ctr in netbootxyz dokuwiki forgejo; do
    if systemctl is-active "$ctr.service" &>/dev/null; then
        echo "  $ctr: actief"
    else
        echo "  $ctr: NIET actief (start via Cockpit)"
    fi
done

echo ""
echo "--- TFTP-poort 69 controleren ---"
if ss -ulnp 2>/dev/null | grep -q ':69 '; then
    echo "  Poort 69/UDP is in gebruik (door de netboot.xyz container)."
    ss -ulnp | grep ':69 '
else
    warn "  Poort 69/UDP is NIET in gebruik. Controleer de netbootxyz container."
fi

echo ""
echo "--- Netwerkconfiguratie samenvatting ---"
echo "  Interface:     $DEFAULT_ROUTE_IFACE"
echo "  Server-IP:     $SERVER_IP"
echo "  Netwerk:       $NETWORK_CIDR"
echo "  Netwerkadres:  $NETWORK_ADDR"
echo "  Netmasker:     $NETMASK"

# ============================================================================
# SECTIE 13: AFSLUITENDE INFORMATIE
# ============================================================================
#
# Toon alle URLs en belangrijke vervolgstappen.

info "[9/9] Installatie voltooid!"
echo ""
echo "============================================"
echo " Installatie voltooid!"
echo "============================================"
echo ""
echo " Toegang:"
echo "   Cockpit:      https://$SERVER_IP:$COCKPIT_PORT"
echo "   netboot.xyz:  http://$SERVER_IP:$NETBOOT_HTTP_PORT"
echo "   netboot web:  http://$SERVER_IP:$NETBOOT_WEB_PORT"
echo "   DokuWiki:     http://$SERVER_IP:$DOKUWIKI_PORT"
echo "   Forgejo:      http://$SERVER_IP:$FORGEJO_HTTP_PORT"
echo "   Forgejo SSH:  ssh -p $FORGEJO_SSH_PORT git@$SERVER_IP"
echo ""
echo " Belangrijk:"
echo "   1. Zet het IP-adres van deze server vast in je Fritzbox:"
echo "      Heimnetz → Netzwerk → Netzwerkeinstellungen → IPv4"
echo "      Vink aan: 'Diesem Netzwerkgerät immer die gleiche IPv4-Adresse zuweisen'"
echo ""
echo "   2. TFTP wordt afgehandeld door de netboot.xyz container op poort 69/UDP."
echo "      dnsmasq doet ALLEEN proxy-DHCP en verwijst clients naar dit IP."
echo ""
echo "   3. TFTP-bestanden: /srv/tftp (netboot.xyz vult deze automatisch)"
echo ""
echo "   4. Containers die niet automatisch starten:"
echo "      Cockpit → Podman Containers → netbootxyz / dokuwiki / forgejo → Start"
echo ""
echo " Troubleshooting: zie de documentatie bovenaan dit script."
echo ""
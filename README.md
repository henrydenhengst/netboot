┌─────────────────────────────────────────────────────────────────────────────┐
│                    NETBOOT.XYZ ON OPENSUSE TUMBLEWEED                        │
│                          TECHNISCH ONTWERP v7.0                              │
└─────────────────────────────────────────────────────────────────────────────┘


╔═════════════════════════════════════════════════════════════════════════════╗
║                          1. HET PROBLEEM                                    ║
╚═════════════════════════════════════════════════════════════════════════════╝

Jouw internetrouter kan geen DHCP opties 66/67 voor PXE.
Router doet alleen standaard DHCP op 192.168.x.x.
Je wilt PXE netboot op een dedicated unmanaged switch.

Oplossing: twee volledig gescheiden netwerken met eigen DHCP servers.


╔═════════════════════════════════════════════════════════════════════════════╗
║                          2. ARCHITECTUUR                                    ║
╚═════════════════════════════════════════════════════════════════════════════╝

                    ┌──────────────────┐
                    │    INTERNET       │
                    └────────┬─────────┘
                             │
                    ┌────────┴─────────┐
                    │    ROUTER        │
                    │ DHCP: 192.168.x.x│
                    └────────┬─────────┘
                             │
                    ┌────────┴─────────┐
                    │   NIC2 (WAN)     │
                    └────────┬─────────┘
                             │
              ┌──────────────┴──────────────┐
              │     TUMBLEWEED SERVER        │
              │  IP: 10.10.10.1 (PXE LAN)   │
              │  - DHCP server (alleen PXE) │
              │  - TFTP server              │
              │  - Web UI (poort 3000)      │
              │  - NAT voor internet        │
              └──────────────┬──────────────┘
                             │
                    ┌────────┴─────────┐
                    │   NIC1 (PXE)     │
                    └────────┬─────────┘
                             │
                    ┌────────┴─────────┐
                    │ UNMANAGED SWITCH │
                    │   (geen config)  │
                    └────────┬─────────┘
                             │
              ┌──────────────┴──────────────┐
              │    PXE CLIENTS              │
              │  DHCP: 10.10.10.100-200     │
              └─────────────────────────────┘


╔═════════════════════════════════════════════════════════════════════════════╗
║                          3. NETWERKEN                                       ║
╚═════════════════════════════════════════════════════════════════════════════╝

NETWERK 1 - WAN (internet)
├── Router DHCP: 192.168.x.x
├── Server NIC2: verbinding met router
└── Alleen voor internet toegang

NETWERK 2 - PXE LAN (dedicated switch)
├── Server DHCP: 10.10.10.1/24
├── Server NIC1: verbinding met switch
├── DHCP range: 10.10.10.100 - 10.10.10.200
├── Geen router op dit netwerk
└── Alleen PXE clients en deze server

WAAROM DIT WERKT:
├── Twee DHCP servers bestaan naast elkaar (verschillende netwerken)
├── Router weet niks van PXE LAN (geen conflicten)
├── Server doet NAT zodat PXE clients internet hebben
└── Unmanaged switch heeft geen configuratie nodig


╔═════════════════════════════════════════════════════════════════════════════╗
║                          4. BOOT FLOW                                       ║
╚═════════════════════════════════════════════════════════════════════════════╝

STAP 1: PXE client boot op dedicated switch
        │
        ▼
STAP 2: Client stuurt DHCP broadcast
        │
        ▼
STAP 3: Alleen server reageert (router zit op ander netwerk)
        │
        ▼
STAP 4: Server geeft IP adres (10.10.10.x) + boot file (ipxe.efi)
        │
        ▼
STAP 5: Client laadt ipxe.efi via TFTP van server
        │
        ▼
STAP 6: iPXE start en laadt HTTP menu van server (poort 3000)
        │
        ▼
STAP 7: netboot.xyz menu verschijnt - kies OS om te installeren
        │
        ▼
STAP 8: Installatiebestanden komen via server van internet (NAT)


╔═════════════════════════════════════════════════════════════════════════════╗
║                          5. SERVER COMPONENTEN                              ║
╚═════════════════════════════════════════════════════════════════════════════╝

DNSMASQ (native)
├── DHCP server op PXE interface
├── IP range: 10.10.10.100 - 10.10.10.200
├── Gateway: 10.10.10.1 (de server zelf)
├── DNS: 1.1.1.1, 8.8.8.8
├── TFTP server voor boot bestanden
└── Boot file: ipxe.efi (universeel voor BIOS/UEFI)

NETBOOT.XYZ (podman container)
├── Web UI op poort 3000
├── Assets en configuratie persistent
├── HTTP menu voor iPXE chain
└── Network: host (deelt server netwerk)

FIREWALLD
├── Interne zone voor PXE interface
├── Externe zone voor WAN interface
├── Masquerade voor NAT (internet voor PXE clients)
└── Poorten: 67/udp (DHCP), 69/udp (TFTP), 80/tcp, 3000/tcp

INTERFACE PINNING (udev)
├── MAC adres van PXE NIC wordt vastgelegd
├── Interface krijgt persistente naam: pxe0
└── Werkt na elke reboot


╔═════════════════════════════════════════════════════════════════════════════╗
║                          6. ROUTER BENODIGDHEDEN                            ║
╚═════════════════════════════════════════════════════════════════════════════╝

De router heeft GEEN speciale configuratie nodig.

Wat router wel doet:
├── Gewoon DHCP op zijn eigen netwerk (192.168.x.x)
├── Internet verbinding voor de server (via NIC2)
└── Verder niks

Wat router NIET hoeft te kunnen:
├── Geen DHCP opties 66/67
├── Geen next-server configuratie
├── Geen PXE ondersteuning
└── Geen VLAN configuratie


╔═════════════════════════════════════════════════════════════════════════════╗
║                          7. VOORDELEN                                       ║
╚═════════════════════════════════════════════════════════════════════════════╝

VOOR DE HOMELAB ADMINISTRATOR
├── Werkt met elke router (ook die zonder PXE opties)
├── Unmanaged switch is voldoende (geen configuratie)
├── Geen DHCP conflicten (aparte netwerken)
├── Volledige controle over PXE omgeving
└── Werkt na reboot automatisch weer

VOOR DE PXE CLIENTS
├── Krijgen altijd een IP adres (geen timeouts)
├── Bootloader wordt betrouwbaar geladen (TFTP)
├── Menu werkt via HTTP (robuust)
├── Ondersteunt BIOS en UEFI (ipxe.efi)
└── Internet werkt via NAT (niets extra configureren)

VOOR DE NETWERKSTABILITEIT
├── Router blijft ongewijzigd (geen risico)
├── Geen broadcast storms naar WAN
├── Server is single point of failure maar makkelijk te herstellen
└── Switch is passief (stroom erop = werken)


╔═════════════════════════════════════════════════════════════════════════════╗
║                          8. VERANTWOORDING                                  ║
╚═════════════════════════════════════════════════════════════════════════════╝

WAAROM GEEN PROXYDHCP?
├── dnsmasq ondersteunt geen echte ProxyDHCP mode
├── ISC DHCP is complex en verouderd
├── Full DHCP op dedicated switch is eenvoudiger
└── Geen andere DHCP op PXE netwerk = veilig

WAAROM FULL DHCP OP DEDICATED SWITCH?
├── Geen afhankelijkheid van router functionaliteit
├── Volledige controle over IP range en opties
├── Werkt met elke unmanaged switch
└── Simpele troubleshooting (alles op één server)

WAAROM NAT?
├── PXE clients hebben internet nodig (OS installaties)
├── Router zit op ander netwerk
├── NAT is de eenvoudigste oplossing
└── Geen extra routing configuratie nodig

WAAROM IPXE VIA HTTP (niet TFTP)?
├── HTTP is robuuster dan TFTP
├── Grote bestanden laden sneller
├── Foutafhandeling is beter
└── netboot.xyz web UI gebruikt HTTP


╔═════════════════════════════════════════════════════════════════════════════╗
║                          9. BENODIGDHEDEN                                   ║
╚═════════════════════════════════════════════════════════════════════════════╝

HARDWARE
├── Server met openSUSE Tumbleweed
├── Twee netwerkkaarten (NIC1 + NIC2)
├── Unmanaged switch (elke goedkope switch werkt)
├── Netwerkkabels
└── PXE-capabele clients

SERVER SOFTWARE (geïnstalleerd door playbook)
├── Podman (voor netboot.xyz container)
├── dnsmasq (DHCP + TFTP)
├── firewalld (NAT + firewall)
├── wicked (netwerk persistentie)
└── iproute2 (netwerk tools)

CONFIGURATIE (eenmalig handmatig)
├── MAC adres van PXE NIC opschrijven
│   commando: ip link show | grep -A1 enp | grep link/ether
└── MAC adres invullen in playbook vars


╔═════════════════════════════════════════════════════════════════════════════╗
║                          10. NA REBOOT                                       ║
╚═════════════════════════════════════════════════════════════════════════════╝

WAT AUTOMATISCH HERSTART:
├── Network interface configuratie (static IP op 10.10.10.1)
├── firewalld met zones en masquerade
├── dnsmasq (DHCP + TFTP)
├── netboot.xyz container (podman)
└── IP forwarding en NAT regels

WAT PERSISTENT IS:
├── udev rule: PXE interface heet altijd "pxe0"
├── DHCP leases blijven bewaard
├── netboot.xyz assets en configuratie blijven
└── TFTP boot bestanden blijven

WAT JE MOET CHECKEN NA REBOOT:
├── systemctl status dnsmasq
├── systemctl status netbootxyz
├── ip addr show pxe0
└── firewall-cmd --list-all


╔═════════════════════════════════════════════════════════════════════════════╗
║                          11. TROUBLESHOOTING                                ║
╚═════════════════════════════════════════════════════════════════════════════╝

CLIENT KRIJGT GEEN IP
├── Check: server draait? (systemctl status dnsmasq)
├── Check: switch verbonden met NIC1?
├── Check: ss -ulpn | grep :67 (luistert dnsmasq?)
└── Check: firewall poort 67 open? (firewall-cmd --list-ports)

CLIENT LAADT GEEN BOOTLOADER
├── Check: TFTP werkt? (tftp 10.10.10.1 get undionly.kpxe)
├── Check: bestand bestaat? (ls -la /srv/tftp/ipxe.efi)
└── Check: poort 69 open? (ss -ulpn | grep :69)

GEEN NETBOOT.XYZ MENU
├── Check: container draait? (podman ps)
├── Check: web interface? (curl localhost:3000)
├── Check: HTTP script? (curl http://10.10.10.1:3000/boot.ipxe)
└── Check: poort 80/3000 open? (ss -tulpn | grep -E ':80|:3000')

GEEN INTERNET OP PXE CLIENTS
├── Check: IP forwarding aan? (sysctl net.ipv4.ip_forward)
├── Check: NAT regels? (iptables -t nat -L -n -v)
├── Check: WAN interface heeft internet? (ping 1.1.1.1)
└── Check: firewall masquerade? (firewall-cmd --zone=external --query-masquerade)

MAC DETECTIE WERKT NIET
├── Check: MAC correct? (ip link show)
├── Check: kleine letters? (mac moet lowercase zijn)
└── Check: ip -j link show (werkt commando?)


╔═════════════════════════════════════════════════════════════════════════════╗
║                          12. SAMENVATTING                                   ║
╚═════════════════════════════════════════════════════════════════════════════╝

DIT ONTWERP IS CORRECT VOOR JOUW SITUATIE OMDAT:

✓ Je router geen DHCP opties ondersteunt
✓ Je een dedicated unmanaged switch hebt
✓ Je volledige controle wilt over PXE
✓ Je werkt met openSUSE Tumbleweed
✓ Je een robuuste, werkende oplossing nodig hebt

DE BELANGRIJKSTE PRINCIPES:

1. Twee gescheiden netwerken met eigen DHCP (geen conflict)
2. Server doet alles: DHCP + TFTP + Web UI + NAT
3. Router doet alleen internet (niks speciaals)
4. Unmanaged switch werkt out-of-the-box
5. Alles is persistent en werkt na reboot

DIT IS PRODUCTIE-KLAAR VOOR HOMELAB EN SMB.
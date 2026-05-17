# Netboot.xyz op openSUSE Tumbleweed
## Volledig technisch ontwerp

| Category | Badge |
|----------|-------|
| **Playbook** | ![Version](https://img.shields.io/badge/version-7.0-blue) ![Status](https://img.shields.io/badge/status-production--ready-brightgreen) |
| **Distributie** | ![openSUSE](https://img.shields.io/badge/openSUSE-Tumbleweed-178e3b?logo=opensuse) |
| **Architectuur** | ![DHCP](https://img.shields.io/badge/DHCP-FULL%20mode-blue) ![TFTP](https://img.shields.io/badge/TFTP-enabled-purple) ![PXE](https://img.shields.io/badge/PXE-iPXE%2FEFI-orange) |
| **Container** | ![Podman](https://img.shields.io/badge/container-Podman-8821e0?logo=podman) ![Netboot.xyz](https://img.shields.io/badge/netboot.xyz-latest-178e3b) |
| **Networking** | ![Firewall](https://img.shields.io/badge/firewall-firewalld-0078d7) ![NAT](https://img.shields.io/badge/NAT-masquerade-green) |
| **Interface** | ![Pinning](https://img.shields.io/badge/interface-udev%20pinning-important) ![Persistent](https://img.shields.io/badge/persistent-pxe0-green) |
| **Boot Flow** | ![Entry Point](https://img.shields.io/badge/entry-ipxe.efi-blue) ![Chain](https://img.shields.io/badge/chain-HTTP-brightgreen) |
| **Ports** | ![DHCP](https://img.shields.io/badge/67-UDP-blue) ![TFTP](https://img.shields.io/badge/69-UDP-purple) ![HTTP](https://img.shields.io/badge/80-TCP-orange) |
| **Build** | ![Ansible](https://img.shields.io/badge/Ansible-2.20.5-ee0000?logo=ansible) ![OpenSUSE](https://img.shields.io/badge/openSUSE-Tumbleweed-green) |

---

## 1. Doel van dit ontwerp

Dit document beschrijft hoe je een netboot.xyz PXE server opzet op openSUSE Tumbleweed voor een situatie waarin je router geen DHCP opties 66 en 67 ondersteunt. De oplossing gebruikt twee gescheiden netwerken met eigen DHCP servers.

---

## 2. Uitgangssituatie

- Een router die alleen standaard DHCP doet op 192.168.x.x
- Een server met openSUSE Tumbleweed
- Twee netwerkkaarten in de server
- Een unmanaged switch (geen configuratie mogelijk)
- PXE-capabele clients

De router kan geen speciale DHCP opties, geen next-server, geen PXE ondersteuning.

---

## 3. Kern van de oplossing

Maak een tweede, volledig gescheiden netwerk. Dit PXE netwerk heeft zijn eigen DHCP server die draait op de Tumbleweed server. De router blijft DHCP doen op het originele netwerk. De twee netwerken bestaan naast elkaar zonder conflicten.

---

## 4. Netwerk structuur

**Netwerk 1 - WAN (bestaande thuisnetwerk)**

- Router als DHCP server
- IP range: 192.168.x.x (wat de router ook gebruikt)
- Doel: internet toegang voor de server
- Aangesloten op NIC2 van de server

**Netwerk 2 - PXE LAN (nieuw netwerk)**

- Tumbleweed server als DHCP server
- Server eigen IP: 10.10.10.1
- DHCP range: 10.10.10.100 tot 10.10.10.200
- Subnetmasker: 255.255.255.0
- Doel: PXE clients voorzien van IP en boot informatie
- Aangesloten op NIC1 van de server en op de unmanaged switch

**Waarom deze keuzes**

De range 10.10.10.x is gekozen omdat die niet overlapt met de meeste standaard thuisnetwerken (die vaak 192.168.x.x gebruiken). Het subnet is klein (254 adressen) wat meer dan genoeg is voor een homelab. Het server IP is .1 wat de conventie volgt voor een gateway.

---

## 5. Server rollen en taken

De Tumbleweed server heeft meerdere rollen in dit ontwerp:

**DHCP server (dnsmasq)**

Geeft IP adressen uit aan PXE clients. Dit is nodig omdat de router dat niet doet op het PXE netwerk. De server reageert alleen op DHCP requests op de PXE interface, niet op de WAN interface.

**TFTP server (dnsmasq)**

Serveert het iPXE boot bestand (ipxe.efi) naar clients. Dit bestand is klein en wordt via TFTP geladen omdat dat het enige protocol is dat vroege PXE firmware begrijpt.

**Web server (netboot.xyz container)**

Serveert het boot menu via HTTP op poort 3000. Dit is het menu waar de gebruiker een besturingssysteem kiest om te installeren.

**NAT gateway**

Zorgt dat PXE clients via de server bij het internet kunnen komen. De clients hebben geen directe verbinding met de router; de server zit er tussen.

**Firewall**

Beperkt toegang tot de server en beschermt het PXE netwerk.

---

## 6. Boot proces stap voor stap

**Stap 1: Client boot**

De PXE client wordt aangezet en krijgt via het BIOS of UEFI de opdracht om via het netwerk te booten. De client zit alleen op de unmanaged switch, niet op het thuisnetwerk van de router.

**Stap 2: DHCP broadcast**

De client stuurt een DHCP broadcast uit over de switch. Omdat de router niet op dit netwerk zit, kan alleen de Tumbleweed server reageren.

**Stap 3: DHCP response**

dnsmasq op de server ziet de broadcast en reageert. Het geeft de client een vrij IP adres uit de range 10.10.10.100-200. Ook vertelt het de client waar de bootloader te vinden is: op 10.10.10.1 via TFTP, bestand ipxe.efi.

**Stap 4: Bootloader laden**

De client downloadt ipxe.efi via TFTP. Dit bestand werkt op zowel BIOS als UEFI systemen, dus één bestand voor alle clients.

**Stap 5: iPXE start**

Het iPXE bootloader start op. iPXE kan meer protocollen dan traditionele PXE, waaronder HTTP. Dit is robuuster en sneller dan TFTP.

**Stap 6: Menu laden**

iPXE volgt de instructies in de DHCP response (optie 209) en laadt het menu via HTTP van de server: http://10.10.10.1:3000/boot.ipxe

**Stap 7: Gebruiker kiest**

Het netboot.xyz menu verschijnt. De gebruiker kiest welk besturingssysteem of welke tool gestart moet worden.

**Stap 8: Installatie**

De client downloadt de installatiebestanden via de server. De server stuurt het verkeer door naar internet via NAT. De client ziet de router niet, maar heeft wel gewoon internet.

---

## 7. Waarom bepaalde keuzes zijn gemaakt

**Geen ProxyDHCP**

dnsmasq ondersteunt geen echte ProxyDHCP mode. ProxyDHCP is een techniek waarbij een server alleen PXE informatie geeft maar geen IP adressen. Omdat dit niet goed werkt in dnsmasq, is gekozen voor een volledige DHCP server op het PXE netwerk. Dit is veilig omdat er geen andere DHCP server op dat netwerk zit.

**Full DHCP op dedicated switch**

Omdat de switch unmanaged is en er geen andere DHCP server op dat netwerk kan komen, is full DHCP de eenvoudigste en meest betrouwbare oplossing. De router zit op een ander netwerk en stoort niet.

**NAT in plaats van routing**

NAT is gekozen omdat het geen extra configuratie op de router vereist. De router ziet alle verkeer van PXE clients alsof het van de server zelf komt. Dit werkt met elke router, zonder uitzondering.

**ipxe.efi als universeel boot bestand**

Dit bestand werkt op zowel BIOS als UEFI systemen. De lezer hoeft dus niet twee aparte boot bestanden te configureren. iPXE kan ook HTTP, wat betrouwbaarder is dan TFTP.

**HTTP voor het menu in plaats van TFTP**

HTTP is robuuster, sneller, en heeft betere foutafhandeling dan TFTP. Grote menu bestanden laden sneller en problemen zijn makkelijker te debuggen.

**10.10.10.x in plaats van 192.168.x.x**

De meeste standaard routers gebruiken 192.168.x.x. Door een ander bereik te kiezen voorkom je verwarring en conflicten. Het is voor de lezer direct duidelijk dat dit een apart netwerk is.

---

## 8. Persistentie en herstart

Alles moet werken na een reboot van de server.

**Netwerk configuratie**

De static IP configuratie van de PXE interface wordt opgeslagen in /etc/sysconfig/network/ifcfg-pxe0. De interface krijgt een vaste naam (pxe0) via een udev regel die kijkt naar het MAC adres. Na elke reboot heet de interface hetzelfde en heeft hij het juiste IP adres.

**Services**

dnsmasq en de podman container voor netboot.xyz zijn geconfigureerd als systemd services met restart=always. Als een service crasht, start systemd hem automatisch opnieuw. Bij de boot starten ze allebei vanzelf.

**Firewall**

firewalld is geconfigureerd met permanente regels voor zones en masquerade. Na een reboot zijn de zones en NAT regels weer actief.

**DHCP leases**

dnsmasq bewaart DHCP leases in /var/lib/misc/dnsmasq.leases. Als de server herstart, onthoudt hij welke IP adressen al waren uitgedeeld.

**Boot bestanden**

De iPXE boot bestanden staan in /srv/tftp en blijven gewoon bestaan na een reboot.

---

## 9. Wat de router moet kunnen

De router hoeft helemaal niets speciaals te kunnen. Geen DHCP opties, geen next-server, geen PXE ondersteuning, geen VLAN configuratie.

De router doet alleen:

- DHCP op zijn eigen netwerk (bijv. 192.168.1.x)
- Internet verkeer doorsturen

Meer is niet nodig. Dit ontwerp werkt met elke router, van goedkope ISP routers tot oude modems.

---

## 10. Wat je handmatig moet doen

Het playbook doet bijna alles automatisch, maar een paar dingen moet de lezer zelf doen.

**MAC adres achterhalen**

Je moet het MAC adres weten van de netwerkkaart die naar de PXE switch gaat. Dit doe je met:

    ip link show | grep -A1 enp | grep link/ether

Het MAC adres ziet eruit als aa:bb:cc:dd:ee:ff.

**MAC adres invullen**

In het playbook staat een regel:

    pxe_nic_mac: ""

De lezer vult hier het eigen MAC adres tussen de aanhalingstekens in.

**Kabels aansluiten**

- NIC1 van de server gaat naar de unmanaged switch
- NIC2 van de server gaat naar de router
- PXE clients gaan naar dezelfde unmanaged switch

**Playbook draaien**

    ansible-playbook netboot.yml --ask-become-pass

---

## 11. Troubleshooting

**Client krijgt geen IP**

Controleer of dnsmasq draait: systemctl status dnsmasq

Controleer of de server luistert op poort 67: ss -ulpn | grep :67

Controleer of de switch goed is aangesloten op de juiste netwerkkaart.

**Client laadt geen bootloader**

Test TFTP: tftp 10.10.10.1 -c get ipxe.efi

Controleer of het bestand bestaat: ls -la /srv/tftp/ipxe.efi

Controleer poort 69: ss -ulpn | grep :69

**Menu verschijnt niet**

Controleer of de container draait: podman ps

Test de web interface: curl http://localhost:3000

Controleer of het HTTP script werkt: curl http://10.10.10.1:3000/boot.ipxe

**Client heeft geen internet**

Controleer IP forwarding: sysctl net.ipv4.ip_forward

Controleer NAT regels: iptables -t nat -L -n -v

Controleer of de server zelf internet heeft: ping 1.1.1.1

**Alles werkt maar na reboot niet**

Controleer of de udev regel bestaat: cat /etc/udev/rules.d/99-pxe-netboot.rules

Controleer of de interface pxe0 bestaat: ip link show pxe0

Controleer of services enabled zijn: systemctl status dnsmasq netbootxyz

---

## 12. Samenvatting

Dit ontwerp lost het probleem op van een router die geen PXE ondersteunt.

De oplossing is een apart PXE netwerk met eigen DHCP op de Tumbleweed server. De router blijft ongewijzigd. Alles werkt na een reboot. Geen speciale router configuratie nodig.

Je hoeft alleen het MAC adres van de PXE netwerkkaart te achterhalen en in het playbook te zetten. De rest gebeurt automatisch.

Dit is een robuuste, productieklare oplossing voor homelab en SMB omgevingen.
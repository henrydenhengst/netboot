# Netboot Server Setup for Devuan (Fully Automated)

![Devuan](https://img.shields.io/badge/OS-Devuan-6f42c1?style=for-the-badge&logo=debian&logoColor=white)
![Shell Script](https://img.shields.io/badge/Script-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![PXE](https://img.shields.io/badge/Boot-PXE-blue?style=for-the-badge)
![Netboot](https://img.shields.io/badge/Netboot-Automated-orange?style=for-the-badge)

## Hardware vereisten

Minimale setup:
- Server met twee fysieke netwerkinterfaces (NICs)
- Eén netwerkkabel naar je bestaande router (voor WAN)
- Eén netwerkkabel naar een aparte switch (voor LAN)
- Netwerk switch (ongemanaged is prima) voor de PXE clients
- Stroomvoorziening voor server en switch

Optioneel maar handig:
- Extra netwerkkabels voor de PXE clients
- Monitor en toetsenbord (alleen tijdens installatie van Devuan)
- SSH toegang (als je server headless draait)

Niet nodig:
- Geen grafische kaart (headless is prima)
- Geen bijzondere netwerkkaarten (standaard NICs werken)

Belangrijk:
- De switch voor PXE clients mag NIET verbonden zijn met je bestaande router
- De server heeft twee aparte fysieke poorten nodig (USB NICs werken ook, maar fysiek is stabieler)

## Doel

Dit script zet automatisch een netboot server op op Devuan Linux.
Je hebt een server nodig met twee netwerkkaarten (NICs).
Het script vraagt niets, het doet alles zelf.

## Werking

De server krijgt twee netwerken:
- WAN (NIC 1): verbinding met jouw router (192.168.178.x)
- LAN (NIC 2): eigen netwerk voor PXE clients (10.0.0.1/24)

Clients die op de LAN switch zitten krijgen automatisch een IP adres (10.0.0.50 tot 10.0.0.200), kunnen via NAT internet op, en kunnen netbooten naar elke gewenste OS.

## Belangrijk

De LAN switch mag NOOIT verbonden zijn met jouw bestaande router.
Anders krijg je twee DHCP servers op hetzelfde netwerk.

## Wat het script installeert

- dnsmasq (DHCP + TFTP)
- nfs-kernel-server (voor network boot)
- nginx (web interface)
- iptables (voor NAT)
- netboot.xyz bootloaders
- Devuan netboot image

## Wat het script configureert

- Statisch IP 10.0.0.1 op de LAN interface
- DHCP server alleen op de LAN interface
- IP forwarding (clients kunnen internet op)
- NAT (MASQUERADE) via de WAN interface
- DNS forwarder via 9.9.9.9 en 1.1.1.1
- TFTP root in /srv/tftp
- NFS exports voor /srv/nfs en /srv/tftp
- Web interface op http://10.0.0.1

## Detectie logica

WAN interface:
- Eerste keus: heeft een IP in 192.168.178.x
- Fallback: interface van de default route

LAN interface:
- Eerste keus: fysieke NIC zonder IP, en niet de WAN
- Fallback: elke andere fysieke NIC

## Init systeem ondersteuning

Het script werkt op alle Devuan varianten:
- sysvinit
- OpenRC
- systemd

## Logging

Alle output wordt weggeschreven naar /var/log/netboot.log
Dit is handig voor later debuggen.

## Services

Na installatie draaien deze services:
- dnsmasq (DHCP + TFTP)
- tftpd-hpa
- nfs-kernel-server
- nginx

## Stop condities

Het script stopt met een foutmelding als:
- Het niet als root draait
- Het OS geen Devuan is
- Er geen WAN interface gevonden wordt
- Er geen LAN interface gevonden wordt
- Een download mislukt

## Waarschuwingen

Het script geeft een waarschuwing als:
- Er al een DHCP server actief is op het systeem
- De LAN fallback gebruikt wordt

## Benodigde packages

Het script installeert:
- dnsmasq
- tftpd-hpa
- nfs-kernel-server
- nginx
- wget, curl, unzip
- vim, net-tools, htop
- iptables, iptables-persistent

## Netwerk configuratie bestanden

- /etc/network/interfaces.d/<LAN_IF> (statisch IP)
- /etc/dnsmasq.conf (DHCP + TFTP)
- /etc/default/tftpd-hpa
- /etc/exports (NFS)
- /etc/nginx/sites-available/netboot

## Directory structuur

- /srv/tftp (bootloaders en netboot images)
- /srv/nfs (NFS shares)
- /var/www/netboot (web interface)

## Boot proces

1. Client stuurt DHCP broadcast
2. Dnsmasq geeft IP adres en vertelt waar de bootloader staat
3. Client haalt bootloader via TFTP
4. Bootloader (iPXE) start en haalt OS via internet (via NAT)
5. Netboot.xyz menu verschijnt

## Testen

Sluit een client aan op de LAN switch.
Zet PXE boot aan in de BIOS/UEFI.
De client moet een IP krijgen uit 10.0.0.50-200.
Het netboot.xyz menu moet verschijnen.

## Debuggen

Log bestand: /var/log/netboot.log
DHCP logs: tail -f /var/log/daemon.log | grep dnsmasq
Interfaces: ip -brief addr

## Direct uitvoeren
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/henrydenhengst/infraforge/main/netboot/post-install.sh)
```

## download → check → run

```bash
curl -fsSL -o post-install.sh https://raw.githubusercontent.com/henrydenhengst/infraforge/main/netboot/post-install.sh
```

## homelab pro

```bash
curl -fsSL https://raw.githubusercontent.com/henrydenhengst/infraforge/main/netboot/post-install.sh | tee post-install.sh
bash post-install.sh
```

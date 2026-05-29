# LCH Init - openSUSE Tumbleweed Installatie Handleiding

## Overzicht

Deze handleiding beschrijft de installatie van openSUSE Tumbleweed met LXQT desktop voor Linux Café Haarlem. Na de basisinstallatie wordt Ansible gebruikt voor de verdere configuratie.

Wat krijg je?

- openSUSE Tumbleweed (rolling release)
- LXQT desktop omgeving
- LightDM display manager
- SSH server met hardening
- Firewalld met SSH poort open
- Chrony tijdsynchronisatie (NL servers)
- Fail2ban voor extra beveiliging
- SSD TRIM ondersteuning
- Persistent logging (journald)
- NetworkManager (in plaats van wicked)

## Benodigdheden

- openSUSE Tumbleweed ISO (netinstall of full DVD)
- Minimaal 4GB RAM (8GB aanbevolen)
- Minimaal 40GB schijfruimte (SSD aanbevolen)
- Internetverbinding
- USB stick van 4GB of groter

## Stap 1: AutoYAST Installatie

### 1.1 Boot vanaf installatie media

Steek de USB in en boot er vanaf. Kies Installation. Selecteer taal: Dutch of English.

### 1.2 Handmatige installatie stappen

Network configuratie:
- Interface: DHCP (automatisch)
- Hostname: lch-init (tijdelijk)
- Domain: lch.lan

Partities:
- / (root) op hele schijf met ext4 bestandssysteem

Tip: Voor een SSD wordt TRIM later automatisch ingeschakeld.

### 1.3 Gebruikers aanmaken (BELANGRIJK!)

Root gebruiker:
- Geef een sterk wachtwoord
- Minimaal 12 karakters
- Mix van letters, cijfers en symbolen
- Bewaar veilig in password manager

Gebruiker lch:
- Username: lch
- Full name: Linux Café Haarlem
- Password: kies een sterk wachtwoord
- Vink WEL aan: Default group: wheel (sudo rechten)
- Vink WEL aan: Default group: video (voor desktop)
- Vink NIET aan: Disable user login
- Vink NIET aan: Automatic login (veiliger)

Waarschuwing: Zonder de wheel groep werkt sudo niet en faalt het Ansible script!

### 1.4 Software selectie

Kies tijdens installatie:
- LXQT Desktop Environment
- Base System
- X Window System

Ansible wordt later door het playbook geïnstalleerd.

## Stap 2: Post-Installatie met Ansible

### 2.1 Inloggen na reboot

Niet inloggen als root! Log in als lch met je wachtwoord.

### 2.2 Controleer of Ansible werkt

Check of Ansible geïnstalleerd is:

    `ansible --version`

Mocht Ansible ontbreken:

    `sudo zypper install ansible python3`

### 2.3 Maak het playbook bestand

Kopieer de inhoud van lch-postinstall.yml naar een bestand:

    `vim lch-postinstall.yml`

Of download van een server:

    `wget http://jouw-server/lch-postinstall.yml`

### 2.4 Draai het playbook

Voor de volledige installatie:

    `ansible-playbook -K lch-postinstall.yml`

Alleen basis (geen desktop, sneller voor servers):

    `ansible-playbook -K lch-postinstall.yml --skip-tags "desktop"`

Alleen updates (na eerdere installatie):

    `ansible-playbook -K lch-postinstall.yml --tags "updates"`

Je wordt gevraagd om het sudo wachtwoord. Typ het wachtwoord van lch.

### 2.5 Wat gebeurt er?

- Hostname wordt automatisch ingesteld op basis van serial of uuid
- lch krijgt sudo rechten
- SSH hardening (geen root login, geen wachtwoord auth)
- Firewall opent alleen SSH poort
- Systeem updates (zypper dup - kan 5-30 minuten duren)
- Chrony met Nederlandse NTP servers
- NetworkManager wordt ingeschakeld, wicked uitgeschakeld
- Persistent logging met max 1GB
- LightDM display manager configuratie
- Fail2ban voor SSH beveiliging

## Stap 3: Na de installatie

### 3.1 Controleer de configuratie

Hostname checken:

    `hostname`

Sudo checken:

    `sudo whoami`

Dit moet "root" tonen.

SSH status:

    `sudo systemctl status sshd`

Firewall status:

    `sudo firewall-cmd --list-services`

Tijdsynchronisatie:

    `timedatectl status`

Fail2ban status:

    `sudo fail2ban-client status sshd`

### 3.2 Reboot indien nodig

Als er een kernel update was:

    `sudo reboot`

### 3.3 Eindresultaat

Je ziet een samenvatting met alle configuratie. Het systeem is nu klaar voor gebruik.

## Probleemoplossing

### Probleem: sudo: command not found

Log in als root via de console:
```bash
    su -
    zypper install sudo
    usermod -aG wheel lch
    exit
```
### Probleem: Ansible playbook faalt

Check syntax:

    `ansible-playbook --syntax-check lch-postinstall.yml`

Draai met extra uitvoer:

    `ansible-playbook -K lch-postinstall.yml -vvv`

Draai alleen specifieke delen:

    `ansible-playbook -K lch-postinstall.yml --tags "ssh,firewall"`

### Probleem: Geen internet na installatie

Check NetworkManager:

    `sudo systemctl status NetworkManager`

Start handmatig:

    `sudo systemctl start NetworkManager`

Verbind met netwerk (voorbeeld):

    `sudo nmcli device connect eth0`

### Probleem: LightDM start niet

Check status:

    `sudo systemctl status lightdm`

Bekijk logs:

    `journalctl -u lightdm`

Start X handmatig als fallback:

    `startx`

## Handige commando's

Systeem updates na installatie:

    `sudo zypper dup`

Check of reboot nodig is:

    `ls /var/run/reboot-needed`

Logs bekijken:

    `journalctl -f`

Services status:

    `sudo systemctl status sshd firewalld chronyd fail2ban`

IP adres bekijken:

    `ip addr show`

WiFi verbinden (indien geen desktop):
```bash
    nmcli device wifi list
    nmcli device wifi connect "SSID" password "wachtwoord"
```
Vanaf een andere machine verbinden:

    `ssh lch@[ip-adres]`

SSH key instellen (aanbevolen):
```bash
    ssh-keygen -t ed25519
    ssh-copy-id lch@[ip-adres]
```
## Checklist

Tijdens installatie:

- Root wachtwoord ingesteld
- Gebruiker lch aangemaakt
- Groep WHEEL aangevinkt
- Groep VIDEO aangevinkt
- LXQT pattern geselecteerd

Na installatie:

- Ingelogd als lch (niet root)
- Ansible playbook gedownload
- Playbook gedraaid met -K
- Reboot uitgevoerd indien nodig

Installatie succesvol! Je systeem is klaar voor gebruik.
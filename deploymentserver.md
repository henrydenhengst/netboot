# 🚀 Debian 13 Deployment Server - Complete Setup Guide

BIOS-check is een must: Zet de machine aan en druk op F10 om de BIOS te openen. Controleer of PXE-boot is ingeschakeld en zet de boot-modus op UEFI voor de beste resultaten.

1. Zet de Z420 aan en druk op F10 voor de BIOS
2. Zoek naar "Boot Mode" of "Option ROM Launch Policy"
3. Zet deze op UEFI-only of UEFI (niet Legacy)
4. Zorg dat "Network Boot" of "PXE" is ingeschakeld
5. Sla op en start opnieuw op

## 📋 Overzicht

Dit project bevat alles wat je nodig hebt om een **volledige PXE-deployment server** op te zetten voor Debian 13 (Trixie). Het systeem werkt op alle 64-bit computers van 2006 tot 2026 en ondersteunt zowel BIOS als UEFI.

Je kunt kiezen uit vijf verschillende installatieprofielen:
- **XFCE** - Lichtgewicht, ideaal voor oudere hardware
- **GNOME** - Moderne desktop, volledige ervaring
- **KDE Plasma** - Fraaie desktop, veel aanpassingsopties
- **Server** - Minimale installatie zonder GUI
- **Custom** - Volledig aanpasbaar naar eigen wens

Alle clients loggen hun activiteiten naar de server, zodat je centraal kunt zien wat er gebeurt. De installatie verloopt volledig automatisch en gebruikt encrypted wachtwoorden voor beveiliging. Het post-installatie script detecteert automatisch de hardware en past de configuratie aan op basis van RAM, SSD of HDD, en of het een laptop of desktop is.

---

## 🖥️ Wat je nodig hebt

### Voor de server (Deployment Server)
Je hebt een machine nodig met Debian 12 of 13 (minimale installatie). De processor moet 64-bit zijn en je hebt minimaal 2GB RAM nodig, maar 4GB is aanbevolen. Voor de opslag heb je minimaal 20GB vrije schijfruimte nodig, want de Debian DVD van 4GB wordt gedownload en er komen nog packages bij. De server heeft één netwerkpoort die een vast IP-adres krijgt op 10.0.0.1. Tijdens de installatie heb je internet nodig om alle bestanden te downloaden, maar na de installatie kunnen clients offline blijven.

### Voor de clients (Te installeren machines)
Elke client moet een 64-bit processor hebben, wat betekent dat alle computers vanaf ongeveer 2006 tot 2026 ondersteund worden. De client heeft minimaal 1GB RAM nodig, maar 2GB is aanbevolen voor een soepele ervaring met XFCE. Voor opslag is 20GB vrije schijfruimte nodig. De client moet via het netwerk kunnen opstarten, dus PXE-boot moet ondersteund worden in de BIOS of UEFI. Dit is standaard op de meeste zakelijke en veel consumenten moederborden.

---

## 🚀 Stap-voor-stap installatie

### Deel 1: De server installeren en voorbereiden

Begin met een minimale installatie van Debian 13 op de server. Tijdens de installatie kies je alleen voor "Standard system utilities" zodat je een schone basis hebt. Zorg dat je het netwerk configureert met een vast IP-adres of laat DHCP het doen tijdens de installatie (het script zet later een vast IP).

Nadat Debian is geïnstalleerd, log je in als root. Download het setup script naar de server of kopieer het handmatig. Het script heet `deploy-server.sh` en is alles-in-één. Het installeert alle packages, configureert het netwerk, zet de PXE server op, downloadt de Debian DVD, maakt alle preseed bestanden aan, configureert remote logging, en start alle services.

Maak het script uitvoerbaar met `chmod +x` en draai het als root. Het script vraagt om bevestiging voordat het begint, dus je hebt de kans om te controleren of je de juiste machine hebt. Het script doet de rest automatisch. Afhankelijk van je internet snelheid duurt dit ongeveer 20 tot 30 minuten, omdat de Debian DVD van 4GB gedownload moet worden.

Na het script is het verstandig om de server opnieuw op te starten met `reboot`. Controleer daarna of alle services draaien met `systemctl status dnsmasq`, `systemctl status nfs-kernel-server`, en `systemctl status rsyslog`. Je kunt ook testen of TFTP werkt met `tftp 10.0.0.1 -c get pxelinux.0` en of NFS werkt met `showmount -e 10.0.0.1`.

### Deel 2: Een client installeren via PXE

Sluit een client aan op dezelfde switch als de server. Zet de client aan en ga naar de BIOS of UEFI. Zet de bootvolgorde zo dat "Network Boot" of "PXE Boot" als eerste staat. Soms staat dit onder "Boot Options" of "Advanced Settings".

Sla de instellingen op en start de client opnieuw op. De client zal nu automatisch een IP-adres krijgen van de server via DHCP. Vervolgens wordt het PXE-menu geladen van de server. Dit menu toont alle beschikbare installatieopties.

Kies een optie door op het juiste nummer te drukken. Als je niets doet, wordt na 30 seconden automatisch de XFCE installatie gestart. De installatie verloopt volledig automatisch: de schijf wordt gepartitioneerd, het systeem wordt geïnstalleerd, de gekozen desktop wordt toegevoegd, de NFS repository wordt gemount, en het post-installatie script draait.

Na ongeveer 10 tot 15 minuten is de installatie voltooid en wordt de client opnieuw opgestart. Bij het opstarten wordt het post-installatie script nog een keer uitgevoerd om alle drivers en optimalisaties toe te passen. De client is dan klaar voor gebruik.

### Deel 3: Wat er automatisch gebeurt op de client

Het post-installatie script detecteert eerst de hardware: de CPU, hoeveel RAM er is, of er een SSD of HDD is, of het een laptop of desktop is, en welke GPU erin zit. Op basis van deze detectie worden de juiste drivers en optimalisaties gekozen.

Als er minder dan 2GB RAM is, wordt een minimale XFCE installatie gedaan en wordt er een swap bestand aangemaakt. Bij meer RAM wordt de volledige desktop geïnstalleerd. SSD's krijgen TRIM ingeschakeld voor betere prestaties en langere levensduur. Laptops krijgen TLP voor energiebeheer en batterij optimalisaties.

De GPU drivers worden automatisch gekozen op basis van de gedetecteerde hardware. Voor oude NVIDIA kaarten (GeForce 7, 8, 9 series) worden legacy drivers geïnstalleerd. Voor moderne NVIDIA kaarten worden de nieuwste drivers gebruikt. Hetzelfde geldt voor AMD en Intel.

Daarna worden alle apps geïnstalleerd: Firefox, Thunderbird, VLC, GIMP, LibreOffice, en vele anderen. Het systeem wordt geoptimaliseerd met zRam, sysctl aanpassingen, en SSD TRIM. De firewall (UFW) wordt ingeschakeld en alleen SSH wordt toegestaan. Automatische beveiligingsupdates worden geconfigureerd.

---

## 📝 Handige commando's en informatie

### Locatie van bestanden op de server

Alle PXE-gerelateerde bestanden staan in `/srv/tftp/`. De preseed bestanden voor automatische installatie staan in `/srv/tftp/preseed/` en heten `xfce.cfg`, `gnome.cfg`, `kde.cfg`, `server.cfg`, en `custom.cfg`. Het post-installatie script voor clients staat in `/srv/tftp/scripts/post-install.sh`. De Debian DVD is gemount in `/srv/debian-repo/` en wordt gedeeld via NFS.

### Wachtwoorden voor clients

Standaard worden deze wachtwoorden gebruikt, maar ze zijn encrypted opgeslagen in de preseed bestanden. Het is aan te raden om ze te wijzigen voor productie gebruik:
- XFCE gebruiker: gebruikersnaam `xfce`, wachtwoord `xfce123`
- GNOME gebruiker: gebruikersnaam `gnome`, wachtwoord `gnome123`
- KDE gebruiker: gebruikersnaam `kde`, wachtwoord `kde123`
- Server admin: gebruikersnaam `admin`, wachtwoord `admin123`

Om de wachtwoorden te wijzigen, pas je de variabelen aan in het begin van het `deploymentserver.sh` script. De variabelen heten `XFCE_PASS`, `GNOME_PASS`, `KDE_PASS`, en `ADMIN_PASS`. Na het wijzigen draai je het script opnieuw.

### Logbestanden

De server houdt verschillende logbestanden bij:
- `/var/log/dnsmasq.log` - DHCP en TFTP activiteit
- `/var/log/client-logs.log` - Alle logs van alle clients
- `/var/log/deploy-server.log` - Log van het server setup script
- `/var/log/syslog` - Algemene systeem logs

Op elke client staat `/var/log/deployment.log` met de output van het post-installatie script. Deze logs worden ook doorgestuurd naar de server.

### Problemen oplossen

Als een client geen IP-adres krijgt, controleer dan of de client op dezelfde switch zit als de server en of de server draait. Kijk in `/var/log/dnsmasq.log` of er DHCP verzoeken binnenkomen.

Als de client wel een IP krijgt maar geen PXE menu laadt, controleer dan of de TFTP root correct is ingesteld. De bestanden moeten in `/srv/tftp/` staan en de bootloader moet `pxelinux.0` heten in de BIOS map.

Als de installatie start maar vastloopt, kijk dan naar de logs op de client door tijdens de installatie naar een andere console te schakelen met Alt+F2, Alt+F3, etc. Daar kun je zien wat er misgaat.

Als de NFS repository niet gemount kan worden, controleer dan of de DVD nog gemount is op de server met `mount | grep debian-repo`. Soms moet de DVD opnieuw gemount worden na een herstart.

---

## 🎯 Volgende stappen

Na een geslaagde installatie kun je het systeem verder uitbreiden. Je kunt extra desktops toevoegen door nieuwe preseed bestanden te maken in `/srv/tftp/preseed/` en ze toe te voegen aan het PXE menu in `/srv/tftp/pxelinux.cfg/default`.

Je kunt ook de post-installatie scripts aanpassen om extra packages te installeren of specifieke configuraties toe te voegen. Het script is modulair opgebouwd, dus je kunt functies toevoegen of uitschakelen door ze te becommentariëren.

---

## 📊 Maximaal aantal gelijktijdige clients

| Component | Capaciteit | Opmerking |
|-----------|------------|-----------|
| HP Z420 server | 100+ clients | Xeon, 32GB RAM, SSD |
| Netwerkkaart | 100 clients | Intel Gigabit |
| Switch | Afhankelijk | Zorg voor voldoende poorten |
| DHCP pool | 101 adressen | 10.0.0.100 t/m 10.0.0.200 |

---

## 🎯 Praktische limieten

| Factor | Limiet | Uitleg |
|--------|--------|--------|
| Server | 100+ | CPU en RAM zijn prima |
| Netwerk | 50-100 | Afhankelijk van switch en kabels |
| Stroom | Praktisch | 100 computers = veel stopcontacten |
| Ruimte | Praktisch | 100 computers = veel tafels/rekken |
| Tijd | 10-15 min | Alle clients tegelijk klaar |

---

## ✅ Conclusie

Met de HP Z420 kun je 100 clients tegelijk installeren. De server kan het aan. De beperkingen zitten in de praktijk: switch, stroom, ruimte en bekabeling.

**De clients zijn allemaal klaar in 10-15 minuten.** 🚀

---

## 📚 Meer informatie

- Debian 13 officiële documentatie: https://www.debian.org/doc/
- Dnsmasq handleiding: https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html
- SYSLINUX PXE documentatie: https://wiki.syslinux.org/wiki/index.php/PXELINUX
- Preseed documentatie: https://www.debian.org/releases/stable/amd64/apb.en.html

---

## ✅ Succes!

Je hebt nu een volledig functionerende deployment server die elke 64-bit computer van de afgelopen 20 jaar kan voorzien van een werkende Debian 13 installatie. Het systeem is ontworpen om zo eenvoudig mogelijk te zijn, maar toch alle flexibiliteit te bieden die je nodig hebt.

Veel succes met je deployments! 🎉
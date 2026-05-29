#!/bin/bash
# =============================================================================
# lch-check.sh - LCH Init systeem check
# =============================================================================

# Kleuren
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Tellers
PASS=0
FAIL=0

check_pass() {
    echo -e "${GREEN}✅ PASS${NC} - $1"
    ((PASS++))
}

check_fail() {
    echo -e "${RED}❌ FAIL${NC} - $1"
    ((FAIL++))
}

check_warn() {
    echo -e "${YELLOW}⚠️ WARN${NC} - $1"
}

echo ""
echo "=========================================="
echo "     LCH INIT - SYSTEEM CHECK"
echo "=========================================="
echo ""

# -----------------------------------------------------------------------------
# 1. USER CHECK
# -----------------------------------------------------------------------------
echo "--- GEBRUIKER ---"

CURRENT_USER=$(whoami)
if [ "$CURRENT_USER" = "lch" ]; then
    check_pass "Ingelogd als lch"
else
    check_fail "Ingelogd als $CURRENT_USER (moet lch zijn)"
fi

if sudo -n true 2>/dev/null; then
    check_pass "Sudo rechten werken"
else
    check_fail "Sudo rechten werken niet"
fi

# -----------------------------------------------------------------------------
# 2. PACKAGES CHECK
# -----------------------------------------------------------------------------
echo ""
echo "--- PACKAGES ---"

for pkg in ansible git python3; do
    if rpm -q $pkg &>/dev/null; then
        check_pass "$pkg is geïnstalleerd"
    else
        check_fail "$pkg is niet geïnstalleerd"
    fi
done

# -----------------------------------------------------------------------------
# 3. SERVICES CHECK
# -----------------------------------------------------------------------------
echo ""
echo "--- SERVICES ---"

for svc in sshd firewalld chronyd NetworkManager; do
    if systemctl is-active --quiet $svc; then
        check_pass "$svc is actief"
    else
        check_fail "$svc is niet actief"
    fi
done

# -----------------------------------------------------------------------------
# 4. FIREWALL CHECK
# -----------------------------------------------------------------------------
echo ""
echo "--- FIREWALL ---"

if firewall-cmd --list-services 2>/dev/null | grep -q ssh; then
    check_pass "SSH poort is open"
else
    check_fail "SSH poort is niet open"
fi

# -----------------------------------------------------------------------------
# 5. SSH HARDENING CHECK
# -----------------------------------------------------------------------------
echo ""
echo "--- SSH HARDENING ---"

if grep -q "^PermitRootLogin no" /etc/ssh/sshd_config; then
    check_pass "Root login uitgeschakeld"
else
    check_fail "Root login nog ingeschakeld"
fi

if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config; then
    check_pass "Wachtwoord auth uitgeschakeld"
else
    check_fail "Wachtwoord auth nog ingeschakeld"
fi

if grep -q "^AllowUsers lch" /etc/ssh/sshd_config; then
    check_pass "Alleen lch mag inloggen"
else
    check_warn "AllowUsers niet geconfigureerd"
fi

# -----------------------------------------------------------------------------
# 6. HOSTNAME CHECK
# -----------------------------------------------------------------------------
echo ""
echo "--- HOSTNAME ---"

HOSTNAME=$(hostname)
if [[ "$HOSTNAME" =~ ^lch- ]]; then
    check_pass "Hostname correct: $HOSTNAME"
else
    check_fail "Hostname incorrect: $HOSTNAME (moet beginnen met lch-)"
fi

# -----------------------------------------------------------------------------
# 7. SSD TRIM CHECK
# -----------------------------------------------------------------------------
echo ""
echo "--- SSD TRIM ---"

if systemctl is-active --quiet fstrim.timer; then
    check_pass "fstrim.timer is actief"
else
    if lsblk -dno rota 2>/dev/null | grep -q "^0$"; then
        check_fail "fstrim.timer niet actief op SSD"
    else
        check_warn "Geen SSD gedetecteerd (fstrim niet nodig)"
    fi
fi

# -----------------------------------------------------------------------------
# 8. TIJDSSYNCHRONISATIE
# -----------------------------------------------------------------------------
echo ""
echo "--- TIJDSSYNCHRONISATIE ---"

if timedatectl status 2>/dev/null | grep -q "synchronized: yes"; then
    check_pass "Tijd is gesynchroniseerd"
else
    check_fail "Tijd is niet gesynchroniseerd"
fi

if grep -q "nl.pool.ntp.org" /etc/chrony.conf 2>/dev/null; then
    check_pass "Nederlandse NTP servers geconfigureerd"
else
    check_warn "Geen Nederlandse NTP servers"
fi

# -----------------------------------------------------------------------------
# 9. FAIL2BAN CHECK
# -----------------------------------------------------------------------------
echo ""
echo "--- FAIL2BAN ---"

if systemctl is-active --quiet fail2ban; then
    check_pass "fail2ban is actief"
    if fail2ban-client status sshd 2>/dev/null | grep -q "Banned.*[1-9]"; then
        BANNED=$(fail2ban-client status sshd 2>/dev/null | grep "Banned" | awk '{print $4}')
        check_warn "$BANNED IP(s) zijn verbannen"
    fi
else
    check_warn "fail2ban is niet actief (optioneel)"
fi

# -----------------------------------------------------------------------------
# 10. LOGGING CHECK
# -----------------------------------------------------------------------------
echo ""
echo "--- LOGGING ---"

if [ -d "/var/log/journal" ]; then
    check_pass "Persistent journald actief"
else
    check_warn "Persistent journald niet actief"
fi

# -----------------------------------------------------------------------------
# SAMENVATTING
# -----------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "              SAMENVATTING"
echo "=========================================="
echo -e "${GREEN}Geslaagd: $PASS${NC}"
echo -e "${RED}Gefaald: $FAIL${NC}"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}✅ ALLES GOED! Systeem is correct geconfigureerd.${NC}"
else
    echo -e "${RED}❌ Er zijn $FAIL proble(a)m(en). Draai het playbook opnieuw.${NC}"
    echo ""
    echo "Herstel commando:"
    echo "  ansible-playbook -K lch-postinstall.yml"
fi

echo ""
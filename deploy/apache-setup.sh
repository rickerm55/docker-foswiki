#!/bin/sh
# Install deploy/apache-site.conf: Apache serves port 80 (challenges + redirect)
# and port 443 (TLS, proxied to the foswiki container on 127.0.0.1:8443).
# Also turns PHP off and uses the event MPM. See deploy/FRONT-END.md.
# Safe to rerun after editing apache-site.conf.
# Run with: sudo deploy/apache-setup.sh
set -eu

SITE=/etc/apache2/sites-available/000-default.conf
BACKUP=/etc/apache2/000-default.conf.bak-$(date +%Y%m%d%H%M%S)
HERE=$(dirname "$(readlink -f "$0")")
MODS="ssl socache_shmcb proxy proxy_http headers alias"

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

echo "== Installing site config (backup: $BACKUP)"
cp -p "$SITE" "$BACKUP"
install -o root -g root -m 644 "$HERE/apache-site.conf" "$SITE"

echo "== Enabling modules: $MODS"
# shellcheck disable=SC2086
a2enmod -q $MODS

# Nothing on kube uses PHP. Turning it off lets Apache use the event MPM
# (mod_php requires prefork) and shrinks what the internet can reach.
PHP_MODS=$(ls /etc/apache2/mods-enabled/ 2>/dev/null | sed -n 's/^\(php[0-9.]*\)\.load$/\1/p')
PREFORK=0; [ -e /etc/apache2/mods-enabled/mpm_prefork.load ] && PREFORK=1
if [ -n "$PHP_MODS" ] || [ "$PREFORK" = 1 ]; then
    echo "== Disabling PHP ($PHP_MODS) and switching to the event MPM"
    # shellcheck disable=SC2086
    [ -n "$PHP_MODS" ] && a2dismod -q $PHP_MODS
    [ "$PREFORK" = 1 ] && a2dismod -q mpm_prefork
    a2enmod -q mpm_event
fi

restore() {
    cp -p "$BACKUP" "$SITE"
    if [ "$PREFORK" = 1 ]; then
        a2dismod -q mpm_event || true
        a2enmod -q mpm_prefork || true
    fi
    # shellcheck disable=SC2086
    [ -n "$PHP_MODS" ] && { a2enmod -q $PHP_MODS || true; }
    systemctl restart apache2 || true
    echo "Restored the previous site config, MPM and PHP (new modules left enabled; harmless)." >&2
    exit 1
}

apache2ctl configtest || { echo "Config test failed." >&2; restore; }
systemctl restart apache2 || { echo "Apache failed to restart." >&2; restore; }

echo "== Removing /var/www/html/test.txt (old public test file)"
rm -f /var/www/html/test.txt

echo "== Checking Apache locally (doesn't depend on the router)"
fail=0
check() { # label expected actual
    if [ "$3" = "$2" ]; then echo "ok   $1 ($3)"; else echo "FAIL $1: expected $2, got $3"; fail=1; fi
}
check "port 80 redirects to https" 301 \
    "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: wiki.machs.org' http://127.0.0.1/Machs/WebHome)"
probe=apache-check-$$
echo ok > "/var/www/html/.well-known/acme-challenge/$probe"
check "challenge path served on port 80" 200 \
    "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: wiki.machs.org' "http://127.0.0.1/.well-known/acme-challenge/$probe")"
rm -f "/var/www/html/.well-known/acme-challenge/$probe"
RES="--resolve wiki.machs.org:443:127.0.0.1"
# shellcheck disable=SC2086
check "port 443 serves the wiki with a valid cert" 200 \
    "$(curl -s $RES -o /dev/null -w '%{http_code}' https://wiki.machs.org/Machs/WebHome)"
# shellcheck disable=SC2086
check "HSTS header sent" yes \
    "$(curl -s $RES -D - -o /dev/null https://wiki.machs.org/Machs/WebHome | grep -qi '^strict-transport-security:' && echo yes || echo no)"
check "event MPM in use" event \
    "$(apache2ctl -V 2>/dev/null | awk -F': *' '/Server MPM/{print tolower($2)}')"
check "PHP module off" none \
    "$(apache2ctl -M 2>/dev/null | grep -q php && echo loaded || echo none)"
# shellcheck disable=SC2086
check "port 443 response comes via Apache" apache \
    "$(curl -s $RES -D - -o /dev/null https://wiki.machs.org/Machs/WebHome | tr -d '\r' | awk -F': ' 'tolower($1)=="x-front-end"{print $2}')"

if [ "$fail" = 1 ]; then
    echo "A check failed. Apache is the public front end, so check the site now (deploy/front-end-check.sh)." >&2
    echo "To undo the site config: sudo cp -p $BACKUP $SITE && sudo systemctl restart apache2" >&2
    exit 1
fi
echo "== Done. Check the public site: deploy/front-end-check.sh"
echo "   To undo: sudo cp -p $BACKUP $SITE && sudo systemctl restart apache2"

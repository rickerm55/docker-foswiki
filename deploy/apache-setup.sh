#!/bin/sh
# Install deploy/apache-site.conf: Apache serves port 80 (challenges + redirect)
# and port 443 (TLS, proxied to the foswiki container on 127.0.0.1:8443).
# Doesn't change where the router sends traffic; see deploy/FRONT-END.md.
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

restore() {
    cp -p "$BACKUP" "$SITE"
    systemctl restart apache2 || true
    echo "Restored the previous site config (modules left enabled; they're harmless)." >&2
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
check "port 443 response comes via Apache" apache \
    "$(curl -s $RES -D - -o /dev/null https://wiki.machs.org/Machs/WebHome | tr -d '\r' | awk -F': ' 'tolower($1)=="x-front-end"{print $2}')"

if [ "$fail" = 1 ]; then
    echo "A check failed. Public traffic is unaffected unless the router points 443 at Apache." >&2
    echo "To undo: sudo cp -p $BACKUP $SITE && sudo systemctl restart apache2" >&2
    exit 1
fi
echo "== Done. Apache is ready; public traffic goes wherever the router points 443."
echo "   Check which: deploy/front-end-check.sh    Switch: see deploy/FRONT-END.md"
echo "   To undo: sudo cp -p $BACKUP $SITE && sudo systemctl restart apache2"

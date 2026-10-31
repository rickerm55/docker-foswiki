#!/bin/sh
# One-time cutover to the /etc/letsencrypt lineage. Run with: sudo deploy/install.sh
# Stops before changing anything if the lineage or its renewal doesn't check out.
set -eu

LIVE=/etc/letsencrypt/live/wiki.machs.org
HOOK=/etc/letsencrypt/renewal-hooks/deploy/foswiki-cert-deploy
# sites-enabled holds a symlink to this file; edit the target so the link survives.
SITE=/etc/apache2/sites-available/000-default.conf
BACKUP=/etc/apache2/000-default.conf.bak-$(date +%Y%m%d%H%M%S)
HERE=$(dirname "$(readlink -f "$0")")

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

echo "== Checking lineage"
certbot certificates --cert-name wiki.machs.org
openssl x509 -in "$LIVE/fullchain.pem" -noout -checkend $((30 * 24 * 3600)) \
    || { echo "$LIVE cert has under 30 days left; stopping." >&2; exit 1; }

echo "== Dry-run renewal (webroot validation)"
certbot renew --cert-name wiki.machs.org --dry-run

echo "== Installing deploy hook"
install -o root -g root -m 755 "$HERE/cert-deploy-hook.sh" "$HOOK"

echo "== Pointing Apache at $LIVE (backup: $BACKUP)"
cp -p "$SITE" "$BACKUP"
sed -i \
    -e "s|^\( *SSLCertificateFile \).*|\1$LIVE/fullchain.pem|" \
    -e "s|^\( *SSLCertificateKeyFile \).*|\1$LIVE/privkey.pem|" \
    "$SITE"
if ! apache2ctl configtest; then
    cp -p "$BACKUP" "$SITE"
    echo "Apache config test failed; restored the backup." >&2
    exit 1
fi

echo "== Running deploy hook"
RENEWED_LINEAGE=$LIVE RENEWED_DOMAINS=wiki.machs.org "$HOOK"

echo "== Done. To undo Apache: sudo cp -p $BACKUP $SITE && sudo systemctl reload apache2"

#!/bin/sh
# One-time cutover to the /etc/letsencrypt lineage. Run with: sudo deploy/install.sh
# Stops before changing anything if the lineage or its renewal doesn't check out.
set -eu

LIVE=/etc/letsencrypt/live/wiki.machs.org
HOOK=/etc/letsencrypt/renewal-hooks/deploy/foswiki-cert-deploy
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

echo "== Setting up Apache (port 80 challenges/redirect, port 443 proxy)"
"$HERE/apache-setup.sh"

echo "== Running deploy hook"
RENEWED_LINEAGE=$LIVE RENEWED_DOMAINS=wiki.machs.org "$HOOK"

echo "== Done."

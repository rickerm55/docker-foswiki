#!/bin/sh
# Daily check of the certs actually being served. Emails an alert if the public
# cert is unreachable or near expiry, or if the container's cert differs from it.
# --test always sends, to prove mail delivery.
set -u

HOST=wiki.machs.org
MAIL_TO=stores@machs.org
MIN_SECONDS=$((21 * 24 * 3600))

served_cert() {
    echo | timeout 15 openssl s_client -connect "$1" -servername "$HOST" 2>/dev/null \
        | openssl x509 2>/dev/null
}

problems=""
add_problem() {
    problems="$problems$1
"
}

public_cert=$(served_cert "$HOST:443")
if [ -z "$public_cert" ]; then
    add_problem "Could not read a certificate from $HOST:443."
    public_end=unknown
else
    public_end=$(echo "$public_cert" | openssl x509 -noout -enddate | cut -d= -f2)
    echo "$public_cert" | openssl x509 -noout -checkend "$MIN_SECONDS" >/dev/null \
        || add_problem "$HOST:443 cert expires $public_end, under 21 days away."
fi

container_cert=$(served_cert localhost:8443)
if [ -z "$container_cert" ]; then
    add_problem "Could not read a certificate from the container on localhost:8443."
    container_end=unknown
else
    container_end=$(echo "$container_cert" | openssl x509 -noout -enddate | cut -d= -f2)
    [ "$container_end" = "$public_end" ] \
        || add_problem "Container cert expires $container_end but the public cert expires $public_end."
fi

details="Public ($HOST:443) expires: $public_end
Container (localhost:8443) expires: $container_end

Host: $(hostname)
Renewal runs from certbot.timer. Check: sudo certbot certificates; journalctl -u certbot.service"

if [ "${1:-}" = "--test" ]; then
    printf 'Test of the certificate alert. No action needed.\n\n%s%s\n' "$problems" "$details" \
        | mail -s "TEST: $HOST certificate check" "$MAIL_TO"
elif [ -n "$problems" ]; then
    printf '%s\n%s\n' "$problems" "$details" \
        | mail -s "ALERT: $HOST certificate problem" "$MAIL_TO"
fi

printf '%s%s\n' "$problems" "$details"
[ -z "$problems" ]

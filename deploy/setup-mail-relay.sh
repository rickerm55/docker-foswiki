#!/bin/sh
# One-time setup: sends this server's mail through Gmail so alerts can be delivered.
# Run with: sudo deploy/setup-mail-relay.sh
# Prompts for a Google app password; it is stored only in /etc/postfix/sasl_passwd*.
set -eu

# Must be a real Google login, not an alias. A low-use account limits what a
# leaked app password can reach.
ACCOUNT=rickerm@gmail.com
RELAY='[smtp.gmail.com]:587'
PASSWD_FILE=/etc/postfix/sasl_passwd
HERE=$(dirname "$(readlink -f "$0")")

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

printf 'Google app password for %s (hidden): ' "$ACCOUNT"
stty -echo
trap 'stty echo' EXIT
read -r password
stty echo
trap - EXIT
echo
password=$(printf '%s' "$password" | tr -d ' ')
[ -n "$password" ] || { echo "No password entered; nothing changed." >&2; exit 1; }

echo "== Writing credentials"
install -m 600 /dev/null "$PASSWD_FILE"
printf '%s %s:%s\n' "$RELAY" "$ACCOUNT" "$password" > "$PASSWD_FILE"
postmap "$PASSWD_FILE"
chmod 600 "$PASSWD_FILE.db"

echo "== Configuring postfix"
postconf -e "relayhost=$RELAY" smtp_sasl_auth_enable=yes \
    "smtp_sasl_password_maps=hash:$PASSWD_FILE" \
    smtp_sasl_security_options=noanonymous smtp_tls_security_level=encrypt \
    smtp_address_preference=ipv4
systemctl reload postfix
postconf relayhost

echo "== Sending test email"
"$HERE/cert-check.sh" --test || true
sleep 8

echo "== Delivery result"
grep 'postfix/smtp\[' /var/log/mail.log | tail -n 3 | cut -c1-300

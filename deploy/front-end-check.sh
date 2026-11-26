#!/bin/sh
# Show which front end serves https://wiki.machs.org right now, and that both
# paths are healthy. No sudo needed. See deploy/FRONT-END.md.
#
# From kube, wiki.machs.org resolves to the public IP, so the first request
# goes out to the router and back in: it takes the same path as visitors.
HOST=wiki.machs.org
URL="https://$HOST/Machs/WebHome"

front=$(curl -s -m 15 -D - -o /dev/null "$URL" | tr -d '\r' \
        | awk -F': ' 'tolower($1)=="x-front-end"{print $2}')
code=$(curl -s -m 15 -o /dev/null -w '%{http_code}' "$URL")
tls=$(echo | timeout 10 openssl s_client -connect "$HOST:443" -servername "$HOST" 2>/dev/null \
      | awk '/^New, /{print $2; exit}' | tr -d ,)

if [ "$front" = apache ]; then
    echo "Public:    via Apache   HTTP $code, $tls"
else
    echo "Public:    NOT via Apache (check the router's 443 forward)   HTTP $code, $tls"
fi

a=$(curl -s -m 10 --resolve "$HOST:443:127.0.0.1" -o /dev/null -w '%{http_code}' "$URL")
c=$(curl -s -m 10 -k --connect-to "$HOST:443:127.0.0.1:8443" -o /dev/null -w '%{http_code}' "$URL")
echo "Apache:    local port 443 -> HTTP $a"
echo "Container: local port 8443 -> HTTP $c"
[ "$front" = apache ] && [ "$code" = 200 ] && [ "$a" = 200 ] && [ "$c" = 200 ]

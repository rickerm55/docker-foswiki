#!/bin/sh
# Certbot deploy hook: publishes a renewed wiki.machs.org cert to Apache and the
# foswiki container. Installed to /etc/letsencrypt/renewal-hooks/deploy/ by
# deploy/install.sh. Certbot runs it as root, once per renewed lineage.
set -u

WIKI_DIR=/home/bq/docker-foswiki
HTTPS_DIR="$WIKI_DIR/https"

case " ${RENEWED_DOMAINS:-} " in
    *" wiki.machs.org "*) ;;
    *) exit 0 ;;
esac

status=0

# Both serve the cert: Apache on 443 (public when the router points 443 at it)
# and the container on 8443 (public otherwise, and Apache's upstream). See
# deploy/FRONT-END.md. Apache reads /etc/letsencrypt directly; a reload is enough.
systemctl reload apache2 || { echo "apache2 reload failed" >&2; status=1; }

# Overwrite in place: docker-compose.yml bind-mounts single files, so mv or an
# atomic replace would leave the container holding the old inode.
for f in cert.pem chain.pem fullchain.pem privkey.pem; do
    cp -L "$RENEWED_LINEAGE/$f" "$HTTPS_DIR/$f" || { echo "copy of $f failed" >&2; status=1; }
done
chmod 600 "$HTTPS_DIR/privkey.pem" || status=1

docker compose -f "$WIKI_DIR/docker-compose.yml" exec -T foswiki nginx -s reload \
    || { echo "foswiki nginx reload failed" >&2; status=1; }

exit $status

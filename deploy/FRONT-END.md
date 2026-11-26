# wiki.machs.org front end

Apache on the host is the public front end. The router forwards:

| External | Internal (kube) | What answers |
|---|---|---|
| 80 | 80 | Apache: Let's Encrypt challenge files; everything else redirects to `https://wiki.machs.org` |
| 443 | 443 | Apache: TLS 1.2/1.3 with the Let's Encrypt cert, proxied to the foswiki container on `127.0.0.1:8443` |

The container listens on loopback only (`127.0.0.1:8443` and `127.0.0.1:8765`
in `docker-compose.yml`), so nothing but Apache can reach it.

Why Apache in front: Ubuntu's unattended-upgrades patches it automatically,
while the container's nginx is only patched when the image is rebuilt.

Switched 2026-11-26: router 443 moved from 8443 (container) to 443 (Apache);
container ports bound to loopback; PHP turned off.

## Check it

```bash
deploy/front-end-check.sh
```

This shows the path public traffic takes (Apache adds an `X-Front-End: apache`
response header) and checks Apache (local 443) and the container (local 8443).
It exits non-zero if any check fails.

Logs: `/var/log/apache2/wiki-access.log` and `wiki-error.log` (readable by the
`adm` group). The container's nginx log is `/var/log/nginx/foswiki-access.log`
inside the container.

## Configuration

- **Source:** `deploy/apache-site.conf`. Edit this, then rerun
  `sudo deploy/apache-setup.sh` to install it as
  `/etc/apache2/sites-available/000-default.conf`. Don't edit the installed copy.
  The script:
  - backs up the old config
  - enables the modules it needs (ssl, proxy, proxy_http, headers)
  - turns PHP off and uses the event MPM
  - tests the config, restarts Apache, and rolls back if either step fails
  - checks the redirect, the challenge path, HTTPS, HSTS (from Foswiki), the MPM and the
    `X-Front-End` header
- **Real visitor IPs:** Apache sends `X-Forwarded-For`. The container's nginx
  trusts it only from Docker-internal addresses (`set_real_ip_from 172.16.0.0/12`
  in `https/nginx.default.conf`), so Foswiki logs the real visitor IP.
- **Certificate:** the renewal deploy hook reloads Apache, which reads
  `/etc/letsencrypt` directly. It also copies the cert into the container, which
  still serves HTTPS to Apache on the loopback hop.
- **Timeouts:** Apache allows 300 s per request (`ProxyTimeout`). The 259-page
  `FullRecipeBookTopical` PDF takes about 10 s.
- **HSTS:** sent by Foswiki's SecurityHeadersPlugin (`max-age=31536000;
  includeSubDomains`, which covers only names under `wiki.machs.org`), not by
  Apache, so the header isn't duplicated.
- **PHP:** off (`a2dismod php8.5`). Nothing on kube used it. The
  `libapache2-mod-php` package is still installed.

## Undo: go back to the container serving directly

1. In `docker-compose.yml`, remove `127.0.0.1:` from the two `ports` lines, then
   run `docker compose up -d foswiki`.
2. In the router, change external 443 → internal **8443**.
3. Check: `deploy/front-end-check.sh` should say `NOT via Apache`.

Apache can stay as it is: port 80 is still needed for certificate renewal.
Browsers that saw HSTS keep using HTTPS, which the container also serves.

To get PHP back: `sudo a2dismod mpm_event && sudo a2enmod mpm_prefork php8.5 && sudo systemctl restart apache2`.

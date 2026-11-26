# wiki.machs.org front end: Apache or direct

Public HTTPS can reach the wiki two ways. Both stay working side by side, and
the **router's port 443 forward is the switch**. Nothing on kube changes when
you flip it.

| Router forward | Path | Who handles TLS |
|---|---|---|
| 443 → **8443** | internet → foswiki container's nginx | nginx inside the image (patched only when the image is rebuilt) |
| 443 → **443** | internet → host Apache → container (127.0.0.1:8443) | Apache on the host (patched automatically by unattended-upgrades; TLS 1.2/1.3 only) |

Port 80 always goes to Apache. It serves Let's Encrypt challenge files and
redirects everything else to `https://wiki.machs.org`.

## Which path is live?

```bash
deploy/front-end-check.sh
```

It prints the path public traffic takes (Apache adds an `X-Front-End: apache`
response header) and checks that both Apache (local 443) and the container
(local 8443) answer. It exits non-zero if any of the three fails.

From a browser: open the developer tools' Network tab, load the wiki, and look
for `X-Front-End: apache` in the response headers.

## Switch to Apache

1. Make sure Apache is ready: `deploy/front-end-check.sh` must show
   `Apache: local port 443 -> HTTP 200`. If not, run `sudo deploy/apache-setup.sh`.
2. In the router, change the forward for external **443** from internal port
   **8443** to **443** (kube, TCP).
3. Run `deploy/front-end-check.sh` again. It should say `via Apache`.
4. From outside your network (a phone on mobile data), load the wiki, log in,
   edit a page, and run a search.

Apache's logs for the wiki: `/var/log/apache2/wiki-access.log` and
`wiki-error.log` (readable by the `adm` group).

## Switch back

In the router, change external **443** back to internal **8443**. That's all.

## Setup details

- `deploy/apache-site.conf` is the source; `sudo deploy/apache-setup.sh` installs
  it to `/etc/apache2/sites-available/000-default.conf`, enables the modules,
  tests, restarts, and checks. It backs up the old config first and prints an
  undo command. Edit the source and rerun the script, not the installed copy.
- The container's nginx trusts `X-Forwarded-For` only from Docker-internal
  addresses (`set_real_ip_from 172.16.0.0/12` in `https/nginx.default.conf`),
  so Foswiki logs the real visitor IP on both paths. Direct visitors can't fake
  it, because their own address isn't in that range.
- The certificate deploy hook reloads Apache and copies the cert into the
  container, so both paths always serve the current certificate.
- Apache allows 300 s per request (`ProxyTimeout`); the 259-page
  `FullRecipeBookTopical` PDF takes about 10 s.

## Cleanup, once Apache has been live for a while

These remove the way back, so do them only after you're settled on Apache:

1. **Hide the container:** in `docker-compose.yml` change the ports to
   `"127.0.0.1:8765:80"` and `"127.0.0.1:8443:443"`, then
   `docker compose up -d foswiki`. After this, switching back also means
   reverting this change.
2. **Turn off PHP** (nothing on kube uses it): `sudo a2dismod php8.3` and
   switch Apache to the event worker: `sudo a2dismod mpm_prefork && sudo a2enmod mpm_event`,
   then `sudo systemctl restart apache2`.
3. **Add HSTS** to the 443 vhost in `apache-site.conf`:
   `Header always set Strict-Transport-Security "max-age=31536000"`, then rerun
   `sudo deploy/apache-setup.sh`.
4. Update `deploy/CERTIFICATE-RENEWAL.md` and `CLAUDE.md` to describe only the
   Apache path.

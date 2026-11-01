# wiki.machs.org TLS Certificate Renewal

The Let's Encrypt certificate for wiki.machs.org renews automatically on the server `kube`. Routine renewal needs no action: no challenge files, no key copying and no restarts. This setup replaces the old manual process using `cert-renew.sh`, which has been removed.

If you receive an alert email, go to [Troubleshooting](#troubleshooting).

## How it works

1. **Renew:** `certbot.timer` runs `certbot renew` as root twice a day. Certbot renews once the certificate has about 30 days left, proving control of the domain by writing a temporary file under `/var/www/html/.well-known/acme-challenge/`.
2. **Deploy:** after a successful renewal, and only then, certbot runs a deploy hook that:
   - reloads Apache, which reads the certificate directly from `/etc/letsencrypt`
   - copies the certificate and key into `~/docker-foswiki/https/`
   - reloads nginx inside the `foswiki` container, without restarting it
3. **Monitor:** a daily cron job at 08:00 checks the certificates actually being served and sends email only if there is a problem.

Traffic flows from the internet to Apache on port 443, then to the `foswiki` container on port 8443. Both use the same certificate.

Let's Encrypt no longer sends expiry warning emails, so the daily check is the only warning of a failed renewal.

## Where everything lives

| Item | Location |
|---|---|
| Certificate and key | `/etc/letsencrypt/live/wiki.machs.org/` |
| Renewal settings | `/etc/letsencrypt/renewal/wiki.machs.org.conf` |
| Renewal schedule | `certbot.timer` (systemd) |
| Installed deploy hook | `/etc/letsencrypt/renewal-hooks/deploy/foswiki-cert-deploy` |
| Deploy hook source | `~/docker-foswiki/deploy/cert-deploy-hook.sh` |
| Daily check | `~/docker-foswiki/deploy/cert-check.sh`, in the `bq` crontab |
| Apache site config | `/etc/apache2/sites-available/000-default.conf` |
| Container's certificate copies | `~/docker-foswiki/https/` |
| Mail relay credentials | `/etc/postfix/sasl_passwd` |

Alerts go to stores@machs.org, an alias for rick@machs.org. Server mail is relayed through Gmail using a Google app password for rickerm@gmail.com, a low-use account chosen to limit what a leaked password could reach. Alerts therefore arrive from rickerm@gmail.com. Sign in to that account occasionally so Google doesn't treat it as inactive, because alerts stop if the account stops working.

## Common commands

Run these from `~/docker-foswiki`.

```bash
# Check both served certificates. Prints expiry dates; emails only on a problem.
deploy/cert-check.sh

# Send a test email regardless of certificate state
deploy/cert-check.sh --test

# Show the certificate certbot holds
sudo certbot certificates --cert-name wiki.machs.org

# Test renewal without changing anything (does not run the deploy hook)
sudo certbot renew --cert-name wiki.machs.org --dry-run

# See recent renewal runs and the schedule
journalctl -u certbot.service -n 20 --no-pager
systemctl list-timers certbot.timer
```

## Troubleshooting

### Alert: certificate expires in under 21 days

Certbot should have renewed about 9 days earlier, so renewal or deployment has failed.

1. Run `sudo certbot certificates --cert-name wiki.machs.org` and compare its expiry date with the one in the alert.
2. **If certbot's date is later,** renewal worked but deployment failed. Run the deploy hook by hand (see below).
3. **If the dates match,** renewal itself is failing. Run the dry run above and read the error. Then check `sudo less /var/log/letsencrypt/letsencrypt.log`.

The most likely cause is that Let's Encrypt can't reach `http://wiki.machs.org/.well-known/acme-challenge/` from the internet. Check DNS, router port forwarding for port 80, and that Apache is running.

Once the dry run passes, renew immediately with:

```bash
sudo certbot renew --cert-name wiki.machs.org
```

If more than 30 days remain, certbot will skip this as not yet due.

### Alert: container certificate differs from the public one

Apache and the container are on different certificates, usually because the container wasn't running during deployment. Run the deploy hook by hand.

### Alert: could not read a certificate

Either Apache (port 443) or the container (port 8443) isn't responding. Check them with:

```bash
systemctl status apache2
docker compose ps
```

### Run the deploy hook by hand

This is safe to repeat. It republishes the current certificate without contacting Let's Encrypt.

```bash
sudo env RENEWED_LINEAGE=/etc/letsencrypt/live/wiki.machs.org \
  RENEWED_DOMAINS=wiki.machs.org \
  /etc/letsencrypt/renewal-hooks/deploy/foswiki-cert-deploy
```

### Test email doesn't arrive

Check the delivery result:

```bash
grep 'postfix/smtp\[' /var/log/mail.log | tail -n 5
```

A `535` error means Google rejected the login, usually because the app password was revoked or the account password changed. Create a new app password while signed in as rickerm@gmail.com, then run `sudo deploy/setup-mail-relay.sh`.

The login must be a real account, not an alias. Gmail rejects the stores@machs.org alias.

## Maintenance rules

- **Keep `~/docker-foswiki` on a branch that contains `deploy/`.** Cron runs the daily check from this folder. If the script is missing, the check fails silently and no alerts are sent.
- **Reinstall the hook after editing its source.** Certbot runs an installed copy, kept root-owned so that root never executes a file a regular user can edit:
  ```bash
  sudo install -o root -g root -m 755 deploy/cert-deploy-hook.sh \
    /etc/letsencrypt/renewal-hooks/deploy/foswiki-cert-deploy
  ```
- **Overwrite files in `https/` in place.** `docker-compose.yml` mounts these as individual files. Replacing one with `mv` leaves the running container on the old file until it is recreated.
- **Keep `.well-known/acme-challenge/` reachable over plain HTTP on port 80.** Any future redirect or proxy rule on port 80 must exempt this path, or renewal will fail.
- **Don't run `certbot --manual`.** Certificates issued that way can't renew automatically.
- **Don't commit `https/` or key material.** The repository is public, and `https/` is in `.gitignore`.

## Rebuilding on a new server

1. Install certbot and Apache, and get the wiki running with Docker Compose.
2. Make sure `wiki.machs.org` points to the server and port 80 is reachable from the internet.
3. Issue the certificate:
   ```bash
   sudo certbot certonly --webroot -w /var/www/html -d wiki.machs.org
   ```
4. Install the hook and point Apache at the certificate. This stops without changing anything if the certificate or a dry-run renewal fails:
   ```bash
   sudo deploy/install.sh
   ```
5. Set up the mail relay. This prompts for the app password and sends a test email:
   ```bash
   sudo deploy/setup-mail-relay.sh
   ```
6. Add the daily check with `crontab -e`:
   ```
   0 8 * * * /home/bq/docker-foswiki/deploy/cert-check.sh >/dev/null 2>&1
   ```

The scripts assume the repository is at `/home/bq/docker-foswiki` and that the Apache site config already has `SSLCertificateFile` and `SSLCertificateKeyFile` lines. Adjust them if the new server differs.

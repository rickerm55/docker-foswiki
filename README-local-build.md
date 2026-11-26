# Local image build (kube)

The `timlegge/docker-foswiki:latest` image on Docker Hub hasn't been rebuilt since
2026-03-15, so its Alpine packages (nginx, OpenSSL, ImageMagick, Perl modules) piled
up security fixes it never picked up. Since 2026-11-25 the site runs an image built
locally from this repo's `Dockerfile`, tagged by build date.

Arcane can't update a local image (`com.getarcaneapp.arcane.updater=false` in
`docker-compose.yml`), so **rebuild every 1–2 months**, or sooner after a serious
nginx/OpenSSL advisory.

## Rebuild

```bash
cd ~/docker-foswiki
TAG=$(date +%F)

# 1. Snapshot the wiki data (pages, config, plugins) right before the change,
#    so a rollback doesn't depend on last night's backup.
docker run --rm -v foswiki_foswiki_www:/src:ro -v ~/backups/foswiki:/dst alpine:3.22 \
  tar czf /dst/foswiki_www-$TAG.tgz -C /src .

# 2. Build (about 10–15 min: CPAN compiles plus ~60 plugin downloads)
docker build --pull --no-cache -t foswiki-local:$TAG .

# 3. Test it on a COPY of the data, on local-only ports
docker volume create foswiki_test_www
docker run --rm -v foswiki_test_www:/dst -v ~/backups/foswiki:/src:ro alpine:3.22 \
  tar xzf /src/foswiki_www-$TAG.tgz -C /dst
docker run -d --name foswiki-test -p 127.0.0.1:18443:443 -v foswiki_test_www:/var/www/foswiki \
  -v $PWD/https/nginx.default.conf:/etc/nginx/http.d/default.conf:ro \
  -v $PWD/https/docker-foswiki.crt:/etc/nginx/docker-foswiki.crt:ro \
  -v $PWD/https/docker-foswiki.key:/etc/nginx/docker-foswiki.key:ro foswiki-local:$TAG
sleep 20
for p in /Machs/WebHome /Main/WikiUsers /bin/login/Main/WebHome; do
  curl -sk -L --connect-to wiki.machs.org:443:127.0.0.1:18443 -o /dev/null \
    -w "%{http_code} %{url_effective}\n" "https://wiki.machs.org$p"; done
docker exec foswiki-test tail -20 /var/www/foswiki/working/logs/error.log
# (Solr "No such file" lines in `docker logs foswiki-test` are expected: no Solr in the test.)
docker rm -f foswiki-test && docker volume rm foswiki_test_www

# 4. Switch: set `image: foswiki-local:$TAG` in docker-compose.yml, then
docker compose up -d foswiki
```

`--connect-to` matters: the site redirects to `https://wiki.machs.org/...`, and
without it curl follows the redirect to the *live* site and the test proves nothing.

## Rollback

Point `image:` back at the previous tag (keep the last one or two images) and
`docker compose up -d foswiki`. If the data itself is damaged, restore the tarball
from step 1 into `foswiki_foswiki_www`.

## Known gotchas

- `alpine:edge` is Alpine's rolling development branch. Packages can change
  underneath you between builds. Always test (step 3) before switching.
- 2026-11-25: `perl-cgi-session` 4.49 started requiring `Crypt::SysRandom` without
  declaring it as a dependency, which caused 500 errors on every page.
  `perl-crypt-sysrandom` is now listed explicitly in the Dockerfile.

## Solr (search)

Search runs on **Solr 9** (`solr:9-slim`), switched from Solr 5 on 2026-11-26.
SolrPlugin 10.x was installed into the wiki volume on 2026-04-06 and needs a Solr 9
schema. Under Solr 5 every search failed with `undefined field: "source"`.

- **Config:** `solr9/configsets/foswiki_configs/` in this repo. It was copied from
  SolrPlugin 10.20's `solr_9/` directory (inside the image at
  `/var/www/foswiki/solr_9`, which the volume hides in the running container), plus
  one local line: the `webcat` field, which SolrPlugin 10.00 sent but 10.20
  dropped. The wiki was upgraded to 10.20 on 2026-11-26, so the line is now unused
  but harmless. **After a future SolrPlugin upgrade,** compare its `solr_9/` config
  with `solr9/` and do a full reindex.
- **Data:** the `foswiki_solr9_data` volume. On first start, `solr-precreate` copies
  the config into it (`/var/solr/data/foswiki/conf`). After that, **editing files in
  `solr9/` does nothing until you copy them in:**
  ```bash
  docker compose exec solr sh -c 'cp /opt/solr/server/solr/configsets/foswiki_configs/conf/* /var/solr/data/foswiki/conf/'
  docker compose exec solr curl -s "http://localhost:8983/solr/admin/cores?action=RELOAD&core=foswiki"
  ```
  After a schema change, also do a full reindex.
- **Full reindex** (takes a few minutes; search results are incomplete while it runs):
  ```bash
  docker compose exec foswiki sh -c 'cd /var/www/foswiki/tools && ./solrindex mode=full > /tmp/idx.log 2>&1; grep -c "^Indexing" /tmp/idx.log; grep -o "\"msg\":\"[^\"]*" /tmp/idx.log | sort | uniq -c'
  ```
  Normal edits are indexed automatically (iwatch → `tools/solrjob`). A full index
  covers only Foswiki's "user" webs (Main, Machs, Trash): about 580 docs, under a
  minute. System/Sandbox/Applications are skipped unless named, e.g.
  `./solrindex web=Sandbox mode=full`.
- **Commits:** `SOLR_OPTS` in docker-compose.yml sets auto soft-commit to 6 s.
  Without it, indexed pages don't show up in search until Solr restarts.
- **Updates:** Arcane auto-updates `solr:9-slim` within Solr 9 (global 72 h delay).
  Solr 10 is a manual move. SolrPlugin ships a `solr_10/` config for it.
- **Leftovers:** the Solr 5 volumes (`foswiki_solr_configsets`, `foswiki_solr_foswiki`,
  `foswiki_solr_logs`) are still mounted by the foswiki service, because the entrypoint
  `cd`s into those paths. They're harmless. The `solr:5` image can be removed once
  you're happy.
- **Rollback to Solr 5:** restore the old `solr:` service from git history and run
  `docker compose up -d solr`. Its volumes were never touched, but search was
  already broken under Solr 5, so this only helps if Solr 9 is worse.

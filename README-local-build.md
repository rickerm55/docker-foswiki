# Local image build (kube)

The `timlegge/docker-foswiki:latest` image on Docker Hub hasn't been rebuilt since
2026-03-15, so its Alpine packages (nginx, OpenSSL, ImageMagick, Perl modules) piled
up security fixes it never picked up. Since 2026-11-25 the site runs an image built
locally from this repo's `Dockerfile`, tagged by build date.

Arcane can't update a local image (`com.getarcaneapp.arcane.updater=false` in
`docker-compose.yml`), so **rebuild every 1–2 months**, or sooner after a serious
nginx/OpenSSL advisory.

## Rebuild

`deploy/rebuild.sh` runs each stage and prints the next command when it's done.
No sudo needed.

```bash
cd ~/docker-foswiki
deploy/rebuild.sh build          # ~15 min: snapshot the wiki volume, build foswiki-local:<date>
deploy/rebuild.sh test <tag>     # ~5 min: run the new image on a COPY of the wiki, check it
deploy/rebuild.sh switch <tag>   # make it live (seconds of downtime), check, list manual steps
deploy/rebuild.sh prune          # later: remove old images and snapshots (asks first)
```

What each stage does:

- **build:** snapshots `foswiki_foswiki_www` to `~/backups/foswiki/foswiki_www-<tag>-prebuild.tgz`,
  then runs `docker build --pull --no-cache`. The log goes to
  `~/.cache/foswiki-rebuild/build-<tag>.log`. If the date tag already exists, it adds
  `b`, `c`, and so on. It finishes with a smoke test that loads the Perl modules
  that broke before (CGI::Session, Crypt::SysRandom, and others).
- **test:** copies the live wiki volume and runs the new image on
  `127.0.0.1:18443`, attached to the live Solr. It checks:
  - four pages, the login page and an attachment download
  - search, including the `source` facet that broke under Solr 5
  - the 259-page `FullRecipeBookTopical` PDF
  - new entries in Foswiki's `error.log`

  Then it removes the test container and volume.
- **switch:** records the current image on the `# Previous:` line in
  `docker-compose.yml`, switches, runs the same checks against the live site plus
  `deploy/front-end-check.sh`, then lists the manual checks and the commit command.
  The manual checks are logging in, editing and searching, uploading, and an Arcane
  rescan.
- **check:** runs the same checks against the live site at any time.

The checks use `curl --connect-to`, because the site redirects to
`https://wiki.machs.org/...`. A plain request would be answered by the live site,
and the test would prove nothing.

## Rollback

```bash
deploy/rebuild.sh rollback
```

This swaps back to the image on the `# Previous:` line. Running it again swaps
forward. Keep the previous image on disk until the new one has run for a while;
`prune` keeps both. If the wiki data itself is damaged, restore the snapshot from
`build` into `foswiki_foswiki_www`.

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

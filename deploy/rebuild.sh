#!/bin/bash
# Rebuild the Foswiki image in stages. Each stage ends by printing the next command.
#
#   deploy/rebuild.sh build            snapshot the wiki volume, build foswiki-local:<date>
#   deploy/rebuild.sh test <tag>       run <tag> on a COPY of the wiki and check it
#   deploy/rebuild.sh switch <tag>     make <tag> live and check it (records rollback target)
#   deploy/rebuild.sh rollback         go back to the previous image
#   deploy/rebuild.sh prune            remove old images and snapshots
#   deploy/rebuild.sh check            run the checks against the live site
#
# No sudo needed (docker group). Background: README-local-build.md.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")/.."
COMPOSE=${COMPOSE:-docker-compose.yml}
REPO=foswiki-local
LIVE_VOL=foswiki_foswiki_www
TEST_VOL=foswiki_test_www
TEST_NAME=foswiki-test
TEST_PORT=18443
SNAP_DIR=$HOME/backups/foswiki
LOG_DIR=$HOME/.cache/foswiki-rebuild
HOST=wiki.machs.org
SELF=deploy/rebuild.sh

say()  { printf '\n== %s\n' "$*"; }
next() { printf '\n>> Next: %s\n' "$*"; }
die()  { printf '\nSTOP: %s\n' "$*" >&2; exit 1; }

current_tag()  { sed -n "s/^ *image: $REPO:\([^ ]*\).*/\1/p" "$COMPOSE" | head -1; }
previous_ref() { sed -n 's/^ *# Previous: \([^ ]*\).*/\1/p' "$COMPOSE" | head -1; }
image_exists() { docker image inspect "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- checks
# site_checks <port> <label>: the same checks for the test container and the live site.
site_checks() {
    local port=$1 label=$2 fail=0 code size ctype t body
    local C=(curl -sk -m 30 --connect-to "$HOST:443:127.0.0.1:$port")
    say "Checks against $label (port $port)"
    for p in /Machs/WebHome /Main/WikiUsers /Machs/ChickenPotPie /bin/login/Main/WebHome; do
        read -r code size < <("${C[@]}" -o /dev/null -w '%{http_code} %{size_download}\n' "https://$HOST$p")
        if [ "$code" = 200 ] && [ "$size" -gt 2000 ]; then echo "ok   page $p ($size bytes)"
        else echo "FAIL page $p: HTTP $code, $size bytes"; fail=1; fi
    done

    read -r code ctype < <("${C[@]}" -o /dev/null -w '%{http_code} %{content_type}\n' \
        "https://$HOST/pub/Machs/WebPreferences/TheMachs.png")
    if [ "$code" = 200 ] && [[ $ctype == image/* ]]; then echo "ok   attachment download"
    else echo "FAIL attachment: HTTP $code, $ctype"; fail=1; fi

    # facet.field=source is the field Solr 5's schema lacked; this catches a schema mismatch.
    body=$("${C[@]}" "https://$HOST/bin/rest/SolrPlugin/proxy?q=chicken&wt=json&rows=1&facet=true&facet.field=source&facet.field=web" || true)
    if [[ $body =~ \"numFound\":([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -gt 0 ]; then
        echo "ok   search (${BASH_REMATCH[1]} hits for 'chicken')"
    else echo "FAIL search: ${body:0:150}"; fail=1; fi

    local pdf; pdf=$(mktemp)
    read -r code size t < <(curl -sk -m 300 --connect-to "$HOST:443:127.0.0.1:$port" -o "$pdf" \
        -w '%{http_code} %{size_download} %{time_total}\n' "https://$HOST/bin/genpdf/Machs/FullRecipeBookTopical")
    if [ "$code" = 200 ] && [ "$(head -c 4 "$pdf")" = "%PDF" ] && [ "$size" -gt 1000000 ]; then
        echo "ok   PDF export, 259-page recipe book ($((size / 1024)) KB in ${t%.*}s)"
    else echo "FAIL PDF export: HTTP $code, $size bytes"; fail=1; fi
    rm -f "$pdf"
    return $fail
}

errlog_lines() { docker exec "$1" sh -c 'wc -l < /var/www/foswiki/working/logs/error.log 2>/dev/null || echo 0'; }
show_new_errors() { # container, line count before
    local now; now=$(errlog_lines "$1")
    if [ "$now" -gt "$2" ]; then
        echo "NOTE $((now - $2)) new line(s) in Foswiki's error.log during the checks:"
        docker exec "$1" sh -c "tail -n +$(($2 + 1)) /var/www/foswiki/working/logs/error.log" | cut -c1-200 | head -20
    else
        echo "ok   no new entries in Foswiki's error.log"
    fi
}

wait_ready() { # port, seconds
    for _ in $(seq "$2"); do
        [ "$(curl -sk -m 5 -o /dev/null -w '%{http_code}' --connect-to "$HOST:443:127.0.0.1:$1" "https://$HOST/Machs/WebHome")" = 200 ] && return 0
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------- stages
cmd_build() {
    local tag; tag=$(date +%F)
    if image_exists "$REPO:$tag"; then
        for s in b c d e f; do image_exists "$REPO:$tag$s" || { tag=$tag$s; break; }; done
    fi
    mkdir -p "$SNAP_DIR" "$LOG_DIR"
    say "Building $REPO:$tag (current live image: $REPO:$(current_tag))"
    df -h /var/lib/docker "$SNAP_DIR" | sed 's/^/   /'

    say "Snapshotting $LIVE_VOL to $SNAP_DIR/foswiki_www-$tag-prebuild.tgz"
    docker run --rm -v "$LIVE_VOL":/src:ro -v "$SNAP_DIR":/dst alpine:3.22 \
        tar czf "/dst/foswiki_www-$tag-prebuild.tgz" -C /src .
    ls -lh "$SNAP_DIR/foswiki_www-$tag-prebuild.tgz" | awk '{print "   " $5 "  " $9}'

    local log=$LOG_DIR/build-$tag.log start=$SECONDS
    say "Building (10-15 min; log: $log)"
    if ! docker build --pull --no-cache -t "$REPO:$tag" . >"$log" 2>&1; then
        tail -25 "$log"
        die "Build failed. Read the log above; if an Alpine package broke, see 'Known gotchas' in README-local-build.md."
    fi
    echo "   built in $(((SECONDS - start) / 60)) min"

    say "Quick smoke test: Perl modules that broke before"
    docker run --rm --entrypoint perl "$REPO:$tag" \
        -MCGI -MCGI::Session -MCGI::Session::ID::md5 -MCrypt::SysRandom -MFCGI -MDBI -MImage::Magick \
        -e 'print "   ok  modules load (Perl $^V)\n"' \
        || die "A core Perl module doesn't load. Don't switch to this image."
    docker run --rm --entrypoint sh "$REPO:$tag" -c \
        'echo "   $(nginx -v 2>&1); $(openssl version)"'

    next "$SELF test $tag"
}

cleanup_test() {
    docker rm -f -v "$TEST_NAME" >/dev/null 2>&1 || true
    docker volume rm "$TEST_VOL" >/dev/null 2>&1 || true
}

cmd_test() {
    local tag=${1:?usage: $SELF test <tag>}
    image_exists "$REPO:$tag" || die "No image $REPO:$tag (docker image ls $REPO)."
    cleanup_test
    trap cleanup_test EXIT

    say "Copying the live wiki volume to $TEST_VOL"
    docker volume create "$TEST_VOL" >/dev/null
    docker run --rm -v "$LIVE_VOL":/src:ro -v "$TEST_VOL":/dst alpine:3.22 sh -c 'cp -a /src/. /dst/'

    say "Starting $REPO:$tag as $TEST_NAME on 127.0.0.1:$TEST_PORT (uses the live Solr for search)"
    docker run -d --name "$TEST_NAME" --network foswiki_frontend -p "127.0.0.1:$TEST_PORT:443" \
        -v "$TEST_VOL":/var/www/foswiki \
        -v /opt/solr/server/logs -v /opt/solr/server/solr/configsets -v /opt/solr/server/solr/solr_foswiki \
        -v "$PWD/https/nginx.default.conf":/etc/nginx/http.d/default.conf:ro \
        -v "$PWD/https/docker-foswiki.crt":/etc/nginx/docker-foswiki.crt:ro \
        -v "$PWD/https/docker-foswiki.key":/etc/nginx/docker-foswiki.key:ro \
        "$REPO:$tag" >/dev/null
    docker network connect foswiki_backend "$TEST_NAME"
    if ! wait_ready "$TEST_PORT" 120; then
        docker logs --tail 30 "$TEST_NAME" 2>&1
        die "The test container never served the home page. Logs are above."
    fi

    local before; before=$(errlog_lines "$TEST_NAME")
    local ok=1
    site_checks "$TEST_PORT" "TEST image $REPO:$tag" || ok=0
    show_new_errors "$TEST_NAME" "$before"
    echo "   test image: $(docker exec "$TEST_NAME" sh -c 'nginx -v 2>&1; openssl version' | tr '\n' ' ')"
    echo "   live image: $(docker compose exec -T foswiki sh -c 'nginx -v 2>&1; openssl version' | tr '\n' ' ')"

    say "Removing the test container and volume"
    cleanup_test; trap - EXIT
    [ "$ok" = 1 ] || die "The new image failed a check. Keep the current one; investigate before switching."
    next "$SELF switch $tag"
}

set_image() { # new_tag, previous_ref
    sed -i -e "s|^\( *image: \)$REPO:[^ ]*|\1$REPO:$1|" \
           -e "s|^\( *# Previous: \).*|\1$2 (kept on disk for rollback: $SELF rollback)|" "$COMPOSE"
}

go_live() {
    docker compose up -d foswiki 2>&1 | grep -v obsolete | sed 's/^/   /'
    wait_ready 8443 120 || die "The live container isn't serving pages. Roll back: $SELF rollback"
}

cmd_switch() {
    local tag=${1:?usage: $SELF switch <tag>} cur; cur=$(current_tag)
    image_exists "$REPO:$tag" || die "No image $REPO:$tag."
    [ "$tag" != "$cur" ] || die "$REPO:$tag is already live."
    image_exists "$REPO:$cur" || echo "NOTE the current image $REPO:$cur isn't on disk, so rollback won't be possible."

    say "Switching the live wiki from $REPO:$cur to $REPO:$tag (a few seconds of downtime)"
    set_image "$tag" "$REPO:$cur"
    go_live
    local before; before=$(errlog_lines foswiki-foswiki-1)
    local ok=1
    site_checks 8443 "LIVE site" || ok=0
    show_new_errors foswiki-foswiki-1 "$before"
    say "Public front end"; deploy/front-end-check.sh || ok=0
    [ "$ok" = 1 ] || die "A live check failed. Roll back now: $SELF rollback"

    cat <<EOF

== Automated checks passed. Your turn (in a browser, on https://$HOST):
   1. Log in
   2. Edit a page, save, then search for a word you added (within a minute)
   3. Upload a small attachment to a test page, then delete it
   4. In Arcane, rescan foswiki-local:$tag (expect 0 or near-0 vulnerabilities)
   5. Optional: configure > Extensions for updates. If SolrPlugin updates, compare
      its solr_9 config with solr9/ and run a full reindex (README-local-build.md, Solr section).

   If something's wrong:  $SELF rollback
   When happy, commit:    git commit -am "Foswiki image $tag" && git push
   Later, tidy up:        $SELF prune
EOF
}

cmd_rollback() {
    local cur prev; cur=$(current_tag); prev=$(previous_ref)
    [[ $prev == "$REPO:"* ]] || die "No rollback target recorded in $COMPOSE ('# Previous:' line is '$prev')."
    image_exists "$prev" || die "$prev isn't on disk any more."
    say "Rolling back from $REPO:$cur to $prev"
    set_image "${prev#"$REPO":}" "$REPO:$cur"
    go_live
    site_checks 8443 "LIVE site after rollback" || true
    deploy/front-end-check.sh || true
    echo
    echo "   $REPO:$cur is now recorded as '# Previous', so '$SELF rollback' would switch back to it."
    echo "   Commit: git commit -am \"Roll back Foswiki image to ${prev#"$REPO":}\""
}

cmd_prune() {
    local keep1 keep2; keep1=$REPO:$(current_tag); keep2=$(previous_ref)
    say "Images (keeping $keep1 and $keep2)"
    local old=()
    while read -r ref; do
        [ "$ref" = "$keep1" ] || [ "$ref" = "$keep2" ] || old+=("$ref")
    done < <(docker image ls "$REPO" --format '{{.Repository}}:{{.Tag}}')
    if [ ${#old[@]} -gt 0 ]; then
        printf '   remove %s\n' "${old[@]}"
        read -r -p "   Remove these images? [y/N] " a
        [ "$a" = y ] && docker image rm "${old[@]}"
    else echo "   nothing to remove"; fi

    say "Snapshots in $SNAP_DIR (keeping the newest 3)"
    mapfile -t snaps < <(ls -1t "$SNAP_DIR"/foswiki_www-*.tgz 2>/dev/null | tail -n +4)
    if [ ${#snaps[@]} -gt 0 ]; then
        printf '   remove %s\n' "${snaps[@]##*/}"
        read -r -p "   Remove these snapshots? [y/N] " a
        # The snapshots are root-owned (written by a container), so delete them the same way.
        [ "$a" = y ] && docker run --rm -v "$SNAP_DIR":/d alpine:3.22 rm -f "${snaps[@]/#$SNAP_DIR//d}"
    else echo "   nothing to remove"; fi
    du -sh "$SNAP_DIR" | sed 's/^/   /'
}

cmd_check() {
    local before; before=$(errlog_lines foswiki-foswiki-1)
    local ok=1
    site_checks 8443 "LIVE site ($REPO:$(current_tag))" || ok=0
    show_new_errors foswiki-foswiki-1 "$before"
    say "Public front end"; deploy/front-end-check.sh || ok=0
    [ "$ok" = 1 ]
}

case ${1:-} in
    build)    cmd_build ;;
    test)     cmd_test "${2:-}" ;;
    switch)   cmd_switch "${2:-}" ;;
    rollback) cmd_rollback ;;
    prune)    cmd_prune ;;
    check)    cmd_check ;;
    *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

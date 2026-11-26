#!/bin/sh
# Wrapper around htmldoc to handle two known failure modes:
# 1. Empty files cause htmldoc to segfault (exit 1339)
#    - Skip empty files passed to --titlefile (empty title page)
#    - Skip empty positional content files
#    - Note: -f/--outfile output files are always created empty by Foswiki
#      BEFORE calling htmldoc, so these are NEVER checked.
# 2. Large documents hang indefinitely — enforce a timeout

TIMEOUT_SEC=120   # 2 minutes per PDF generation (matches fastcgi_read_timeout)

# Ensure PATH is set properly for FCGI environment
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

FILTERED_ARGS=""
PREV=""

for i in "$@"; do
  # If previous arg was --titlefile, skip both if empty
  if [ "$PREV" = "--titlefile" ]; then
    if [ -f "$i" ] && [ ! -s "$i" ]; then
      echo "WARN: htmldoc-wrapper: skipping empty titlefile: $i" >&2
    else
      # Include both --titlefile and its value
      FILTERED_ARGS="--titlefile $FILTERED_ARGS"
      FILTERED_ARGS="$FILTERED_ARGS $i"
    fi
    PREV=""
    continue
  fi

  # If previous arg was -f or --outfile (output file), always include
  if [ "$PREV" = "-f" ] || [ "$PREV" = "--outfile" ]; then
    FILTERED_ARGS="$FILTERED_ARGS $i"
    PREV=""
    continue
  fi

  # Current arg
  case "$i" in
    --titlefile)
      # Don't add yet — wait to see if file is valid
      PREV="$i"
      ;;
    -f|--outfile)
      PREV="$i"
      FILTERED_ARGS="$FILTERED_ARGS $i"
      ;;
    --*)
      FILTERED_ARGS="$FILTERED_ARGS $i"
      ;;
    *)
      # Positional (content file): skip if empty
      if [ -f "$i" ] && [ ! -s "$i" ]; then
        echo "WARN: htmldoc-wrapper: skipping empty content file: $i" >&2
      else
        FILTERED_ARGS="$FILTERED_ARGS $i"
      fi
      ;;
  esac
done

# Run htmldoc with a timeout
# shellcheck disable=SC2086
timeout "$TIMEOUT_SEC" htmldoc $FILTERED_ARGS
rc=$?

if [ "$rc" -eq 124 ]; then
  echo "ERR: htmldoc-wrapper: htmldoc timed out after ${TIMEOUT_SEC}s" >&2
  exit 1
fi

exit "$rc"

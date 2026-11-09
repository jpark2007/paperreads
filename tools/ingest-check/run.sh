#!/bin/zsh
# Builds and runs the ingest regression harness against the app's real Web/ingest.js.
#
#   tools/ingest-check/run.sh [ingest-check options] [arxiv ids | file.html ...]
#
# With no ids it runs the regression set. Extra options (e.g. --render DIR --focus .box,
# --dump DIR, --missing 50) are passed through. Fetched HTML is cached so arXiv sees at most
# one request per paper. Override the scratch location with INGEST_CHECK_DIR and the Web
# directory under test (e.g. a built app's Contents/Resources/Web) with INGEST_CHECK_WEB.
set -euo pipefail

here=${0:A:h}
repo=${here:h:h}
scratch=${INGEST_CHECK_DIR:-${TMPDIR:-/tmp}/paperreads-ingest-check}
bin=$scratch/ingest-check
cache=$scratch/ingest-cache
mkdir -p "$bin" "$cache"

if [[ ! -x $bin/ingest-check || $here/main.swift -nt $bin/ingest-check ]]; then
  swiftc -O -swift-version 5 -framework AppKit -framework WebKit \
    -o "$bin/ingest-check" "$here/main.swift"
fi

regression=(2610.39302v1 1706.03762 2511.18397 2006.11239 2611.09685v1)
has_input=0
skip=0
for a in "$@"; do
  if (( skip )); then skip=0; continue; fi
  case $a in
    --min|--missing|--dump|--json|--render|--shots|--focus|--focus-count|--base|--web|--cache) skip=1 ;;
    -*) ;;
    *) has_input=1 ;;
  esac
done
(( has_input )) || set -- "$@" "${regression[@]}"

exec "$bin/ingest-check" --web "${INGEST_CHECK_WEB:-$repo/Paperreads/Web}" --cache "$cache" "$@"

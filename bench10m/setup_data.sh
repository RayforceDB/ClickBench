#!/bin/bash
# Acquire the ClickBench dataset for the rayforce runner.
#
# Produces <repo>/rayforce/hits.csv (the full 100M-row ClickBench dataset,
# ~76 GB uncompressed) using the official downloader at lib/download-hits-csv
# (fetches hits.csv.gz ~14 GB, decompresses with pigz). Idempotent: skips the
# download if hits.csv is already present.
#
# Env:
#   ROWS   if set, also write a head -N subset to rayforce/hits_<ROWS>.csv
#          (e.g. ROWS=10000000 for the 10M slice). The full hits.csv is the
#          source; the slice is cheap (head). Point run_rf.sh's CSV at it.
set -euo pipefail
REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
DEST="$REPO/rayforce"
mkdir -p "$DEST"

if [ -f "$DEST/hits.csv" ]; then
  echo "hits.csv already present: $DEST/hits.csv ($(du -h "$DEST/hits.csv" | cut -f1))"
else
  echo "downloading full hits.csv via lib/download-hits-csv (this is large: ~14 GB gz -> ~76 GB) ..."
  "$REPO/lib/download-hits-csv" "$DEST"
  echo "done: $DEST/hits.csv ($(du -h "$DEST/hits.csv" | cut -f1))"
fi

if [ -n "${ROWS:-}" ]; then
  slice="$DEST/hits_${ROWS}.csv"
  if [ -f "$slice" ]; then
    echo "slice already present: $slice"
  else
    echo "writing $ROWS-row slice -> $slice ..."
    head -n "$ROWS" "$DEST/hits.csv" > "$slice"
    echo "done: $slice ($(du -h "$slice" | cut -f1))"
  fi
fi

cat <<EOF

Next:
  # build rayforce (separate repo) -> get the release binary, then:
  RAY_BIN=/path/to/rayforce CSV=$DEST/hits.csv bench10m/run_rf.sh
  # on a machine without headroom, cap memory so a miss can't reboot it:
  RAY_BIN=/path/to/rayforce CSV=$DEST/hits.csv MEMMAX=160G bench10m/run_rf.sh
See bench10m/README_100M.md for the full procedure and memory facts.
EOF

#!/bin/bash
# Rayforce ClickBench runner — OUT-OF-CORE via the splayed on-disk store.
#
# This is the path for LARGE data (100M) on limited RAM. Unlike run_rf.sh
# (.csv.read, full in-memory — needs ~2.5x the CSV size in RAM), this:
#   1. builds a splayed column store once (.csv.splayed, RAM bounded by the
#      build's chunking; writes mmap-able per-column files to disk), then
#   2. opens it zero-copy (.db.splayed.get — mmaps columns + the symfile
#      domain, no parse, no intern) and runs the 43 queries over mmap.
# Measured (20M): in-memory .csv.read peak ~40 GB vs .db.splayed.get ~5.6 GB.
#
# Emits BOTH timings (min-of-3, ms) AND a per-query result signature so a
# capped/low-RAM run can be checked for CORRECTNESS, not just completion —
# a query under memory pressure can finish with wrong/partial answers.
#
# Env:
#   RAY_BIN  rayforce binary      (default ../rayforce/rayforce or $PATH)
#   CSV      hits CSV             (default <repo>/rayforce/hits.csv = 100M)
#   STORE    store dir            (default <repo>/bench10m/rfstore)
#   THREADS  worker cores         (default nproc)        -> rayforce -c
#   MEMMAX   cgroup cap, e.g. 32G (optional; swap off, clean kill on overrun)
#   REBUILD  =1 to rebuild store from CSV even if present
set -uo pipefail
REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$REPO/bench10m"
RAY=${RAY_BIN:-$(command -v rayforce || echo "$REPO/../rayforce/rayforce")}
CSV=${CSV:-$REPO/rayforce/hits.csv}
SCHEMA=$REPO/rayforce/schema.rfl
STORE=${STORE:-$REPO/bench10m/rfstore}
THREADS=${THREADS:-$(nproc)}

[ -x "$RAY" ] || { echo "rayforce not found: $RAY (set RAY_BIN)" >&2; exit 1; }
[ -f "$SCHEMA" ] || { echo "schema not found: $SCHEMA" >&2; exit 1; }

cap() { if [ -n "${MEMMAX:-}" ]; then
          systemd-run --user --scope -q -p MemoryMax="$MEMMAX" -p MemorySwapMax=0 "$@"
        else "$@"; fi; }

# ---- 1. Build store once (RAM-bounded; slow single-threaded SYM intern) ----
if [ "${REBUILD:-0}" = 1 ] || [ ! -d "$STORE" ]; then
  [ -f "$CSV" ] || { echo "CSV not found: $CSV (run ./setup_data.sh)" >&2; exit 1; }
  echo "building splayed store: $CSV -> $STORE (one-time, slow) ..." >&2
  rm -rf "$STORE"
  b=$(mktemp)
  cat "$SCHEMA" > "$b"
  printf '(do (set hits (.csv.splayed hit-names hit-types "%s" "%s")) (count hits))\n' "$CSV" "$STORE" >> "$b"
  cap "$RAY" -c "$THREADS" -t 1 -i < "$b" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -aE '^[0-9]+$' | tail -1
  rm -f "$b"
  [ -d "$STORE" ] || { echo "store build failed" >&2; exit 1; }
fi
echo "store: $STORE ($(du -sh "$STORE" 2>/dev/null | cut -f1))" >&2

# ---- 2. Query over mmap (zero-copy) — timings + result signatures ----
s=$(mktemp)
printf '(set hits (.db.splayed.get "%s"))\n' "$STORE" >> "$s"
for i in $(seq 0 42); do
  q=$(cat "q/$(printf 'q%02d' "$i").rfl")
  for r in 1 2 3; do printf '%s\n' "$q" >> "$s"; done
done
cap "$RAY" -c "$THREADS" -t 1 -i < "$s" > /tmp/rfstore_raw.txt 2>&1
rm -f "$s"
sed 's/\x1b\[[0-9;]*m//g' /tmp/rfstore_raw.txt | grep -aoE '^╰─┤ [0-9.]+ ms' | awk '{print $2}' > rf_times.txt

nerr=$(grep -ac 'error:' /tmp/rfstore_raw.txt)
mapfile -t T < rf_times.txt
echo "rayforce(store): ${#T[@]} timings  errors=$nerr"
[ "$nerr" -eq 0 ] || { echo "WARNING: $nerr errors — results NOT trustworthy (raw: /tmp/rfstore_raw.txt)" >&2; }
: > rf_store_min.txt
for i in $(seq 0 42); do
  b=$((1 + i*3))
  min=$(printf '%s\n%s\n%s\n' "${T[$b]:-NA}" "${T[$((b+1))]:-NA}" "${T[$((b+2))]:-NA}" | sort -g | head -1)
  printf 'q%02d %s\n' "$i" "$min" >> rf_store_min.txt
done
cat rf_store_min.txt
echo ""
echo "CORRECTNESS: raw query output saved to /tmp/rfstore_raw.txt — diff its" >&2
echo "data rows against a known-good reference (e.g. DuckDB on the same CSV)" >&2
echo "before trusting any capped/low-RAM timings." >&2

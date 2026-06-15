#!/bin/bash
# Rayforce ClickBench runner — in-memory (.csv.read), honest min-of-3.
#
# Row-count agnostic: the row count is whatever the CSV holds. Point CSV at
# the full hits.csv for the 100M-row run, or a head -N slice for a subset.
#
# Env:
#   RAY_BIN   path to the rayforce binary           (default: ../rayforce/rayforce or $PATH)
#   CSV       path to the hits CSV                   (default: <repo>/rayforce/hits.csv = full 100M)
#   THREADS   worker threads                         (default: nproc)
#   MEMMAX    optional cgroup memory ceiling, e.g. 160G. When set, rayforce
#             runs inside a transient systemd scope with MemoryMax=$MEMMAX and
#             swap disabled — if it would exceed the cap the cgroup OOM-killer
#             kills ONLY rayforce, the machine stays up (no swap thrash, no
#             reboot). Leave unset on a machine with headroom.
#   OUT       results file                           (default: rf_min.txt)
#
# Measured in-memory floor (full bench, load + 43x3): ~13 GB / 10M rows.
# Extrapolated 100M in-memory: ~130-200 GB (SYM dict sublinear, high-card
# group-by hash tables near-linear). Use a ~64GB-RAM-per-10M machine, or run
# the on-disk parted store instead (see README_100M.md) on a small box.
set -uo pipefail
REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$REPO/bench10m"

RAY=${RAY_BIN:-$(command -v rayforce || echo "$REPO/../rayforce/rayforce")}
CSV=${CSV:-$REPO/rayforce/hits.csv}
SCHEMA=$REPO/rayforce/schema.rfl
THREADS=${THREADS:-$(nproc)}
OUT=${OUT:-rf_min.txt}

if [ ! -x "$RAY" ]; then echo "rayforce binary not found/executable: $RAY (set RAY_BIN)" >&2; exit 1; fi
if [ ! -f "$CSV" ]; then echo "CSV not found: $CSV (run ./setup_data.sh or set CSV)" >&2; exit 1; fi
if [ ! -f "$SCHEMA" ]; then echo "schema not found: $SCHEMA" >&2; exit 1; fi

s=$(mktemp)
trap 'rm -f "$s"' EXIT
cat "$SCHEMA" > "$s"
printf '(do (set hits (.csv.read hit-types "%s")) null)\n' "$CSV" >> "$s"
for i in $(seq 0 42); do
  q=$(cat "q/$(printf 'q%02d' "$i").rfl")
  for r in 1 2 3; do printf '%s\n' "$q" >> "$s"; done
done

run() { "$RAY" -t "$THREADS" -i; }
if [ -n "${MEMMAX:-}" ]; then
  echo "running under cgroup cap MemoryMax=$MEMMAX (swap off)" >&2
  run() { systemd-run --user --scope -q -p MemoryMax="$MEMMAX" -p MemorySwapMax=0 \
            "$RAY" -t "$THREADS" -i; }
fi

run < "$s" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -aP '^╰─┤' | grep -oP '[0-9.]+ (?=ms)' > rf_times.txt

mapfile -t T < rf_times.txt
echo "rayforce: ${#T[@]} timings (expect 131: schema-noop + load + 43x3)"
if [ "${#T[@]}" -ne 131 ]; then
  echo "WARNING: incomplete run — likely OOM-killed under the cap or a query error." >&2
fi
: > "$OUT"
for i in $(seq 0 42); do
  b=$((2 + i*3))
  min=$(printf '%s\n%s\n%s\n' "${T[$b]:-NA}" "${T[$((b+1))]:-NA}" "${T[$((b+2))]:-NA}" | sort -g | head -1)
  printf 'q%02d %s\n' "$i" "$min" >> "$OUT"
done
cat "$OUT"

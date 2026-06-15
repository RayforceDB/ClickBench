# Rayforce ClickBench — 100M-row run

Portable harness to run the 43 ClickBench queries against rayforce on the
full 100M-row dataset. Clone, build rayforce, fetch data, run.

## 1. Build rayforce

From the rayforce repo (sibling checkout works by default):

```
git clone git@github.com:RayforceDB/rayforce.git
cd rayforce && make -j release      # produces ./rayforce
```

## 2. Fetch the dataset

```
cd ClickBench
bench10m/setup_data.sh              # downloads full hits.csv (~14 GB gz -> ~76 GB)
```

Optional smaller slice for a quick check (cheap `head`):

```
ROWS=10000000 bench10m/setup_data.sh   # also writes rayforce/hits_10000000.csv
```

## 3. Run

In-memory (`.csv.read`) — the default, fastest, RAM-heavy:

```
RAY_BIN=/path/to/rayforce CSV=$PWD/rayforce/hits.csv bench10m/run_rf.sh
```

Threads default to `nproc`; override with `THREADS=`. Results (min-of-3 per
query, ms) print and land in `bench10m/rf_min.txt`.

### Memory — measured, and how to not crash the box

In-memory load holds the whole dataset resident. Measured floor for the full
bench (load + all 43 queries x3):

| rows | in-memory floor | true peak |
|------|-----------------|-----------|
| 10M  | ~13 GB          | ~20 GB    |
| 100M | ~130-200 GB (extrapolated) | — |

The 100M figure is an extrapolation: the SYM dictionary grows sublinearly but
high-cardinality group-by hash tables grow near-linearly, so size it for the
upper end. **A ~180 GB machine is the target for the in-memory 100M run.**

If you are unsure the dataset fits, cap memory so a miss kills only rayforce
(no swap thrash, no reboot) instead of taking down the machine:

```
RAY_BIN=/path/to/rayforce CSV=$PWD/rayforce/hits.csv MEMMAX=160G bench10m/run_rf.sh
```

`MEMMAX` runs rayforce in a transient `systemd-run --user --scope` with
`MemoryMax` set and swap disabled. On overshoot the cgroup OOM-killer takes
only that process; `run_rf.sh` then reports an incomplete run (fewer than 131
timings) rather than hanging. Raise `MEMMAX` and rerun.

### Low-RAM alternative: on-disk parted store

The in-memory path needs ~180 GB for 100M. On a smaller box, build the
on-disk parted store instead — it ingests the CSV in bounded chunks and
queries run over memory-mapped columns, so resident memory stays small. See
`rayforce/run.sh` (`.csv.parted` ... `RAY_PART_ROWS`), which is the
out-of-core equivalent of disk-based engines (duckdb-on-file, clickhouse).

## Reference points (10M, same box, in-memory floors)

For sizing other engines on the same machine:

| engine | mode | 10M RAM floor |
|--------|------|---------------|
| DuckDB (`.db` on disk) | streams from disk | < 1 GB |
| DuckDB (`:memory:`)    | compact columnar in RAM | < 1 GB |
| Polars (`scan_parquet`) | lazy, materializes touched columns | 2-4 GB |
| rayforce (`.csv.read`)  | full frame in RAM | ~13 GB |

rayforce in-memory is the RAM-heavy one by design (speed for memory); the
others stream or hold compact representations, so 16 GB is ample for them at
10M and they are not the binding constraint when choosing the machine.

# rind bench harness

Comparative benchmarks for every shipped rind command vs `podman` (always) and `docker` (when daemon is up). Driven by [poop](https://github.com/andrewrk/poop) for idempotent commands; outer-loop shell timing for `rm` and `pull-cold` (poop has no setup hook).

## Prereqs

- `poop` on PATH. Install: `git clone https://github.com/andrewrk/poop && cd poop && zig build -Doptimize=ReleaseFast && cp zig-out/bin/poop ~/.local/bin/`.
- `podman` (recommended — rootless / daemonless = apples-to-apples vs rind).
- `docker` optional. Skipped automatically if `docker ps` fails.
- `zig` 0.16.0 (already required by the project).

## Run

```sh
just bench               # full pass: build release + every scenario
just bench-quick         # skip pull-cold + rm (read-only + run only, ~2 min)
just bench-snapshot      # copy results/latest.md → results/history/<date>_<sha>.md
```

Or directly:

```sh
bash bench/run-all.sh                  # full
bash bench/run-all.sh --skip rm,pull-cold
bash bench/run-all.sh --only run
bash bench/run-all.sh --no-build       # use existing zig-out/bin/rind
```

## Build mode

The harness builds with `zig build -Doptimize=ReleaseFast -Dstrip` and **refuses Debug**. An unstripped 71MB Debug binary costs ~33ms wall on every `rind run` because libcrun memfd-clones `/proc/self/exe` (see `build.zig:28`). Debug numbers would dominate the <80ms target and not reflect what users see.

## Scenarios

| script | command | type | notes |
|---|---|---|---|
| `run.sh` | `run --rm alpine /bin/true` | poop 5s | flagship; <80ms target (`docs/rind.md:42`) |
| `ps.sh` | `ps -a` | poop default | pre-creates 5 stopped containers per runtime |
| `images.sh` | `images` | poop default | read-only |
| `inspect.sh` | `inspect alpine:3.19` | poop default | read-only |
| `pull-warm.sh` | `pull alpine:3.19` (warm) | poop 3s | <100ms target (`docs/rind.md:271`) |
| `pull-cold.sh` | `pull alpine:3.19` (cold) | outer 3 iters | rind only, wipes `RIND_ROOT` between iters, captures `--timing` |
| `rm.sh` | `rm <container>` | outer 50 iters | pre-creates per-iter container |

## Results

`bench/results/latest.md` is regenerated each run. Snapshots live in `bench/results/history/`. Raw poop output is captured under `bench/results/.raw/` (gitignored — useful for debugging the parse).

## Hot-spot map — if a scenario benches slow

Each scenario has a named follow-up. Don't go fishing.

1. **`run` >80ms** → instrument overlay setup in `src/runtime/` with `Io.Clock.awake.now(io)` (mirror `src/pull.zig:360,398,631,660`). Add a `--timing` flag on `run` like `pull` already has. Suspects: overlay `mount(2)` syscall, rootless `chown`, bundle compose.
2. **`run` slow + ReleaseFast+strip binary still >20MB** → try `-Doptimize=ReleaseSmall`. memfd-clone of `/proc/self/exe` cost in `vendor/crun-1.23/src/cloned_binary.c` scales with binary size.
3. **`ps` slow vs docker** → `src/cli/ps.zig:129` walks `/proc/*` to reconcile `.running` rows. With many host pids this is `O(host_pids)`. Fix: only `stat /proc/<pid>` for pids in `state.json`.
4. **`pull-warm` >100ms** → likely TLS handshake or DNS. Check if HEAD-on-warm-cache is even necessary in `src/registry/`; ETag/digest skip would eliminate the round-trip. musl + `dev-libc` quirk noted at `build.zig:21-25`.
5. **`run --rm` slower than `run` (no `--rm`)** → `state.json` fsync on teardown. Likely the next-tallest pole after the MNT_DETACH win in `a9a76b4`.

## Caveats

- `docker` runs against a daemon (image already mmap'd in daemon memory). Treat docker numbers as informational, not the apples-to-apples comparison. **podman is the comparator that matters.**
- Cold pull benches network — re-running with different ISPs / times of day will give very different numbers. Trend it, don't chase a single absolute.
- Bench machines should be on AC, not battery. Disable `intel_pstate`/`amd-pstate` boost throttling for stable numbers if you care about <5% noise.

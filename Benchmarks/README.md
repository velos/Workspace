# Workspace benchmarks

`WorkspaceBenchmarks` measures Workspace operations against generated fixtures. It builds on macOS and Linux only and doesn't run as part of `swift test`.

## Running

```sh
swift run -c release WorkspaceBenchmarks --preset small --json Benchmarks/Results/before.json
swift run -c release WorkspaceBenchmarks --preset small --json Benchmarks/Results/after.json \
  --compare Benchmarks/Results/before.json
swift run -c release WorkspaceBenchmarks --preset medium --filter transaction,limitedWrite
```

Scenario IDs have the form `backend/persistence/operation`, such as `local/directory/checkpointIncremental`. `--filter` takes comma-separated substrings of those IDs. `--compare` prints timing ratios and exact count differences against a saved report; compare the same preset on the same machine. `--json` rewrites the report after every scenario. Run `--help` for iteration counts, warmups and deadlines.

| Preset | Regular files | Size | Rough time at defaults |
| --- | --- | --- | --- |
| `small` | 1,000 | about 20 MiB | 2 to 5 minutes |
| `medium` | 10,000 | about 200 MiB | 10 to 30 minutes |
| `large` | 100,000, deeply nested | about 98 MiB | well over an hour |

The `large` preset runs only the local backend. Times depend on the filesystem and whether native watchers are available.

## Method

- Each scenario runs in a fresh child process, with one warmup and five measured samples by default. A child that exceeds the deadline (30 minutes by default) is killed and reported as failed.
- Fixture generation and per-sample setup are excluded from timing and counters. Write scenarios use independently prepared stores, so `write1001` always times exactly the 1,001st mutation.
- Without `--fixture-dir`, fixtures and scratch trees live in the temporary directory and are removed on completion or interrupt. `--fixture-dir PATH` generates a fixture there, or validates and reuses one already there. `--keep-fixture` preserves a generated one.
- If any scenario fails, the run exits nonzero after writing the successful results. Run outside a restrictive macOS sandbox, or the FSEvents scenarios fail.

| Scenario | What's timed | Setup excluded | Counter blind spots |
| --- | --- | --- | --- |
| `writeText`, `apply50`, `limitedWrite` | One recorded write, 50 edits, a quota-limited write with warm accounting | No-op preparation, file reset, priming the limit accounting | Checkpoint store; Limited's metadata traversal is visible |
| `transaction`, `transactionFirst` | Begin, one draft write, commit | Preparation; for `transaction` only, an initial begin and discard and a baseline checkpoint | Draft filesystem, checkpoint store |
| `preview` | One edit preview | Preparation | Draft filesystem |
| `checkpointFirst`, `checkpointIncremental` | First capture; capture after one change | Preparation; for incremental, the baseline and the change | Checkpoint store |
| `diff`, `restore` | Checkpoint-to-current diff or restore after one change | Preparation, baseline, change | Checkpoint store |
| `readCheckpoint`, `readCheckpointWarm`, `readCurrent` | Cold and primed checkpoint reads; a current read | Baseline; the first read for the warm variant | Checkpoint store |
| `search`, `glob` | Search for an absent literal; a `**/*` glob | Preparation | Glob internals; `globMatches` is visible |
| `history1000`, `history1000Cached` | Loading 1,000 mutations in a fresh directory-backed Workspace; reading cached in-memory history | Seeding 1,000 mutations | Checkpoint store |
| `write1001` | The 1,001st recorded directory-backed write | Preparation and 1,000 mutations | Checkpoint store |
| `eventsInitial`, `eventsExternal` | Starting observation; an external write until its event arrives | Preparation; for external, the initial observation | The external write itself; recaptures are visible |

## Reading the results

The table reports median and p90 wall time (linear interpolation between samples), backend bytes and calls read, `stat` and list calls, entries visited, glob matches, logical store bytes and files written, and memory: setup RSS high-water, its increase during the operation, RSS held with the result alive, and that held figure for the first run.

- Counters observe calls at the `FileSystem` boundary, not system calls. They exclude checkpoint-store I/O and a backend's internal glob traversal. Scoped walks report `walk` and `walkEntry` counters, and their content reads still count as reads.
- Store writes are estimated from directory metadata before and after the operation: appended growth or the final size of created and replaced files. Temporary and deleted files, repeated overwrites and OS write amplification don't show.
- After the first run, allocator reuse hides most of a result's memory, so the measured-sample memory figures can be near zero or slightly negative. Use the first-run column for a result's live footprint. Zero high-water growth can also mean reuse.
- The JSON report keeps every sample, including warmups, and each child's peak RSS. RSS is normalized to bytes on both platforms.

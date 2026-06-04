# Test report — mergerfs-tools maintenance runner

**Host:** ZimaCube Pro (amd64, ZimaOS 1.6.1, kernel 6.12.x)
**Date:** 2026-06-04 · **Operator:** maintainer · **Guide:** [TESTGUIDE-mergerfs-tools.md](TESTGUIDE-mergerfs-tools.md)
**Feature:** `scripts/pool-status.sh` + `scripts/mergerfs-tool.sh` + `build/Dockerfile.mergerfs-tools`

**Test rig:** reused the 30-May single throwaway disk (Hitachi HTS723232, 298 GiB; it
re-enumerated as `/dev/sda` this session — device letters are not stable across reboots,
as the KB warns). GPT, 3× ext4: `SR-DATA1` (80 G), `SR-DATA2` (80 G), `SR-PARITY` (138 G),
mounted at `/DATA/srtest/{data1,data2,parity}`. Pool target `/DATA/srtest/pool`.
Branches `data1:data2` (parity excluded). Other disks (Samsung 4 TB, Crucial 1 TB, both
exFAT user data; `nvme0n1` system) **never touched**.

> **Single-spindle functional test** — exercises every software path of the runner.
> NOT a multi-disk fault-tolerance test. **arm64 not exercised.**

## Result summary

| # | Phase | Result |
|---|---|---|
| 0 | Build runner image on host (`python:3-alpine`+rsync+7 tools @`80d6c95`) | ✅ `mergerfs-tools:local`, 50.3 MB |
| 1 | Tool execution inside container (musl libc risk) | ✅ Python 3.14.5, rsync 3.4.3; `balance`/`dedup`/`fsck` import + argparse OK — **no `libc.so.6` crash on musl** |
| 2 | Install / sysext merge | ✅ checksum OK; mergerfs **v2.42.0** (upgraded base v1.5.4), snapraid **v14.5** |
| 3 | Config + unbalanced dataset (28× 512 MB = 14 G on data1, 0 on data2) | ✅ data1 19% / data2 1% |
| 4 | Initial `snapraid sync` (direct, first-ever parity) | ✅ "Everything OK" |
| 5 | `mergerfs-tool.sh status` (native, no Docker) | ✅ spread 18 pts → "noticeably unbalanced"; mergerfs `v2.42.0` |
| 6 | `mergerfs-tool.sh --quiesce balance` | ✅ stop timers → containerized move of **13/28** files → "Branches within 2.0% range" → auto `snapraid sync` "sync OK" → re-arm timers |
| 7 | Post-balance delete-guard interaction | ✅ moved-as-deleted files did **not** false-abort the sync (post-move threshold raised; fail-closed disk-missing checks kept) |
| 8 | `status` after balance | ✅ data1 11% / data2 9%, spread 2 → "reasonably balanced" |
| 9 | Distribution | ✅ pool 28 files = 15 (data1) + 13 (data2) |
| 10 | **Data integrity** | ✅ pool checksum manifest **byte-identical** before/after (`sha256` of manifest equal; `HASH_MATCH_PASS`) |
| 11 | **`snapraid check`** (full parity-vs-data verify) | ✅ "Everything OK" |
| 12 | `uninstall.sh` | ✅ reverted to base mergerfs v1.5.4, units removed, sysext unmerged, data/config preserved |
| — | Full teardown (post-test) | ✅ runner image removed, test files + config + staged repo cleaned; box back to pre-test state |

## Bugs found and fixed during this test

- **`pool-status.sh` version parse** — grepped for the word "version", but
  `mergerfs --version` prints `mergerfs v2.42.0` (no such word) → showed `?`.
  Fixed to `head -1 | awk '{print $NF}'`.
- **Runner hardcoded `-v /media:/media`** — branches outside `/media` (here
  `/DATA/srtest/{data1,data2}`) were invisible inside the container, so
  `mergerfs.balance` could read the branch list from the pool xattr but not reach the
  files. Fixed to bind-mount **each configured branch** at its own path (derived from
  `pool.env` `BRANCHES`). This would have broken any non-`/media` pool.

## Environment notes (ZimaOS specifics, also folded into ZIMAOS-KNOWLEDGE.md §7.5)

- **Docker needs root on ZimaOS.** As the SSH user, the buildx CLI-plugin fails to load
  (no access to `/DATA/.docker`) and `docker build` silently degrades to global help.
  Run via `sudo`.
- **`docker build - < Dockerfile` over SSH does not work** (stdin-as-Dockerfile doesn't
  survive the hop). Transfer the file and build with `-f <file> <context>`, or run the
  stdin form directly on the host. ADD-from-URL needs no local context.
- **busybox lacks `xargs` and `diff`.** Integrity checks used `find -exec sha256sum {} +`
  and compared manifest hashes instead.
- **mergerfs.* tools import cleanly on Alpine musl** — the `ctypes` libc binding for
  `lgetxattr` works; no glibc assumption bit us.

## Verdict

Full `--quiesce balance` flow validated end-to-end on real hardware (amd64), including
bit-level parity integrity. Same caveats as the storage core: single-spindle, and arm64
still needs a pass. Ready for wider testing (see the tester guide).

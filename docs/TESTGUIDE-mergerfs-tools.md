# Tester guide — mergerfs-tools maintenance runner

Hi @gelbuilding 👋 — thanks for offering to test this. This guide walks you through
validating the new **pool-maintenance tooling** (`pool-status.sh` + `mergerfs-tool.sh`)
that wraps [trapexit/mergerfs-tools](https://github.com/trapexit/mergerfs-tools).
It builds on the base module you already validated — credit for the underlying
filesystem goes to **trapexit**, author of [mergerfs](https://github.com/trapexit/mergerfs).

It should take ~30–45 min plus disk I/O time. Please record results in the table at
the bottom and report back on the PR or the forum thread.

---

## ⚠️ Read first — safety

- **Use throwaway / test data only.** `balance`, `consolidate -e`, `dedup -e`, `dup -e`
  physically move or delete files between disks. Don't point this at data you can't lose
  until you trust it.
- **It needs root + Docker.** ZimaOS has no native Python, so the tools run in a small
  one-shot container (`python:3-alpine` + rsync, ~50 MB) that is built automatically on
  first use. The storage layer itself stays native — Docker is only for this maintenance step.
- **`balance` needs ≥ 2 data branches** to have somewhere to move files to.
- **`balance` and SnapRAID:** a balance moves files between disks, which SnapRAID sees as
  *removed from one disk + added to another*. Always use `--quiesce` — it stops the
  sync/scrub timers, runs the tool, re-syncs parity, and re-arms the timers. `balance`
  **refuses to run without it** (it has no dry-run upstream).
- **arm64 is untested.** If you're on a Zima ARM board, please note that — your run would
  be the first arm64 data point.
- Make sure the pool is **idle** during a balance (pause Samba / apps writing to it).

---

## Prerequisites

1. The module installed and a pool mounted (see the main [README](../README.md) →
   *Install*). Confirm:
   ```sh
   /usr/bin/mergerfs --version        # expect v2.42.0
   /usr/bin/snapraid --version        # expect v14.5
   ```
2. A **test pool** with at least **two data branches** + a parity disk, configured in:
   - `/DATA/AppData/mergerfs-snapraid/config/pool.env`     (`MOUNTPOINT`, `BRANCHES`, `OPTS`)
   - `/DATA/AppData/mergerfs-snapraid/config/snapraid.conf` (`data`/`parity`/`content`)
3. The pool started and an initial parity built:
   ```sh
   sudo systemctl start mergerfs-pool.service
   sudo /usr/bin/snapraid -c /DATA/AppData/mergerfs-snapraid/config/snapraid.conf sync
   ```

A shortcut used throughout this guide:
```sh
T=/DATA/AppData/mergerfs-snapraid/scripts/mergerfs-tool.sh
```

---

## Test cases

### T1 — `status` (native, no Docker)
```sh
sudo "$T" status
```
**PASS:** prints the pool mountpoint + mergerfs version, a per-branch fullness table
(SIZE/USED/AVAIL/USE%), and a verdict line — either
`-> noticeably unbalanced ...` (spread ≥ 15 points) or `-> reasonably balanced ...`.
No Docker is invoked.

### T2 — first-run image build
The image builds automatically the first time you run a containerized tool (e.g. T5).
To pre-build it manually from the Dockerfile that `install.sh` placed next to the scripts:
```sh
sudo DOCKER_CONFIG=/DATA/.docker docker build -t mergerfs-tools:local - \
  < /DATA/AppData/mergerfs-snapraid/scripts/Dockerfile.mergerfs-tools
sudo DOCKER_CONFIG=/DATA/.docker docker images mergerfs-tools:local
```
**PASS:** an image `mergerfs-tools:local` exists (~50 MB). Python 3 + rsync inside:
```sh
sudo DOCKER_CONFIG=/DATA/.docker docker run --rm mergerfs-tools:local \
  sh -c 'python3 --version; rsync --version | head -1'
```

### T3 — `balance` refuses without a parity plan
```sh
sudo "$T" balance
```
**PASS:** it prints `REFUSE: 'balance' moves files immediately and has no dry-run.`
and exits **without moving anything**.

### T4 — dry-run `consolidate` (safe, no data moved)
Pick any directory inside the pool that has files spread across branches:
```sh
sudo "$T" consolidate "$MOUNTPOINT/SomeDir"     # no -e = print only
```
**PASS:** it prints the `rsync ...` commands it *would* run but moves nothing
(file counts on each branch unchanged).

### T5 — the real balance (`--quiesce`)
If your pool is already uneven, skip ahead. To create a deliberate imbalance on a
**test** pool, write some data directly onto the **first** branch (use a real branch
path from your `pool.env` `BRANCHES`, e.g. `/media/sda`):
```sh
B1=/media/sda     # <-- set to your first branch
for i in $(seq 1 20); do sudo dd if=/dev/zero of="$B1/testfile_$i.bin" bs=8M count=64 status=none; done
sync
sudo "$T" status   # expect a clear spread, "noticeably unbalanced"
```
Now balance:
```sh
sudo "$T" --quiesce balance
```
**PASS:** you should see, in order:
1. `--- stopping snapraid timers ...`
2. `--- running mergerfs.balance ---` then per-file `rsync` moves
3. `Branches within 2.0% range:` with each branch's free %
4. `--- snapraid sync ...` → `sync OK ...`
5. `--- re-arming snapraid timers ---`

Then confirm:
```sh
sudo "$T" status          # spread should now be small, "reasonably balanced"
systemctl is-active snapraid-sync.timer   # timers should be back to their prior state
```

### T6 — integrity after balance
```sh
CONF=/DATA/AppData/mergerfs-snapraid/config/snapraid.conf
sudo /usr/bin/snapraid -c "$CONF" status     # expect "No error detected"
sudo /usr/bin/snapraid -c "$CONF" check      # full parity-vs-data verify; expect "Everything OK"
```
Optional checksum proof that files survived the move unchanged
(note: busybox on ZimaOS has **no `xargs`/`diff`** — use `find -exec`):
```sh
sudo find "$MOUNTPOINT" -name 'testfile_*.bin' -exec sha256sum {} + | sort > /DATA/after.txt
# compare against a baseline you captured the same way before the balance
```
**PASS:** `snapraid check` = "Everything OK"; every file still present and readable.

### T7 — `fsck` audit (read-only)
```sh
sudo "$T" fsck "$MOUNTPOINT"
```
**PASS:** runs an ownership/permission audit and reports findings without changing
anything (it only modifies metadata if you add `-f manual|newest|nonroot`).

### T8 — (optional) `dedup` dry-run, `ctl` introspection
```sh
sudo "$T" dedup "$MOUNTPOINT"               # dry-run; add -e (and --quiesce) to actually remove
sudo "$T" ctl -m "$MOUNTPOINT" list values  # show runtime mergerfs options
```
**PASS:** dedup lists duplicates without removing; ctl prints the live option values.

---

## Cleanup (test data)
```sh
sudo rm -f /media/sda/testfile_*.bin        # whichever branch(es) you wrote to
sudo /usr/bin/snapraid -c "$CONF" sync       # realign parity to the removed test files
```

---

## Results — please fill in

| # | Test | Result (✅/❌) | Notes (arch, output, surprises) |
|---|---|---|---|
| T1 | `status` | | |
| T2 | image build + python/rsync | | |
| T3 | `balance` refuses w/o `--quiesce` | | |
| T4 | `consolidate` dry-run moves nothing | | |
| T5 | `--quiesce balance` rebalances + re-syncs | | |
| T6 | `snapraid check` "Everything OK" | | |
| T7 | `fsck` audit | | |
| T8 | dedup dry-run / ctl (optional) | | |

**Environment:** ZimaOS version ____ · board (amd64 / arm64) ____ · mergerfs ____ · snapraid ____

**How to report:** comment on the PR
([#1](https://github.com/chicohaager/zimaos-mergerfs-snapraid-sysext/pull/1)) or the
forum thread. Logs live in `/DATA/AppData/mergerfs-snapraid/logs/`. Thanks! 🙏

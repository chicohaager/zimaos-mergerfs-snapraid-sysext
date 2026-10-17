# Hardware test log — zimaos-mergerfs-snapraid-sysext

**Host:** ZimaCube Pro (amd64, ZimaOS 1.6.1, kernel 6.12.25)
**Date:** 2026-05-30 · **Operator:** maintainer · **Plan:** [TESTPLAN.md](TESTPLAN.md)

**Test rig:** single throwaway disk `/dev/sdd` (Hitachi HTS723232, 298 GiB), GPT,
3× ext4: `SR-DATA1` (80 G), `SR-DATA2` (80 G), `SR-PARITY` (~135 G). Mounted at
`/DATA/srtest/{data1,data2,parity}`. Pool target `/DATA/StorageTest`.

> **Single-spindle functional test** — validates all software paths. NOT a real
> fault-tolerance test (data + parity share one physical disk).

## Result summary

| # | Phase | Result |
|---|---|---|
| 0 | sysext build + merge (earlier) | ✅ gzip `.raw`, merged, binaries on `/usr/bin` |
| 1 | Partition + format `/dev/sdd` (by maintainer) | ✅ 3× ext4 labelled |
| 2 | Mount by label | ✅ data1/data2 by LABEL; parity by device (see G2) |
| 3 | Pool start via `mergerfs-pool.service` | ✅ `active`, `/DATA/StorageTest` = fuse.mergerfs 157 G |
| 4 | Write 32 files (~296 MB) | ✅ even spread 16/16 across branches (`category.create=mfs`) |
| 5 | `snapraid sync` (via wrapper) | ✅ parity built, "Everything OK"; guard parsed `removed=0` |
| 6 | `snapraid scrub` (full) | ✅ "Everything OK" |
| 7 | Single-file loss → `fix` | ✅ deleted `file_24.bin`, recovered, `check` OK |
| 8 | **Mass-delete guard** | ✅ deleted 11 → `removed=11 > threshold=5` → **ABORT**, parity untouched |
| 9 | Single-parity limit (honest) | ⚠️ fix after cross-disk bulk delete → 156 unrecoverable (expected w/ 1 parity) |
| 10 | `replace-disk.sh d1` (dead-disk sim) | ✅ emptied data1 → rebuilt 12/12 files, 0 unrecoverable, `check` OK, pool auto-restarted |
| 11 | **Boot-race reboot** | ✅ cold boot → sysext merged, **pool auto-mounted**, watchdog fired +9s, timers armed |
| 12 | `uninstall.sh` preserves data | ✅ module + units + binary removed, **all data/parity/config preserved** |

## Key evidence

**Pool (phase 3):**
```
ActiveState=active  Result=success
/DATA/StorageTest 1:2 fuse.mergerfs   157G   /DATA/StorageTest
/usr/bin/mergerfs -o defaults,allow_other,...,branches-mount-timeout=30 /DATA/srtest/data1:/DATA/srtest/data2 /DATA/StorageTest
```
→ confirms merged binary runs, unit + wrapper work, `branches-mount-timeout=30`
accepted by mergerfs 2.42.0.

**Sync + guard parse (phase 5):** real SnapRAID 14.5 summary parsed correctly —
`0 equal / 32 added / 0 removed …` → `removed=0 threshold=200`. Parity "Everything OK".

**Single-file recovery (phase 7):**
```
deleted /DATA/srtest/data1/file_24.bin (10000000 bytes) → not in pool
snapraid fix → "recovered file_24.bin", 39 recovered, 0 unrecoverable
restored YES, size=10000000 ; snapraid check → Everything OK
```

**Mass-delete guard (phase 8):**
```
removed=11 threshold=5
ABORT: 11 removed > 5 — sync skipped (possible data loss).   (wrapper exit=1)
```
The guard prevented a bulk-delete from poisoning parity. ✅

**Single-parity limit (phase 9, honest):** the 11 deleted files spanned BOTH data
disks; a `fix` then reported 156 **unrecoverable** blocks. This is correct SnapRAID
behaviour — one parity reconstructs at most one disk per stripe. It is *why* the
guard exists and why production wants parity ≥ the failure domain. Not a module bug.

**Disk replacement (phase 10):**
```
emptied /DATA/srtest/data1 (0 files) → replace-disk.sh d1 (auto-confirmed)
guards passed (mountpoint ✓, ext4 ✓) → fix -d d1: 449 recovered, 0 unrecoverable, Everything OK
check → Everything OK ; sync re-aligned ; pool auto-restarted (fuse.mergerfs)
data1 restored: 12/12 files
```

## ZimaOS gotchas discovered (folded into README + KB)

- **G1 — `mksquashfs` must be `gzip`**: kernel SquashFS has ZLIB/LZ4/LZO only, no
  ZSTD/XZ. Confirmed live: zstd `.raw` would fail the merge.
- **G2 — stale signatures survive `mkfs.ext4`**: `/dev/sdd3` kept an old
  `zfs_member 'datastore'` label, so `blkid` wouldn't expose its ext4 LABEL and
  `mount LABEL=SR-PARITY` failed. Mounted by device instead. Fix for clean
  identity: `wipefs --types zfs_member -a <part>` before mkfs (or `wipefs -a`).
- **G3 — `/mnt` is read-only** on ZimaOS; mountpoints must live under `/DATA`.
- **G4 — `/usr/local/bin` absent, PATH = `/usr/bin:/usr/sbin`** → binaries ship in
  `/usr/bin` (build relocates the mergerfs tarball off `usr/local`).
- **G5 — security-hook**: `mkfs`/format is blocked for the agent by design →
  destructive disk prep is run by the operator.

## Boot-race (phase 11) — the decisive result

Test mounts pinned in `/etc/fstab` by **LABEL** (`nofail`), units enabled, then
`systemctl reboot`. After the cold boot:

```
uptime: up 0 min                              # genuine reboot
systemd-sysext status → mergerfs-snapraid     # merged on boot
findmnt /DATA/StorageTest → fuse.mergerfs     # *** POOL AUTO-MOUNTED ***
mergerfs-pool.service → active, enabled
mergerfs-pool-watchdog.timer fired 9s after boot
snapraid-sync.timer → Sun 04:00 ; snapraid-scrub.timer → Sun 05:00  (armed)
```

**The boot-race fix works.** `After=systemd-sysext.service` + the 15 s watchdog
timer started the pool after the `/usr` merge completed.

**Bonus finding (open-point #4 confirmed):** across the reboot the test disk
re-enumerated **`/dev/sdd` → `/dev/sda`**. Because fstab used `LABEL=`, the mounts
came up regardless — concrete proof that by-LABEL/UUID identity is essential on
ZimaOS, where device letters are not stable.

## Uninstall (phase 12)

`/tmp` was cleared by the reboot, so the identical uninstall steps were run inline.
Result: units removed, `mergerfs-snapraid.raw` deleted, `systemd-sysext refresh`
re-merged `/usr` without our module. **Preserved:** d1=12, d2=12 files, parity
158 MB, `/DATA/AppData/.../config`. Clean removal, zero data loss.

## Two notable ZimaOS findings (folded into README + KB)

- **F1 — ZimaOS base already ships mergerfs, but ancient: `v1.5.4` (~2020)** at
  `/usr/bin/mergerfs` (+ `mergerfs-fusermount`, **no** `mount.mergerfs`), baked into
  the base `/usr` squashfs (no extension). Our sysext correctly **shadows it with
  2.42.0** while merged and **reverts to 1.5.4** on uninstall. → the module's real
  value includes *upgrading* the stale built-in, not just adding it.
- **F2 — ZimaOS auto-adopts ext4 partitions as storage**: after uninstall + fstab
  removal, the storage daemon re-mounted `sda1/sda2` under `/DATA/srtest` and wrote
  a `.zimaos_storage.json` marker (open-point #5 confirmed). Implication: pool
  branches should be the ZimaOS-managed mounts (`/media/sdX`), and manual mounts
  contend with the automounter.

## Conclusion

**Fully hardware-validated on a ZimaCube Pro (amd64).** Build → merge → pool →
sync/scrub → file recovery → mass-delete guard → disk replacement → boot-race →
uninstall all pass. Single-spindle (no real fault tolerance) and arm64 remain the
only untested dimensions.

---

## 2026-10-17 — scripts-in-sysext, late AppData disk, guards (ZimaOS 1.8.0, kernel 6.18.9)

Same rig and pool (`/DATA/StorageTest` over `/DATA/srtest/data{1,2}`). Each item was
first shown failing (stub/container tests, `tests/`) and then run on the host.

| # | Check | Result |
|---|---|---|
| 1 | `install.sh` over the old layout | ✅ scripts in `/usr/lib/mergerfs-snapraid`, old copies → `scripts/.replaced-*`, units 0644, `After=… DATA.mount` |
| 2 | AppData appears 20 s after the pool starts (forum #21) | ✅ `waiting for …pool.env`, mounted when it appeared |
| 3 | AppData never appears (`CONFIG_WAIT=5`) | ✅ unit `failed` with the path in the message |
| 4 | Timers right after install | ✅ active, next run listed (old installer: enabled but inactive until boot) |
| 5 | Sync with the unedited example `snapraid.conf` | ✅ `REFUSE`, snapraid not run, no log written |
| 6 | `branches-mount-timeout-fail` (throw-away pool) | ✅ without: rc=0, mounted despite unmounted branch · with: rc=1, nothing mounted |
| 7 | Empty, unmounted branch / marked / unmarked same-fs / real mounts | ✅ refuse · mount · NOTE + rc=1 · mount |
| 8 | Failure alert (`OnFailure=`) | ✅ `ALERT-snapraid-sync.service-*.txt` written within 1 s |
| 9 | **Reboot** (`systemctl reboot`, boot 09:17:04) | ✅ see below |

**Reboot journal (abridged, `journalctl -b -o short-precise`):**

```
09:17:10.564  (sd-merge) Merged extensions into '/usr'.
09:17:10.682  Started Daily SnapRAID sync.            (timer active after boot)
09:17:10.738  Starting mergerfs storage pool (ZimaOS)...      (via multi-user.target)
09:17:10.762  start-pool.sh: waiting for branch /DATA/srtest/data1 to mount (up to 90s)...
09:17:12.776  start-pool.sh: waiting for branch /DATA/srtest/data2 to mount (up to 90s)...
09:17:14.135  mergerfs: All 2 branches are mounted
09:17:14.137  start-pool.sh: mergerfs pool mounted at /DATA/StorageTest
09:17:19.102  mergerfs-pool-watchdog.service: Deactivated successfully.
```

The branch-mount race is real on this box: the pool unit started 0.17 s after the
merge, while both branch partitions were still unmounted; the branch wait held it
~3 s. `systemctl --failed` empty, all 36 containers back.

**Not covered:** a reboot with `APP_DIR` on a second, late-mounting disk (here AppData
is on `/DATA`, readable at once) — covered only by item 2 (late appearance at runtime).
**Note:** `config/snapraid.conf` on this rig is byte-identical to the example (mtime
2026-06-05), so no parity sync is possible there until it is rewritten.

---

## 2026-10-17 (afternoon) — test rig re-armed; SnapRAID 15.0 compatibility

**Rig change:** the old parity partition (now `sdc3`, 138 GiB) has **no filesystem**
any more (`lsblk`: no FSTYPE/UUID/LABEL); it was left untouched. Parity moved to the
NVMe system disk (`/DATA/srtest/parity/snapraid.parity`, a different device than the
data partitions `sdc1`/`sdc2`). `config/snapraid.conf` had been byte-identical to the
example since 2026-06-05 — rewritten for the rig (template kept as a backup).

| # | Check (SnapRAID 14.5 from the module) | Result |
|---|---|---|
| 1 | 8 × 25 MiB written through the pool | spread 4/4 across `data1`/`data2` (`mfs`) |
| 2 | `systemctl start snapraid-sync.service` | `result=success`, 8 added, guard `removed=0` |
| 3 | `snapraid check` | "Everything OK", 210 MB read |
| 4 | delete `file2.bin` on the branch → `snapraid -f … fix` | "0 unrecoverable"; all 8 sha256 OK; `diff`: "No differences" |

**SnapRAID 15.0** (static build from `Dockerfile.snapraid`, source sha256
`ceba44e1…ce19` = release digest), isolated: own parity + content files (NVMe +
`/dev/shm`), same data branches.

| # | Check | Result |
|---|---|---|
| a | `snapraid-sync.sh` with 15.0 | rc=0; the guard parses 15.0's diff summary (`8 added`, `removed=0`) |
| b | `check` | "Everything OK" |
| c | guard with `DELETE_THRESHOLD=0`, one file deleted | ABORT, names `--allow-deletes 1` |
| d | `fix` with 15.0 | "0 unrecoverable", all 8 sha256 OK, next sync clean |
| e | content format | 14.5 reads 15.0's content and 15.0 reads 14.5's (`diff` rc=0 both ways); both start with `SNAPCNT3` |
| f | 14.5 array afterwards | `diff` "No differences", `check` "Everything OK" |

→ For this module's use (ext4 branches, no snapshot option) 15.0 behaved like 14.5,
in both directions of the content file. The pin stays 14.5 until a deliberate bump.

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

> **Counting note (2026-10-19):** SnapRAID's `recovered` / `unrecoverable` numbers count
> **errors**, not files. In the v1.2.0 run further down, `d1` held 4 files of 3 MiB each =
> 4 × 12 blocks of 256 KiB (SnapRAID's default block size) = the `48 recovered errors` it
> printed. The figures above are summaries of such output, not file counts.

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

---

## 2026-10-17 (evening) — dedicated parity disk again; module with SnapRAID 15.0

**Parity partition re-created.** `wipefs -n` on `sdc3` showed why `lsblk`/`blkid` saw no
filesystem: two conflicting signatures — the May `ext4 SR-PARITY` (clean, last written
2026-07-01) **and** two stale `zfs_member` labels "datastore" at the end of the
partition (`zpool import`: no pools). That is gotcha G2 again: creating a new ext4 alone
leaves such labels behind. Decided by the maintainer: `wipefs -a`, then a fresh ext4
`SR-PARITY` without reserved blocks (behind a gate: by-id path, size, not mounted, no
holders, no importable pool). After: only the ext4 signature, `blkid -p` unambiguous;
the ZimaOS automounter did not mount it.

**Mount:** own unit `DATA-srtest-parity.mount` in `/etc/systemd/system`, by UUID, at
`/DATA/srtest/parity` (not the automounter's `/media/...`), ordered after `DATA.mount`.
Parity lives in a **sub-directory** `sr/` that exists only on that filesystem, so an
unmounted parity disk fails closed:

| # | Check | Result |
|---|---|---|
| 1 | parity copied to the new disk | sha256 identical; `check` "Everything OK", `diff` "No differences" |
| 2 | mount stopped → `systemctl start snapraid-sync.service` | `result=exit-code` — "Error accessing file '…/sr/snapraid.parity'", ABORT; ALERT file written; **no** parity file created on the NVMe underneath |
| 3 | mount started again → sync | `success`, all 8 manifest files OK |

**Module with SnapRAID 15.0** (CI build of `4a27370`, `VERSIONS` = 15.0) installed on the
rig: install's version check passed, sync over the unit read the 14.5-written content
and succeeded, `check` "Everything OK", `diff` "No differences", pool restarted active.

**Not covered:** a reboot with the new parity mount unit — done on 2026-10-18, see below.

---

## 2026-10-18 — v1.2.0 from the release assets; reboot with the parity mount unit

**Install:** source tarball of tag `v1.2.0` plus the release's `mergerfs-snapraid_amd64.raw`
and `SHA256SUMS` downloaded on the rig, `sudo ./install.sh` over the CI build of the
previous evening.

| # | Check | Result |
|---|---|---|
| 1 | `install.sh` checksum | `mergerfs-snapraid_amd64.raw: OK` |
| 2 | merged versions vs. `VERSIONS` | mergerfs v2.42.0, SnapRAID v15.0 — match |
| 3 | installed image | sha256 `d225dbe4…` = the amd64 line of the release's `SHA256SUMS` |
| 4 | existing `pool.env` / recorded AppData path | kept ("not overwritten") |
| 5 | after install | pool, parity mount, watchdog/sync/scrub timers active; 0 failed units; 36 containers |

**Reboot** (`systemctl reboot`; `boot_id` changed, back over ssh on the 3rd 10 s poll;
`journalctl -b -o short-precise`, abridged — the unit is `DATA-srtest-parity.mount`):

```
11:27:36.137  Mounted SnapRAID test-rig parity disk (SR-PARITY on the Hitachi test disk).
11:27:36.867  (sd-merge) Merged extensions into '/usr'.
11:27:36.977  Started Daily SnapRAID sync.
11:27:37.046  Starting mergerfs storage pool (ZimaOS)...
11:27:37.063  start-pool.sh: waiting for branch .../data1 to mount (up to 90s)...
11:27:39.076  start-pool.sh: waiting for branch .../data2 to mount (up to 90s)...
11:27:40.440  mergerfs: All 2 branches are mounted
11:27:40.441  start-pool.sh: mergerfs pool mounted
```

| # | Check after the reboot | Result |
|---|---|---|
| 6 | parity mount before the pool | mounted 11:27:36, pool active 11:27:40; `sr/snapraid.parity` present |
| 7 | image sha256 | unchanged, `d225dbe4…` |
| 8 | `systemctl --failed` | 0 units; timers active; 36 containers back |
| 9 | `systemctl start snapraid-sync.service` | `Result=success`, `ExecMainStatus=0`; `snapraid status`: "No error detected" |

**Scheduled runs seen on the same day:** the nightly sync (04:00) ended `success`. The
Sunday scrub (05:00) ran 0.2 s and logged "Nothing to scrub" — the default plan
(`-p 12 -o 10`) only takes blocks older than 10 days, and the array was re-synced on
2026-10-17, so `snapraid status` says "100% of the array is not scrubbed".

**Not covered:** a reboot with `APP_DIR` on a second, late-mounting disk; arm64 on real
hardware.

## 2026-10-18 — v1.2.0 on a ZimaBoard 2 (second machine, RAM-backed stand-in disks)

**Machine:** ZimaBoard 2 (DMI `product_name` "ZimaBoard2", Intel N150, 15.7 GB RAM), ZimaOS v1.8.0,
kernel 6.18.9, x86-64, `/dev/fuse` present. Its two SATA SSDs carry the box's own btrfs RAID and were not
touched. No reboot was done on this machine, and arm64 is still unverified.

**Before:** `mergerfs-snapraid.raw` (sha256 `0a4bb551…`, SnapRAID 14.5), installed 2026-10-02 under
ZimaOS 1.8.0-beta1, was still merged under 1.8.0 final (`systemd-sysext status`, merged since the 2026-10-16
boot) — a second data point for "survives ZimaOS updates", next to 1.6.1 → 1.7.1. No units, no config.

**Install exactly as the README's "From a release" block:** tag archive + `mergerfs-snapraid_amd64.raw` +
`SHA256SUMS`, then `sudo ./install.sh`: `mergerfs-snapraid_amd64.raw: OK`, "checksum OK", SnapRAID 15.0,
mergerfs 2.42.0, image sha256 `d225dbe4…` = the release's `SHA256SUMS`.

**Stand-in disks:** one 128 MiB tmpfs each for `d1`, `d2` and parity. Two plain folders or bind mounts of one
filesystem do not work: SnapRAID refuses ("Disks … are on the same device", hint `--force-device`); with
`replace-disk.sh` this ended in a failed recovery that left sync/scrub blocked and `RECOVERY-IN-PROGRESS` in
place, as documented. The example `minfreespace=20G` must be lowered for disks this small (otherwise "No space
left on device"); the run used `16M`.

| # | Check | Result |
|---|---|---|
| 1 | start with the unedited example config | pool service `failed` ("REFUSE: …/pool.env is the unedited example"), `snapraid-sync.sh` rc=1 ("REFUSE: …/snapraid.conf is the unedited example") |
| 2 | pool over `d1`+`d2` | `fuse.mergerfs`, 8 files from both disks in one folder |
| 3 | first sync, `check` | rc=0 "Everything OK"; `check`: "Everything OK" |
| 4 | guard with `DELETE_THRESHOLD=0`, one file deleted | `ABORT: 1 files removed > limit 0`, prints `sudo …/snapraid-sync.sh --allow-deletes 1`; that one-time release syncs (rc=0) |
| 5 | `d1` replaced by a blank disk, `replace-disk.sh d1` | `48 recovered errors`, `0 unrecoverable errors` (errors, not files: 4 files × 12 blocks on `d1`); all 8 files sha256-identical; timers active, marker removed, pool remounted |
| 6 | afterwards | 0 failed units; the box's 4 containers unchanged |

**Cleanup:** `uninstall.sh`, the original image put back (sha256 `0a4bb551…` again), test directories removed.

**Not covered:** a reboot on this machine, real separate disks, arm64 on real hardware.

## 2026-10-19 — v1.2.0 reboot on the ZimaBoard 2

Same machine as above, same starting point (original image `0a4bb551…`, no config, no `/etc/default`
file, 4 containers). v1.2.0 installed again from the release assets (image sha256 `d225dbe4…` = `SHA256SUMS`).
The pool for this test sits on two folders under `/DATA` (one filesystem, `.mergerfs.branch` markers),
because tmpfs disks would not survive the reboot; SnapRAID is therefore not part of this run (it refuses two
data disks on one device, see above).

Before the reboot: pool mounted as `fuse.mergerfs`, 4 random test files (1 MiB each) recorded by sha256, boot
ID, image hash, mtime of `/etc/default/mergerfs-snapraid` and the running containers saved. No established
connections to container ports, RAID `[UU]`, 0 failed units. Reboot triggered at 09:52:22 CEST (5 s delay); SSH
answered again at 09:53:08.

| # | Check after the reboot | Result |
|---|---|---|
| 1 | boot ID changed, uptime < 90 min | yes (`cd67a84a…` → `60a14b96…`) |
| 2 | `mergerfs-snapraid` merged, image sha256 unchanged | yes |
| 3 | `/etc/default/mergerfs-snapraid` present, same mtime | yes |
| 4 | `mergerfs-pool.service` active, watchdog/sync/scrub timers active | yes; mergerfs started 09:52:52, the watchdog ran at 09:52:58 and found the pool up |
| 5 | pool mounted as `fuse.mergerfs`, the 4 files byte-identical | yes |
| 6 | 0 failed units, same containers as before | yes |

11 of 11 checks passed (counted from the output file). Nothing was started by hand. Afterwards the original
image was put back (sha256 `0a4bb551…`), units, config, `/etc/default` file and test folders removed, 0
failed units, same containers.

Second run the same morning with SnapRAID on three devices: data1 in a folder on `/DATA` (eMMC), data2 in a
folder on the box's btrfs RAID, parity on a 120 GB USB SSD (exFAT, mounted by ZimaOS during boot; parity only,
because exFAT has no persistent inode numbers for data disks). First sync through `snapraid-sync.service`
(`Result=success`), `check` clean. Reboot at 10:19; afterwards 13 of 13 checks passed, including
`snapraid status` ("No error detected") and `snapraid check`. Cleanup removed the test folders on all three
devices; original image back.

Third run: the late-disk case from the forum. Installed with `install.sh --app-dir
/media/sdc1/mergerfs-snapraid`, so `config/` and `logs/` live on the USB SSD (now ext4); data2 on the same
USB SSD, data1 on `/DATA`, parity on the btrfs RAID. After the reboot the journal shows the order:

| Time (CEST) | Event |
|---|---|
| 10:41:36.62 | kernel starts |
| 10:41:40.66 | `start-pool.sh`: "waiting for /media/sdc1/mergerfs-snapraid/config/pool.env (up to 300s)..." |
| 10:41:41.24 | ZimaOS storage daemon mounts `sdc1` |
| 10:41:43.23 | "mergerfs pool mounted" |

13 of 13 checks passed (pool, timers, files byte-identical, `snapraid status`/`check` clean). Cleanup removed
the AppData folder and the test folders on all devices; original image back.

**Still not covered:** arm64 on real hardware.

## 2026-10-19 — v1.2.1 on a ZimaBoard 2 (ZimaOS 1.8.0): no alert before setup, replace-disk guards

Installed from the release assets (image sha256 `303b9a85…` = `SHA256SUMS`), stand-in disks (tmpfs, own device each).
Script: `mergerfs-guards-test.sh` in the maintainer's host-script collection.

| # | Case | Result v1.2.1 | Control: same script on v1.2.0 |
|---|---|---|---|
| 1 | 20 s after `install.sh` (watchdog timer has fired, pool refused the example) | pool unit `failed`, **0** alert files | FAIL — alert file written |
| 2 | first sync over d1+d2 | rc=0 | rc=0 |
| 3 | d1 "failed", the other data disk d2 bind-mounted at d1's path | `REFUSE: … is on the same device as d2 …`, no `snapraid fix` | FAIL — not refused |
| 4 | replacement holds a file | `REFUSE: … is not empty (first entries: …/alte-datei.bin)`, no fix | FAIL — not refused |
| 5 | replacement as ZimaOS adopts it: `.mergerfs.branch .trash .zimaos_storage.json lost+found` | accepted, `16 recovered errors`, `0 unrecoverable errors`, all 8 files sha256-identical, timers active | ok |
| 6 | afterwards | 0 failed units, the box's 4 containers unchanged | — |

**Cleanup:** original image back (sha256 `0a4bb551…`), no test mounts, config and defaults removed — 8 of 8 checks, after both runs.

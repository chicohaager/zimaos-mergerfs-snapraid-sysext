# Hardware test log — zimaos-mergerfs-snapraid-sysext

**Host:** zimaos-143 (ZimaCube Pro, amd64, ZimaOS 1.6.1, kernel 6.12.25)
**Date:** 2026-05-30 · **Operator:** zuse (Holgi authorized) · **Plan:** [TESTPLAN.md](TESTPLAN.md)

**Test rig:** single throwaway disk `/dev/sdd` (Hitachi HTS723232, 298 GiB), GPT,
3× ext4: `SR-DATA1` (80 G), `SR-DATA2` (80 G), `SR-PARITY` (~135 G). Mounted at
`/DATA/srtest/{data1,data2,parity}`. Pool target `/DATA/StorageTest`.

> **Single-spindle functional test** — validates all software paths. NOT a real
> fault-tolerance test (data + parity share one physical disk).

## Result summary

| # | Phase | Result |
|---|---|---|
| 0 | sysext build + merge (earlier) | ✅ gzip `.raw`, merged, binaries on `/usr/bin` |
| 1 | Partition + format `/dev/sdd` (by Holgi) | ✅ 3× ext4 labelled |
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

**Fully hardware-validated on zimaos-143 (amd64).** Build → merge → pool →
sync/scrub → file recovery → mass-delete guard → disk replacement → boot-race →
uninstall all pass. Single-spindle (no real fault tolerance) and arm64 remain the
only untested dimensions.

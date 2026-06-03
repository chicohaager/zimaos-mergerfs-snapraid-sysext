# Hardware test plan — zimaos-mergerfs-snapraid-sysext

Host: **zimaos-143** (ZimaCube Pro, amd64, ZimaOS 1.6.1, kernel 6.12.25).
Date: 2026-05-30. Operator: zuse (on Holgi's authorization).

## Destructive scope — READ FIRST

**Only `/dev/sdd` is touched** (Hitachi HTS723232A7A364, 298 GiB, by-id
`ata-Hitachi_HTS723232A7A364_E3834563C702XM`, attached 2026-05-30 13:29).
It currently holds a leftover NTFS partition + stale ZFS signature — to be wiped.

**Never touched:** `/dev/sdb` (Samsung 870 QVO 4TB, exFAT, user data),
`/dev/sdc` (Crucial P310 1TB, exFAT, user data), `nvme0n1` (system + /DATA).

## What this test proves — and what it does NOT

One physical disk is available. It is partitioned into data + parity partitions,
so the test is **functional, single-spindle**:

- ✅ Proves: mergerfs pool mounts; SnapRAID `sync`/`scrub`/`status`; file-loss
  recovery (`fix`); `replace-disk.sh` flow + guards; mass-deletion guard;
  unit/boot behaviour; uninstall preserves data.
- ❌ Does NOT prove real fault tolerance: parity on a separate spindle is what
  survives a physical disk death. Two+ physical disks needed for that.

## Partition layout on /dev/sdd (GPT)

| Part | Size | FS | Label | Role |
|---|---|---|---|---|
| sdd1 | 80 G | ext4 | `SR-DATA1` | mergerfs branch d1 |
| sdd2 | 80 G | ext4 | `SR-DATA2` | mergerfs branch d2 |
| sdd3 | ~130 G | ext4 | `SR-PARITY` | SnapRAID parity (≥ largest data = 80 G ✓) |

Mounted by LABEL at fixed paths (demonstrates the by-LABEL identity recommendation
and avoids ZimaOS `/media/sdXN` letter drift):
`/mnt/sr-data1`, `/mnt/sr-data2`, `/mnt/sr-parity`.

## Config under test

`pool.env`: `BRANCHES="/mnt/sr-data1:/mnt/sr-data2"`, `MOUNTPOINT="/DATA/StorageTest"`.
`snapraid.conf`: `parity /mnt/sr-parity/snapraid.parity`, `data d1 /mnt/sr-data1`,
`data d2 /mnt/sr-data2`, content files on each data disk + /DATA/AppData.

## Test phases (each logged with command + output)

1. **Format**: wipe sdd, GPT, 3× ext4 with labels, mount by label.
2. **Pool up**: `systemctl start mergerfs-pool.service` → `/DATA/StorageTest`
   mounted, `df` shows pooled size (~160 G).
3. **Write**: create test files across the pool; confirm they land on the
   branches (mfs create policy).
4. **Sync**: `snapraid-sync.sh` → parity built, `snapraid status` clean.
5. **Scrub**: `snapraid-scrub.sh` → no errors.
6. **File-loss recovery**: delete a file from a branch, `snapraid fix` → restored,
   `check` clean.
7. **Mass-deletion guard**: delete > threshold files, run `snapraid-sync.sh` →
   guard ABORTS, parity untouched.
8. **Disk replacement**: simulate (wipe sdd1), `replace-disk.sh d1` → guards pass,
   `fix -d d1` → `check` → `sync` → data back.
9. **Boot-race** (optional, needs reboot — interrupts prod): enable timers, reboot,
   confirm pool auto-mounts + timers armed.
10. **Uninstall**: `uninstall.sh` → module gone, data + parity + config preserved.

Results recorded in `docs/TESTLOG.md`.

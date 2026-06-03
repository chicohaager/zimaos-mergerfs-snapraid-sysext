# Handoff — mergerfs + SnapRAID sysext for ZimaOS

For **Gelbuilding** (Icewhale Community). This builds on your mergerfs+SnapRAID PoC
and packages it as a proper `systemd-sysext` module — same delivery mechanism as
the ZimaOS `cron` / `tailscale` mods. Thanks for the original proof of concept.

## What's in this package

```
build/out/mergerfs-snapraid_amd64.raw   ← the sysext image (gzip squashfs)
build/out/SHA256SUMS                     ← checksum (verified before merge by install.sh)
install.sh / uninstall.sh                ← root installer (uninstall preserves all data)
units/                                   ← systemd units (installed to /etc, NOT in the .raw)
scripts/                                 ← start/stop pool, snapraid sync/scrub, replace-disk
config/*.example                         ← pool.env + snapraid.conf templates
build/                                    ← Dockerfile + scripts to rebuild from source
docs/                                     ← architecture/recovery SVGs, TESTPLAN, TESTLOG
.github/workflows/build.yml               ← CI: builds amd64 + arm64, smoke-tests, publishes
```

## Install (amd64 ZimaOS)

```sh
sudo ./install.sh                 # verifies SHA, merges sysext, installs units, places templates
# edit before real use:
#   /DATA/AppData/mergerfs-snapraid/config/pool.env       (BRANCHES = data disks, NOT parity)
#   /DATA/AppData/mergerfs-snapraid/config/snapraid.conf  (parity/content/data = underlying disks)
sudo systemctl start mergerfs-pool.service
sudo /DATA/AppData/mergerfs-snapraid/scripts/snapraid-sync.sh   # first parity build
```
`sudo ./uninstall.sh` removes the module but keeps all data, parity and config.

## Image contents (amd64)

`/usr/bin/{mergerfs (v2.42.0), snapraid (v14.5, static), mergerfs-fusermount, fsck.mergerfs}`,
`/usr/lib/mergerfs/preload.so`, `/usr/sbin/mount.mergerfs`,
`extension-release` = `ID=_any` + `ARCHITECTURE=x86-64`.
`sha256(mergerfs-snapraid_amd64.raw)` is in `build/out/SHA256SUMS`.

## Key design decisions (the non-obvious bits)

- **gzip squashfs, not zstd.** The ZimaOS kernel's SquashFS has ZLIB/LZ4/LZO only —
  a zstd `.raw` fails the merge with "Invalid argument". (`-comp gzip` in build-sysext.sh)
- **Binaries in `/usr/bin`.** `/usr/local/bin` doesn't exist on ZimaOS and isn't on
  PATH; the build relocates the mergerfs tarball off `usr/local`.
- **Units in `/etc`, not in the sysext** + a 15 s watchdog timer. A unit *inside* the
  sysext is invisible at boot (the `multi-user.target` vs `systemd-sysext.service`
  race you'll know from cron/tailscale). Verified: pool auto-mounts after reboot.
- **SnapRAID statically linked**; **mergerfs from the official static tarball**.
- **SnapRAID points at the underlying disks**, never the pool; parity disk is never
  a mergerfs branch. `replace-disk.sh` guards a disk swap; `snapraid-sync.sh` has a
  mass-deletion guard.
- **Use by-LABEL/UUID for the disks** — ZimaOS device letters are not stable across
  reboot (we saw `/dev/sdd → /dev/sda`).
- **Heads-up:** ZimaOS 1.6.1 already ships an ancient **mergerfs v1.5.4** in its base
  `/usr`; this module shadows it with 2.42.0 while merged and reverts on uninstall.

## Status — honest

**amd64: fully hardware-validated** on a ZimaCube Pro (ZimaOS 1.6.1, kernel 6.12.25)
on 2026-05-30 — build → merge → pool → sync/scrub → file recovery → mass-delete
guard → disk-replacement → **cold-boot boot-race** → uninstall. Full evidence with
commands + output in [TESTLOG.md](TESTLOG.md). The array test was single-spindle
(one disk partitioned data+parity): it exercises every code path but is **not** a
real multi-disk fault-tolerance test — use separate physical disks (parity ≥ largest
data) in production.

**arm64:** build it from CI (`.github/workflows/build.yml` cross-builds via qemu on
GitHub runners — reliable, unlike ad-hoc qemu on a ZimaCube). Not hardware-tested;
no confirmed arm64 Zima hardware exists yet.

To rebuild from source: `cd build && ./build-snapraid.sh amd64 && ./build-sysext.sh amd64`.

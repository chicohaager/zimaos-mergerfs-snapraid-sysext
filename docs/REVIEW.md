# Code & security review — 2026-05-30

Independent two-reviewer pass (security + shell-correctness) plus author review.
All findings below were **fixed**; the `.raw` binaries are unchanged (every fix is
in scripts/units/build/install). Verified with `sh -n` + `dash -n`, guard-parse
simulation, and SHA-dedup simulation.

| # | Sev | Finding | Fix |
|---|-----|---------|-----|
| 1 | **CRITICAL** | `replace-disk.sh`: under `set -e`, a non-zero `snapraid fix`/`check`/`sync` aborted the script **before** restarting pool + timers → array left offline mid-recovery. | EXIT trap (`restore_services`) restarts pool + timers on every path, success or failure. |
| 2 | **HIGH** | `snapraid-sync.sh`: mass-delete guard swallowed the `diff` exit code (`|| true`); a diff that errored before its summary parsed as `removed=0` and the sync ran — overwriting parity in the exact disk-dropout case the guard targets. | Capture `diff` exit (only 0/2 allowed) **and** require the summary block; otherwise **fail closed**. Parse hardened to `$2=="removed"`. |
| 3 | **HIGH** | Boot-race watchdog could no-op if the sysext merge took >15 s (`ConditionPathExists` fails, no retry). | Watchdog `.service` now `After=/Wants=systemd-sysext.service` and waits up to 30 s for `/usr/bin/mergerfs` before starting the pool. |
| 4 | **HIGH** | Supply chain: mergerfs + SnapRAID source/tarballs downloaded with **no integrity check**, then baked into a root image. | Pinned SHA256 verified after download in `build-sysext.sh` (per-arch) and `Dockerfile.snapraid` (build-arg). |
| 5 | **MEDIUM** | `install.sh`: `pool.env` is `.`-sourced as root and scripts run as root, but perms weren't hardened — a writable `/DATA/AppData` would be root code-exec. | `chown -R root:root` + `chmod -R go-w` on `config/` and `scripts/`. |
| 6 | **MEDIUM** | `build-sysext.sh`: `SHA256SUMS` **appended** on every rebuild → stale duplicate line broke `install.sh`'s `sha256sum -c`. | Remove the prior line for the image before appending (1 line per file). CI publish dedups by filename. |
| 7 | **MEDIUM** | mergerfs `allow_other` without `default_permissions` → underlying perms not kernel-enforced. | Added `default_permissions` to the `OPTS` example + documented the trust implication. |
| 8 | **LOW** | CI: no `permissions:` block (over-privileged `GITHUB_TOKEN`); convoluted curl in smoke step. | `permissions: contents: read` default + `contents: write` only on `publish`; smoke step simplified. Recommend pinning `uses:` actions to commit SHAs. |

**Verified fine (no change needed):** sourced-config quoting in `start-pool.sh`
(values are quoted; risk was perms, see #5), `mktemp -d` + trap temp handling,
`replace-disk.sh` re-exec/tee logging, root execution model (mount/parity work
needs root), no secrets anywhere.

**Not re-tested live:** the array test rig was torn down after the functional test;
the guard/trap fixes are validated by `sh -n`/`dash -n` + output-format simulation,
not a fresh on-hardware array run. Re-installing the module would allow a live re-test.

---

# Second pass — 2026-06-03

Pre-commit review of every script/unit/CI file (`sh -n` + `dash -n` clean on all).
Two new findings, both fixed; `.raw` binaries unchanged (fixes are in build/scripts).

| # | Sev | Finding | Fix |
|---|-----|---------|-----|
| 9 | **MEDIUM** | `build-snapraid.sh`: `DOCKER_CONFIG="${DOCKER_CONFIG:-/DATA/.docker}"` used `:-`, so the CI's intentional `DOCKER_CONFIG=""` (env in `build.yml`, meant to use the runner's own docker config) was treated as unset and forced back to `/DATA/.docker` — a path that does not exist on the GitHub runner, breaking the documented intent. | Switched to `${DOCKER_CONFIG-/DATA/.docker}` (no colon): default applies only when *unset* (ZimaOS), an explicit empty value is honoured (CI). Verified both branches. |
| 10 | **MEDIUM** | `replace-disk.sh`: the tee re-exec ended with `"$0" "$@" \| tee … ; exit $?`. POSIX sh has no `PIPESTATUS`, so `$?` was tee's status — a **failed disk rebuild would exit 0**, so any caller/automation would read the recovery as successful (the EXIT trap still restores services, but the exit code lied). | Capture the inner exit status via a `mktemp` status file and `exit "${rc:-1}"`, fail-closed to 1 if the status is missing. |

**Verified fine (no change needed):** install.sh checksum subshell fails closed
(empty `grep` → `sha256sum -c` exits non-zero); snapraid-sync fail-closed guard
(findings #2/#11 path) still intact; all unit ordering (`After=systemd-sysext.service`
+ watchdog) unchanged; no secrets; config templates correct (data/parity point at
underlying disks, not the pool).

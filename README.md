# wolfi-hfsplus

[![build-and-scan](https://github.com/reuc/wolfi-hfsplus/actions/workflows/build-and-scan.yml/badge.svg)](https://github.com/reuc/wolfi-hfsplus/actions/workflows/build-and-scan.yml)

A [Wolfi](https://github.com/wolfi-dev) toolchain container image with the **HFS/HFS+ file system utilities** from Ubuntu's [`hfsprogs`](https://launchpad.net/ubuntu/+source/hfsprogs) package. It runs as **root** with a **busybox shell** and is meant to be started with **`--privileged`**, so it can format, check and mount real block and loop devices.

It is derived from [reuc/wolfi-polyglot](https://github.com/reuc/wolfi-polyglot) (shell variant). The image contains:

- **hfsprogs 540.1.linux3**: `mkfs.hfsplus`, `fsck.hfsplus`, plus `mkfs.hfs` and `fsck.hfs`, laid out as in Ubuntu
- **Device tools** from util-linux: `mount`, `umount`, `losetup`, `blkid` (Wolfi's busybox doesn't include these applets)
- **Python 3.14.x**, with pip and the dev headers
- **Go**, the latest version in Wolfi
- **Rust**, with rustc and cargo
- **A C toolchain** (gcc, binutils, glibc-dev, make, pkgconf), for cgo and native extensions
- **busybox** as `/bin/sh`, with no package manager

The Makefile builds the image, runs two smoke tests (one locked down, one privileged) and a **CVE gate** with [grype](https://github.com/anchore/grype). The gate fails unless all of these hold:

| Severity | Allowed |
|----------|---------|
| Critical | 0       |
| High     | < 3     |
| Medium   | < 5     |
| Low      | < 10    |

## How it differs from wolfi-polyglot

| | wolfi-polyglot (shell) | wolfi-hfsplus |
|---|---|---|
| User | `nonroot` (65532) | `root` (0), `HOME=/root` |
| Intended run mode | locked down (`--cap-drop=ALL`) | `--privileged` |
| HFS/HFS+ tools | no | hfsprogs, built from the Ubuntu source package |
| mount / losetup / blkid | no | yes (util-linux) |
| Distroless variant | yes | no (busybox shell only) |

## Requirements

- Docker with BuildKit (Docker 23+ has it on by default)
- [grype](https://github.com/anchore/grype#installation) and `jq`, for the CVE gate
- [syft](https://github.com/anchore/syft#installation), optional, for SBOMs
- Network access to `cgr.dev`, `packages.wolfi.dev` and `archive.ubuntu.com` (for the hfsprogs source)
- To **mount** HFS+ volumes: a host kernel with the `hfsplus` (or `hfs`) driver. Formatting and checking don't need it.

## Quick start

```bash
make            # build, smoke-test and CVE-gate the image
make run        # privileged root shell with the current directory at /work
make help       # list all targets
```

`make` exits non-zero if the build, a smoke test or the CVE gate fails, so you can use it as a CI step directly.

## Make targets

| Target | What it does |
|--------|--------------|
| `all` (default) | `build` + `test` + `scan` |
| `build` | Builds the image |
| `test` | Runs both smoke tests |
| `test-locked` | Smoke test with every capability dropped: toolchains, plus HFS on image files |
| `test-privileged` | Smoke test with `--privileged`: also formats, checks and mounts a loop device |
| `run` | Interactive privileged root shell, current directory mounted at `/work` |
| `scan` | Runs the CVE gate |
| `sbom` | Writes an SPDX JSON SBOM to `reports/` |
| `clean` | Removes the built image and `reports/` |

## Configuration

Override any variable on the command line, for example `make build TAG=v1 PLATFORM=linux/arm64`.

| Variable | Default | Description |
|----------|---------|-------------|
| `IMAGE` | `wolfi-hfsplus` | Image repository name |
| `TAG` | today's date (`YYYYMMDD`) | Image tag |
| `PLATFORM` | `linux/amd64` | Target platform (`linux/arm64` also works) |
| `BASE_IMAGE` | `cgr.dev/chainguard/wolfi-base:latest` | Builder base image. Pin it by digest for reproducible builds. |
| `PYTHON_VERSION` | `3.14` | Python minor version. The build fails if the installed Python doesn't match. |
| `GO_PACKAGE` | `go` | Wolfi Go package. Set e.g. `go-1.25` to pin a minor version. |
| `RUST_PACKAGE` | `rust` | Wolfi Rust package |
| `EXTRA_PACKAGES` | *(empty)* | More Wolfi packages to install, separated by spaces |
| `APK_CACHE_BUST` | today's date | Changing it forces packages to be fetched again |
| `NO_CACHE` | *(empty)* | Set to `1` to build with `--no-cache` |
| `MAX_CRITICAL` / `MAX_HIGH` / `MAX_MEDIUM` / `MAX_LOW` | `0` / `2` / `4` / `9` | CVE gate limits (the most allowed of each) |
| `REPORT_DIR` | `reports` | Where scan reports and SBOMs are written |
| `GRYPE` / `SYFT` / `JQ` | `grype` / `syft` / `jq` | Tool paths |

The hfsprogs source is set by build args in the `Dockerfile` (`HFSPROGS_VERSION`, `HFSPROGS_REVISION`, `HFSPROGS_MIRROR` and the two SHA-256 hashes). See [Updating hfsprogs](#updating-hfsprogs).

### Examples

```bash
# Reproducible build with a pinned base image
make BASE_IMAGE=cgr.dev/chainguard/wolfi-base@sha256:<digest>

# Add partitioning tools (these add CVE surface)
make EXTRA_PACKAGES="sfdisk gptfdisk"

# Build for arm64
make PLATFORM=linux/arm64

# Force a fresh build to pick up newly published CVE fixes
make NO_CACHE=1
```

## Using the image

### Privileged access

An image can't grant itself privileges, so they have to be given when the container starts. Use `--privileged` for anything that touches a device:

```bash
docker run --rm -it --privileged wolfi-hfsplus:<tag>
```

`--privileged` gives the container every capability and the host's devices **as they were when the container started**. To see disks plugged in later (USB drives, SD cards), also bind-mount `/dev`:

```bash
docker run --rm -it --privileged -v /dev:/dev wolfi-hfsplus:<tag>
```

> **Warning:** a privileged root container can read, write and reformat every disk on the host. Double-check device names (`lsblk`, `blkid`) before running `mkfs`. Only run it on hosts and with devices you mean to change.

If you only need one device, you can give the container less than `--privileged`. To format or check a device, passing that device is enough:

```bash
docker run --rm -it --device /dev/sdb2 wolfi-hfsplus:<tag> fsck.hfsplus -f -n /dev/sdb2
```

Mounting also needs `CAP_SYS_ADMIN`, and on hosts that use AppArmor (Ubuntu, for example) Docker's default profile blocks `mount` as well:

```bash
docker run --rm -it --device /dev/sdb2 --cap-add SYS_ADMIN \
  --security-opt apparmor=unconfined wolfi-hfsplus:<tag>
```

### HFS+ examples

```bash
# Identify the volume
blkid /dev/sdb2

# Check a volume without changing it, then repair it
fsck.hfsplus -f -n /dev/sdb2
fsck.hfsplus -f -y /dev/sdb2

# Create a journaled HFS+ volume
mkfs.hfsplus -J -v "Backup" /dev/sdb2

# Mount it (needs the host kernel's hfsplus driver)
mkdir -p /mnt/hfs
mount -t hfsplus /dev/sdb2 /mnt/hfs
umount /mnt/hfs
```

Formatting and checking also work on **image files**, and those don't need any privileges:

```bash
docker run --rm -v "$PWD":/work -w /work wolfi-hfsplus:<tag> sh -c '
  truncate -s 1G disk.img &&
  mkfs.hfsplus -v Data disk.img &&
  fsck.hfsplus -f -n disk.img'
```

To mount an image file, attach it to a loop device (privileged):

```bash
dev=$(losetup --find --show disk.img)
mount -t hfsplus "$dev" /mnt/hfs
# ...
umount /mnt/hfs && losetup -d "$dev"
```

### Notes on hfsprogs

- **Legacy HFS:** `mkfs.hfs` (or `mkfs.hfsplus -h`) creates a classic HFS volume instead of HFS+.
- **Journaled volumes:** Linux mounts journaled HFS+ **read-only** unless you pass `-o force`. Use `-o force` only on a volume that was cleanly unmounted, ideally after an `fsck.hfsplus -f -y`.
- **Case-sensitive HFSX (`mkfs.hfsplus -s`):** the Linux `mkfs.hfsplus` leaves the root folder's *HasFolderCount* flag unset (an upstream `FIXME` in `makehfs.c`). Both `fsck.hfsplus` and macOS's `fsck_hfs` then report the new volume as needing repair. Run `fsck.hfsplus -f -y` once after creating it. The smoke test checks that this repair works. (Ubuntu's packaged `fsck.hfsplus` happens not to report the problem, but macOS does.)
- **`/proc` must be mounted** for `fsck.hfsplus`, which reads `/proc/self/mounts` to see whether the volume is mounted. Docker always mounts it, so this only matters if you copy the binary into a bare chroot.
- **No man pages** are installed. Run `mkfs.hfsplus` or `fsck.hfsplus` with no arguments to print the usage.
- **License:** hfsprogs is Apple's `diskdev_cmds` under the Apple Public Source License 2.0, with an MIT-licensed blocks runtime. The Debian copyright file is at `/usr/share/doc/hfsprogs/copyright`, and the exact source version is in `/usr/share/doc/hfsprogs/VERSION`.

### Toolchains

```bash
# Run a build with the current directory mounted
docker run --rm -v "$PWD":/work -w /work wolfi-hfsplus:<tag> \
  sh -c 'go build ./... && cargo build --release && python3 -m pytest'
```

- Everything runs as root, so bind-mounted output is owned by root on the host. Add `--user "$(id -u):$(id -g)" -e HOME=/tmp` if you don't need devices and want files owned by you.
- **pip** installs into the system site-packages by default (`PIP_ROOT_USER_ACTION=ignore` silences the root warning). A virtualenv (`python3 -m venv .venv`) keeps projects separate.
- **Go** never downloads other toolchain versions (`GOTOOLCHAIN=local`) and builds with `-trimpath` by default.
- **Caches** go under `/root`: `GOPATH`, `GOCACHE` and `CARGO_HOME`. To keep them between runs, mount a volume there.

## How hfsprogs is built

Wolfi has no hfsprogs package, so the `hfsprogs` stage of the Dockerfile builds it:

1. Downloads the Ubuntu source package from `archive.ubuntu.com`: the upstream tarball and the Debian packaging, version **540.1.linux3-6build1** (the one in Ubuntu 26.04 LTS).
2. Checks both files against SHA-256 hashes copied from the signed `.dsc`. The build fails on a mismatch.
3. Applies the Debian patches in `debian/patches/series` order, so the result matches Ubuntu's package: gcc builds, the ARM fix and legacy HFS support.
4. Compiles with `-O2`. Wolfi's gcc adds the OpenSSF hardening flags itself: PIE, full RELRO, BIND_NOW, stack protector and `_FORTIFY_SOURCE`.
5. Installs the binaries in Ubuntu's layout. Wolfi merges `/sbin` and `/usr/sbin` into `/usr/bin`, so `/usr/sbin/mkfs.hfsplus` and `/sbin/mkfs.hfsplus` resolve as well.
6. Reads the binaries' shared-library needs (`readelf`) and installs exactly those packages into the image as apk `so:` dependencies (currently `so:libcrypto.so.4`).

The rootfs stage then formats and checks a small HFS+ image file inside the finished rootfs. A missing library or a broken binary fails the build.

### Updating hfsprogs

1. Pick a version from <https://archive.ubuntu.com/ubuntu/pool/universe/h/hfsprogs/>. Prefer the one in the current LTS, because pool files for interim releases are removed when those releases reach end of life.
2. Copy the SHA-256 hashes of the `.orig.tar.gz` and `.debian.tar.xz` from the matching `.dsc`.
3. Update `HFSPROGS_VERSION`, `HFSPROGS_REVISION`, `HFSPROGS_ORIG_SHA256` and `HFSPROGS_DEBIAN_SHA256` in the `Dockerfile`, then run `make`.

## How it's built and locked down

Running as root with `--privileged` is the point of this image, so it is not hardened like wolfi-polyglot. It still keeps these properties:

1. **Only the listed packages get in.** A throwaway `wolfi-base` stage installs them into an empty root folder with `apk add --root … --initdb --no-scripts`, and that folder is copied into `FROM scratch`. The hfsprogs build tools (curl, patch, headers) stay in their own stage.
2. **No package manager.** `apk-tools` is never installed in the final image, and the apk signing keys and caches are removed.
3. **Pinned third-party source.** The hfsprogs tarballs are verified by SHA-256 before they are used.
4. **No setuid or setgid binaries.** These bits are removed from every file (nothing needs them when everything runs as root).
5. **The scanners still see the packages.** The installed-package list (`/lib/apk/db/installed`) is kept on purpose, so grype, trivy and syft can identify every apk package.
6. **Empty build context.** The Dockerfile copies nothing from the repository, so `.dockerignore` excludes everything and no local files can leak into the image.

## CVE gate

`make scan`:

1. Updates the grype vulnerability database.
2. Scans the image with `--by-cve`, which turns GHSA IDs into CVE IDs where possible. It prints a table and writes `reports/image-grype.json`.
3. Counts **unique vulnerability IDs** per severity. A CVE that affects several packages counts once.
4. Fails if any count is above its limit.

Grype uses the Wolfi security database, so it already ignores CVEs that Wolfi has marked as fixed or not affecting the package.

**Blind spot:** hfsprogs is compiled from source, so it isn't in the apk database and grype doesn't scan it. Its runtime library (`libcrypto`) is an apk package and is scanned. To check hfsprogs itself, follow the [Ubuntu CVE tracker for hfsprogs](https://ubuntu.com/security/cves?package=hfsprogs) and update the pinned version when Ubuntu ships a fix.

### When the gate fails

1. **Rebuild with fresh packages.** Wolfi usually publishes fixes within days: `make NO_CACHE=1`.
2. **Find what's affected** in `reports/image-grype.json`. This lists vulnerability ID, package, installed version and fixed version:
   ```bash
   jq -r '.matches[] | [.vulnerability.severity, .vulnerability.id, .artifact.name, .artifact.version, (.vulnerability.fix.versions|join(","))] | @tsv' \
     reports/image-grype.json | sort -u
   ```
3. **Remove packages you don't need**, especially anything added with `EXTRA_PACKAGES`.
4. **Pin an older minor version** if the newest one has a regression (`GO_PACKAGE=go-1.xx`).
5. **For a reviewed false positive**, add a [grype ignore rule](https://github.com/anchore/grype#specifying-matches-to-ignore) in `.grype.yaml` with a justification. Don't loosen the limits to make a build pass.

## Smoke tests

`tests/smoke.py` is piped into the container's Python through stdin. Both tests use a read-only root filesystem, tmpfs for `/tmp` and `/root`, and `--network=none`.

**`make test-locked`** runs with `--cap-drop=ALL` and `--security-opt=no-new-privileges`, and checks:

- the process runs as root (UID/GID 0) with `HOME=/root`, and has no capabilities
- `/bin/sh` is busybox and `apk` is absent
- Python is 3.14.x, and `ssl`, `sqlite3`, `ctypes`, `venv`, `zlib`, `lzma` and `bz2` import, and `pip` works
- C (via both `cc` and `gcc`), Go, cgo and Rust each compile a program that runs and prints the expected output, and `gcc` reads the OpenSSF hardening spec file
- `mkfs.hfsplus`, `fsck.hfsplus`, `mkfs.hfs`, `fsck.hfs`, `mount`, `umount`, `losetup` and `blkid` are on `PATH`, the `.hfs` aliases point at the `.hfsplus` binaries, and `hfsbootdata` is installed
- on image files, for **HFS+**, **journaled HFS+**, **case-sensitive HFSX** and **legacy HFS**: `mkfs` succeeds, the on-disk signature is right (`H+`, `HX` or `BD`), the journal bit is set where expected, `fsck` passes and `blkid` detects the type. For HFSX it also checks the known HasFolderCount report and that `fsck -y` repairs it.

**`make test-privileged`** runs with `--privileged` and checks everything above, plus:

- the process has `CAP_SYS_ADMIN` and `/dev/loop-control` exists
- an image attached to a **loop block device** can be formatted with `mkfs.hfsplus`, checked with `fsck.hfsplus` and identified by `blkid`
- if the host kernel has the `hfsplus` driver: the device mounts, a file and a directory written to it persist through `umount` and a read-only remount, and `fsck` still passes. Without the driver this part prints `[SKIP]` and doesn't fail the test.

## Continuous integration

`.github/workflows/build-and-scan.yml` builds, smoke-tests and CVE-gates the image on **both architectures**: `amd64` on `ubuntu-24.04` and `arm64` on `ubuntu-24.04-arm`. Each job builds natively, with no QEMU emulation. Each job:

1. tries to load the runner's `hfsplus` kernel module (installing `linux-modules-extra` if needed), so the privileged mount check can run. If it can't, it posts a notice and the check is skipped.
2. runs `make build NO_CACHE=1` and checks that the image architecture matches the job
3. runs `make test-locked`, then `make test-privileged`
4. runs `make scan`

The workflow runs on every pull request, on every push to `main`, daily at 06:17 UTC, and on demand (**Actions → build-and-scan → Run workflow**). Each job writes a table of CVE counts and findings to the run summary and uploads `reports/` as an artifact named `grype-<arch>`, kept for 30 days. The workflow only builds and scans; it doesn't publish images.

To make the gate block merges, add **`build-and-scan (all)`** as a required status check in the branch protection rule for `main`. It passes only when both architecture jobs pass.

## Files

```
.
├── .github/
│   ├── dependabot.yml           # weekly GitHub Actions updates
│   ├── scripts/run-annotated.sh # turns failures into workflow annotations
│   └── workflows/
│       ├── build-and-scan.yml   # CI: build, smoke tests, CVE gate
│       └── codeql.yml           # CodeQL (actions, python)
├── Dockerfile             # hfsprogs build + root/busybox rootfs
├── Makefile               # build / test / run / scan / sbom
├── tests/smoke.py         # smoke test (locked and privileged)
├── .dockerignore          # empty build context
└── README.md
```

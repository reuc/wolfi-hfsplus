"""Smoke test run inside the image (piped via stdin: `python3 - < tests/smoke.py`).

Checks the user, the Python version, that Go, cgo and Rust can compile and run
real programs, and that the HFS/HFS+ utilities (hfsprogs) work.

Set EXPECT_PRIVILEGED=1 when the container runs with --privileged. That checks
the capabilities and also runs mkfs/fsck against a real loop block device and,
if the host kernel has the hfsplus driver, mounts it and writes a file.
EXPECT_PRIVILEGED=0 checks that every capability was dropped.
"""

import os
import shutil
import stat
import subprocess
import sys
import tempfile

failures = []
CAP_SYS_ADMIN = 21


def check(name, ok, detail=""):
    print(f"[{'PASS' if ok else 'FAIL'}] {name}{(': ' + detail) if detail else ''}")
    if not ok:
        failures.append(name)
    return ok


def skip(name, detail):
    print(f"[SKIP] {name}: {detail}")


def run(cmd, cwd=None):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr).strip()


def last_line(out):
    lines = out.splitlines()
    return lines[-1] if lines else ""


def cap_eff():
    with open("/proc/self/status") as f:
        for line in f:
            if line.startswith("CapEff:"):
                return int(line.split()[1], 16)
    return 0


def read_at(path, offset, size):
    with open(path, "rb") as f:
        f.seek(offset)
        return f.read(size)


# ---- user, shell, package manager -----------------------------------------
check("runs as root", (os.getuid(), os.getgid()) == (0, 0), f"uid={os.getuid()} gid={os.getgid()}")
check("HOME is /root", os.environ.get("HOME") == "/root", os.environ.get("HOME", ""))
check("busybox shell", os.path.lexists("/bin/sh") and "busybox" in os.path.realpath("/bin/sh"),
      os.path.realpath("/bin/sh"))
check("no apk", shutil.which("apk") is None)

expect_priv = os.environ.get("EXPECT_PRIVILEGED")
caps = cap_eff()
if expect_priv == "1":
    check("CAP_SYS_ADMIN (privileged)", bool(caps & (1 << CAP_SYS_ADMIN)), f"CapEff={caps:#x}")
    check("/dev/loop-control", os.path.exists("/dev/loop-control"))
elif expect_priv == "0":
    check("no capabilities (locked)", caps == 0, f"CapEff={caps:#x}")

# ---- Python -----------------------------------------------------------------
check("python 3.14.x", sys.version_info[:2] == (3, 14), sys.version.split()[0])

for mod in ("ssl", "sqlite3", "ctypes", "venv", "zlib", "lzma", "bz2"):
    try:
        __import__(mod)
        check(f"import {mod}", True)
    except Exception as e:  # noqa: BLE001
        check(f"import {mod}", False, repr(e))

rc, out = run([sys.executable, "-m", "pip", "--version"])
check("pip", rc == 0, out)

# ---- toolchains -------------------------------------------------------------
with tempfile.TemporaryDirectory() as d:
    # C via both compiler entry points (Wolfi routes these through gcc-wrapper)
    with open(os.path.join(d, "hello.c"), "w") as f:
        f.write('#include <stdio.h>\nint main(void){ puts("c-ok"); return 0; }\n')
    for compiler in ("cc", "gcc"):
        exe = os.path.join(d, f"hello-{compiler}")
        rc, out = run([compiler, "-o", exe, "hello.c"], cwd=d)
        check(f"{compiler} build", rc == 0, out)
        if rc == 0:
            rc, out = run([exe])
            check(f"{compiler} run", out == "c-ok", out)

    # The OpenSSF hardening spec must still be applied.
    rc, out = run(["gcc", "-v"])
    check("gcc uses hardening spec", "openssf.spec" in out or "gcc_spec_file" in out,
          next((l for l in out.splitlines() if "Reading specs" in l), "no 'Reading specs' line"))

    # Go (pure)
    with open(os.path.join(d, "main.go"), "w") as f:
        f.write('package main\nimport "fmt"\nfunc main(){ fmt.Println("go-ok") }\n')
    rc, out = run(["go", "build", "-o", "hello-go", "main.go"], cwd=d)
    check("go build", rc == 0, out)
    if rc == 0:
        rc, out = run([os.path.join(d, "hello-go")])
        check("go run", out == "go-ok", out)

    # Go with cgo (exercises gcc + glibc-dev)
    cgo = os.path.join(d, "cgo")
    os.mkdir(cgo)
    with open(os.path.join(cgo, "main.go"), "w") as f:
        f.write(
            'package main\n/*\n#include <stdlib.h>\nint add(int a,int b){return a+b;}\n*/\n'
            'import "C"\nimport "fmt"\nfunc main(){ fmt.Println(int(C.add(2,3))) }\n'
        )
    rc, out = run(["go", "build", "-o", "hello-cgo", "main.go"], cwd=cgo)
    check("cgo build", rc == 0, out)
    if rc == 0:
        rc, out = run([os.path.join(cgo, "hello-cgo")])
        check("cgo run", out == "5", out)

    # Rust via cargo (offline, no dependencies)
    rc, out = run(["cargo", "new", "--vcs", "none", "--quiet", "hello-rs"], cwd=d)
    check("cargo new", rc == 0, out)
    if rc == 0:
        proj = os.path.join(d, "hello-rs")
        rc, out = run(["cargo", "build", "--release", "--offline", "--quiet"], cwd=proj)
        check("cargo build", rc == 0, out)
        if rc == 0:
            rc, out = run([os.path.join(proj, "target", "release", "hello-rs")])
            check("rust run", out == "Hello, world!", out)

# ---- HFS / HFS+ utilities (hfsprogs) ----------------------------------------
for tool in ("mkfs.hfsplus", "fsck.hfsplus", "mkfs.hfs", "fsck.hfs",
             "mount", "umount", "losetup", "blkid"):
    check(f"{tool} on PATH", shutil.which(tool) is not None, shutil.which(tool) or "missing")
check("hfsbootdata", os.path.isfile("/usr/share/misc/hfsbootdata"))
for alias, target in (("mkfs.hfs", "mkfs.hfsplus"), ("fsck.hfs", "fsck.hfsplus")):
    p = shutil.which(alias)
    check(f"{alias} -> {target}", p is not None and os.path.basename(os.path.realpath(p)) == target)


def fsck_ok(name, target):
    rc, out = run(["fsck.hfsplus", "-f", "-n", target])
    return check(f"{name}: fsck", rc == 0 and "appears to be OK" in out, last_line(out))


def blkid_type(target):
    rc, out = run(["blkid", "-p", "-o", "value", "-s", "TYPE", target])
    return out if rc == 0 else f"rc={rc} {out}"


# (label, mkfs command, signature at offset 1024, blkid TYPE)
FORMATS = [
    ("HFS+", ["mkfs.hfsplus", "-v", "SmokePlus"], b"H+", "hfsplus"),
    ("HFS+ journaled", ["mkfs.hfsplus", "-J", "-v", "SmokeJournal"], b"H+", "hfsplus"),
    ("HFSX case-sensitive", ["mkfs.hfsplus", "-s", "-v", "SmokeHFSX"], b"HX", "hfsplus"),
    ("legacy HFS", ["mkfs.hfs", "-v", "SmokeHFS"], b"BD", "hfs"),
]

with tempfile.TemporaryDirectory() as d:
    for label, mkfs, sig, fstype in FORMATS:
        img = os.path.join(d, label.replace(" ", "-") + ".img")
        with open(img, "wb") as f:
            f.truncate(64 * 1024 * 1024)
        rc, out = run(mkfs + [img])
        if not check(f"{label}: mkfs", rc == 0, last_line(out)):
            continue
        got = read_at(img, 1024, 2)
        check(f"{label}: signature", got == sig, repr(got))
        if label == "HFS+ journaled":
            # Volume header attributes (big-endian u32 at 1024+4), bit 13 = journaled.
            attrs = int.from_bytes(read_at(img, 1028, 4), "big")
            check(f"{label}: journal bit", bool(attrs & (1 << 13)), f"attributes={attrs:#010x}")
        if sig == b"HX":
            # Known upstream behaviour: the Linux newfs_hfs leaves the root
            # folder's HasFolderCount flag unset on HFSX (`#if !LINUX // FIXME`
            # in makehfs.c). fsck.hfsplus and macOS fsck_hfs both flag it; one
            # `fsck.hfsplus -fy` fixes it. If this ever stops reproducing,
            # upstream fixed mkfs and the README note can go.
            rc, out = run(["fsck.hfsplus", "-f", "-n", img])
            check(f"{label}: fsck flags HasFolderCount (known)",
                  rc != 0 and "HasFolderCount flag needs to be set (id = 2)" in out, last_line(out))
            rc, out = run(["fsck.hfsplus", "-f", "-y", img])
            check(f"{label}: fsck -y repairs", rc == 0 and "repaired successfully" in out,
                  last_line(out))
        fsck_ok(label, img)
        got = blkid_type(img)
        check(f"{label}: blkid", got == fstype, got)

# ---- privileged: real block device + kernel mount ---------------------------
def attach_loop(img):
    """Attach img to a free loop device; create the node if Docker didn't."""
    rc, out = run(["losetup", "--find", "--show", img])
    if rc == 0:
        return out.splitlines()[-1]
    # /dev in a container only has the loop nodes that existed at start; the
    # free device the kernel hands out may be newer, so create its node.
    rc2, dev = run(["losetup", "--find"])
    if rc2 != 0 or not dev.startswith("/dev/loop"):
        raise RuntimeError(f"losetup failed: {out} / {dev}")
    if not os.path.exists(dev):
        os.mknod(dev, stat.S_IFBLK | 0o660, os.makedev(7, int(dev[len("/dev/loop"):])))
    rc, out = run(["losetup", dev, img])
    if rc != 0:
        raise RuntimeError(f"losetup {dev}: {out}")
    return dev


if expect_priv == "1":
    with tempfile.TemporaryDirectory() as d:
        img = os.path.join(d, "device.img")
        mnt = os.path.join(d, "mnt")
        os.mkdir(mnt)
        with open(img, "wb") as f:
            f.truncate(64 * 1024 * 1024)
        dev = None
        mounted = False
        try:
            dev = attach_loop(img)
            check("loop device attached", True, dev)
            rc, out = run(["mkfs.hfsplus", "-v", "SmokeDevice", dev])
            check("loop: mkfs.hfsplus", rc == 0, last_line(out))
            fsck_ok("loop", dev)
            got = blkid_type(dev)
            check("loop: blkid", got == "hfsplus", got)

            rc, out = run(["mount", "-t", "hfsplus", dev, mnt])
            if rc != 0 and ("unknown filesystem type" in out or "No such device" in out):
                skip("loop: kernel mount", f"host kernel has no hfsplus driver ({out})")
            elif check("loop: mount -t hfsplus", rc == 0, out):
                mounted = True
                with open(os.path.join(mnt, "hello.txt"), "w") as f:
                    f.write("hfs-ok\n")
                os.mkdir(os.path.join(mnt, "dir"))
                rc, out = run(["umount", mnt])
                mounted = rc != 0
                check("loop: umount", rc == 0, out)
                fsck_ok("loop after write", dev)
                rc, out = run(["mount", "-t", "hfsplus", "-o", "ro", dev, mnt])
                if check("loop: remount ro", rc == 0, out):
                    mounted = True
                    p = os.path.join(mnt, "hello.txt")
                    data = open(p).read() if os.path.exists(p) else None
                    check("loop: file persisted", data == "hfs-ok\n", repr(data))
                    check("loop: dir persisted", os.path.isdir(os.path.join(mnt, "dir")))
        except Exception as e:  # noqa: BLE001
            check("loop device test", False, repr(e))
        finally:
            if mounted:
                run(["umount", mnt])
            if dev:
                rc, out = run(["losetup", "-d", dev])
                check("loop device detached", rc == 0, out)

print()
if failures:
    print(f"{len(failures)} check(s) failed: {', '.join(failures)}")
    sys.exit(1)
print("All smoke checks passed.")

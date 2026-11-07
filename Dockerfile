# syntax=docker/dockerfile:1
#
# Wolfi toolchain image (Python 3.14.x, Go, Rust, C) with HFS/HFS+ utilities.
# Variant: runs as ROOT, busybox shell kept, NO package manager.
#
# The image is meant to be started with `docker run --privileged` so that
# mkfs.hfsplus / fsck.hfsplus / mount can reach block and loop devices. An image
# cannot grant itself privileges; see the README and `make run`.
#
# The rootfs is assembled with `apk --root` in a throwaway builder stage and
# copied into `scratch`, so only the packages listed below (and their deps)
# end up in the final image. apk-tools is never installed in the final image.
#
# Wolfi has no hfsprogs package, so the `hfsprogs` stage compiles it from the
# Ubuntu source package (Apple diskdev_cmds 540.1 plus the Debian patches).

ARG BASE_IMAGE=cgr.dev/chainguard/wolfi-base:latest

# ---- hfsprogs: mkfs.hfsplus / fsck.hfsplus --------------------------------
FROM ${BASE_IMAGE} AS hfsprogs

# Ubuntu 26.04 LTS ("resolute") source package. The hashes come from the
# signed .dsc next to the tarballs:
#   ${HFSPROGS_MIRROR}/hfsprogs_${HFSPROGS_VERSION}-${HFSPROGS_REVISION}.dsc
# When bumping the version, update both hashes from that file.
ARG HFSPROGS_VERSION=540.1.linux3
ARG HFSPROGS_REVISION=6build1
ARG HFSPROGS_MIRROR=https://archive.ubuntu.com/ubuntu/pool/universe/h/hfsprogs
ARG HFSPROGS_ORIG_SHA256=b01b203a97f9a3bf36a027c13ddfc59292730552e62722d690d33bd5c24f5497
ARG HFSPROGS_DEBIAN_SHA256=e5edfafed563ad337e2ca16d8439f0424ecf0e0ac558c2c5896569cf7389f914
ARG APK_CACHE_BUST=0

RUN set -eux; \
    echo "cache-bust: ${APK_CACHE_BUST}"; \
    # uuid/uuid.h (util-linux-dev) is needed at compile time only; the
    # binaries link nothing but glibc and libcrypto.
    apk add --no-cache build-base curl openssl-dev patch util-linux-dev xz; \
    mkdir -p /build; \
    cd /build; \
    orig="hfsprogs_${HFSPROGS_VERSION}.orig.tar.gz"; \
    deb="hfsprogs_${HFSPROGS_VERSION}-${HFSPROGS_REVISION}.debian.tar.xz"; \
    curl -fsSL -o "$orig" "${HFSPROGS_MIRROR}/$orig"; \
    curl -fsSL -o "$deb" "${HFSPROGS_MIRROR}/$deb"; \
    printf '%s  %s\n' \
        "${HFSPROGS_ORIG_SHA256}" "$orig" \
        "${HFSPROGS_DEBIAN_SHA256}" "$deb" | sha256sum -c -; \
    tar -xzf "$orig"; \
    cd "diskdev_cmds-${HFSPROGS_VERSION}"; \
    tar -xJf "../$deb"; \
    sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' debian/patches/series | \
        while read -r p; do patch -p1 < "debian/patches/$p"; done; \
    # Upstream sets no optimisation level. Wolfi's gcc adds the OpenSSF
    # hardening flags (PIE, full RELRO, stack protector, FORTIFY) on its own.
    CFLAGS="-O2" make -j"$(nproc)"; \
    # Same layout as Ubuntu's hfsprogs package. Wolfi merges /sbin and
    # /usr/sbin into /usr/bin, so the binaries go there.
    install -D -m 0755 -s newfs_hfs.tproj/newfs_hfs /out/usr/bin/mkfs.hfsplus; \
    install -D -m 0755 -s fsck_hfs.tproj/fsck_hfs   /out/usr/bin/fsck.hfsplus; \
    # Invoked as mkfs.hfs, newfs_hfs creates a legacy HFS (not HFS+) volume.
    ln -s mkfs.hfsplus /out/usr/bin/mkfs.hfs; \
    ln -s fsck.hfsplus /out/usr/bin/fsck.hfs; \
    install -D -m 0644 debian/hfsbootdata.img /out/usr/share/misc/hfsbootdata; \
    install -D -m 0644 debian/copyright /out/usr/share/doc/hfsprogs/copyright; \
    echo "${HFSPROGS_VERSION}-${HFSPROGS_REVISION}" > /out/usr/share/doc/hfsprogs/VERSION; \
    # Record the shared libraries the binaries need, as apk "so:" names, so the
    # rootfs stage installs exactly those (e.g. so:libcrypto.so.4).
    mkdir -p /deps; \
    readelf -d /out/usr/bin/mkfs.hfsplus /out/usr/bin/fsck.hfsplus | \
        sed -n 's/.*Shared library: \[\(.*\)\]$/so:\1/p' | sort -u > /deps/hfsprogs.txt; \
    cat /deps/hfsprogs.txt

# ---- rootfs ---------------------------------------------------------------
FROM ${BASE_IMAGE} AS builder

ARG PYTHON_VERSION=3.14
ARG GO_PACKAGE=go
ARG RUST_PACKAGE=rust
ARG EXTRA_PACKAGES=""
# Change this value (the Makefile passes today's date) to force a fresh package
# resolution so newly published CVE fixes are picked up.
ARG APK_CACHE_BUST=0

COPY --from=hfsprogs /deps/hfsprogs.txt /tmp/hfsprogs-deps.txt

RUN set -eux; \
    echo "cache-bust: ${APK_CACHE_BUST}"; \
    mkdir -p /rootfs; \
    apk add --no-cache --no-scripts --initdb --root /rootfs \
        --keys-dir /etc/apk/keys \
        --repositories-file /etc/apk/repositories \
        wolfi-baselayout \
        ca-certificates-bundle \
        glibc \
        glibc-locale-posix \
        tzdata \
        busybox \
        "python-${PYTHON_VERSION}" \
        "python-${PYTHON_VERSION}-dev" \
        "py${PYTHON_VERSION}-pip" \
        "${GO_PACKAGE}" \
        "${RUST_PACKAGE}" \
        gcc \
        glibc-dev \
        binutils \
        make \
        pkgconf \
        # Device tooling for the privileged use case. Wolfi's busybox has no
        # mount/umount/losetup/blkid applets, so these come from util-linux.
        mount \
        umount \
        losetup \
        blkid \
        $(cat /tmp/hfsprogs-deps.txt) \
        ${EXTRA_PACKAGES}; \
    # --no-scripts skips busybox's applet-link trigger, so create the links here.
    chroot /rootfs /bin/busybox --install -s; \
    # Ensure unversioned python entry points exist.
    for l in python3 python; do \
        [ -e "/rootfs/usr/bin/$l" ] || ln -s "python${PYTHON_VERSION}" "/rootfs/usr/bin/$l"; \
    done; \
    # Fail the build if the Python we got is not the requested minor version.
    chroot /rootfs /usr/bin/python3 --version | grep -Eq "^Python ${PYTHON_VERSION}\.[0-9]+$"; \
    # The image runs as root: make sure root's home exists and is private.
    mkdir -p /rootfs/root /rootfs/tmp; \
    chown 0:0 /rootfs/root; \
    chmod 0700 /rootfs/root; \
    chmod 1777 /rootfs/tmp; \
    # Strip setuid/setgid bits (nothing needs them when everything runs as
    # root); drop apk caches and signing keys. /lib/apk/db is deliberately
    # KEPT so scanners (grype/trivy/syft) can see every installed package.
    find /rootfs -xdev -type f -perm /6000 -exec chmod a-s {} +; \
    rm -rf /rootfs/var/cache/apk/* /rootfs/etc/apk/keys /rootfs/root/.cache /tmp/hfsprogs-deps.txt

COPY --from=hfsprogs /out/ /rootfs/

# Fail the build if hfsprogs can't run in the final rootfs (e.g. a missing
# shared library): format and check a small HFS+ image file. No privileges
# are needed for this, only for real block or loop devices.
#
# fsck_hfs reads /proc/self/mounts without a NULL check (upstream bug, also in
# Ubuntu's build) and segfaults if /proc is missing. /proc is always mounted in
# a running container, but not in this chroot, so give it an empty stand-in
# for the check and remove it afterwards.
RUN set -eux; \
    img=/rootfs/tmp/build-check.img; \
    truncate -s 16M "$img"; \
    chroot /rootfs /usr/bin/mkfs.hfsplus -v BuildCheck /tmp/build-check.img; \
    mkdir -p /rootfs/proc/self; \
    : > /rootfs/proc/self/mounts; \
    chroot /rootfs /usr/bin/fsck.hfsplus -f -n /tmp/build-check.img; \
    rm -rf /rootfs/proc/self "$img"

FROM scratch

COPY --from=builder /rootfs/ /

ENV PATH=/root/.cargo/bin:/root/go/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
    HOME=/root \
    LANG=C.UTF-8 \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_ROOT_USER_ACTION=ignore \
    GOTOOLCHAIN=local \
    GOPATH=/root/go \
    GOCACHE=/root/.cache/go-build \
    GOFLAGS=-trimpath \
    CARGO_HOME=/root/.cargo

# Root on purpose: formatting, checking and mounting devices needs it.
USER 0:0
WORKDIR /root

CMD ["/bin/sh"]

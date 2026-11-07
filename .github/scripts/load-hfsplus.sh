#!/usr/bin/env bash
# Best effort: load the runner's hfsplus kernel module so the privileged smoke
# test can mount an HFS+ loop device. GitHub's Ubuntu runners ship it in
# linux-modules-extra-<kernel>, which may need installing first. Never fails
# the job: without the module the smoke test skips just the mount check.
set -uo pipefail

if sudo modprobe hfsplus 2>/dev/null; then
  echo "hfsplus loaded"
  exit 0
fi

kernel=$(uname -r)
if timeout 300 sudo apt-get update -qq &&
   timeout 300 sudo apt-get install -y -qq "linux-modules-extra-${kernel}" &&
   sudo modprobe hfsplus; then
  echo "hfsplus loaded (installed linux-modules-extra-${kernel})"
else
  echo "::notice title=hfsplus::hfsplus kernel module unavailable on ${kernel}; the HFS+ mount check will be skipped"
fi
exit 0

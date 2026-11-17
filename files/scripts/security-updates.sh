#!/usr/bin/env bash
# Install Fedora's critical and important security updates the base image
# doesn't have yet, so a build started for one (security-rebuild.yml) has it
# even before ublue's next base image. The kernel stays the base image's: it's
# signed and its modules are built for it.
set -euo pipefail
dnf5 -y upgrade --refresh --security --advisory-severities=critical,important --exclude='kernel*'

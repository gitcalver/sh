#!/bin/sh
# Copyright © 2026 Michael Shields
# SPDX-License-Identifier: MIT

set -eu

SNAPSHOT="${1:?Usage: install-git.sh SNAPSHOT}"

apt_install_git() {
    printf 'Acquire::Check-Valid-Until "false";\n' \
        >/etc/apt/apt.conf.d/99no-check-valid-until
    apt-get update
    apt-get install -y --no-install-recommends git
    rm -rf /var/lib/apt/lists/*
}

# Debian (DEB822 format, snapshot.debian.org)
if [ -f /etc/apt/sources.list.d/debian.sources ]; then
    . /etc/os-release
    KEYRING=$(grep -m1 'Signed-By:' /etc/apt/sources.list.d/debian.sources | awk '{print $2}')
    cat >/etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: http://snapshot.debian.org/archive/debian/${SNAPSHOT}/
Suites: ${VERSION_CODENAME} ${VERSION_CODENAME}-updates
Components: main
Signed-By: ${KEYRING}

Types: deb
URIs: http://snapshot.debian.org/archive/debian-security/${SNAPSHOT}/
Suites: ${VERSION_CODENAME}-security
Components: main
Signed-By: ${KEYRING}
EOF
    apt_install_git

# Ubuntu 24.04+ (DEB822 format, snapshot.ubuntu.com)
elif [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    . /etc/os-release
    # snapshot.ubuntu.com redirects to HTTPS; ca-certificates is needed.
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates
    rm -rf /var/lib/apt/lists/*
    cat >/etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: http://snapshot.ubuntu.com/ubuntu/${SNAPSHOT}
Suites: ${VERSION_CODENAME} ${VERSION_CODENAME}-updates ${VERSION_CODENAME}-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    apt_install_git

# Ubuntu 22.04 (traditional sources.list, snapshot.ubuntu.com)
elif [ -f /etc/apt/sources.list ] && [ -f /etc/lsb-release ]; then
    . /etc/os-release
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates
    rm -rf /var/lib/apt/lists/*
    ARCHIVE="http://snapshot.ubuntu.com/ubuntu/${SNAPSHOT}"
    cat >/etc/apt/sources.list <<EOF
deb ${ARCHIVE} ${VERSION_CODENAME} main universe
deb ${ARCHIVE} ${VERSION_CODENAME}-updates main universe
deb ${ARCHIVE} ${VERSION_CODENAME}-security main universe
EOF
    apt_install_git

# Alpine (pin package version)
elif command -v apk >/dev/null; then
    apk add --no-cache "git=${SNAPSHOT}"

# Amazon Linux 2023 (releasever lock)
elif command -v dnf >/dev/null && grep -qi "Amazon" /etc/system-release 2>/dev/null; then
    dnf --releasever="${SNAPSHOT}" install -y git
    dnf clean all

# Fedora (pin package version)
elif command -v dnf >/dev/null; then
    dnf install -y "git-${SNAPSHOT}"
    dnf clean all

# Amazon Linux 2 (pin package version)
elif command -v yum >/dev/null; then
    yum install -y "git-${SNAPSHOT}"
    yum clean all

else
    echo "Unsupported distribution" >&2
    exit 1
fi

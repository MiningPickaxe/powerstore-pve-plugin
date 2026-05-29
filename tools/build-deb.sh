#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# build-deb.sh — Build a Debian package for powerstore-pve-plugin
# Usage: bash tools/build-deb.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
PLUGIN_PM="${REPO_DIR}/PowerStorePlugin.pm"

# ---------------------------------------------------------------------------
# Resolve version from debian/changelog
# ---------------------------------------------------------------------------
VERSION=$(head -1 "${REPO_DIR}/debian/changelog" \
    | grep -Po '\(\K[^)]+')
[[ -n "$VERSION" ]] || { echo "ERROR: Could not determine version from debian/changelog"; exit 1; }
echo "Building version: ${VERSION}"

# ---------------------------------------------------------------------------
# Inject version into plugin (idempotent)
# ---------------------------------------------------------------------------
sed -i "s/^our \\\$VERSION = .*;/our \$VERSION = '${VERSION}';/" "${PLUGIN_PM}"
echo "Injected version ${VERSION} into ${PLUGIN_PM}"

# ---------------------------------------------------------------------------
# Verify Perl syntax
# ---------------------------------------------------------------------------
perl -c "${PLUGIN_PM}" || { echo "ERROR: Perl syntax check failed"; exit 1; }
echo "Perl syntax OK."

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
cd "${REPO_DIR}"
dpkg-buildpackage -us -uc -b --no-sign

# Move output to a build/ directory for clarity
mkdir -p "${REPO_DIR}/build"
mv -f ../${PLUGIN_NAME:-powerstore-pve-plugin}_*.deb \
       ../${PLUGIN_NAME:-powerstore-pve-plugin}_*.changes \
       ../${PLUGIN_NAME:-powerstore-pve-plugin}_*.buildinfo \
       "${REPO_DIR}/build/" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Checksums
# ---------------------------------------------------------------------------
echo
echo "Build artifacts:"
ls -lh "${REPO_DIR}/build/"
cd "${REPO_DIR}/build"
sha256sum ./* > SHA256SUMS
echo
echo "SHA256SUMS:"
cat SHA256SUMS

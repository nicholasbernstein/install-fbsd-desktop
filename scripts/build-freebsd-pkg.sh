#!/bin/sh
# Build a FreeBSD package for install-fbsd-desktop without requiring a full
# ports tree checkout. Run on FreeBSD with pkg(8) available.
#
# Usage:
#   sh scripts/build-freebsd-pkg.sh [output-dir]
#
# Produces:
#   <outdir>/installx.sh
#   <outdir>/install-fbsd-desktop-<version>.pkg
#   <outdir>/ports-sysutils-install-fbsd-desktop.tar.gz
#   <outdir>/SHA256SUMS

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OUTDIR=${1:-"$ROOT/dist"}
VERSION=${INSTALLX_PKG_VERSION:-0.2.0}
# Optional git short hash for uniqueness in CI
if [ -n "${INSTALLX_PKG_REVISION:-}" ]; then
	VERSION="${VERSION}_${INSTALLX_PKG_REVISION}"
fi

PKGNAME=install-fbsd-desktop
STAGEDIR=$(mktemp -d /tmp/ifd-stage.XXXXXX)
META=$(mktemp /tmp/ifd-manifest.XXXXXX)
trap 'rm -rf "$STAGEDIR" "$META"' EXIT

umask 022
mkdir -p "$OUTDIR" \
	"$STAGEDIR/usr/local/sbin" \
	"$STAGEDIR/usr/local/share/${PKGNAME}" \
	"$STAGEDIR/usr/local/share/doc/${PKGNAME}"

install -m 755 "$ROOT/installx.sh" "$STAGEDIR/usr/local/sbin/installx"
ln -sf installx "$STAGEDIR/usr/local/sbin/install-fbsd-desktop"
install -m 755 "$ROOT/test_installx.sh" "$STAGEDIR/usr/local/share/${PKGNAME}/test_installx.sh"
install -m 644 "$ROOT/shunit2" "$STAGEDIR/usr/local/share/${PKGNAME}/shunit2"
install -m 644 "$ROOT/ReadMe.md" "$STAGEDIR/usr/local/share/doc/${PKGNAME}/ReadMe.md"

# Minimal +MANIFEST for pkg create (NO_ARCH-style package)
cat > "$META" <<EOF
name: ${PKGNAME}
version: "${VERSION}"
origin: sysutils/${PKGNAME}
comment: Interactive installer for FreeBSD desktop environments
desc: |-
  installx installs and configures a FreeBSD graphical desktop or Wayland
  compositor (KDE, GNOME, Xfce, Sway, Hyprland, and others) with a single menu.
www: https://github.com/nicholasbernstein/install-fbsd-desktop
prefix: /usr/local
categories: [sysutils]
licenselogic: single
licenses: [BSD3CLAUSE]
deps: {
  dialog: {origin: misc/dialog, version: ">=0"}
}
EOF

if ! command -v pkg >/dev/null 2>&1 ; then
	echo "error: pkg(8) not found; run this script on FreeBSD" >&2
	exit 1
fi

# pkg create embeds host ABI; content is still architecture-independent scripts
pkg create -M "$META" -r "$STAGEDIR" -o "$OUTDIR"

# Ship the raw installer script
install -m 644 "$ROOT/installx.sh" "$OUTDIR/installx.sh"

# Ports tree fragment for consumers who want to drop into /usr/ports
PORTS_TAR="$OUTDIR/ports-sysutils-install-fbsd-desktop.tar.gz"
(
	cd "$ROOT"
	tar -czf "$PORTS_TAR" \
		--exclude 'ports/sysutils/install-fbsd-desktop/work' \
		ports/sysutils/install-fbsd-desktop \
		ports/README.md
)

# Canonical package filename (pkg create may add abi suffix)
PKGFILE=$(ls -1 "$OUTDIR"/${PKGNAME}-*.pkg 2>/dev/null | head -n 1 || true)
if [ -z "$PKGFILE" ] ; then
	echo "error: package file not found in $OUTDIR" >&2
	ls -la "$OUTDIR" >&2 || true
	exit 1
fi

# Content fingerprint: hash of the installable payload (not the .pkg wrapper,
# which can embed timestamps). Prefer hashing staged files + script + ports.
FINGERPRINT_DIR=$(mktemp -d /tmp/ifd-fp.XXXXXX)
: > "$FINGERPRINT_DIR/content.list"
_hash_one() {
	if command -v sha256 >/dev/null 2>&1 ; then
		sha256 -q "$1"
	else
		sha256sum "$1" | awk '{print $1}'
	fi
}
# Stable ordered content fingerprint (payload + ports metadata)
# Avoid pipe subshell so redirects always hit content.list
find "$STAGEDIR" -type f | sort > "$FINGERPRINT_DIR/filelist"
while read -r f ; do
	printf '%s  %s\n' "$(_hash_one "$f")" "${f#"$STAGEDIR"}"
done < "$FINGERPRINT_DIR/filelist" >> "$FINGERPRINT_DIR/content.list"
printf '%s  %s\n' "$(_hash_one "$ROOT/installx.sh")" "installx.sh" >> "$FINGERPRINT_DIR/content.list"
for f in Makefile pkg-descr pkg-plist ; do
	p="$ROOT/ports/sysutils/install-fbsd-desktop/$f"
	if [ -f "$p" ] ; then
		printf '%s  %s\n' "$(_hash_one "$p")" "ports/$f" >> "$FINGERPRINT_DIR/content.list"
	fi
done
CONTENT_SHA=$(_hash_one "$FINGERPRINT_DIR/content.list")
echo "$CONTENT_SHA" > "$OUTDIR/CONTENT_SHA256"
rm -rf "$FINGERPRINT_DIR"

# SHA256SUMS for release assets
(
	cd "$OUTDIR"
	if command -v sha256 >/dev/null 2>&1 ; then
		sha256 installx.sh "$(basename "$PKGFILE")" \
			ports-sysutils-install-fbsd-desktop.tar.gz CONTENT_SHA256 > SHA256SUMS
	else
		sha256sum installx.sh "$(basename "$PKGFILE")" \
			ports-sysutils-install-fbsd-desktop.tar.gz CONTENT_SHA256 > SHA256SUMS
	fi
)

echo "Built package artifacts in $OUTDIR:"
ls -la "$OUTDIR"
echo "CONTENT_SHA256=$CONTENT_SHA"

#!/bin/sh
# Build a FreeBSD package for install-fbsd-desktop without a full ports tree.
# Run on FreeBSD with pkg(8).
#
# Usage:
#   sh scripts/build-freebsd-pkg.sh [output-dir]
#
# Produces under outdir:
#   installx.sh
#   install-fbsd-desktop-<version>.pkg
#   ports-sysutils-install-fbsd-desktop.tar.gz
#   SHA256SUMS
#   CONTENT_SHA256

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OUTDIR=${1:-"$ROOT/dist"}
BASE_VERSION=${INSTALLX_PKG_VERSION:-0.2.0}
# FreeBSD package versions: use digits/dots only for the base, optional _N revision.
# Git hash goes in a +g suffix (allowed) rather than _abcdef (PORTREVISION is numeric).
REV=${INSTALLX_PKG_REVISION:-}
if [ -n "$REV" ] ; then
	# Sanitize: only [0-9a-fA-F]
	REV=$(echo "$REV" | tr -cd '0-9a-fA-F' | cut -c1-12)
	VERSION="${BASE_VERSION}.g${REV}"
else
	VERSION="${BASE_VERSION}"
fi

PKGNAME=install-fbsd-desktop
STAGEDIR=$(mktemp -d /tmp/ifd-stage.XXXXXX)
META=$(mktemp /tmp/ifd-manifest.XXXXXX)
PLIST=$(mktemp /tmp/ifd-plist.XXXXXX)
trap 'rm -rf "$STAGEDIR" "$META" "$PLIST"' EXIT

echo "build-freebsd-pkg: ROOT=$ROOT OUTDIR=$OUTDIR VERSION=$VERSION"

umask 022
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR" \
	"$STAGEDIR/usr/local/sbin" \
	"$STAGEDIR/usr/local/share/${PKGNAME}" \
	"$STAGEDIR/usr/local/share/doc/${PKGNAME}"

# Stage payload
cp "$ROOT/installx.sh" "$STAGEDIR/usr/local/sbin/installx"
chmod 755 "$STAGEDIR/usr/local/sbin/installx"
ln -sf installx "$STAGEDIR/usr/local/sbin/install-fbsd-desktop"
cp "$ROOT/test_installx.sh" "$STAGEDIR/usr/local/share/${PKGNAME}/test_installx.sh"
chmod 755 "$STAGEDIR/usr/local/share/${PKGNAME}/test_installx.sh"
cp "$ROOT/shunit2" "$STAGEDIR/usr/local/share/${PKGNAME}/shunit2"
chmod 644 "$STAGEDIR/usr/local/share/${PKGNAME}/shunit2"
cp "$ROOT/ReadMe.md" "$STAGEDIR/usr/local/share/doc/${PKGNAME}/ReadMe.md"
chmod 644 "$STAGEDIR/usr/local/share/doc/${PKGNAME}/ReadMe.md"

# plist of files relative to STAGEDIR (absolute paths for pkg create -r)
{
	echo "/usr/local/sbin/installx"
	echo "/usr/local/sbin/install-fbsd-desktop"
	echo "/usr/local/share/${PKGNAME}/test_installx.sh"
	echo "/usr/local/share/${PKGNAME}/shunit2"
	echo "/usr/local/share/doc/${PKGNAME}/ReadMe.md"
} > "$PLIST"

# UCL manifest for pkg create -M
# Keep fields minimal — exotic keys break older/newer pkg differently.
cat > "$META" <<EOF
name = "${PKGNAME}";
version = "${VERSION}";
origin = "sysutils/${PKGNAME}";
comment = "Interactive installer for FreeBSD desktop environments";
maintainer = "ports@FreeBSD.org";
www = "https://github.com/nicholasbernstein/install-fbsd-desktop";
prefix = "/usr/local";
desc = <<EOD
installx installs and configures a FreeBSD graphical desktop or Wayland
compositor (KDE, GNOME, Xfce, Sway, Hyprland, and others) with a single menu.
EOD
categories [ sysutils ];
licenselogic = "single";
licenses [ BSD3CLAUSE ];
EOF

if ! command -v pkg >/dev/null 2>&1 ; then
	echo "error: pkg(8) not found; run this script on FreeBSD" >&2
	exit 1
fi

echo "build-freebsd-pkg: pkg version: $(pkg -v 2>/dev/null || echo unknown)"
echo "build-freebsd-pkg: staged tree:"
find "$STAGEDIR" -type f -o -type l | sort
echo "build-freebsd-pkg: manifest:"
cat "$META"

# Try modern UCL-ish first; fall back to YAML-like if create fails
set +e
pkg create -v -M "$META" -p "$PLIST" -r "$STAGEDIR" -o "$OUTDIR" 2> "$OUTDIR/pkg-create.err"
_rc=$?
if [ "$_rc" -ne 0 ] ; then
	echo "build-freebsd-pkg: first pkg create failed (rc=$_rc), retrying with YAML-style manifest" | tee -a "$OUTDIR/pkg-create.err"
	cat > "$META" <<EOF
name: ${PKGNAME}
version: ${VERSION}
origin: sysutils/${PKGNAME}
comment: Interactive installer for FreeBSD desktop environments
maintainer: ports@FreeBSD.org
www: https://github.com/nicholasbernstein/install-fbsd-desktop
prefix: /usr/local
desc: |-
  installx installs and configures a FreeBSD graphical desktop or Wayland
  compositor with a single menu.
categories: [sysutils]
licenselogic: single
licenses: [BSD3CLAUSE]
EOF
	pkg create -v -M "$META" -p "$PLIST" -r "$STAGEDIR" -o "$OUTDIR" 2>> "$OUTDIR/pkg-create.err"
	_rc=$?
fi
set -e

if [ "$_rc" -ne 0 ] ; then
	echo "error: pkg create failed (rc=$_rc)" >&2
	cat "$OUTDIR/pkg-create.err" >&2 || true
	ls -la "$OUTDIR" >&2 || true
	exit "$_rc"
fi

# Raw installer script for release assets
cp "$ROOT/installx.sh" "$OUTDIR/installx.sh"
chmod 644 "$OUTDIR/installx.sh"

# Ports tree fragment
PORTS_TAR="$OUTDIR/ports-sysutils-install-fbsd-desktop.tar.gz"
(
	cd "$ROOT"
	tar -czf "$PORTS_TAR" \
		--exclude 'ports/sysutils/install-fbsd-desktop/work' \
		ports/sysutils/install-fbsd-desktop \
		ports/README.md
)

PKGFILE=$(ls -1 "$OUTDIR"/${PKGNAME}-*.pkg 2>/dev/null | head -n 1 || true)
if [ -z "$PKGFILE" ] ; then
	echo "error: package file not found in $OUTDIR" >&2
	ls -la "$OUTDIR" >&2 || true
	exit 1
fi
echo "build-freebsd-pkg: created $PKGFILE"

# Content fingerprint (stable ordered digests)
_hash_one() {
	if command -v sha256 >/dev/null 2>&1 ; then
		sha256 -q "$1"
	else
		sha256sum "$1" | awk '{print $1}'
	fi
}
FINGERPRINT=$(mktemp /tmp/ifd-fp.XXXXXX)
: > "$FINGERPRINT"
find "$STAGEDIR" -type f | sort | while read -r f ; do
	printf '%s  %s\n' "$(_hash_one "$f")" "${f#"$STAGEDIR"}"
done >> "$FINGERPRINT"
printf '%s  %s\n' "$(_hash_one "$ROOT/installx.sh")" "installx.sh" >> "$FINGERPRINT"
for f in Makefile pkg-descr pkg-plist ; do
	p="$ROOT/ports/sysutils/install-fbsd-desktop/$f"
	if [ -f "$p" ] ; then
		printf '%s  %s\n' "$(_hash_one "$p")" "ports/$f" >> "$FINGERPRINT"
	fi
done
CONTENT_SHA=$(_hash_one "$FINGERPRINT")
echo "$CONTENT_SHA" > "$OUTDIR/CONTENT_SHA256"
rm -f "$FINGERPRINT"

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

echo "build-freebsd-pkg: artifacts in $OUTDIR"
ls -la "$OUTDIR"
echo "CONTENT_SHA256=$CONTENT_SHA"
exit 0

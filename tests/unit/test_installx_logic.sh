#!/bin/sh
# FreeBSD unit tests for pure helpers inside installx.sh.
# Does not run the installer. Does not require production companion files.
#
# Usage (FreeBSD):
#   sh tests/unit/test_installx_logic.sh
#
# Extracts functions from installx.sh, installs mocks, runs shunit2.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

INSTALLX="${ROOT}/installx.sh"
EXTRACT="${ROOT}/tests/unit/extract_functions.sh"
SHUNIT2="${ROOT}/shunit2"

if [ ! -f "$INSTALLX" ] ; then
	echo "FAIL: installx.sh not found at $INSTALLX" >&2
	exit 1
fi
if [ ! -x "$EXTRACT" ] && [ -f "$EXTRACT" ] ; then
	chmod +x "$EXTRACT" 2>/dev/null || true
fi
if [ ! -f "$EXTRACT" ] ; then
	echo "FAIL: extract_functions.sh missing" >&2
	exit 1
fi
if [ ! -f "$SHUNIT2" ] ; then
	echo "FAIL: shunit2 missing at $SHUNIT2" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Mocks / test state (defined before extracted functions so callers exist)
# ---------------------------------------------------------------------------
LOGFILE=/dev/null
NEED_XORG=yes
vc_pkgs=""
vc_selected=""
vc_post_nvidia_xconfig=0
vc_post_vbox=0
MOCK_KLDS=""
MOCK_LOADER=""
MOCK_CATALOG=""

# Controlled catalog: space-separated package names that are "available"
pkg_is_available() {
	_pn=$1
	[ -z "$_pn" ] && return 1
	case " ${MOCK_CATALOG} " in
		*" ${_pn} "*) return 0 ;;
		*) return 1 ;;
	esac
}

# Override after extract — installx definitions would replace these if extracted.
# We intentionally do NOT extract graphics_enable_kld / graphics_loader_conf
# so our mocks stay in place (graphics_select calls them by name).
graphics_enable_kld() {
	MOCK_KLDS="${MOCK_KLDS} $1"
	MOCK_KLDS=$(echo "$MOCK_KLDS" | sed 's/^ *//')
}

graphics_loader_conf() {
	MOCK_LOADER="${MOCK_LOADER}
$1"
}

# sysrc should not be needed if we don't extract graphics_enable_kld
sysrc() {
	echo "sysrc mock: $*" >>"$LOGFILE"
}

# ---------------------------------------------------------------------------
# Extract pure helpers from the real installx.sh
# ---------------------------------------------------------------------------
_EXTRACTED=$(mktemp "${TMPDIR:-/tmp}/installx-unit.XXXXXX") || exit 1
# shellcheck disable=SC2064
trap 'rm -f "$_EXTRACTED"' EXIT INT TERM

# Note: omit graphics_enable_kld and graphics_loader_conf so mocks apply.
sh "$EXTRACT" "$INSTALLX" \
	is_noninteractive \
	kde_desktop_pkgs \
	desktop_required_pkgs \
	desktop_menu_label \
	pkgs_find_missing \
	pkgs_filter_available \
	graphics_append_pkg \
	graphics_select \
	graphics_warn_nvidia_conflict \
	> "$_EXTRACTED"

# shellcheck disable=SC1090
. "$_EXTRACTED"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
reset_graphics_state() {
	vc_pkgs=""
	vc_selected=""
	vc_post_nvidia_xconfig=0
	vc_post_vbox=0
	MOCK_KLDS=""
	MOCK_LOADER=""
	NEED_XORG=yes
}

assert_pkg_list_contains() {
	# $1 haystack list, $2 needle package
	case " $1 " in
		*" $2 "*) return 0 ;;
		*) fail "expected package list to contain '$2'; got: $1" ;;
	esac
}

assert_pkg_list_lacks() {
	case " $1 " in
		*" $2 "*) fail "expected package list NOT to contain '$2'; got: $1" ;;
		*) return 0 ;;
	esac
}

# ---------------------------------------------------------------------------
# Tests: is_noninteractive
# ---------------------------------------------------------------------------
test_is_noninteractive_env() {
	unset INSTALLX_NONINTERACTIVE CI 2>/dev/null || true
	INSTALLX_NONINTERACTIVE=0
	CI=
	export INSTALLX_NONINTERACTIVE CI
	assertFalse "default interactive" is_noninteractive

	INSTALLX_NONINTERACTIVE=1
	assertTrue "INSTALLX_NONINTERACTIVE=1" is_noninteractive

	INSTALLX_NONINTERACTIVE=0
	CI=true
	assertTrue "CI=true" is_noninteractive

	CI=1
	assertTrue "CI=1" is_noninteractive
}

# ---------------------------------------------------------------------------
# Tests: KDE / Plasma 6 resolution
# ---------------------------------------------------------------------------
test_kde_prefers_full_kde_meta() {
	MOCK_CATALOG="kde plasma6-plasma plasma6-plasma-desktop konsole"
	_got=$(kde_desktop_pkgs)
	assertEquals "kde" "$_got"
}

test_kde_falls_back_to_plasma6_plasma() {
	MOCK_CATALOG="plasma6-plasma konsole"
	_got=$(kde_desktop_pkgs)
	assertEquals "plasma6-plasma konsole" "$_got"
}

test_kde_plasma6_without_konsole() {
	MOCK_CATALOG="plasma6-plasma"
	_got=$(kde_desktop_pkgs)
	assertEquals "plasma6-plasma" "$_got"
}

test_kde_component_fallback() {
	MOCK_CATALOG="plasma6-plasma-desktop plasma6-plasma-workspace konsole dolphin"
	_got=$(kde_desktop_pkgs)
	assert_pkg_list_contains "$_got" "plasma6-plasma-desktop"
	assert_pkg_list_contains "$_got" "plasma6-plasma-workspace"
	assert_pkg_list_contains "$_got" "konsole"
	assert_pkg_list_contains "$_got" "dolphin"
	assert_pkg_list_lacks "$_got" "kde"
}

test_kde_empty_when_unavailable() {
	MOCK_CATALOG="firefox bash"
	_got=$(kde_desktop_pkgs) || true
	assertEquals "" "$_got"
}

test_desktop_required_kde_includes_stack() {
	MOCK_CATALOG="kde"
	_got=$(desktop_required_pkgs KDE)
	assert_pkg_list_contains "$_got" "kde"
	assert_pkg_list_contains "$_got" "sddm"
	assert_pkg_list_contains "$_got" "dbus"
	assert_pkg_list_contains "$_got" "xorg"
}

test_desktop_required_sway_wayland() {
	_got=$(desktop_required_pkgs Sway)
	assert_pkg_list_contains "$_got" "sway"
	assert_pkg_list_contains "$_got" "wayland"
	assert_pkg_list_contains "$_got" "seatd"
	assert_pkg_list_contains "$_got" "ly"
	assert_pkg_list_contains "$_got" "swaylock-effects"
}

test_desktop_required_hyprland() {
	_got=$(desktop_required_pkgs Hyprland)
	assert_pkg_list_contains "$_got" "hyprland"
	assert_pkg_list_contains "$_got" "alacritty"
	assert_pkg_list_contains "$_got" "ly"
}

test_desktop_menu_label_kde() {
	_got=$(desktop_menu_label kde)
	assertTrue "label mentions Plasma 6" "echo \"$_got\" | grep -q 'Plasma 6'"
}

# ---------------------------------------------------------------------------
# Tests: package filter
# ---------------------------------------------------------------------------
test_pkgs_filter_available() {
	MOCK_CATALOG="bash sudo firefox"
	_got=$(pkgs_filter_available bash missingpkg sudo 2>/dev/null)
	assert_pkg_list_contains "$_got" "bash"
	assert_pkg_list_contains "$_got" "sudo"
	assert_pkg_list_lacks "$_got" "missingpkg"
}

test_pkgs_find_missing() {
	MOCK_CATALOG="bash"
	if pkgs_find_missing bash sudo 2>/dev/null ; then
		fail "expected missing sudo"
	fi
	assertEquals "sudo" "$MISSING_PKGS"

	assertTrue "all present" "pkgs_find_missing bash"
}

# ---------------------------------------------------------------------------
# Tests: graphics_select (handbook)
# ---------------------------------------------------------------------------
test_graphics_intel_drm_kmod() {
	reset_graphics_state
	graphics_select i915kms
	assertEquals "drm-kmod" "$vc_pkgs"
	assertEquals "i915kms" "$MOCK_KLDS"
}

test_graphics_amdgpu() {
	reset_graphics_state
	graphics_select amdgpu
	assertEquals "drm-kmod" "$vc_pkgs"
	assertEquals "amdgpu" "$MOCK_KLDS"
}

test_graphics_nvidia_current_kms() {
	reset_graphics_state
	NEED_XORG=yes
	graphics_select nvidia
	assert_pkg_list_contains "$vc_pkgs" "nvidia-drm-kmod"
	assert_pkg_list_contains "$vc_pkgs" "nvidia-settings"
	assert_pkg_list_contains "$vc_pkgs" "nvidia-xconfig"
	assertEquals "nvidia-drm" "$MOCK_KLDS"
	assertTrue "modeset loader conf" "echo \"$MOCK_LOADER\" | grep -q 'hw.nvidiadrm.modeset'"
	assertEquals "1" "$vc_post_nvidia_xconfig"
}

test_graphics_nvidia_wayland_no_xconfig_pkgs() {
	reset_graphics_state
	NEED_XORG=no
	graphics_select nvidia
	assert_pkg_list_contains "$vc_pkgs" "nvidia-drm-kmod"
	assert_pkg_list_lacks "$vc_pkgs" "nvidia-xconfig"
	assertEquals "0" "$vc_post_nvidia_xconfig"
}

test_graphics_nvidia304() {
	reset_graphics_state
	graphics_select nvidia304
	assert_pkg_list_contains "$vc_pkgs" "nvidia-driver-304"
	assertEquals "nvidia" "$MOCK_KLDS"
}

test_graphics_vbox() {
	reset_graphics_state
	graphics_select vbox
	assertEquals "virtualbox-ose-additions" "$vc_pkgs"
	assertEquals "1" "$vc_post_vbox"
}

test_graphics_scfb_x11_only() {
	reset_graphics_state
	NEED_XORG=yes
	graphics_select scfb
	assertEquals "xf86-video-scfb" "$vc_pkgs"

	reset_graphics_state
	NEED_XORG=no
	graphics_select scfb
	assertEquals "" "$vc_pkgs"
}

test_graphics_vesa_x11_only() {
	reset_graphics_state
	NEED_XORG=yes
	graphics_select vesa
	assertEquals "xf86-video-vesa" "$vc_pkgs"

	reset_graphics_state
	NEED_XORG=no
	graphics_select vesa
	assertEquals "" "$vc_pkgs"
}

test_graphics_vmwgfx() {
	reset_graphics_state
	NEED_XORG=yes
	graphics_select vmwgfx
	assert_pkg_list_contains "$vc_pkgs" "xf86-video-vmware"
	assertEquals "vmwgfx" "$MOCK_KLDS"
}

test_graphics_append_dedup() {
	reset_graphics_state
	graphics_append_pkg drm-kmod
	graphics_append_pkg drm-kmod
	graphics_append_pkg nvidia-drm-kmod
	assertEquals "drm-kmod nvidia-drm-kmod" "$vc_pkgs"
}

test_graphics_warn_nvidia_conflict() {
	reset_graphics_state
	vc_selected="nvidia nvidia470"
	# Should not fail; only log warning
	graphics_warn_nvidia_conflict
}

# ---------------------------------------------------------------------------
# Run shunit2
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
. "$SHUNIT2"

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
	check_root_owned_not_writable \
	_gettytab_strip_ly \
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
# Tests: ly greeter helpers (gettytab strip + ownership checks)
# ---------------------------------------------------------------------------
test_gettytab_strip_ly_removes_block() {
	_in=$(mktemp "${TMPDIR:-/tmp}/gt-in.XXXXXX")
	_out=$(mktemp "${TMPDIR:-/tmp}/gt-out.XXXXXX")
	cat > "$_in" <<'EOF'
# comment
default:\
	:np:

Ly:\
	:lo=/usr/local/bin/ly_wrapper:\
	:al=root:

Pc|Pc|Pc console:\
	:ht:np:sp#115200:
EOF
	_gettytab_strip_ly "$_in" "$_out"
	assertFalse "Ly: block removed" "grep -q '^Ly:' \"$_out\""
	assertFalse "ly_wrapper line removed" "grep -q ly_wrapper \"$_out\""
	assertTrue "default preserved" "grep -q '^default:' \"$_out\""
	assertTrue "Pc preserved" "grep -q '^Pc|' \"$_out\""
	assertTrue "comment preserved" "grep -q '^# comment' \"$_out\""
	rm -f "$_in" "$_out"
}

test_gettytab_strip_ly_idempotent() {
	_in=$(mktemp "${TMPDIR:-/tmp}/gt-in.XXXXXX")
	_out=$(mktemp "${TMPDIR:-/tmp}/gt-out.XXXXXX")
	_out2=$(mktemp "${TMPDIR:-/tmp}/gt-out2.XXXXXX")
	cat > "$_in" <<'EOF'
foo:\
	:np:

Ly:\
	:lo=/old:\
	:al=root:
EOF
	_gettytab_strip_ly "$_in" "$_out"
	_gettytab_strip_ly "$_out" "$_out2"
	assertEquals "second strip is stable" "$(cat "$_out")" "$(cat "$_out2")"
	assertFalse "still no Ly" "grep -q '^Ly:' \"$_out2\""
	rm -f "$_in" "$_out" "$_out2"
}

test_gettytab_rebuild_single_ly_entry() {
	# Simulate transactional rewrite: strip + append exactly one Ly block
	_in=$(mktemp "${TMPDIR:-/tmp}/gt-in.XXXXXX")
	_mid=$(mktemp "${TMPDIR:-/tmp}/gt-mid.XXXXXX")
	_out=$(mktemp "${TMPDIR:-/tmp}/gt-out.XXXXXX")
	cat > "$_in" <<'EOF'
std:\
	:np:

Ly:\
	:lo=/usr/local/bin/ly:\
	:al=root:
EOF
	_gettytab_strip_ly "$_in" "$_mid"
	{
		cat "$_mid"
		cat <<'EOF'

# installx
Ly:\
	:lo=/usr/local/bin/ly_wrapper:\
	:al=root:
EOF
	} > "$_out"
	_count=$(grep -c '^Ly:' "$_out")
	assertEquals "exactly one Ly: entry" "1" "$_count"
	assertTrue "uses ly_wrapper not bare ly as lo" "grep -q 'lo=/usr/local/bin/ly_wrapper' \"$_out\""
	assertFalse "bare ly lo removed" "grep -q 'lo=/usr/local/bin/ly:' \"$_out\""
	assertTrue "al=root kept" "grep -q ':al=root:' \"$_out\""
	rm -f "$_in" "$_mid" "$_out"
}

test_check_root_owned_missing_path() {
	if [ "$(uname -s 2>/dev/null)" != "FreeBSD" ] ; then
		startSkipping
	fi
	assertFalse "missing path fails" "check_root_owned_not_writable /nonexistent/installx-ly-test-$$"
	endSkipping
}

test_check_root_owned_rejects_world_writable() {
	if [ "$(uname -s 2>/dev/null)" != "FreeBSD" ] || [ "$(id -u)" -ne 0 ] ; then
		# Needs FreeBSD stat(1) and root to own the file as root
		startSkipping
	fi
	_f=$(mktemp /tmp/installx-own.XXXXXX)
	chmod 666 "$_f"
	# Ensure root-owned (we are root in FreeBSD CI)
	chown root:wheel "$_f" 2>/dev/null || true
	assertFalse "world-writable rejected" "check_root_owned_not_writable \"$_f\""
	rm -f "$_f"
	endSkipping
}

test_check_root_owned_accepts_safe_file() {
	if [ "$(uname -s 2>/dev/null)" != "FreeBSD" ] || [ "$(id -u)" -ne 0 ] ; then
		startSkipping
	fi
	_f=$(mktemp /tmp/installx-own.XXXXXX)
	chown root:wheel "$_f"
	chmod 644 "$_f"
	assertTrue "root-owned 644 accepted" "check_root_owned_not_writable \"$_f\""
	rm -f "$_f"
	endSkipping
}

test_check_root_owned_rejects_non_root_owner() {
	if [ "$(uname -s 2>/dev/null)" != "FreeBSD" ] ; then
		startSkipping
		endSkipping
		return 0
	fi
	_f=$(mktemp /tmp/installx-own.XXXXXX)
	if [ "$(id -u)" -eq 0 ] ; then
		if ! pw usershow nobody >/dev/null 2>&1 ; then
			rm -f "$_f"
			startSkipping
			endSkipping
			return 0
		fi
		chown nobody "$_f"
	fi
	# As non-root, creator is already non-root — sufficient
	chmod 644 "$_f"
	assertFalse "non-root owner rejected" "check_root_owned_not_writable \"$_f\""
	rm -f "$_f"
}

# ---------------------------------------------------------------------------
# Run shunit2
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
. "$SHUNIT2"

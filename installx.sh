#!/bin/sh
# Nick Bernstein https://github.com/nicholasbernstein/install-fbsd-desktop
# most of this comes from the freebsd handbook 5.4.1. Quick Start x-config

# NOTE: Do not use `set -o pipefail` here, as it breaks /bin/sh on FreeBSD 13.x

LOGFILE="installx.log"
ERRLOG="installx.err"
date > "$LOGFILE"
: > "$ERRLOG"

# Non-interactive / CI mode: set INSTALLX_NONINTERACTIVE=1 (or CI=true).
# Optional env overrides:
#   INSTALLX_USER          user to add to video/wheel (default: uid 1001 or "nick")
#   INSTALLX_DESKTOP       desktop/compositor name (default: awesome)
#                          X11: KDE LXDE LXQT GNOME Xfce4 WindowMaker awesome MATE Cinnamon
#                          Wayland: Sway Hyprland  (same menu; stack is chosen automatically)
#   INSTALLX_ROLLING       yes|no — use pkg "latest" instead of quarterly
#                          (default: no, except newest/preview FreeBSD where quarterly
#                          desktop packages are often incomplete — then default yes)
#   INSTALLX_EXTRA_PKGS    space-separated packages (default: bash sudo)
#   INSTALLX_OPT           space-separated option names matching the dialog checklist (see below)
#   INSTALLX_GRAPHICS      yes|no|auto — install GPU drivers (default: no).
#                          auto = yes + pciconf detection when VIDEO_CARD unset
#   INSTALLX_VIDEO_CARD    space-separated driver keys, or "auto" to detect via pciconf.
#                          Keys: i915kms amdgpu radeonkms nvidia nvidia_modeset
#                          nvidia470 nvidia390 nvidia340 vesa scfb vmwgfx
#   INSTALLX_BASH_SHELL    yes|no — set user shell to bash (default: yes if bash installed)
#   INSTALLX_SUDO_WHEEL    yes|no — allow %wheel to sudo (default: yes if sudo installed)
#   INSTALLX_AUDIO         yes|no — load sound drivers and probe/show devices (default: yes)
#   INSTALLX_SND_DEFAULT_UNIT  pcm unit number for hw.snd.default_unit, or empty/skip to leave default
#   INSTALLX_AUDIO_PKGS    yes|no — install pulseaudio + sndio helpers (default: yes if AUDIO=yes)
#
# Each desktop sets a small profile (SESSION_TYPE, packages, display manager). The user only
# picks what they want; X11 vs Wayland plumbing is applied automatically.
is_noninteractive() {
	[ "${INSTALLX_NONINTERACTIVE:-0}" = "1" ] || [ "${CI:-}" = "true" ] || [ "${CI:-}" = "1" ]
}

# UI: always use cdialog (devel/cdialog). Base bsddialog is intentionally
# not used — its gauge/programbox behaviour differs enough to break this UI.
# If cdialog is missing we print a clear message and pkg-install it first.
DIALOG_BIN=""
resolve_dialog_bin() {
	# Ensure /usr/local/bin is searchable after a fresh pkg install
	PATH="${PATH}:/usr/local/bin"
	export PATH

	# Force pkg bootstrap silently to prevent invisible [y/N] prompts from hanging
	export ASSUME_ALWAYS_YES=yes
	if [ -x /usr/sbin/pkg ] && ! command -v pkg >/dev/null 2>&1 ; then
		env ASSUME_ALWAYS_YES=yes /usr/sbin/pkg bootstrap -y >/dev/null 2>&1 || true
	fi

	if command -v cdialog >/dev/null 2>&1 ; then
		DIALOG_BIN=$(command -v cdialog)
		echo "installx: using cdialog ($DIALOG_BIN)" >> "$LOGFILE"
		return 0
	fi

	if ! command -v pkg >/dev/null 2>&1 ; then
		echo "error: pkg not available; cannot install cdialog" >&2
		return 1
	fi

	echo "installx: installing cdialog…" | tee -a "$LOGFILE"
	if ! env ASSUME_ALWAYS_YES=yes pkg install -y cdialog >>"$LOGFILE" 2>&1 ; then
		# Origin form if the short name is unavailable in this catalog
		if ! env ASSUME_ALWAYS_YES=yes pkg install -y devel/cdialog >>"$LOGFILE" 2>&1 ; then
			echo "error: failed to install cdialog (see $LOGFILE)" >&2
			return 1
		fi
	fi

	# Refresh PATH in case pkg just dropped the binary into /usr/local/bin
	PATH="${PATH}:/usr/local/bin"
	export PATH
	hash -r 2>/dev/null || true

	if command -v cdialog >/dev/null 2>&1 ; then
		DIALOG_BIN=$(command -v cdialog)
		echo "installx: cdialog ready ($DIALOG_BIN)" | tee -a "$LOGFILE"
		return 0
	fi

	echo "error: cdialog installed but not found in PATH=$PATH" >&2
	return 1
}

# Child PIDs for long-running background work (pkg update, etc.). Do NOT
# background cdialog — that causes SIGTTOU suspend on exit (hang).
INSTALLX_CHILD_PID=""

installx_kill_pid() {
	_kp="$1"
	[ -z "$_kp" ] && return 0
	kill -TERM "$_kp" 2>/dev/null || true
	sleep 0.1 2>/dev/null || true
	kill -KILL "$_kp" 2>/dev/null || true
	wait "$_kp" 2>/dev/null || true
}

# Clean abort on Ctrl+C (SIGINT) / SIGTERM.
installx_abort() {
	_sig=${1:-INT}
	echo "" >> "$LOGFILE" 2>/dev/null || true
	echo "installx: Ctrl+C / signal ${_sig} — exiting." >> "$LOGFILE" 2>/dev/null || true
	echo ""
	echo "installx: Ctrl+C — exiting."
	installx_kill_pid "${INSTALLX_CHILD_PID:-}"
	INSTALLX_CHILD_PID=""
	
	# Restore terminal sanity before quitting
	stty sane 2>/dev/null || true
	trap - INT TERM HUP
	exit 130
}
trap 'installx_abort INT' INT
trap 'installx_abort TERM' TERM
trap 'installx_abort HUP' HUP

# Run a long non-UI command in the background so Ctrl+C hits our trap.
# Usage: installx_run_interruptible cmd [args...]
# Sets $INSTALLX_RUN_RC to the child's exit status.
# Never use this for cdialog (ncurses must run in the foreground).
installx_run_interruptible() {
	"$@" &
	INSTALLX_CHILD_PID=$!
	wait "${INSTALLX_CHILD_PID}"
	INSTALLX_RUN_RC=$?
	INSTALLX_CHILD_PID=""
	return "${INSTALLX_RUN_RC}"
}

# pkg update with an interactive output box. Sets INSTALLX_RUN_RC.
installx_pkg_update_with_progress() {
	_box_title="${1:-Updating package catalog}"

	# Log always; avoid printing to the console right before the box
	echo "installx: ${_box_title}…" >> "$LOGFILE"
	
	if is_noninteractive || [ -z "${DIALOG_BIN:-}" ] ; then
		echo "installx: ${_box_title}…"
		installx_run_interruptible sh -c "env ASSUME_ALWAYS_YES=yes pkg update 2>&1 | tee -a \"${LOGFILE}\""
		return "${INSTALLX_RUN_RC}"
	fi

	_pkg_rcfile=$(mktemp /tmp/installx-pkgup.XXXXXX) || _pkg_rcfile="/tmp/installx-pkgup.$$"

	# Run pkg update, capture its exit code, and stream output to both the log and the UI
	(
		env ASSUME_ALWAYS_YES=yes pkg update 2>&1
		echo $? > "${_pkg_rcfile}"
	) | tee -a "$LOGFILE" | "$DIALOG_BIN" --title "${_box_title}" --programbox 20 75

	if [ -f "${_pkg_rcfile}" ] ; then
		INSTALLX_RUN_RC=$(cat "${_pkg_rcfile}")
		rm -f "${_pkg_rcfile}"
	else
		INSTALLX_RUN_RC=1
	fi
	return "${INSTALLX_RUN_RC}"
}

# Wrapper: rest of script keeps calling dialog … which invokes cdialog.
# Must run in the FOREGROUND. Backgrounding ncurses causes SIGTTOU on
# tcsetattr at exit, which suspends the process and makes wait hang forever.
dialog() {
	if [ -z "$DIALOG_BIN" ] ; then
		echo "error: cdialog UI not available" >&2
		return 127
	fi
	if [ -z "${TERM:-}" ] || [ "$TERM" = "dumb" ] || [ "$TERM" = "unknown" ] ; then
		export TERM=xterm
	fi

	# Protect against piped execution and background SIGTTOU: force cdialog
	# to read the interactive keyboard natively from the terminal.
	if [ -c /dev/tty ] ; then
		"$DIALOG_BIN" "$@" < /dev/tty
	else
		"$DIALOG_BIN" "$@" < /dev/null
	fi
	return $?
}

# cdialog draws UI on stderr. Only steal stderr in noninteractive mode.
if is_noninteractive ; then
	export ASSUME_ALWAYS_YES=yes
	export IGNORE_OSVERSION="${IGNORE_OSVERSION:-yes}"
	exec 2>>"$ERRLOG"
	set -x
	PS4="$0 $LINENO >"
else
	set +x
	# Ctrl+C = INTR on this tty
	stty isig 2>/dev/null || true
	stty intr '^C' 2>/dev/null || true

	echo "installx: interactive mode (log: $LOGFILE)" | tee -a "$LOGFILE"
	if ! resolve_dialog_bin ; then
		echo "error: need cdialog (pkg install cdialog)." >&2
		echo "  Or: INSTALLX_NONINTERACTIVE=1 INSTALLX_DESKTOP=... $0" >&2
		exit 1
	fi
fi

grep -q "kern.vty" /boot/loader.conf || echo "kern.vty=vt" >> /boot/loader.conf

change_pkg_url_to_latest () {
	# Opt-in only (INSTALLX_ROLLING=yes or interactive Yes). Default remains quarterly.
	# Repo configs: /etc/pkg and/or /usr/local/etc/pkg/repos.
	for _pf in /etc/pkg/FreeBSD.conf /usr/local/etc/pkg/repos/FreeBSD.conf ; do
		if [ -f "$_pf" ] && grep -q 'quarterly' "$_pf" 2>/dev/null ; then
			sed -i '.bak' -e 's/quarterly/latest/g' "$_pf"
			echo "pkg: rewrote quarterly→latest in $_pf" | tee -a "$LOGFILE"
		fi
		[ -f "$_pf" ] && grep -H 'url' "$_pf" 2>/dev/null | tee -a "$LOGFILE" || true
	done
	# Local override so "latest" wins if base conf was already non-quarterly
	mkdir -p /usr/local/etc/pkg/repos
	cat > /usr/local/etc/pkg/repos/FreeBSD.conf <<'PKGEOF'
# installx.sh — only written when user opts into the "latest" package set
FreeBSD: {
  url: "pkg+https://pkg.FreeBSD.org/${ABI}/latest",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}
PKGEOF
	echo "pkg: wrote /usr/local/etc/pkg/repos/FreeBSD.conf (latest, opt-in)" | tee -a "$LOGFILE"
}

load_card_readers () {
	# Load MMC/SD card-reader support
	sysrc kld_list+="mmc"
	sysrc kld_list+="mmcsd"
	sysrc kld_list+="sdhci"
}

load_atapi() {
	# Access ATAPI devices through the CAM subsystem
	sysrc kld_list+="atapicam"
}

load_fuse() {
	# Filesystems in Userspace
	fuse_pkgs="fuse fuse-utils"
	extra_pkgs="$extra_pkgs fusefs-lkl e2fsprogs"
	sysrc kld_list+="fusefs"
}

load_coretemp(){
	# Intel Core thermal sensors
	sysrc kld_list+="coretemp"
}

load_amdtemp() {
	# AMD K8, K10, K11 thermal sensors
	if ( sysctl -a | grep -q -i "hw.model" | grep -q AMD ) ; then 
		amdtemp_load="YES"
	fi
}

load_bluetooth() { 
	# most common bluetooth adapters use this
	sysrc kld_list+="ng_ubt"
	sysrc hcsecd_enable="YES"
	sysrc sdpd_enable="YES"
}

enable_ipfw_firewall() {
	# this enables the ipfw firewall with the workstation profile
	# it allows communication w/ other hosts on the network, outgoing traffic
	# and any specific ports (ssh) we choose to enable
	sysrc firewall_type="WORKSTATION"
	sysrc firewall_myservices="22/tcp"
	sysrc firewall_allowservices="any"
	sysrc firewall_enable="YES"
}

enable_tmpfs() {
	# In-memory filesystems
	sysrc kld_list+="tmpfs"
}

enable_async_io() {
	# Asynchronous I/O
	sysrc kld_list+="aio"
}

enable_workstation_pwr_mgmnt() {
	# powerd: hiadaptive speed while on AC power, adaptive while on battery power
	sysrc powerd_enable="YES"
	sysrc powerd_flags="-a hiadaptive -b adaptive"
}

enable_webcam(){
	#this just enables the ability to use webcams
	extra_pkgs="$extra_pkgs webcamd"
	sysrc kld_list+="cuse4bsd"
	sysrc webcamd_enable="YES"
}

enable_cups() {
	#this just enables the ability to use printers
	extra_pkgs="$extra_pkgs cups"
	sysrc cupsd_enable="YES"
}

linuxBaseC7 () {
		sysrc kld_list+="linux"
		kldstat | grep -q linux || kldload linux
		sysrc kld_list+="linux64"
		kldstat | grep -q linux64 || kldload linux64
		sysrc linux_enable="YES"

		mkdir -p /compat/linux/proc /compat/linux/dev/shm /compat/linux/sys
		grep "/compat/linux/proc" /etc/fstab 2>/dev/null || \
			echo "linprocfs   /compat/linux/proc  linprocfs rw 0 0" >> /etc/fstab
		grep "/compat/linux/sys" /etc/fstab 2>/dev/null || \
			echo "linsysfs    /compat/linux/sys   linsysfs  rw 0 0" >> /etc/fstab
		grep "/compat/linux/dev" /etc/fstab 2>/dev/null || \
			echo "tmpfs    /compat/linux/dev/shm  tmpfs rw,mode=1777 0 0" >> /etc/fstab
}

enable_virtualbox_ose_additions() {
		sysrc vboxguest_enable="YES"
		sysrc vboxservice_enable="YES"
		if ! is_noninteractive ; then
			dialog --infobox "Please use VBoxSVGA as the virtualbox display driver for best performance." 0 0
		else
			echo "noninteractive: VirtualBox guest additions enabled; use VBoxSVGA for best performance." | tee -a "$LOGFILE"
		fi
}

adjust_sysctl_buffers() { 
	sysctl net.local.stream.recvspace=65536
	grep "net.local.stream.recvspace" /etc/sysctl.conf || echo "net.local.stream.recvspace=65536" >> /etc/sysctl.conf
	sysctl net.local.stream.sendspace=65536
	grep "net.local.stream.sendspace" /etc/sysctl.conf || echo "net.local.stream.sendspace=65536" >> /etc/sysctl.conf
}

report(){
	# $1 - testname, $2 - $?
        STATUS="OK"
        if [ "$2" -eq 1 ] ; then
                STATUS="FAILED"
        fi
        echo "$1: $STATUS" | tee -a $LOGFILE
}

# this is mainly just to make sure pkg has been bootstrapped
export ASSUME_ALWAYS_YES=yes
if ! is_noninteractive ; then
	# First interactive UI: welcome must block for OK before any progress gauge.
	dialog --title "installx" --msgbox \
"Welcome to install-fbsd-desktop.

This program will guide you through sensible choices when installing a FreeBSD desktop.

You can cancel a screen with Esc, quit from the desktop menu, or press Ctrl+C to abort at any time." 12 60
	_drc=$?
	if [ "$_drc" -ge 128 ] ; then
		installx_abort INT
	fi
	# Cancel/ESC: cdialog Cancel=1, ESC=255
	if [ "$_drc" -eq 1 ] || [ "$_drc" -eq 255 ] ; then
		echo "installx: cancelled at welcome screen." | tee -a "$LOGFILE"
		exit 0
	fi
fi

# Progress UI starts right after OK (no silent work before the programbox)
installx_pkg_update_with_progress "Updating Package Catalog"
report "pkg bootstrapping" "$INSTALLX_RUN_RC"
if ! is_noninteractive ; then
	echo "installx: package catalog ready; continuing…" >> "$LOGFILE"
fi

# Package catalog validation tools
pkg_is_available() {
	_pn="$1"
	[ -z "$_pn" ] && return 1
	# Already installed
	if pkg info -e "$_pn" >/dev/null 2>&1 ; then
		return 0
	fi
	# Exact name in remote catalogs (after pkg update)
	if pkg rquery -e "%n == \"${_pn}\"" %n >/dev/null 2>&1 ; then
		_hit=$(pkg rquery -e "%n == \"${_pn}\"" %n 2>/dev/null | head -n 1)
		[ -n "$_hit" ] && return 0
	fi
	# Fallback: exact search
	if pkg search -q -e "$_pn" 2>/dev/null | grep -qx "$_pn" ; then
		return 0
	fi
	return 1
}

default_prefer_latest_packages() {
	_ver=$(freebsd-version 2>/dev/null || uname -r)
	_mm=$(echo "$_ver" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')

	# Development / prerelease branches almost always need latest ports
	case "$_ver" in
		*CURRENT*|*STABLE*|*BETA*|*RC*|*PRERELEASE*|*ALPHA*)
			echo "pkg: FreeBSD $_ver looks like a development/preview branch — prefer latest" | tee -a "$LOGFILE"
			return 0
			;;
	esac

	# Fallback heuristic: base desktop stack present but no major DE metas yet
	if pkg_is_available xorg || pkg_is_available xorg-minimal ; then
		if ! pkg_is_available kde \
			&& ! pkg_is_available plasma6-plasma \
			&& ! pkg_is_available gnome \
			&& ! pkg_is_available xfce ; then
			echo "pkg: quarterly desktop catalog looks sparse on $_ver — prefer latest" | tee -a "$LOGFILE"
			return 0
		fi
	fi
	return 1
}

# ---------------------------------------------------------------------------
# Package branch logic
# ---------------------------------------------------------------------------
_prefer_latest=0
if default_prefer_latest_packages ; then
	_prefer_latest=1
fi

if is_noninteractive ; then
	if [ -n "${INSTALLX_ROLLING:-}" ] ; then
		case "${INSTALLX_ROLLING}" in
			[Yy][Ee][Ss]|1|true|TRUE) rolling=0 ;;
			*) rolling=1 ;;
		esac
	elif [ "$_prefer_latest" -eq 1 ] ; then
		rolling=0
	else
		rolling=1
	fi
	echo "noninteractive: use_latest_packages=$( [ "$rolling" -eq 0 ] && echo yes || echo no ) prefer_latest_default=${_prefer_latest}" | tee -a "$LOGFILE"
else
	if [ "$_prefer_latest" -eq 1 ] ; then
		dialog --title "Package branch" --yesno "This FreeBSD release looks new or still filling out quarterly packages.\n\nUse the 'latest' package branch? (recommended here)\n\n• Yes = latest (more complete desktop packages on new releases)\n• No  = quarterly (more conservative)\n\nYou can stay on quarterly if you prefer." 14 62
		rolling=$?
	else
		dialog --defaultno --title "Package branch" --yesno "Use quarterly packages (recommended), or switch to 'latest'?\n\n• No  = quarterly (default)\n• Yes = latest (newer ports)\n\nMost users on stable releases should choose No." 12 60
		rolling=$?
	fi
fi

if [ "$rolling" -eq 0  ] ; then 
	change_pkg_url_to_latest
	report "quarterly->latest changed" "$?"
	installx_pkg_update_with_progress "Updating Package Catalog (latest)"
else
	echo "pkg: staying on quarterly package set" | tee -a "$LOGFILE"
fi

# Set up defaults
SESSION_TYPE="x11"          
NEED_XORG="yes"             
SEATD_NEEDED="no"           
DISPLAY_MGR="sddm"          
DESKTOP_PKGS=""
XINIT_CMD=""                
WAYLAND_COMPOSITOR=""       

kde_desktop_pkgs() {
	if pkg_is_available kde ; then
		echo "kde"
	elif pkg_is_available plasma6-plasma ; then
		echo "plasma6-plasma konsole"
	elif pkg_is_available plasma5-plasma ; then
		echo "plasma5-plasma"
	else
		echo "kde"
	fi
}

desktop_required_pkgs() {
	case $(echo "$1" | tr '[:upper:]' '[:lower:]') in
		kde) echo "$(kde_desktop_pkgs) sddm dbus xorg" ;;
		gnome) echo "gnome gdm dbus" ;;
		xfce4|xfce) echo "xfce sddm dbus xorg" ;;
		mate) echo "mate sddm dbus xorg" ;;
		cinnamon) echo "cinnamon sddm dbus xorg" ;;
		lxqt) echo "lxqt sddm dbus xorg" ;;
		lxde) echo "lxde-meta lxde-common sddm dbus xorg" ;;
		windowmaker) echo "windowmaker wmakerconf sddm dbus xorg" ;;
		awesome) echo "awesome sddm dbus xorg" ;;
		sway) echo "sway swayidle swaylock-effects alacritty waybar wayland seatd xwayland ly dbus" ;;
		hyprland) echo "hyprland alacritty wayland seatd xwayland ly dbus" ;;
		*) echo "" ;;
	esac
}

desktop_menu_label() {
	case $(echo "$1" | tr '[:upper:]' '[:lower:]') in
		kde) echo "KDE Plasma 6 (X11)" ;;
		gnome) echo "GNOME desktop (X11)" ;;
		xfce4) echo "Lightweight XFCE desktop (X11)" ;;
		mate) echo "MATE desktop, GNOME 2 fork (X11)" ;;
		cinnamon) echo "Cinnamon desktop (X11)" ;;
		lxqt) echo "Lightweight Qt desktop (X11)" ;;
		lxde) echo "Lightweight X11 desktop (X11)" ;;
		windowmaker) echo "Window Maker (X11)" ;;
		awesome) echo "Awesome tiling WM (X11)" ;;
		sway) echo "Sway tiling compositor (Wayland)" ;;
		hyprland) echo "Hyprland compositor (Wayland)" ;;
		*) echo "$1" ;;
	esac
}

ALL_DESKTOP_TAGS="KDE GNOME Xfce4 MATE Cinnamon LXQT LXDE WindowMaker awesome Sway Hyprland"

AVAILABLE_DESKTOPS=""
UNAVAILABLE_DESKTOPS=""

echo "pkg: validating desktop options against package catalog…" | tee -a "$LOGFILE"

_val_dir=$(mktemp -d /tmp/installx-val.XXXXXX) || _val_dir="/tmp/installx-val.$$"
mkdir -p "${_val_dir}"
(
	_av=""
	_un=""
	for _tag in $ALL_DESKTOP_TAGS ; do
		_req=$(desktop_required_pkgs "$_tag")
		_missing=0
		for _pn in $_req; do
			if ! pkg_is_available "$_pn"; then _missing=1; break; fi
		done
		if [ $_missing -eq 0 ] ; then
			_av="${_av} ${_tag}"
		else
			_un="${_un} ${_tag}"
		fi
	done
	echo "$_av" | sed 's/^ *//' > "${_val_dir}/available"
	echo "$_un" | sed 's/^ *//' > "${_val_dir}/unavailable"
) &
INSTALLX_CHILD_PID=$!

if ! is_noninteractive && [ -n "${DIALOG_BIN:-}" ] ; then
	"$DIALOG_BIN" --title "Checking desktops" --infobox "Checking which desktops can be installed…\n\nQuerying the package catalog in the background. Please wait." 10 70
	wait "${INSTALLX_CHILD_PID}" 2>/dev/null || true
else
	wait "${INSTALLX_CHILD_PID}" 2>/dev/null || true
fi
INSTALLX_CHILD_PID=""

AVAILABLE_DESKTOPS=$(cat "${_val_dir}/available" 2>/dev/null || true)
rm -rf "${_val_dir}"

if [ -z "$AVAILABLE_DESKTOPS" ] ; then
	echo "FATAL: no desktops have all required packages available in the catalog." | tee -a "$LOGFILE"
	if ! is_noninteractive ; then
		dialog --msgbox "No desktop options are installable from the current package catalog.\n\nNothing has been installed yet. Fix pkg/network and re-run, or exit.\n\nSee installx.log." 0 0
	fi
	exit 1
fi

if is_noninteractive ; then
	desktop="${INSTALLX_DESKTOP:-awesome}"
else
	_menu_cmd='dialog --clear --title "Select Desktop" --menu "Select a desktop that is available in the package catalog." 0 0 0'
	for _tag in $AVAILABLE_DESKTOPS ; do
		_lab=$(desktop_menu_label "$_tag")
		_menu_cmd="$_menu_cmd \"$_tag\" \"$_lab\""
	done
	_menu_cmd="$_menu_cmd \"Quit\" \"Exit without installing anything\" --stdout"
	desktop=$(eval "$_menu_cmd") || desktop="Quit"
	if [ -z "$desktop" ] || [ "$desktop" = "Quit" ] ; then
		echo "User quit before install; no changes from desktop selection." | tee -a "$LOGFILE"
		exit 0
	fi
fi

desktop_key=$(echo "$desktop" | tr '[:upper:]' '[:lower:]')

case $desktop_key in
  kde)
      XINIT_CMD="startplasma-x11"
      DESKTOP_PKGS=$(kde_desktop_pkgs)
      DISPLAY_MGR="sddm"
      ;;
  windowmaker)
      XINIT_CMD="/usr/local/bin/wmaker"
      DESKTOP_PKGS="windowmaker wmakerconf"
      DISPLAY_MGR="sddm"
      mkdir -p /usr/local/share/xsessions
cat <<EOT >/usr/local/share/xsessions/wmaker.desktop
[Desktop Entry]
Encoding=UTF-8
Name=Windowmaker
Comment=Windowmaker Desktop Environment
Exec=/usr/local/bin/wmaker
Icon=
Type=Application
EOT
      ;;
  lxqt)
      XINIT_CMD="startlxqt"
      DESKTOP_PKGS="lxqt"
      DISPLAY_MGR="sddm"
      ;;
  lxde)
      XINIT_CMD="startlxde"
      DESKTOP_PKGS="lxde-meta lxde-common"
      DISPLAY_MGR="sddm"
      ;;
  gnome)
      XINIT_CMD="gnome-session"
      DESKTOP_PKGS="gnome"
      DISPLAY_MGR="gdm"
      sysrc gnome_enable="YES"
      ;;
  xfce4|xfce)
      XINIT_CMD="startxfce4"
      DESKTOP_PKGS="xfce xfce4-goodies"
      DISPLAY_MGR="sddm"
      ;;
  mate)
      XINIT_CMD="mate-session"
      DESKTOP_PKGS="mate"
      DISPLAY_MGR="sddm"
      ;;
  cinnamon)
      XINIT_CMD="cinnamon-session"
      DESKTOP_PKGS="cinnamon"
      DISPLAY_MGR="sddm"
      ;;
  awesome)
      XINIT_CMD="awesome"
      DESKTOP_PKGS="awesome"
      DISPLAY_MGR="sddm"
      ;;
  sway)
      SESSION_TYPE="wayland"
      NEED_XORG="no"
      SEATD_NEEDED="yes"
      DISPLAY_MGR="ly"
      WAYLAND_COMPOSITOR="sway"
      DESKTOP_PKGS="sway swayidle swaylock-effects alacritty waybar"
      XINIT_CMD=""
      ;;
  hyprland)
      SESSION_TYPE="wayland"
      NEED_XORG="no"
      SEATD_NEEDED="yes"
      DISPLAY_MGR="ly"
      WAYLAND_COMPOSITOR="hyprland"
      DESKTOP_PKGS="hyprland alacritty"
      XINIT_CMD=""
      ;;
  *)
     echo "$desktop isn't a valid option."
     if is_noninteractive ; then
       exit 1
     fi
     ;;
esac

echo "profile: desktop=$desktop_key session=$SESSION_TYPE display_mgr=$DISPLAY_MGR need_xorg=$NEED_XORG" | tee -a "$LOGFILE"
apply_display_manager
report "Desktop Selected" "$?"

adjust_sysctl_buffers
report "add sync buffers" "$?"

# Execute final package installation based on choices
_install_pkgs="$DESKTOP_PKGS"
if [ "$NEED_XORG" = "yes" ]; then
    _install_pkgs="$_install_pkgs xorg"
fi
if [ "$SEATD_NEEDED" = "yes" ]; then
    _install_pkgs="$_install_pkgs seatd"
fi

if [ -n "$_install_pkgs" ]; then
    if ! is_noninteractive && [ -n "${DIALOG_BIN:-}" ] ; then
        _pkg_rcfile=$(mktemp /tmp/installx-pkgin.XXXXXX) || _pkg_rcfile="/tmp/installx-pkgin.$$"
        (
            env ASSUME_ALWAYS_YES=yes pkg install -y $_install_pkgs 2>&1
            echo $? > "${_pkg_rcfile}"
        ) | tee -a "$LOGFILE" | "$DIALOG_BIN" --title "Installing Desktops" --programbox 20 75
        
        if [ -f "${_pkg_rcfile}" ] ; then
            _rc=$(cat "${_pkg_rcfile}")
            rm -f "${_pkg_rcfile}"
        else
            _rc=1
        fi
        report "Package installation completed" "$_rc"
    else
        echo "installx: Installing selected desktop environments..." >> "$LOGFILE"
        env ASSUME_ALWAYS_YES=yes pkg install -y $_install_pkgs >> "$LOGFILE" 2>&1
        report "Package installation completed" "$?"
    fi
fi

# Cleanup and exit
echo "Installation complete." | tee -a "$LOGFILE"
exit 0
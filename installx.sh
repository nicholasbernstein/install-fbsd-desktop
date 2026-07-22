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
			&& ! pkg_is_available plasma6-plasma-desktop \
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
slim_extra_pkgs=""
extra_pkgs=""
vc_pkgs=""
audio_pkgs=""

# FreeBSD 11 used slim; keep that default for old releases
if ( uname -r | grep -q "^11" ) ; then
	DISPLAY_MGR="slim"
	slim_extra_pkgs="slim-freebsd-dark-theme"
	pwd_mkdb -p /etc/master.passwd
fi

# Resolve KDE/Plasma package set for this ABI/catalog.
# Prefer meta ports (kde, plasma6-plasma). On some FreeBSD 15.x catalogs the
# metas are missing while individual plasma6-* packages exist — use a
# component fallback so KDE stays installable. Echo empty if nothing usable.
kde_desktop_pkgs() {
	if pkg_is_available kde ; then
		echo "kde"
		return 0
	fi
	if pkg_is_available plasma6-plasma ; then
		# Handbook-style minimal Plasma 6 meta
		if pkg_is_available konsole ; then
			echo "plasma6-plasma konsole"
		else
			echo "plasma6-plasma"
		fi
		return 0
	fi
	if pkg_is_available plasma5-plasma ; then
		echo "plasma5-plasma"
		return 0
	fi
	# Component fallback (metas absent; pieces present — common on early 15.x)
	if pkg_is_available plasma6-plasma-desktop ; then
		_kde_fb="plasma6-plasma-desktop"
		for _kp in \
			plasma6-plasma-workspace \
			plasma6-systemsettings \
			plasma6-breeze \
			plasma6-kwin-x11 \
			plasma6-plasma-pa \
			plasma6-kmenuedit \
			plasma6-kscreen \
			plasma6-kinfocenter \
			plasma6-kde-cli-tools \
			konsole \
			dolphin \
			kde-baseapps
		do
			if pkg_is_available "$_kp" ; then
				_kde_fb="${_kde_fb} ${_kp}"
			fi
		done
		echo "$_kde_fb"
		return 0
	fi
	# Nothing installable for KDE on this catalog
	echo ""
	return 1
}

desktop_required_pkgs() {
	case $(echo "$1" | tr '[:upper:]' '[:lower:]') in
		kde)
			_kp=$(kde_desktop_pkgs)
			if [ -z "$_kp" ] ; then
				# Force validation failure when no KDE set exists
				echo "kde"
			else
				echo "$_kp sddm dbus xorg"
			fi
			;;
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

add_user_to_video() {
	# Your user needs to be in the video group to use video acceleration
	default_user=$(grep 1001 /etc/passwd | awk -F: '{ print $1 }')
	if is_noninteractive ; then
		VUSER="${INSTALLX_USER:-${default_user:-nick}}"
		echo "noninteractive: using video user '$VUSER'" | tee -a "$LOGFILE"
	else
		# Quote default text — empty $default_user must not shift --stdout
		VUSER=$(dialog --title "Video User" --clear --inputbox \
			"What user should be added to the video group?" 0 0 "${default_user:-nick}" --stdout) || true
		if [ -z "$VUSER" ] ; then
			VUSER="${default_user:-nick}"
			echo "installx: empty video user; using '$VUSER'" | tee -a "$LOGFILE"
		fi
	fi

	# ensure home exists for .xinitrc and similar
	if ! id "$VUSER" >/dev/null 2>&1 ; then
		echo "user '$VUSER' does not exist; creating" | tee -a "$LOGFILE"
		pw useradd -n "$VUSER" -m -s /bin/sh || true
	fi
	mkdir -p "/home/$VUSER"
	chown "$VUSER" "/home/$VUSER" 2>/dev/null || true

	pw groupmod video -m "$VUSER" && echo "added $VUSER to group: video"
	report "add $VUSER to video group" "$?"
	pw groupmod wheel -m "$VUSER" && echo "added $VUSER to group: wheel"
	report "add $VUSER to wheel group" "$?"
	# seatd (Wayland) often uses the video group; some builds also ship _seatd/seat
	if pw groupshow _seatd >/dev/null 2>&1 ; then
		pw groupmod _seatd -m "$VUSER" && echo "added $VUSER to group: _seatd" | tee -a "$LOGFILE"
	elif pw groupshow seat >/dev/null 2>&1 ; then
		pw groupmod seat -m "$VUSER" && echo "added $VUSER to group: seat" | tee -a "$LOGFILE"
	fi

	# probably not necessary, logging into an x session as root isn't recommended.
	pw groupmod video -m root
	report "add root to video group" "$?"
}

gen_xinit() {
	# Create .xinitrc in the user's home and /etc/skel for the chosen WM/session.
	if [ -z "$1" ] ; then
		echo "argument needed by gen_xinit"
		return 0
	fi
	# FreeBSD /bin/sh has no echo -e; use printf %b for \n escapes
	xinittxt="#!/bin/sh\nmywm=\"$1\"\nif [ \"\$1\" ] ; then\n\tcase \$1 in\n\t\tdefault) exec \$mywm ;;\n\t\t*) exec \$1 ;;\n\tesac\nelse\n\texec \$mywm\nfi\n"
	printf '%b' "$xinittxt" > "/home/${VUSER}/.xinitrc"
	chown "$VUSER" "/home/${VUSER}/.xinitrc"
	test -d /etc/skel || mkdir /etc/skel
	printf '%b' "$xinittxt" > /etc/skel/.xinitrc
}


# --- Session profile defaults (overridden per desktop below) ---
# User picks one desktop from a single menu; we apply a reasonable stack.
SESSION_TYPE="x11"          # x11 | wayland
NEED_XORG="yes"             # install xorg stack
SEATD_NEEDED="no"           # wayland compositors need seatd
DISPLAY_MGR="sddm"          # sddm | slim | gdm | ly | none
DESKTOP_PKGS=""
XINIT_CMD=""                # set by desktop profile; gen_xinit after user exists
WAYLAND_COMPOSITOR=""       # sway | hyprland | ...
slim_extra_pkgs=""

# FreeBSD 11 used slim; keep that default for old releases
if ( uname -r | grep -q "^11" ) ; then
	DISPLAY_MGR="slim"
	slim_extra_pkgs="slim-freebsd-dark-theme"
	pwd_mkdb -p /etc/master.passwd
fi

seed_sway_config() {
	uhome="/home/${VUSER}"
	mkdir -p "${uhome}/.config/sway" /etc/skel/.config/sway
	if [ -f /usr/local/etc/sway/config ] ; then
		cp /usr/local/etc/sway/config "${uhome}/.config/sway/config"
		cp /usr/local/etc/sway/config /etc/skel/.config/sway/config
	else
		cat > "${uhome}/.config/sway/config" <<'SWAYEOF'
# Minimal Sway config generated by installx.sh
set $mod Mod4
set $term alacritty
bindsym $mod+Return exec $term
bindsym $mod+Shift+q kill
bindsym $mod+Shift+e exec swaynag -t warning -m 'Exit sway?' -b 'Yes' 'swaymsg exit'
output * bg #222222 solid_color
SWAYEOF
		cp "${uhome}/.config/sway/config" /etc/skel/.config/sway/config
	fi
	chown -R "${VUSER}" "${uhome}/.config"
}

seed_hyprland_config() {
	uhome="/home/${VUSER}"
	mkdir -p "${uhome}/.config/hypr" /etc/skel/.config/hypr
	if [ -f /usr/local/share/hyprland/hyprland.conf ] ; then
		cp /usr/local/share/hyprland/hyprland.conf "${uhome}/.config/hypr/hyprland.conf"
	elif [ -f /usr/local/share/examples/hyprland/hyprland.conf ] ; then
		cp /usr/local/share/examples/hyprland/hyprland.conf "${uhome}/.config/hypr/hyprland.conf"
	else
		cat > "${uhome}/.config/hypr/hyprland.conf" <<'HYPREOF'
# Minimal Hyprland config generated by installx.sh
monitor=,preferred,auto,1
exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
input {
    kb_layout = us
    follow_mouse = 1
}
general {
    gaps_in = 4
    gaps_out = 8
    border_size = 2
}
bind = SUPER, Return, exec, alacritty
bind = SUPER, Q, killactive,
bind = SUPER, M, exit,
HYPREOF
	fi
	cp "${uhome}/.config/hypr/hyprland.conf" /etc/skel/.config/hypr/hyprland.conf 2>/dev/null || true
	chown -R "${VUSER}" "${uhome}/.config"
}

# Session .desktop so greeters (SDDM, etc.) list the compositor under Wayland.
ensure_wayland_session_desktop() {
	_comp="${1:-$WAYLAND_COMPOSITOR}"
	[ -z "$_comp" ] && return 0
	mkdir -p /usr/local/share/wayland-sessions
	_exec="$_comp"
	_name="$_comp"
	_desktop_names="$_comp"
	case "$_comp" in
		hyprland|Hyprland)
			_name="Hyprland"
			_desktop_names="Hyprland"
			if command -v Hyprland >/dev/null 2>&1 ; then
				_exec=Hyprland
			elif command -v hyprland >/dev/null 2>&1 ; then
				_exec=hyprland
			else
				_exec=Hyprland
			fi
			_desk="/usr/local/share/wayland-sessions/hyprland.desktop"
			;;
		sway)
			_name="Sway"
			_desktop_names="sway"
			_exec=sway
			_desk="/usr/local/share/wayland-sessions/sway.desktop"
			;;
		*)
			_desk="/usr/local/share/wayland-sessions/${_comp}.desktop"
			;;
	esac
	# Prefer package-provided session files when present
	if [ -f "$_desk" ] ; then
		echo "wayland: session file already present: $_desk" | tee -a "$LOGFILE"
		return 0
	fi
	cat > "$_desk" <<DEOF
[Desktop Entry]
Name=${_name}
Comment=${_name} Wayland compositor
Exec=${_exec}
TryExec=${_exec}
Type=Application
DesktopNames=${_desktop_names}
DEOF
	echo "wayland: wrote session file $_desk (Exec=${_exec})" | tee -a "$LOGFILE"
}

setup_ly_greeter() {
	# FreeBSD x11/ly (see pkg-message): gettytab + ttys with ly_wrapper.
	# Modern ly (>=1.3) requires ly_wrapper, not bare /usr/local/bin/ly.
	_ly_bin=""
	if [ -x /usr/local/bin/ly_wrapper ] ; then
		_ly_bin=/usr/local/bin/ly_wrapper
	elif [ -x /usr/local/bin/ly ] ; then
		# Older packages only shipped ly; still better than skipping
		_ly_bin=/usr/local/bin/ly
		echo "ly: warning: ly_wrapper missing; using $_ly_bin (upgrade x11/ly if login fails)" | tee -a "$LOGFILE"
	else
		echo "ERROR: ly package is not installed (expected /usr/local/bin/ly_wrapper)." | tee -a "$LOGFILE"
		echo "ERROR: greeter was NOT configured. Install with: pkg install -y ly" | tee -a "$LOGFILE"
		return 1
	fi

	# gettytab entry — must use ly_wrapper and al=root (official FreeBSD pkg-message)
	if grep -q '^Ly:' /etc/gettytab 2>/dev/null ; then
		# Rewrite stale entries that still point at bare ly
		if grep -A2 '^Ly:' /etc/gettytab | grep -q 'lo=/usr/local/bin/ly:' ; then
			cp /etc/gettytab /etc/gettytab.installx.bak 2>/dev/null || true
			# Remove old Ly block (name + continuation lines)
			awk '
				BEGIN { skip=0 }
				/^Ly:/ { skip=1; next }
				skip && /^[^[:space:]#]/ { skip=0 }
				skip && /^$/ { skip=0; next }
				skip { next }
				{ print }
			' /etc/gettytab > /etc/gettytab.installx.new \
				&& mv /etc/gettytab.installx.new /etc/gettytab
			echo "ly: removed obsolete gettytab Ly entry (bare ly)" | tee -a "$LOGFILE"
		fi
	fi
	if ! grep -q '^Ly:' /etc/gettytab 2>/dev/null ; then
		cat >> /etc/gettytab <<GETTYEOF

# installx.sh — ly greeter (x11/ly FreeBSD pkg-message)
Ly:\\
	:lo=${_ly_bin}:\\
	:al=root:
GETTYEOF
		echo "ly: added Ly entry to /etc/gettytab (lo=${_ly_bin})" | tee -a "$LOGFILE"
	else
		echo "ly: /etc/gettytab already has Ly: entry" | tee -a "$LOGFILE"
	fi

	# Bind getty on ttyv1 to the Ly class (FreeBSD VTs: ttyv0, ttyv1, …)
	if [ -f /etc/ttys ] && grep -q '^ttyv1' /etc/ttys ; then
		cp /etc/ttys /etc/ttys.installx.bak 2>/dev/null || true
		# shellcheck disable=SC2016
		sed -i '' -e 's|^ttyv1.*|ttyv1	"/usr/libexec/getty Ly"	xterm	on  secure|' /etc/ttys
		echo "ly: configured ttyv1 → getty Ly (backup: /etc/ttys.installx.bak)" | tee -a "$LOGFILE"
		# Re-read ttys without full reboot when possible
		kill -HUP 1 2>/dev/null || true
	else
		echo "ERROR: /etc/ttys missing ttyv1; could not enable ly greeter" | tee -a "$LOGFILE"
		return 1
	fi

	# config.ini — install from sample and set tty for ttyv1
	# FreeBSD: ttyv0=0, ttyv1=1 in some docs; ly's FreeBSD notes use ttyv1
	# and often need tty=2 in config (1-based Linux-style). Prefer sample + tty=2.
	_ly_confdir=/usr/local/etc/ly
	_ly_conf="${_ly_confdir}/config.ini"
	mkdir -p "$_ly_confdir"
	if [ ! -f "$_ly_conf" ] ; then
		if [ -f "${_ly_confdir}/config.ini.sample" ] ; then
			cp "${_ly_confdir}/config.ini.sample" "$_ly_conf"
			echo "ly: installed config.ini from sample" | tee -a "$LOGFILE"
		else
			# Minimal config if sample is missing
			cat > "$_ly_conf" <<'LYCONF'
# installx.sh minimal ly config
tty = 2
animation = none
LYCONF
			echo "ly: wrote minimal config.ini (no sample found)" | tee -a "$LOGFILE"
		fi
	fi
	# Ensure tty points at the VT used by getty Ly (ttyv1 → ly tty 2)
	if grep -qE '^[[:space:]]*#?[[:space:]]*tty[[:space:]]*=' "$_ly_conf" 2>/dev/null ; then
		sed -i '' -E 's/^[[:space:]]*#?[[:space:]]*tty[[:space:]]*=.*/tty = 2/' "$_ly_conf"
	else
		echo "tty = 2" >> "$_ly_conf"
	fi
	echo "ly: config.ini tty=2 (matches ttyv1 getty)" | tee -a "$LOGFILE"

	# Session .desktop so Hyprland/Sway appear in ly's list
	ensure_wayland_session_desktop "${WAYLAND_COMPOSITOR}"

	echo "ly: greeter ready — after reboot use ttyv1 (Alt+F2). Log in and pick the Wayland session." | tee -a "$LOGFILE"
	return 0
}

write_wayland_start_helper() {
	uhome="/home/${VUSER}"
	comp="${1:-$WAYLAND_COMPOSITOR}"
	desktop_name="$comp"
	# FreeBSD hyprland package ships the binary as Hyprland (capital H)
	case "$comp" in
		hyprland|Hyprland)
			desktop_name=Hyprland
			if command -v Hyprland >/dev/null 2>&1 ; then
				comp=Hyprland
			elif command -v hyprland >/dev/null 2>&1 ; then
				comp=hyprland
			else
				comp=Hyprland
			fi
			;;
		sway)
			desktop_name=sway
			comp=sway
			;;
	esac
	# Handbook-style launcher: XDG_RUNTIME_DIR + seatd + dbus session
	cat > "${uhome}/start-desktop.sh" <<EOF
#!/bin/sh
# Generated by installx.sh — start ${desktop_name} on FreeBSD Wayland
# Usage (as your normal user, on a text console):  ~/start-desktop.sh

set -e

if [ "\$(id -u)" -eq 0 ] ; then
	echo "error: do not start the compositor as root; log in as a normal user" >&2
	exit 1
fi

# Runtime directory (required by Wayland; FreeBSD 14.1+ often sets this already)
if [ -z "\${XDG_RUNTIME_DIR:-}" ] ; then
	export XDG_RUNTIME_DIR=/var/run/user/\$(id -u)
fi
if [ ! -d "\$XDG_RUNTIME_DIR" ] ; then
	if mkdir -p "\$XDG_RUNTIME_DIR" 2>/dev/null ; then
		chmod 700 "\$XDG_RUNTIME_DIR"
	else
		export XDG_RUNTIME_DIR=/tmp/xdg-runtime-\$(id -u)
		mkdir -p "\$XDG_RUNTIME_DIR"
		chmod 700 "\$XDG_RUNTIME_DIR"
	fi
fi

export XDG_SESSION_TYPE=wayland
export XDG_CURRENT_DESKTOP=${desktop_name}

# seatd must be running (sysrc seatd_enable=YES; service seatd start)
if ! pgrep -qx seatd 2>/dev/null && ! pgrep -q seatd 2>/dev/null ; then
	echo "error: seatd is not running." >&2
	echo "  As root:  sysrc seatd_enable=YES && service seatd start" >&2
	exit 1
fi

if ! command -v ${comp} >/dev/null 2>&1 ; then
	echo "error: ${comp} not found in PATH" >&2
	exit 1
fi

echo "starting ${comp} (WAYLAND / seatd)…"
if command -v dbus-run-session >/dev/null 2>&1 ; then
	exec dbus-run-session -- ${comp}
fi
exec ${comp}
EOF
	chmod +x "${uhome}/start-desktop.sh"
	chown "${VUSER}" "${uhome}/start-desktop.sh"
	# skel for new users
	mkdir -p /etc/skel
	cp "${uhome}/start-desktop.sh" /etc/skel/start-desktop.sh
	chmod +x /etc/skel/start-desktop.sh
	echo "wayland: wrote ${uhome}/start-desktop.sh → ${comp}" | tee -a "$LOGFILE"
}

apply_display_manager() {
	case "$DISPLAY_MGR" in
		sddm|slim|gdm)
			sysrc "${DISPLAY_MGR}_enable"="YES"
			echo "display manager enabled: $DISPLAY_MGR" | tee -a "$LOGFILE"
			;;
		ly)
			# getty integration happens post-pkg in setup_ly_greeter
			echo "display manager: ly (configured after package install)" | tee -a "$LOGFILE"
			;;
		none|"")
			echo "display manager: none (start session manually)" | tee -a "$LOGFILE"
			;;
		*)
			echo "unknown DISPLAY_MGR=$DISPLAY_MGR" | tee -a "$LOGFILE"
			;;
	esac
}

# ---------------------------------------------------------------------------
# Package catalog helpers (needed before package-branch decision)
# ---------------------------------------------------------------------------

pkgs_find_missing() {
	MISSING_PKGS=""
	for _pn in "$@" ; do
		[ -z "$_pn" ] && continue
		if ! pkg_is_available "$_pn" ; then
			MISSING_PKGS="${MISSING_PKGS} ${_pn}"
		fi
	done
	MISSING_PKGS=$(echo "$MISSING_PKGS" | sed 's/^ *//')
	[ -z "$MISSING_PKGS" ]
}

# Echo only packages that exist in the catalog on stdout; log skips to log/stderr only
pkgs_filter_available() {
	_kept=""
	_drop=""
	for _pn in "$@" ; do
		[ -z "$_pn" ] && continue
		if pkg_is_available "$_pn" ; then
			_kept="${_kept} ${_pn}"
		else
			_drop="${_drop} ${_pn}"
			echo "pkg: not in catalog, removing from selection: ${_pn}" >> "$LOGFILE"
			echo "pkg: not in catalog, removing from selection: ${_pn}" >&2
		fi
	done
	if [ -n "$_drop" ] ; then
		echo "pkg: removed unavailable packages:${_drop}" >> "$LOGFILE"
		echo "pkg: removed unavailable packages:${_drop}" >&2
	fi
	# stdout = clean package list only (safe for command substitution)
	echo "$_kept" | sed 's/^ *//'
}

# Resolve KDE/Plasma package set for this ABI/catalog (15.x quarterly may lack x11/kde)

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
      if [ -z "$DESKTOP_PKGS" ] ; then
          echo "FATAL: KDE/Plasma packages not available in the current pkg catalog." | tee -a "$LOGFILE"
          echo "FATAL: need one of: kde, plasma6-plasma, or plasma6-plasma-desktop (+ components)." | tee -a "$LOGFILE"
          exit 1
      fi
      echo "kde: using packages: $DESKTOP_PKGS" | tee -a "$LOGFILE"
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

# User account next (needed for .xinitrc / home config) — after a viable desktop is chosen
# this will help with performance of desktop applications
adjust_sysctl_buffers
report "add sync buffers" "$?"

add_user_to_video
if [ -n "$XINIT_CMD" ] ; then
	gen_xinit "$XINIT_CMD"
fi

# The following are generally needed by most modern desktops
sysrc dbus_enable="YES"
report "DBus Enabled" "$?"
grep "proc /proc procfs" /etc/fstab || echo "proc /proc procfs rw 0 0" >> /etc/fstab

# A number of the more lightweight desktops don't include everything you need
# and anyone coming from linux probably wants bash, sudo & vim. Let's make
# the transition easy for them
if is_noninteractive ; then
	# Keep the default extras small for CI; override with INSTALLX_EXTRA_PKGS
	extra_pkgs="${INSTALLX_EXTRA_PKGS-bash sudo}"
	extra_pkgs=$(pkgs_filter_available $extra_pkgs)
	echo "noninteractive: extra_pkgs=$extra_pkgs" | tee -a "$LOGFILE"
else
	# Only offer extras that exist in the catalog
	_extra_cmd='dialog --checklist "Select additional packages to install:\n(Unavailable packages already removed.)" 0 0 0'
	_extra_skipped=""
	for _line in \
		"firefox|Firefox Web browser|on" \
		"bash|GNU Bourne-Again SHell|on" \
		"vim|VI Improved|on" \
		"git-lite|Lightweight Git client|on" \
		"sudo|Superuser do|on" \
		"thunderbird|Thunderbird Email Client|off" \
		"obs-studio|OBS-Studio recording/casting|off" \
		"audacity|Audio editor|off" \
		"simplescreenrecorder|Does it need a description?|off" \
		"libreoffice|Open source office suite|off" \
		"vlc|Video player|off" \
		"doas|Simpler alternative to sudo|off" \
		"linux_base-c7|CentOS v7 linux binary compatiblity layer|off" \
		"virtualbox-ose-additions|VirtualBox guest additions|off"
	do
		_en=$(echo "$_line" | cut -d'|' -f1)
		_ed=$(echo "$_line" | cut -d'|' -f2)
		_eo=$(echo "$_line" | cut -d'|' -f3)
		if pkg_is_available "$_en" ; then
			_extra_cmd="$_extra_cmd \"$_en\" \"$_ed\" $_eo"
		else
			_extra_skipped="${_extra_skipped} ${_en}"
			echo "pkg: extra package not in catalog, removed from menu: ${_en}" | tee -a "$LOGFILE"
		fi
	done
	if [ -n "$_extra_skipped" ] ; then
		echo "pkg: extras removed from selection:${_extra_skipped}" | tee -a "$LOGFILE"
	fi
	_extra_cmd="$_extra_cmd --stdout"
	extra_pkgs=$(eval "$_extra_cmd") || extra_pkgs=""
	extra_pkgs=$(echo "$extra_pkgs" | tr -d '"')
fi

echo "Extra packages:" "$extra_pkgs" | tee -a "$LOGFILE"


# by default install the full xorg, but if xorg_minimal is set, override it

echo "$extra_pkgs" | grep -q linux_base-c7 && linuxBaseC7
echo "$extra_pkgs" | grep -q virtualbox-ose-additions && enable_virtualbox_ose_additions

# ---------------------------------------------------------------------------
# Graphics drivers (FreeBSD handbook §X11 / graphics drivers)
#
# Flow: detect GPUs via pciconf → pre-check checklist (or auto in CI) →
# install packages + enable klds. drm-kmod is a metaport (versioned per
# FreeBSD major). NVIDIA default is nvidia-drm-kmod; legacy branches
# (470/390/340) remain available for older cards.
# ---------------------------------------------------------------------------
vc_pkgs=""
vc_post_nvidia_xconfig=0
vc_selected=""
DETECTED_GPUS=""
DETECTED_HINT=""

graphics_append_pkg() {
	for _p in "$@" ; do
		case " ${vc_pkgs} " in
			*" ${_p} "*) ;;
			*) vc_pkgs="${vc_pkgs} ${_p}" ;;
		esac
	done
	vc_pkgs=$(echo "$vc_pkgs" | sed 's/^ *//')
}

graphics_enable_kld() {
	sysrc kld_list+="$1"
	echo "graphics: kld_list+=$1" | tee -a "$LOGFILE"
}

graphics_loader_conf() {
	_line="$1"
	_key=$(echo "$_line" | cut -d= -f1)
	if [ -n "$_key" ] && ! grep -q "^${_key}=" /boot/loader.conf 2>/dev/null ; then
		echo "$_line" >> /boot/loader.conf
		echo "graphics: loader.conf += $_line" | tee -a "$LOGFILE"
	fi
}

graphics_checklist_state() {
	# echo "on" if $1 is in DETECTED_GPUS, else "off"
	case " ${DETECTED_GPUS} " in
		*" $1 "*) echo on ;;
		*) echo off ;;
	esac
}

# Probe pciconf for display-class devices and map PCI vendors → driver keys.
# Sets DETECTED_GPUS (space-separated) and DETECTED_HINT (human summary).
graphics_detect() {
	DETECTED_GPUS=""
	DETECTED_HINT=""
	_pci_raw=$(pciconf -lv 2>/dev/null || true)
	_found=""

	# Device header lines look like:
	#   vgapci0@pci0:0:2:0:  class=0x030000 ... vendor=0x8086 device=0x46a6 ...
	# class 0x03xxxx = display
	_found=$(echo "$_pci_raw" | awk '
		/^[a-zA-Z0-9]+@pci/ && /class=0x03/ {
			if ($0 ~ /vendor=0x8086/) print "i915kms"
			else if ($0 ~ /vendor=0x1002/) print "amdgpu"
			else if ($0 ~ /vendor=0x10de/) print "nvidia"
			else if ($0 ~ /vendor=0x15ad/) print "vmwgfx"
			else if ($0 ~ /vendor=0x80ee/) print "vbox"
			else if ($0 ~ /vendor=0x1234/ || $0 ~ /vendor=0x1af4/ || $0 ~ /vendor=0x1b36/) print "virtio"
			else print "unknown"
		}
	')

	# Also match "class = display" style blocks if header lacked class=0x03
	if [ -z "$_found" ] ; then
		_found=$(echo "$_pci_raw" | awk '
			BEGIN { RS=""; ORS="\n" }
			/class[[:space:]]*=[[:space:]]*display/ || /VGA compatible/ {
				if ($0 ~ /vendor=0x8086/ || $0 ~ /Intel/) print "i915kms"
				else if ($0 ~ /vendor=0x1002/ || $0 ~ /AMD/ || $0 ~ /ATI/) print "amdgpu"
				else if ($0 ~ /vendor=0x10de/ || $0 ~ /NVIDIA/) print "nvidia"
				else if ($0 ~ /vendor=0x15ad/ || $0 ~ /VMware/) print "vmwgfx"
				else print "unknown"
			}
		')
	fi

	for _g in $_found ; do
		case "$_g" in
			i915kms|amdgpu|nvidia|vmwgfx)
				case " ${DETECTED_GPUS} " in
					*" ${_g} "*) ;;
					*) DETECTED_GPUS="${DETECTED_GPUS} ${_g}" ;;
				esac
				;;
			vbox|virtio)
				# Prefer console framebuffer for common hypervisors unless user overrides
				_fb=scfb
				if command -v sysctl >/dev/null 2>&1 ; then
					_boot=$(sysctl -n machdep.bootmethod 2>/dev/null || true)
					case "$_boot" in
						BIOS|bios) _fb=vesa ;;
					esac
				fi
				case " ${DETECTED_GPUS} " in
					*" ${_fb} "*) ;;
					*) DETECTED_GPUS="${DETECTED_GPUS} ${_fb}" ;;
				esac
				;;
			unknown)
				;;
		esac
	done
	DETECTED_GPUS=$(echo "$DETECTED_GPUS" | sed 's/^ *//')

	# No known vendor: fall back by firmware boot method (handbook SCFB vs VESA)
	if [ -z "$DETECTED_GPUS" ] ; then
		_boot=$(sysctl -n machdep.bootmethod 2>/dev/null || echo unknown)
		case "$_boot" in
			UEFI|uefi) DETECTED_GPUS="scfb" ;;
			BIOS|bios) DETECTED_GPUS="vesa" ;;
			*) DETECTED_GPUS="" ;;
		esac
		echo "graphics: no PCI vendor match; bootmethod=${_boot} → suggest [${DETECTED_GPUS}]" | tee -a "$LOGFILE"
	fi

	DETECTED_HINT=$(echo "$_pci_raw" | grep -E "vendor=0x|device=|class=0x03|class[[:space:]]*=[[:space:]]*display" | head -n 12 | tr '\n' ' ')
	[ -z "$DETECTED_HINT" ] && DETECTED_HINT="(no display PCI devices found)"
	echo "graphics: detected drivers [${DETECTED_GPUS}]" | tee -a "$LOGFILE"
	echo "graphics: pciconf hint: ${DETECTED_HINT}" | tee -a "$LOGFILE"
}

# Apply one GPU selection (handbook-aligned)
graphics_select() {
	_gpu="$1"
	case "$_gpu" in
		i915kms)
			graphics_append_pkg drm-kmod
			graphics_enable_kld i915kms
			;;
		amdgpu)
			# Modern AMD — modesetting usually enough; skip vendor DDX by default
			graphics_append_pkg drm-kmod
			graphics_enable_kld amdgpu
			;;
		radeonkms)
			graphics_append_pkg drm-kmod
			graphics_enable_kld radeonkms
			;;
		nvidia)
			# Current handbook default (KMS / PRIME / Wayland)
			graphics_append_pkg nvidia-drm-kmod
			if [ "$NEED_XORG" = "yes" ] ; then
				graphics_append_pkg nvidia-settings nvidia-xconfig
				vc_post_nvidia_xconfig=1
			fi
			graphics_enable_kld nvidia-drm
			graphics_loader_conf 'hw.nvidiadrm.modeset="1"'
			;;
		nvidia_modeset)
			graphics_append_pkg nvidia-driver
			if [ "$NEED_XORG" = "yes" ] ; then
				graphics_append_pkg nvidia-settings nvidia-xconfig
				vc_post_nvidia_xconfig=1
			fi
			graphics_enable_kld nvidia-modeset
			;;
		nvidia470|nvidia_470)
			# Legacy branch for older cards (handbook table)
			graphics_append_pkg nvidia-driver-470
			if [ "$NEED_XORG" = "yes" ] ; then
				graphics_append_pkg nvidia-xconfig
				vc_post_nvidia_xconfig=1
			fi
			graphics_enable_kld nvidia-modeset
			;;
		nvidia390|nvidia_390)
			graphics_append_pkg nvidia-driver-390
			if [ "$NEED_XORG" = "yes" ] ; then
				graphics_append_pkg nvidia-xconfig
				vc_post_nvidia_xconfig=1
			fi
			graphics_enable_kld nvidia-modeset
			;;
		nvidia340|nvidia_340)
			# Pre-390: load nvidia (not modeset); needs legacy console/X in some cases
			graphics_append_pkg nvidia-driver-340
			if [ "$NEED_XORG" = "yes" ] ; then
				graphics_append_pkg nvidia-xconfig
				vc_post_nvidia_xconfig=1
			fi
			graphics_enable_kld nvidia
			;;
		vesa)
			if [ "$NEED_XORG" = "yes" ] ; then
				graphics_append_pkg xf86-video-vesa
			else
				echo "graphics: vesa skipped (X11-only; session is Wayland)" | tee -a "$LOGFILE"
			fi
			;;
		scfb)
			if [ "$NEED_XORG" = "yes" ] ; then
				graphics_append_pkg xf86-video-scfb
			else
				echo "graphics: scfb X11 driver skipped (Wayland); console scfb still available" | tee -a "$LOGFILE"
			fi
			;;
		vmwgfx)
			if [ "$NEED_XORG" = "yes" ] ; then
				graphics_append_pkg xf86-video-vmware
			fi
			graphics_enable_kld vmwgfx
			;;
		other|"")
			;;
		*)
			echo "graphics: unknown selection '$_gpu' (ignored)" | tee -a "$LOGFILE"
			;;
	esac
}

# Warn if multiple conflicting NVIDIA stacks were chosen
graphics_warn_nvidia_conflict() {
	_n=0
	for _t in nvidia nvidia_modeset nvidia470 nvidia_470 nvidia390 nvidia_390 nvidia340 nvidia_340 ; do
		case " ${vc_selected} " in
			*" ${_t} "*) _n=$((_n + 1)) ;;
		esac
	done
	if [ "$_n" -gt 1 ] ; then
		echo "graphics: WARNING: multiple NVIDIA stacks selected (${vc_selected}); pick one family" | tee -a "$LOGFILE"
	fi
}

if is_noninteractive ; then
	case "${INSTALLX_GRAPHICS:-no}" in
		[Yy][Ee][Ss]|1|true|TRUE|auto|AUTO) install_dv_drivers=0 ;;
		*) install_dv_drivers=1 ;;
	esac
else
	dialog --title "Graphics Drivers" --yesno "Would you like to try to install the drivers for your video card?\n\nThe next screen pre-selects drivers from pciconf (you can change them).\nSee: https://www.freebsd.org/doc/handbook/x-config.html" 0 0
	install_dv_drivers=$?
fi

if [ "$install_dv_drivers" -eq 0  ] ; then 

	graphics_detect

	if is_noninteractive ; then
		card="${INSTALLX_VIDEO_CARD:-}"
		case "$card" in
			""|auto|AUTO)
				card="$DETECTED_GPUS"
				echo "noninteractive: auto GPU selection → [$card]" | tee -a "$LOGFILE"
				;;
		esac
	else
		# Pre-check detected drivers; user can still change multi-select
		_def_i915=$(graphics_checklist_state i915kms)
		_def_amd=$(graphics_checklist_state amdgpu)
		_def_radeon=off
		_def_nvidia=$(graphics_checklist_state nvidia)
		_def_vmw=$(graphics_checklist_state vmwgfx)
		_def_scfb=$(graphics_checklist_state scfb)
		_def_vesa=$(graphics_checklist_state vesa)
		# radeonkms never auto-on (AMD defaults to amdgpu); user may enable for pre-HD7000

		card=$(dialog --checklist "GPU drivers (detected: ${DETECTED_GPUS:-none}). Multi-select OK for hybrid/PRIME.\n${DETECTED_HINT}" 0 0 0 \
		i915kms "Intel (drm-kmod → i915kms)" "${_def_i915}" \
		amdgpu "AMD modern (drm-kmod → amdgpu)" "${_def_amd}" \
		radeonkms "AMD legacy pre-HD7000 (drm-kmod → radeonkms)" "${_def_radeon}" \
		nvidia "NVIDIA current (nvidia-drm-kmod, KMS/Wayland)" "${_def_nvidia}" \
		nvidia_modeset "NVIDIA latest modeset-only (no drm)" off \
		nvidia470 "NVIDIA legacy 470.xx branch" off \
		nvidia390 "NVIDIA legacy 390.xx branch" off \
		nvidia340 "NVIDIA legacy 340.xx branch" off \
		scfb "UEFI framebuffer (X11)" "${_def_scfb}" \
		vesa "VESA BIOS fallback (X11)" "${_def_vesa}" \
		vmwgfx "VMware SVGA" "${_def_vmw}" \
		other "None of the above / show pciconf only" off \
		--stdout)
	fi

	card=$(echo "$card" | tr -d '"' | tr ',' ' ')
	vc_selected="$card"
	echo "graphics: selected [$card] session=$SESSION_TYPE FreeBSD=$(uname -r)" | tee -a "$LOGFILE"
	graphics_warn_nvidia_conflict

	_any=0
	for _gpu in $card ; do
		[ -z "$_gpu" ] && continue
		if [ "$_gpu" = "other" ] ; then
			_any=1
			continue
		fi
		graphics_select "$_gpu"
		_any=1
	done

	if [ "$_any" -eq 0 ] || echo " $card " | grep -q " other " ; then
		pciconf_out=$(pciconf -lv 2>/dev/null | grep -B3 display)
		echo "graphics: pciconf display devices:" | tee -a "$LOGFILE"
		echo "$pciconf_out" | tee -a "$LOGFILE"
		if ! is_noninteractive ; then
			dialog --msgbox "No specific driver applied (or 'other' selected).\n\nDetected: ${DETECTED_GPUS:-none}\n\npciconf:\n${pciconf_out}\n\nSee the FreeBSD handbook graphics drivers section." 0 0
		fi
	fi

	if command -v fwget >/dev/null 2>&1 ; then
		echo "graphics: running fwget to fetch device firmware (if any)" | tee -a "$LOGFILE"
		fwget 2>/dev/null || true
	fi

	echo "graphics: packages pending:${vc_pkgs:- (none)}" | tee -a "$LOGFILE"
fi

# ---------------------------------------------------------------------------
# Audio: load drivers, probe /dev/sndstat, show devices, optional default unit
# (probe-and-show — does not auto-pick a default without user/env choice)
# ---------------------------------------------------------------------------
audio_pkgs=""
SNDSTAT_TEXT=""
SND_DEFAULT_UNIT=""

audio_loader_conf() {
	_line="$1"
	_key=$(echo "$_line" | cut -d= -f1)
	if [ -n "$_key" ] && ! grep -q "^${_key}=" /boot/loader.conf 2>/dev/null ; then
		echo "$_line" >> /boot/loader.conf
		echo "audio: loader.conf += $_line" | tee -a "$LOGFILE"
	fi
}

audio_load_drivers() {
	# Meta-driver loads common sound modules (Foundation quick guide)
	audio_loader_conf 'snd_driver_load="YES"'
	# Also try to load now so probe works before reboot
	if command -v kldload >/dev/null 2>&1 ; then
		kldstat -q -n snd_driver 2>/dev/null || kldload snd_driver 2>/dev/null || true
		kldstat -q -n snd_hda 2>/dev/null || kldload snd_hda 2>/dev/null || true
	fi
	# Brief settle time for pcm* attach
	_i=0
	while [ "$_i" -lt 5 ] ; do
		if [ -r /dev/sndstat ] && grep -q 'pcm[0-9]' /dev/sndstat 2>/dev/null ; then
			break
		fi
		_i=$((_i + 1))
		sleep 1
	done
}

audio_probe_sndstat() {
	if [ -r /dev/sndstat ] ; then
		SNDSTAT_TEXT=$(cat /dev/sndstat 2>/dev/null)
	else
		SNDSTAT_TEXT="(no /dev/sndstat — sound modules may need a reboot after install)"
	fi
	echo "audio: /dev/sndstat:" | tee -a "$LOGFILE"
	echo "$SNDSTAT_TEXT" | tee -a "$LOGFILE"
}

# Build dialog menu items from pcm lines: unit + description
audio_pcm_menu_args() {
	# prints pairs: unit "description" for dialog --menu
	echo "$SNDSTAT_TEXT" | awk '
		/^pcm[0-9]+:/ {
			unit=$1
			sub(/^pcm/, "", unit)
			sub(/:.*/, "", unit)
			desc=$0
			sub(/^pcm[0-9]+:[[:space:]]*/, "", desc)
			gsub(/"/, "'\''", desc)
			if (length(desc) > 60) desc=substr(desc,1,57) "..."
			print unit
			print desc
		}
	'
}

audio_set_default_unit() {
	_u="$1"
	case "$_u" in
		""|skip|none|leave) return 0 ;;
	esac
	if ! echo "$_u" | grep -Eq '^[0-9]+$' ; then
		echo "audio: invalid default unit '$_u' (ignored)" | tee -a "$LOGFILE"
		return 1
	fi
	sysctl hw.snd.default_unit="$_u" 2>/dev/null || true
	if grep -q '^hw\.snd\.default_unit=' /etc/sysctl.conf 2>/dev/null ; then
		sed -i '' -e "s/^hw\\.snd\\.default_unit=.*/hw.snd.default_unit=${_u}/" /etc/sysctl.conf
	else
		echo "hw.snd.default_unit=${_u}" >> /etc/sysctl.conf
	fi
	echo "audio: hw.snd.default_unit=${_u} (sysctl + /etc/sysctl.conf)" | tee -a "$LOGFILE"
	SND_DEFAULT_UNIT="$_u"
}

if is_noninteractive ; then
	case "${INSTALLX_AUDIO:-yes}" in
		[Nn][Oo]|0|false|FALSE) install_audio=1 ;;
		*) install_audio=0 ;;
	esac
else
	dialog --title "Audio" --yesno "Set up sound drivers and show detected audio devices?\n\n(Loads snd_driver, probes /dev/sndstat, lets you pick a default pcm unit — no automatic guess.)" 0 0
	install_audio=$?
fi

if [ "$install_audio" -eq 0 ] ; then
	audio_load_drivers
	audio_probe_sndstat

	if is_noninteractive ; then
		# Log probe only; set default unit only if explicitly provided
		if [ -n "${INSTALLX_SND_DEFAULT_UNIT:-}" ] ; then
			audio_set_default_unit "$INSTALLX_SND_DEFAULT_UNIT"
		else
			echo "audio: noninteractive probe complete; default unit left unchanged (set INSTALLX_SND_DEFAULT_UNIT to override)" | tee -a "$LOGFILE"
		fi
		case "${INSTALLX_AUDIO_PKGS:-yes}" in
			[Nn][Oo]|0|false|FALSE) ;;
			*) audio_pkgs="pulseaudio sndio pavucontrol" ;;
		esac
	else
		dialog --title "Audio devices (/dev/sndstat)" --msgbox "Detected sound devices:\n\n${SNDSTAT_TEXT}\n\nNext you may choose a default output unit, or leave the system default." 0 0

		_menu_args=$(audio_pcm_menu_args)
		if [ -n "$_menu_args" ] ; then
			# shellcheck disable=SC2086
			_choice=$(dialog --clear --title "Default audio device" \
				--menu "Select hw.snd.default_unit (or leave unchanged).\nHDMI/DP devices are often listed before analog speakers." 0 0 0 \
				leave "Leave current default unchanged" \
				$_menu_args \
				--stdout) || _choice="leave"
			if [ "$_choice" != "leave" ] && [ -n "$_choice" ] ; then
				audio_set_default_unit "$_choice"
			else
				echo "audio: left hw.snd.default_unit unchanged" | tee -a "$LOGFILE"
			fi
		else
			dialog --title "Audio" --msgbox "No pcm devices found in /dev/sndstat yet.\n\n${SNDSTAT_TEXT}\n\nsnd_driver is set to load at boot; re-check after reboot with: cat /dev/sndstat" 0 0
		fi

		dialog --title "Audio packages" --yesno "Install common desktop audio packages?\n\n• pulseaudio — widely used by desktop apps\n• sndio — used by many FreeBSD ports (e.g. browsers)\n• pavucontrol — volume / device UI" 0 0
		if [ $? -eq 0 ] ; then
			audio_pkgs="pulseaudio sndio pavucontrol"
		fi
	fi

	# Enable sndiod when sndio is requested
	case " $audio_pkgs " in
		*" sndio "*) sysrc sndiod_enable="YES" 2>/dev/null || true ;;
	esac

	echo "audio: packages pending:${audio_pkgs:- (none)}" | tee -a "$LOGFILE"
	report "audio setup" 0
fi

# This is opt activities — must run before package list is finalized
if is_noninteractive ; then
	# Defaults chosen so existing shunit2 checks (fuse, ipfw, minimal footprint) pass in CI
	opt_activities="${INSTALLX_OPT:-load_card_readers load_atapi load_fuse enable_tmpfs enable_async_io enable_workstation_pwr_mgmnt enable_ipfw_firewall minimal_xorg}"
	echo "noninteractive: opt_activities=$opt_activities" | tee -a "$LOGFILE"
else
	opt_activities=$(dialog --checklist "Select additional options" 0 0 0 \
		load_card_readers "enable card readers like sd cards" on \
		load_atapi "enable atapi to enable external storage devices like cds" on \
		load_fuse "enable userspace fileystems" on \
		load_coretemp "enable cpu temp sensors for intel (and amd)" off \
		load_amdtemp "enable additional amd temp sensors" off \
		enable_tmpfs "enable in-mem tempfs" on \
		enable_cups "printing" off \
		enable_webcam "enables webcams to be used" off \
		enable_ipfw_firewall "enables workstation firewall profile + allow ssh" off \
		enable_async_io "enable async io for better perf" on \
		enable_workstation_pwr_mgmnt "change pwr on battery/plugged in" on \
		load_bluetooth "enable bluetooth kernel modules" off \
		minimal_xorg "only install minimal xorg packages" off \
		--stdout )
fi

#
# this comment is just to draw attention to
# the fact that this line is doing the package installs
# and making it easy to find by having a big comment block
# above it
#
xorg_minimal="xorg-minimal xauth xorg-libraries xorg-fonts xorg-fonts-truetype xf86-input-keyboard xf86-input-libinput xf86-input-mouse"
xorg_pkgs="xorg"
# Wayland stack: compositor packages come from DESKTOP_PKGS; this is shared plumbing
wayland_base_pkgs="wayland seatd xwayland"

echo "$opt_activities" | grep -q load_card_readers && load_card_readers
echo "$opt_activities" | grep -q load_atapi && load_atapi
echo "$opt_activities" | grep -q load_fuse && load_fuse
echo "$opt_activities" | grep -q load_coretemp && load_coretemp
echo "$opt_activities" | grep -q load_amdtemp && load_amdtemp
echo "$opt_activities" | grep -q load_bluetooth && load_bluetooth
echo "$opt_activities" | grep -q enable_ipfw_firewall && enable_ipfw_firewall
echo "$opt_activities" | grep -q enable_tmpfs && enable_tmpfs
echo "$opt_activities" | grep -q enable_async_io && enable_async_io
echo "$opt_activities" | grep -q enable_workstation_pwr_mgmnt && enable_workstation_pwr_mgmnt
echo "$opt_activities" | grep -q enable_cups && enable_cups
echo "$opt_activities" | grep -q enable_webcam && enable_webcam

# Display stack: full/minimal Xorg for X11 sessions; wayland+seatd+xwayland for compositors
if [ "$NEED_XORG" = "yes" ] ; then
	echo "$opt_activities" | grep -q minimal_xorg && xorg_pkgs=$xorg_minimal
	display_stack="$xorg_pkgs"
else
	display_stack="$wayland_base_pkgs"
	echo "session is Wayland; using: $display_stack" | tee -a "$LOGFILE"
fi

# Display manager package (empty if none)
dm_pkgs=""
case "$DISPLAY_MGR" in
	sddm|slim|gdm|ly) dm_pkgs="$DISPLAY_MGR" ;;
esac

# Final package list for install — drop anything still missing from the catalog
all_pkgs="$display_stack dbus $DESKTOP_PKGS $extra_pkgs $vc_pkgs $dm_pkgs $slim_extra_pkgs $audio_pkgs"
all_pkgs=$(echo "$all_pkgs" | tr -s ' ')

# Required set: desktop package set + display stack + DM + dbus (no double-count)
_required_final="$DESKTOP_PKGS $display_stack $dm_pkgs dbus"
_required_final=$(echo "$_required_final" | tr -s ' ')
if ! pkgs_find_missing $_required_final ; then
	echo "FATAL: required packages missing from catalog before install: $MISSING_PKGS" | tee -a "$LOGFILE"
	echo "FATAL: desktop=$desktop_key all_pkgs would have been: $all_pkgs" | tee -a "$LOGFILE"
	if ! is_noninteractive ; then
		dialog --msgbox "Cannot install: required packages are not in the catalog:\n\n${MISSING_PKGS}\n\nThe corresponding desktop or feature cannot be used. See installx.log." 0 0
	fi
	exit 1
fi

# Optional packages (extras, audio helpers, video DDX, etc.): drop missing rather than fail
all_pkgs=$(pkgs_filter_available $all_pkgs)
if [ -z "$all_pkgs" ] ; then
	echo "FATAL: package list empty after catalog filter" | tee -a "$LOGFILE"
	exit 1
fi
echo "pkg: final install set: $all_pkgs" | tee -a "$LOGFILE"

# Graphics driver packages in vc_pkgs that vanished: already filtered from all_pkgs;
# if a whole GPU selection had only invalid names, user already saw probe/show path.

# check to see if we should set the user shell to bash
# (moved after all_pkgs is known; previously referenced all_pkgs before it was set)
if ( echo "$all_pkgs" | grep -q "bash" ) ; then
	if is_noninteractive ; then
		case "${INSTALLX_BASH_SHELL:-yes}" in
			[Nn][Oo]|0|false|FALSE) bash_yes=1 ;;
			*) bash_yes=0 ;;
		esac
	else
		dialog --title "Bash" --yesno "Would you like to set the $VUSER user's default shell to bash?" --stdout 0 0
		bash_yes=$?
	fi
fi

# check to see if we should allow %wheel to sudo
if ( echo "$all_pkgs" | grep -q "sudo" ) ; then
	if is_noninteractive ; then
		case "${INSTALLX_SUDO_WHEEL:-yes}" in
			[Nn][Oo]|0|false|FALSE) sudo_yes=1 ;;
			*) sudo_yes=0 ;;
		esac
	else
		dialog --title "sudo" --yesno "Would you like to make sudo act like the default behavior on linux?\n(wheel group can sudo)" --stdout 0 0
		sudo_yes=$?
	fi
fi

echo "pkg install -y $all_pkgs" | tee -a "$LOGFILE"
if ! is_noninteractive && [ -n "${DIALOG_BIN:-}" ] ; then
	_pkg_rcfile=$(mktemp /tmp/installx-pkgin.XXXXXX) || _pkg_rcfile="/tmp/installx-pkgin.$$"
	(
		env ASSUME_ALWAYS_YES=yes pkg install -y $all_pkgs 2>&1
		echo $? > "${_pkg_rcfile}"
	) | tee -a "$LOGFILE" | "$DIALOG_BIN" --title "Installing packages" --programbox 20 75
	if [ -f "${_pkg_rcfile}" ] ; then
		pkg_status=$(cat "${_pkg_rcfile}")
		rm -f "${_pkg_rcfile}"
	else
		pkg_status=1
	fi
else
	if ! is_noninteractive ; then
		echo "installx: installing packages (Ctrl+C aborts)…" | tee -a "$LOGFILE"
	fi
	installx_run_interruptible sh -c "env ASSUME_ALWAYS_YES=yes pkg install -y $all_pkgs 2>&1 | tee -a \"${LOGFILE}\""
	pkg_status=$INSTALLX_RUN_RC
fi
report "package installation: " "$pkg_status"
if [ "$pkg_status" -ne 0 ] && is_noninteractive ; then
	echo "FATAL: package installation failed in noninteractive mode (status=$pkg_status)" | tee -a "$LOGFILE"
	exit 1
fi
if [ "$pkg_status" -ge 128 ] ; then
	# killed by signal (e.g. Ctrl+C) — trap should have exited; belt and suspenders
	installx_abort INT
fi

# post install stuff
if [ "$DISPLAY_MGR" = "slim" ] ; then
	sed -i '' -E 's/^current_theme.+$/current_theme		slim-freebsd-dark-theme/' /usr/local/etc/slim.conf
	report "slim.conf dark theme" "$?"
fi

# Graphics post-install (must run after packages exist)
if [ "${vc_post_nvidia_xconfig:-0}" -eq 1 ] && [ "$NEED_XORG" = "yes" ] ; then
	if command -v nvidia-xconfig >/dev/null 2>&1 ; then
		nvidia-xconfig 2>/dev/null || echo "nvidia-xconfig failed (non-fatal)" | tee -a "$LOGFILE"
		report "nvidia-xconfig" "$?"
	else
		echo "graphics: nvidia-xconfig not installed; skip" | tee -a "$LOGFILE"
	fi
fi

# Wayland: seatd, compositor config, ly greeter, CLI start helper
if [ "$SESSION_TYPE" = "wayland" ] ; then
	if [ "$SEATD_NEEDED" = "yes" ] ; then
		sysrc seatd_enable="YES"
		service seatd start 2>/dev/null || true
		report "seatd enabled" "$?"
	fi
	case "$WAYLAND_COMPOSITOR" in
		sway) seed_sway_config ; report "sway config" "$?" ;;
		hyprland) seed_hyprland_config ; report "hyprland config" "$?" ;;
	esac
	ensure_wayland_session_desktop "$WAYLAND_COMPOSITOR"
	report "wayland session desktop" "$?"
	write_wayland_start_helper "$WAYLAND_COMPOSITOR"
	report "wayland start helper" "$?"
	if [ "$DISPLAY_MGR" = "ly" ] ; then
		if ! setup_ly_greeter ; then
			report "ly greeter" "1"
			echo "WARNING: ly greeter setup failed — log in on the console and run: ~/start-desktop.sh" | tee -a "$LOGFILE"
			echo "WARNING: or fix manually: pkg install ly && see installx.log for gettytab/ttys steps" | tee -a "$LOGFILE"
		else
			report "ly greeter" "0"
		fi
	fi
fi

# make sudo behave like default linux setup
if [ "${sudo_yes:-1}" -eq 0 ] ; then
	test -e /usr/local/etc/sudoers && echo "%wheel ALL=(ALL) ALL" >> /usr/local/etc/sudoers
	report "created sudoers for wheel" "$?"
fi

# on 11.x w/ mate re-installing fixed a core-dump
if [ "$desktop_key" = "mate" ] ; then 
	if ( echo $(uname -r) | grep -q "11" ) ; then 
		pkg install -f gsettings-desktop-schemas
	fi
fi

# Set the user's shell to bash
if [ "${bash_yes:-1}" -eq 0 ] ; then
	chpass -s /usr/local/bin/bash $VUSER || echo "failed to change shell to bash"
fi

if [ "$SESSION_TYPE" = "wayland" ] ; then
	welcome="Thanks for trying this setup script. You selected a Wayland compositor ($WAYLAND_COMPOSITOR). seatd is enabled and a starter script was written to /home/${VUSER}/start-desktop.sh.\n\nLogin greeter: ly on ttyv1 (usually Alt+F2 after boot). Select the ${WAYLAND_COMPOSITOR} session after authenticating. If ly is not running, log in on the console and run: ~/start-desktop.sh\n\nSee the FreeBSD handbook Wayland chapter for details. Report problems to http://bug.freebsddesktop.xyz/ or check installx.log."
else
	welcome="Thanks for trying this setup script. If you're new to FreeBSD, it's worth noting that instead of trying to search google for how to do something, you probably want to check the handbook on freebsd.org or read the built-in man pages. \n\n Doing a 'man -k <topic>' will search for any matching documentation, and unlike some, ahem, other *nix operating systems, FreeBSD's built in documentation is really good.\n\n"
fi
if is_noninteractive ; then
	echo "$welcome" | tee -a "$LOGFILE"
	echo "noninteractive install finished. See $LOGFILE and $ERRLOG" | tee -a "$LOGFILE"
else
	dialog --msgbox "$welcome Hopefully that worked. You'll probably want to reboot at this point. Please report any problems to http://bug.freebsddesktop.xyz/ or see the installx.log file created" 0 0
fi

#!/bin/sh
# Nick Bernstein https://github.com/nicholasbernstein/install-fbsd-desktop
# most of this comes from the freebsd handbook 5.4.1. Quick Start x-config
set -o pipefail
#set -e

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
#   INSTALLX_ROLLING       yes|no — use pkg "latest" (default: yes)
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

# dialog(1) draws its UI on stderr. Redirecting stderr to a file (as we do for
# CI logs) makes every dialog invisible. Only steal stderr in noninteractive mode.
if is_noninteractive ; then
	export ASSUME_ALWAYS_YES=yes
	export IGNORE_OSVERSION="${IGNORE_OSVERSION:-yes}"
	exec 2>>"$ERRLOG"
	set -x
	PS4="$0 $LINENO >"
else
	# Interactive: keep stderr on the TTY so dialog menus work.
	set +x
	if ! command -v dialog >/dev/null 2>&1 ; then
		echo "error: dialog(1) is required for interactive install." >&2
		echo "Install it with:  pkg install misc/dialog" >&2
		echo "Or run noninteractive: INSTALLX_NONINTERACTIVE=1 INSTALLX_DESKTOP=... $0" >&2
		exit 1
	fi
	if [ ! -t 0 ] || [ ! -t 2 ] ; then
		echo "error: interactive install needs a real terminal (stdin + stderr)." >&2
		echo "For automation set INSTALLX_NONINTERACTIVE=1 and INSTALLX_DESKTOP=..." >&2
		exit 1
	fi
	echo "installx: interactive mode (dialog menus). Log: $LOGFILE" | tee -a "$LOGFILE"
fi

grep -q "kern.vty" /boot/loader.conf || echo "kern.vty=vt" >> /boot/loader.conf

change_pkg_url_to_latest () {
	sed -i 'orig' 's/quarterly/latest/' /etc/pkg/FreeBSD.conf
	grep url /etc/pkg/FreeBSD.conf
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
pkg update | tee -a "$LOGFILE"
report "pkg bootstrapping" "$?"

# this will help with performance of desktop applications
# and may help perf during install, so I'm doing it early
adjust_sysctl_buffers
report "add sync buffers" "$?"

add_user_to_video() {
	# Your user needs to be in the video group to use video acceleration
	default_user=`grep 1001 /etc/passwd | awk -F: '{ print $1 }'`
	if is_noninteractive ; then
		VUSER="${INSTALLX_USER:-${default_user:-nick}}"
		echo "noninteractive: using video user '$VUSER'" | tee -a "$LOGFILE"
	else
		VUSER=`dialog --title "Video User" --clear  --inputbox "What user should be added to the video group?" 0 0  $default_user --stdout`
	fi

	# ensure home exists for .xinitrc and similar
	if ! id "$VUSER" >/dev/null 2>&1 ; then
		echo "user '$VUSER' does not exist; creating" | tee -a "$LOGFILE"
		pw useradd -n "$VUSER" -m -s /bin/sh || true
	fi
	mkdir -p "/home/$VUSER"
	chown "$VUSER" "/home/$VUSER" 2>/dev/null || true

	pw groupmod video -m $VUSER && echo "added $VUSER to group: video"
	report "add $VUSER to video group" "$?"
	pw groupmod wheel -m $VUSER && echo "added $VUSER to group: wheel" 
	report "add $VUSER to wheel group" "$?"

	# probably not necessary, logging into an x session as root isn't recommended.
	pw groupmod video -m root
	report "add root to wheel group" "$?"
}

add_user_to_video

gen_xinit() {
	# the following creates a .xinitrc file in the user's home directory that will launch
	# the installed windowmanager as well as allow the slim display manager to pass it as
	# an argument. 
	if [ ! $1 ] ; then 
		echo "argument needed by gen_xinit" 
		return 0 
	else
		xinittxt="#!/bin/sh\n mywm="$1"\n if [ \$1 ] ; then\n \tcase \$1 in \n \t\tdefault) exec \$mywm ;;\n \t\t*) exec \$1 ;;\n \tesac\n else\n \texec \$mywm\n fi"
		#echo -e $xinittxt > /home/$VUSER/.xinitrc && chown $VUSER:$VUSER /home/$VUSER/.xinitrc
		echo -e $xinittxt > /home/$VUSER/.xinitrc && chown $VUSER /home/$VUSER/.xinitrc
		test -d /etc/skel || mkdir /etc/skel
		echo -e $xinittxt > /etc/skel/.xinitrc
	fi
}


# --- Session profile defaults (overridden per desktop below) ---
# User picks one desktop from a single menu; we apply a reasonable stack.
SESSION_TYPE="x11"          # x11 | wayland
NEED_XORG="yes"             # install xorg stack
SEATD_NEEDED="no"           # wayland compositors need seatd
DISPLAY_MGR="sddm"          # sddm | slim | gdm | ly | none
DESKTOP_PKGS=""
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

setup_ly_greeter() {
	# TUI greeter that can start X11 and Wayland sessions (see handbook Wayland chapter)
	if [ ! -x /usr/local/bin/ly ] ; then
		echo "ly not installed; skip greeter setup" | tee -a "$LOGFILE"
		return 0
	fi
	if ! grep -q '^Ly:' /etc/gettytab 2>/dev/null ; then
		cat >> /etc/gettytab <<'GETTYEOF'

# installx.sh — ly greeter
Ly:\
	:lo=/usr/local/bin/ly:\
	:al=:
GETTYEOF
	fi
	if [ -f /etc/ttys ] && grep -q '^ttyv1' /etc/ttys ; then
		cp /etc/ttys /etc/ttys.installx.bak 2>/dev/null || true
		# shellcheck disable=SC2016
		sed -i '' -e 's|^ttyv1.*|ttyv1	"/usr/libexec/getty Ly"	xterm	on  secure|' /etc/ttys
		echo "configured ly on ttyv1 (backup: /etc/ttys.installx.bak)" | tee -a "$LOGFILE"
	fi
}

write_wayland_start_helper() {
	uhome="/home/${VUSER}"
	comp="${1:-$WAYLAND_COMPOSITOR}"
	cat > "${uhome}/start-desktop.sh" <<EOF
#!/bin/sh
# Generated by installx.sh — start the installed Wayland compositor
exec ${comp}
EOF
	chmod +x "${uhome}/start-desktop.sh"
	chown "${VUSER}" "${uhome}/start-desktop.sh"
	# skel for new users
	mkdir -p /etc/skel
	cp "${uhome}/start-desktop.sh" /etc/skel/start-desktop.sh
	chmod +x /etc/skel/start-desktop.sh
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

if is_noninteractive ; then
	case "${INSTALLX_ROLLING:-yes}" in
		[Nn][Oo]|0|false|FALSE) rolling=1 ;;
		*) rolling=0 ;;
	esac
	echo "noninteractive: rolling(latest pkg)=$( [ "$rolling" -eq 0 ] && echo yes || echo no )" | tee -a "$LOGFILE"
else
	dialog --title "Rolling Release" --yesno "Change pkg to use 'latest' packages instead of quarterly? Recommended for workstations. This prevents potential missing firefox package in 13.1 quarterly" 0 0
	rolling=$?
fi

if [ "$rolling" -eq 0  ] ; then 
	change_pkg_url_to_latest
	report "quarterly->latest changed" "$?"
fi


if is_noninteractive ; then
	desktop="${INSTALLX_DESKTOP:-awesome}"
	echo "noninteractive: desktop=$desktop" | tee -a "$LOGFILE"
else
	desktop=$(dialog --clear --title "Select Desktop" \
	        --menu "Select desktop environment or compositor to install:\n(X11 and Wayland options are listed together; setup is chosen automatically.)" 0 0 0 \
	        "KDE"  "KDE Plasma (X11)" \
	        "GNOME" "GNOME desktop (X11)" \
	        "Xfce4" "Lightweight XFCE desktop (X11)" \
	        "MATE"  "MATE desktop, GNOME 2 fork (X11)" \
	        "Cinnamon" "Cinnamon desktop (X11)" \
	        "LXQT" "Lightweight Qt desktop (X11)" \
	        "LXDE"  "Lightweight X11 desktop (X11)" \
	        "WindowMaker" "Window Maker (X11)" \
	        "awesome" "Awesome tiling WM (X11)" \
	        "Sway" "Sway tiling compositor (Wayland)" \
	        "Hyprland" "Hyprland compositor (Wayland)" \
	        --stdout)
fi

# Normalize so dialog labels (WindowMaker, Xfce4, …) and CI env vars match.
desktop_key=$(echo "$desktop" | tr '[:upper:]' '[:lower:]')

case $desktop_key in
  kde)
      # FreeBSD handbook: pkg install kde (Plasma 6 meta); X11 session is startplasma-x11
      # (kde5/plasma5-* packages were removed — they break pkg install on 14/15)
      gen_xinit "startplasma-x11"
      DESKTOP_PKGS="kde"
      DISPLAY_MGR="sddm"
      ;;
  windowmaker)
      gen_xinit "/usr/local/bin/wmaker"
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
      gen_xinit "startlxqt"
      DESKTOP_PKGS="lxqt"
      DISPLAY_MGR="sddm"
      ;;
  lxde)
      gen_xinit "startlxde"
      DESKTOP_PKGS="lxde-meta lxde-common"
      DISPLAY_MGR="sddm"
      ;;
  gnome)
      gen_xinit "gnome-session"
      DESKTOP_PKGS="gnome"
      DISPLAY_MGR="gdm"
      sysrc gnome_enable="YES"
      ;;
  xfce4|xfce)
      gen_xinit "startxfce4"
      DESKTOP_PKGS="xfce xfce4-goodies"
      DISPLAY_MGR="sddm"
      ;;
  mate)
      gen_xinit "mate-session"
      DESKTOP_PKGS="mate"
      DISPLAY_MGR="sddm"
      ;;
  cinnamon)
      gen_xinit "cinnamon-session"
      DESKTOP_PKGS="cinnamon"
      DISPLAY_MGR="sddm"
      ;;
  awesome)
      gen_xinit "awesome"
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
      ;;
  hyprland)
      SESSION_TYPE="wayland"
      NEED_XORG="no"
      SEATD_NEEDED="yes"
      DISPLAY_MGR="ly"
      WAYLAND_COMPOSITOR="hyprland"
      DESKTOP_PKGS="hyprland alacritty"
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
	echo "noninteractive: extra_pkgs=$extra_pkgs" | tee -a "$LOGFILE"
else
	extra_pkgs=$(dialog --checklist "Select additional packages to install:" 0 0 0 \
	firefox "Firefox Web browser" on \
	bash "GNU Bourne-Again SHell" on \
	vim "VI Improved" on \
	git-lite "Lightweight Git client" on \
	sudo "Superuser do" on \
	thunderbird "Thunderbird Email Client" off \
	obs-studio "OBS-Studio recording/casting" off \
	audacity "Audio editor" off \
	simplescreenrecorder "Does it need a description?" off \
	libreoffice "Open source office suite" off \
	vlc "Video player" off \
	doas "Simpler alternative to sudo" off \
	linux_base-c7 "CentOS v7 linux binary compatiblity layer" off \
	virtualbox-ose-additions "VirtualBox guest additions" off \
	--stdout)
fi

echo "Extra packages:" "$extra_pkgs" | tee -a "$LOGFILE"


# by default install the full xorg, but if xorg_minimal is set, override it

echo $extra_pkgs | grep -q linux_base-c7 && linuxBaseC7
echo $extra_pkgs | grep -q virtualbox-ose-additions && enable_virtualbox_ose_additions

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

echo $opt_activities | grep -q load_card_readers && load_card_readers
echo $opt_activities | grep -q load_atapi && load_card_readers
echo $opt_activities | grep -q load_fuse && load_fuse
echo $opt_activities | grep -q load_coretemp && load_card_readers
echo $opt_activities | grep -q load_amdtemp && load_card_readers
echo $opt_activities | grep -q load_bluetooth && load_card_readers
echo $opt_activities | grep -q enable_ipfw_firewall && enable_ipfw_firewall
echo $opt_activities | grep -q enable_tmpfs && enable_tmpfs
echo $opt_activities | grep -q enable_async_io && enable_async_io
echo $opt_activities | grep -q enable_workstation_pwr_mgmnt && enable_workstation_pwr_mgmnt
echo $opt_activities | grep -q load_bluetooth && load_bluetooth
echo $opt_activities | grep -q enable_cups && enable_cups
echo $opt_activities | grep -q enable_webcam && enable_webcam

# Display stack: full/minimal Xorg for X11 sessions; wayland+seatd+xwayland for compositors
if [ "$NEED_XORG" = "yes" ] ; then
	echo $opt_activities | grep -q minimal_xorg && xorg_pkgs=$xorg_minimal
	display_stack="$xorg_pkgs"
else
	display_stack="$wayland_base_pkgs"
	echo "session is Wayland; skipping Xorg metapackage (using: $display_stack)" | tee -a "$LOGFILE"
fi

# Display manager package (empty if none)
dm_pkgs=""
case "$DISPLAY_MGR" in
	sddm|slim|gdm|ly) dm_pkgs="$DISPLAY_MGR" ;;
esac

# Final package list for install
all_pkgs="$display_stack dbus $DESKTOP_PKGS $extra_pkgs $vc_pkgs $dm_pkgs $slim_extra_pkgs $audio_pkgs"

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
pkg install -y $all_pkgs | tee -a "$LOGFILE"
pkg_status=$?
report "package installation: " "$pkg_status"
if [ "$pkg_status" -ne 0 ] && is_noninteractive ; then
	echo "FATAL: package installation failed in noninteractive mode (status=$pkg_status)" | tee -a "$LOGFILE"
	exit 1
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

# Wayland: seatd, compositor config, optional ly greeter, start helper
if [ "$SESSION_TYPE" = "wayland" ] ; then
	if [ "$SEATD_NEEDED" = "yes" ] ; then
		sysrc seatd_enable="YES"
		report "seatd enabled" "$?"
	fi
	case "$WAYLAND_COMPOSITOR" in
		sway) seed_sway_config ; report "sway config" "$?" ;;
		hyprland) seed_hyprland_config ; report "hyprland config" "$?" ;;
	esac
	write_wayland_start_helper "$WAYLAND_COMPOSITOR"
	report "wayland start helper" "$?"
	if [ "$DISPLAY_MGR" = "ly" ] ; then
		setup_ly_greeter
		report "ly greeter" "$?"
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
	welcome="Thanks for trying this setup script. You selected a Wayland compositor ($WAYLAND_COMPOSITOR). seatd is enabled and a starter script was written to /home/${VUSER}/start-desktop.sh. If ly was installed, use the greeter on ttyv1 after reboot; otherwise log in on the console and run: $WAYLAND_COMPOSITOR\n\nSee the FreeBSD handbook Wayland chapter for details. Report problems to http://bug.freebsddesktop.xyz/ or check installx.log."
else
	welcome="Thanks for trying this setup script. If you're new to FreeBSD, it's worth noting that instead of trying to search google for how to do something, you probably want to check the handbook on freebsd.org or read the built-in man pages. \n\n Doing a 'man -k <topic>' will search for any matching documentation, and unlike some, ahem, other *nix operating systems, FreeBSD's built in documentation is really good.\n\n"
fi
if is_noninteractive ; then
	echo "$welcome" | tee -a "$LOGFILE"
	echo "noninteractive install finished. See $LOGFILE and $ERRLOG" | tee -a "$LOGFILE"
else
	dialog --msgbox "$welcome Hopefully that worked. You'll probably want to reboot at this point. Please report any problems to http://bug.freebsddesktop.xyz/ or see the installx.log file created" 0 0
fi


#!/bin/sh
# file: test_installx.sh — post-install checks for installx.sh

testuser="nick"
tuhome="/home/${testuser}"

test_vt_in_loader() {
  assertContains ["checking for kern.vty"]  "$( grep kern.vty /boot/loader.conf )" 'kern.vty' 
}

test_dbus_in_rc() {
  assertContains ["dbus"]  "$( grep dbus_enable /etc/rc.conf )" 'YES' 
}

test_proc_in_fstab() {
  assertContains ["/proc"]  "$( grep proc /etc/fstab )" 'proc /proc procfs rw 0 0' 
}

test_group_members() {
  assertContains ["checking video membership"]  "$( grep video /etc/group )" "${testuser}"
  assertContains ["checking video membership"]  "$( grep wheel /etc/group )" "${testuser}"
  assertContains ["checking video membership"]  "$( grep video /etc/group )" 'root' 
}

test_session_files() {
  # X11 desktops use .xinitrc; Wayland compositors seed config + start helper
  if [ -d "${tuhome}/.config/sway" ] || [ -d "${tuhome}/.config/hypr" ] ; then
    assertTrue "wayland start helper exists" "[ -x ${tuhome}/start-desktop.sh ]"
    if [ -d "${tuhome}/.config/sway" ] ; then
      assertTrue "sway config exists" "[ -e ${tuhome}/.config/sway/config ]"
    fi
    if [ -d "${tuhome}/.config/hypr" ] ; then
      assertTrue "hyprland config exists" "[ -e ${tuhome}/.config/hypr/hyprland.conf ]"
    fi
    # seatd should be enabled for Wayland profiles
    assertContains ["seatd enabled"] "$( grep seatd_enable /etc/rc.conf )" 'YES'
  else
    assertTrue "/etc/skel/.xinitrc exists" "[ -e /etc/skel/.xinitrc ]"
    assertTrue "${tuhome}/.xinitrc exists" "[ -e ${tuhome}/.xinitrc ]"
  fi
}

test_pkg_repo_url_configured() {
	# Default is quarterly; latest only if the user opted in. Either is fine.
	_urls=$(grep -rh 'url' /etc/pkg /usr/local/etc/pkg 2>/dev/null || true)
	assertTrue "pkg repo url configured" "[ -n \"${_urls}\" ]"
	assertTrue "pkg repo is quarterly or latest" \
		"echo \"${_urls}\" | grep -Eq 'quarterly|latest'"
}

test_fuse(){
	assertContains ["fuse module in kldlist"] "$(grep kld_list /etc/rc.conf)" fuse
	assertContains ["pkgs contain e2fsprogs"] "$(pkg info)" 'e2fsprogs'
	assertContains ["pkgs contain fusefs"] "$(pkg info)" 'fusefs'
}

test_ipfw_firewall() {
	assertContains ["firewall enabled"] "$(grep firewall_enable /etc/rc.conf)" 'YES'
}

# Wayland greeter (Sway/Hyprland): hardened ly/getty configuration
test_ly_greeter_config() {
	# Only when this install configured ly (gettytab Ly: block present)
	if ! grep -q '^Ly:' /etc/gettytab 2>/dev/null ; then
		startSkipping
		endSkipping
		return 0
	fi

	assertTrue "ly_wrapper executable" "[ -x /usr/local/bin/ly_wrapper ]"

	# Exactly one Ly: getty class; lo= must be ly_wrapper (not bare ly)
	_ly_n=$(grep -c '^Ly:' /etc/gettytab)
	assertEquals "exactly one Ly: gettytab entry" "1" "$_ly_n"
	assertTrue "gettytab lo=ly_wrapper" "grep -A2 '^Ly:' /etc/gettytab | grep -q 'lo=/usr/local/bin/ly_wrapper'"
	assertTrue "gettytab al=root" "grep -A2 '^Ly:' /etc/gettytab | grep -q ':al=root:'"
	assertFalse "gettytab must not use bare ly as lo" \
		"grep -A2 '^Ly:' /etc/gettytab | grep -q 'lo=/usr/local/bin/ly:'"

	assertTrue "ttyv1 uses getty Ly" "grep '^ttyv1' /etc/ttys | grep -q 'getty Ly'"
	# Recovery console: ttyv0 must not be the Ly greeter
	if grep -q '^ttyv0' /etc/ttys 2>/dev/null ; then
		assertFalse "ttyv0 is not Ly greeter" "grep '^ttyv0' /etc/ttys | grep -q 'getty Ly'"
	fi

	assertTrue "PAM policy for ly exists" \
		"[ -f /usr/local/etc/pam.d/ly ] || [ -f /etc/pam.d/ly ]"

	if [ -f /usr/local/etc/ly/config.ini ] ; then
		assertTrue "ly config.ini has tty" "grep -Eq '^[[:space:]]*tty[[:space:]]*=' /usr/local/etc/ly/config.ini"
	fi

	# seatd enabled for Wayland (sysrc); need not be running in CI
	assertContains ["seatd enabled"] "$(grep seatd_enable /etc/rc.conf 2>/dev/null)" 'YES'
}

###### shunit2 @ end of file (same directory as this script when installed via the port)
. "$(CDPATH= cd -- "$(dirname "$0")" && pwd)/shunit2"

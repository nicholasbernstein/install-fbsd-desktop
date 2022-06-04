#!/bin/sh
# file: installx.sh

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

test_xinitrc() {
  assertTrue "/etc/skel/.xinitrc exists" "[ -e /etc/skel/.xinitrc ]"
  assertTrue "${tuhome}/.xinitrc exists" "[ -e ${tuhome}/.xinitrc ]"
}

test_pkg_url_to_latest() { 
	assertContains ["latest"] "$(grep url /etc/pkg/FreeBSD.conf)" 'latest'
}

test_fuse(){
	assertContains ["fuse module in kldlist"] "$(grep kld_list /etc/rc.conf)" fuse
	assertContains ["pkgs contain e2fsprogs"] "$(pkg info)" 'e2fsprogs'
	assertContains ["pkgs contain fusefs"] "$(pkg info)" 'fusefs'
}

test_ipfw_firewall() {
	assertContains ["firewall enabled"] "$(grep firewall_enable /etc/rc.conf)" 'YES'
}

###### shunit2 @ end of file
. shunit2

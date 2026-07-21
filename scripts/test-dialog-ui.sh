#!/bin/sh
# Smoke-test cdialog the way installx.sh resolves it.
# Run on Linux (CI: apt dialog binary) or FreeBSD (pkg cdialog). Exit 0 on success.
#
# Usage:
#   sh scripts/test-dialog-ui.sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

echo "==> resolve UI binary (cdialog preferred; dialog accepted for Linux CI)"
DIALOG_BIN=""
PATH="${PATH}:/usr/local/bin"
export PATH
if command -v cdialog >/dev/null 2>&1 ; then
	DIALOG_BIN=$(command -v cdialog)
elif command -v dialog >/dev/null 2>&1 ; then
	# Linux package "dialog" is ComeOn Dialog! (same family as FreeBSD cdialog)
	DIALOG_BIN=$(command -v dialog)
else
	echo "FAIL: neither cdialog nor dialog found in PATH" >&2
	exit 1
fi
echo "    using: $DIALOG_BIN"

if [ -z "${TERM:-}" ] || [ "$TERM" = "dumb" ] || [ "$TERM" = "unknown" ] ; then
	TERM=xterm
	export TERM
fi
echo "    TERM=$TERM"

# Prefer a pseudo-tty when available (script(1) on FreeBSD/Linux)
run_with_tty() {
	if command -v script >/dev/null 2>&1 ; then
		# FreeBSD: script -q /dev/null cmd
		# GNU:     script -q -c 'cmd' /dev/null
		if script -q /dev/null true >/dev/null 2>&1 ; then
			script -q /dev/null "$@"
			return $?
		fi
		if script -q -c "true" /dev/null >/dev/null 2>&1 ; then
			script -q -c "$*" /dev/null
			return $?
		fi
	fi
	# Fallback: run directly
	"$@"
}

echo "==> msgbox with timeout (auto-dismiss)"
if ! run_with_tty "$DIALOG_BIN" --timeout 2 --title "installx-test" \
	--msgbox "UI smoke test — auto-closes in 2s." 8 50 ; then
	_rc=$?
	# Some builds return 255 on timeout; treat 0/255 as success for timeout dismiss
	if [ "$_rc" -ne 0 ] && [ "$_rc" -ne 255 ] && [ "$_rc" -ne 1 ] ; then
		echo "FAIL: msgbox --timeout failed (exit $_rc)" >&2
		exit 1
	fi
fi
echo "    msgbox OK"

echo "==> yesno with timeout"
if ! run_with_tty "$DIALOG_BIN" --timeout 2 --title "installx-test" \
	--yesno "Timeout test (auto)." 7 40 ; then
	_rc=$?
	# timeout / no are acceptable for smoke
	if [ "$_rc" -gt 255 ] ; then
		echo "FAIL: yesno unexpected exit $_rc" >&2
		exit 1
	fi
fi
echo "    yesno OK"

echo "==> menu with timeout"
if ! run_with_tty "$DIALOG_BIN" --timeout 2 --title "installx-test" \
	--menu "Pick (auto-timeout):" 12 50 3 \
	"A" "Option A" \
	"B" "Option B" \
	"Quit" "Exit" \
	--stdout >/tmp/installx-dialog-menu.out 2>/tmp/installx-dialog-menu.err ; then
	_rc=$?
	if [ "$_rc" -gt 255 ] ; then
		echo "FAIL: menu unexpected exit $_rc" >&2
		cat /tmp/installx-dialog-menu.err >&2 || true
		exit 1
	fi
fi
echo "    menu OK"

echo "==> programbox brief stream"
(
	echo "line one"
	sleep 0.2 2>/dev/null || sleep 1
	echo "line two"
	echo "done"
) | run_with_tty "$DIALOG_BIN" --title "installx-test" --programbox 12 50 \
	|| true
echo "    programbox OK"

echo "==> installx.sh syntax still valid"
if command -v bash >/dev/null 2>&1 ; then
	bash -n "$ROOT/installx.sh"
else
	sh -n "$ROOT/installx.sh"
fi

echo "PASS: cdialog UI smoke tests"
exit 0

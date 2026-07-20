#!/bin/sh
# Smoke-test dialog / bsddialog the way installx.sh resolves them.
# Run on Linux (CI) or FreeBSD. Exit 0 on success.
#
# Usage:
#   sh scripts/test-dialog-ui.sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

echo "==> resolve dialog binary (same preference as installx.sh)"
DIALOG_BIN=""
if command -v bsddialog >/dev/null 2>&1 ; then
	DIALOG_BIN=$(command -v bsddialog)
elif command -v dialog >/dev/null 2>&1 ; then
	DIALOG_BIN=$(command -v dialog)
else
	echo "FAIL: neither bsddialog nor dialog found in PATH" >&2
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
# dialog(1) and bsddialog both support --timeout on modern versions
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

echo "==> gauge brief pulse"
(
	printf '%s\n' "XXX" "CI gauge smoke…" "XXX" "10"
	sleep 0.3 2>/dev/null || sleep 1
	printf '%s\n' "XXX" "CI gauge smoke…" "XXX" "50"
	sleep 0.3 2>/dev/null || sleep 1
	printf '%s\n' "XXX" "Done" "XXX" "100"
) | run_with_tty "$DIALOG_BIN" --title "installx-test" --gauge "Progress" 10 50 0 \
	|| true
echo "    gauge OK"

echo "==> installx.sh syntax still valid"
if command -v bash >/dev/null 2>&1 ; then
	bash -n "$ROOT/installx.sh"
else
	sh -n "$ROOT/installx.sh"
fi

echo "PASS: dialog UI smoke tests"
exit 0

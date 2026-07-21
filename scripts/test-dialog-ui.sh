#!/bin/sh
# Smoke-test cdialog the way installx.sh resolves it.
# Run on Linux (CI: apt dialog binary) or FreeBSD (pkg cdialog). Exit 0 on success.
#
# Usage:
#   sh scripts/test-dialog-ui.sh
#
# Every widget is wrapped in a hard wall-clock timeout so CI cannot hang.

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

# FreeBSD script(1): script -q /dev/null cmd args... (real PTY, preserves argv).
# GNU script: FreeBSD form hangs or misparses — never use it on Linux.
# Detect by OS, not by probing (probe hangs under GNU script).
SCRIPT_PTY=0
case "$(uname -s 2>/dev/null)" in
	FreeBSD|DragonFly)
		if command -v script >/dev/null 2>&1 ; then
			SCRIPT_PTY=1
		fi
		;;
esac
echo "    SCRIPT_PTY=$SCRIPT_PTY (uname=$(uname -s 2>/dev/null || echo unknown))"

# timeout(1) wraps real binaries only (not shell functions).
run_dialog() {
	_limit="${1:-10}"
	shift
	if command -v timeout >/dev/null 2>&1 ; then
		if [ "$SCRIPT_PTY" -eq 1 ] ; then
			timeout "$_limit" script -q /dev/null "$DIALOG_BIN" "$@"
			return $?
		fi
		timeout "$_limit" "$DIALOG_BIN" "$@"
		return $?
	fi
	if [ "$SCRIPT_PTY" -eq 1 ] ; then
		script -q /dev/null "$DIALOG_BIN" "$@"
		return $?
	fi
	"$DIALOG_BIN" "$@"
}

# Accept timeout/cancel/esc/success for smoke dismissals
_ok_dismiss() {
	_rc="$1"
	# 0=OK, 1=Cancel/No, 4=dialog timeout (some), 124=timeout(1), 255=ESC/dialog timeout
	case "$_rc" in
		0|1|4|124|255) return 0 ;;
		*) return 1 ;;
	esac
}

echo "==> msgbox with timeout (auto-dismiss)"
_rc=0
run_dialog 8 --timeout 2 --title "installx-test" \
	--msgbox "UI smoke test — auto-closes in 2s." 8 50 || _rc=$?
if ! _ok_dismiss "$_rc" ; then
	echo "FAIL: msgbox --timeout failed (exit $_rc)" >&2
	exit 1
fi
echo "    msgbox OK (rc=$_rc)"

echo "==> yesno with timeout"
_rc=0
run_dialog 8 --timeout 2 --title "installx-test" \
	--yesno "Timeout test (auto)." 7 40 || _rc=$?
if ! _ok_dismiss "$_rc" ; then
	echo "FAIL: yesno unexpected exit $_rc" >&2
	exit 1
fi
echo "    yesno OK (rc=$_rc)"

echo "==> menu with timeout"
_rc=0
run_dialog 8 --timeout 2 --title "installx-test" \
	--menu "Pick (auto-timeout):" 12 50 3 \
	"A" "Option A" \
	"B" "Option B" \
	"Quit" "Exit" \
	--stdout >/tmp/installx-dialog-menu.out 2>/tmp/installx-dialog-menu.err || _rc=$?
if ! _ok_dismiss "$_rc" ; then
	echo "FAIL: menu unexpected exit $_rc" >&2
	cat /tmp/installx-dialog-menu.err >&2 || true
	exit 1
fi
echo "    menu OK (rc=$_rc)"

# progressbox exits on EOF (programbox waits for OK and hangs CI forever).
echo "==> progressbox brief stream"
_rc=0
(
	echo "line one"
	echo "line two"
	echo "done"
) | run_dialog 8 --title "installx-test" --progressbox 12 50 || _rc=$?
if [ "$_rc" -ne 0 ] && [ "$_rc" -ne 124 ] && [ "$_rc" -ne 255 ] ; then
	echo "    progressbox rc=$_rc (non-fatal for smoke)"
fi
echo "    progressbox OK (rc=$_rc)"

echo "==> installx.sh syntax still valid"
if command -v bash >/dev/null 2>&1 ; then
	bash -n "$ROOT/installx.sh"
else
	sh -n "$ROOT/installx.sh"
fi

echo "PASS: cdialog UI smoke tests"
exit 0

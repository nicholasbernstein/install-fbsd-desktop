#!/bin/sh
# Extract named shell functions from installx.sh for unit tests only.
# Usage: extract_functions.sh /path/to/installx.sh name1 name2 ...
# Prints function bodies to stdout. Does not modify installx.sh.
#
# Portable /bin/sh + awk (FreeBSD). Handles nested braces in function bodies.

set -eu

if [ "$#" -lt 2 ] ; then
	echo "usage: $0 installx.sh func1 [func2 ...]" >&2
	exit 2
fi

SRC=$1
shift
if [ ! -f "$SRC" ] ; then
	echo "error: source not found: $SRC" >&2
	exit 1
fi

# Build awk pattern: ^(name1|name2)\(\)
NAMES=""
for n in "$@" ; do
	case "$n" in
		*[!a-zA-Z0-9_]*|"")
			echo "error: invalid function name: $n" >&2
			exit 2
			;;
	esac
	if [ -z "$NAMES" ] ; then
		NAMES=$n
	else
		NAMES="$NAMES|$n"
	fi
done

# shellcheck disable=SC2016
awk -v names="$NAMES" '
BEGIN {
	n = split(names, want, "|")
	for (i = 1; i <= n; i++) {
		if (want[i] != "") target[want[i]] = 1
	}
	in_func = 0
	depth = 0
	found = 0
}
# Start of function: name() {  or name () {
/^[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/ {
	line = $0
	# extract name
	name = line
	sub(/[[:space:]]*\(\).*/, "", name)
	if (name in target) {
		in_func = 1
		depth = 0
		found++
		# count braces on this line
		tmp = line
		while (match(tmp, /[{}]/)) {
			ch = substr(tmp, RSTART, 1)
			if (ch == "{") depth++
			else if (ch == "}") depth--
			tmp = substr(tmp, RSTART + 1)
		}
		print line
		if (depth <= 0) {
			in_func = 0
		}
		next
	}
}
in_func {
	print
	tmp = $0
	while (match(tmp, /[{}]/)) {
		ch = substr(tmp, RSTART, 1)
		if (ch == "{") depth++
		else if (ch == "}") depth--
		tmp = substr(tmp, RSTART + 1)
	}
	if (depth <= 0) {
		in_func = 0
	}
	next
}
END {
	if (found == 0) {
		print "error: no matching functions extracted" > "/dev/stderr"
		exit 1
	}
}
' "$SRC"

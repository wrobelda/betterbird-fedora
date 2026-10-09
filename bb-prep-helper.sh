#!/bin/sh
# Apply Betterbird's Mozilla series from the source root and its mail series
# from comm/. git apply supports the copy, rename, and binary patch records.
set -eu

BBP=${1:?usage: bb-prep-helper.sh <patch-directory>}
case "$BBP" in /*) ;; *) BBP=$PWD/$BBP ;; esac
ROOT=$PWD
test -d "$ROOT/comm"
test -d "$BBP"

# A source tree can sit inside the converter checkout. Prevent git from
# finding that outer repository and silently skipping paths outside it.
unset GIT_WORK_TREE GIT_INDEX_FILE
GIT_DIR=/dev/null
export GIT_DIR

apply_series()
{
	series_file=$1
	rundir=$2
	while read -r patch rest || [ -n "$patch" ]; do
		case "$patch" in ''|'#'*) continue ;; esac
		if [ ! -f "$BBP/$patch" ]; then
			echo "error: missing Betterbird patch: $patch" >&2
			exit 1
		fi
		if ! (cd "$rundir" && git apply --whitespace=nowarn "$BBP/$patch"); then
			echo "error: Betterbird patch failed: $patch" >&2
			echo "Use the exact source revision for the Betterbird release." >&2
			exit 1
		fi
		echo "Applied: $patch"
	done < "$series_file"
}

apply_series "$BBP/series-moz" "$ROOT"
apply_series "$BBP/series" "$ROOT/comm"

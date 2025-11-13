#!/bin/bash
#
# arc lint calls linters for all relevant files in parallel, which
# pre-commit run does not like at all (even with --files switch),
# therefore use mkdir lock to only run one pre-commit --all-files instance
# per arc lint run.

set -uo pipefail

# pid of arcanist.php --lint process
gppid=$(ps -o ppid= -p $PPID | xargs)
lock="/tmp/arclint-$gppid.lock"
# mkdir is atomic, file check with -e is not!
if ! mkdir $lock 2>/dev/null; then
	exit 0
fi

log=$(mktemp "/tmp/arclint-XXXXXX")
pre-commit run --all-files > $log 2>&1
status=$?
if [ $status -ne 0 ]; then
	echo "pre-commit run failed with code $status, see $log"
else
	rm $log
fi

exit 0

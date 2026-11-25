#!/usr/bin/env bash
# Records the files in ~/.ssh so test/check-cleanup.sh can tell if they changed.
set -euo pipefail
tmp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
find ~/.ssh -type f 2>/dev/null | sort >"$tmp/rsync-deploy-ssh-snapshot.txt" || true

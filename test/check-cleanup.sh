#!/usr/bin/env bash
#
# Fails if the action left keys, config or known_hosts behind: no
# rsync-deploy.* directory in the temp dir and ~/.ssh unchanged since
# test/snapshot-ssh.sh ran.

set -euo pipefail

tmp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
snapshot="$tmp/rsync-deploy-ssh-snapshot.txt"

leftovers=$(find "$tmp" -maxdepth 1 -name 'rsync-deploy.*' -print)
if [ -n "$leftovers" ]; then
    echo "Temporary files left behind:" >&2
    echo "$leftovers" >&2
    exit 1
fi

current=$(find ~/.ssh -type f 2>/dev/null | sort || true)
if [ "$current" != "$(cat "$snapshot")" ]; then
    echo "$HOME/.ssh changed:" >&2
    diff <(cat "$snapshot") <(echo "$current") >&2 || true
    exit 1
fi

echo "No keys, config or known_hosts left behind"

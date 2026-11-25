#!/usr/bin/env bash
#
# Sends a directory to a server with rsync over SSH, optionally through a
# jump host. Inputs come from INPUT_* environment variables set by action.yml.
#
# Never enable `set -x` here: the private keys go through variables.

set -euo pipefail

fail() {
    echo "::error::$*"
    exit 1
}

# Reads a multi-line input, drops carriage returns and trailing blank lines,
# and prints it with a single final newline (or nothing if it is empty).
normalize() {
    local value
    value=$(printf '%s' "$1" | tr -d '\r')
    if [ -n "$value" ]; then
        printf '%s\n' "$value"
    fi
}

# Quotes a value for a POSIX remote shell.
shell_quote() {
    printf "'%s'" "${1//\'/\'\\\'\'}"
}

host=${INPUT_HOST:-}
port=${INPUT_PORT:-22}
username=${INPUT_USERNAME:-}
key=${INPUT_KEY:-}
known_hosts=${INPUT_KNOWN_HOSTS:-}
proxy_host=${INPUT_PROXY_HOST:-}
proxy_port=${INPUT_PROXY_PORT:-22}
proxy_username=${INPUT_PROXY_USERNAME:-}
proxy_key=${INPUT_PROXY_KEY:-}
proxy_known_hosts=${INPUT_PROXY_KNOWN_HOSTS:-}
source_dir=${INPUT_SOURCE:-./}
target=${INPUT_TARGET:-}
exclude=${INPUT_EXCLUDE:-}
exclude_from=${INPUT_EXCLUDE_FROM:-}

port=${port:-22}
proxy_port=${proxy_port:-22}
source_dir=${source_dir:-./}

# --- Validation -------------------------------------------------------------

[ -n "$host" ] || fail "The 'host' input is required."
[ -n "$username" ] || fail "The 'username' input is required."
[ -n "$key" ] || fail "The 'key' input is required."
[ -n "$known_hosts" ] || fail "The 'known_hosts' input is required. See the README for how to get the line."
[ -n "$target" ] || fail "The 'target' input is required."

if [ -n "$proxy_host" ]; then
    [ -n "$proxy_username" ] || fail "The 'proxy_username' input is required when 'proxy_host' is set."
    [ -n "$proxy_key" ] || fail "The 'proxy_key' input is required when 'proxy_host' is set."
    [ -n "$proxy_known_hosts" ] || fail "The 'proxy_known_hosts' input is required when 'proxy_host' is set. See the README for how to get the line."
fi

[ -d "$source_dir" ] || fail "The source directory '$source_dir' does not exist."

exclude_from_path=""
if [ -n "$exclude_from" ]; then
    exclude_from_path="${source_dir%/}/$exclude_from"
    [ -f "$exclude_from_path" ] || fail "The exclude file '$exclude_from' was not found in '$source_dir' (looked for '$exclude_from_path')."
fi

# Relative remote paths are relative to the remote home, so "~/" is redundant
# and would not be expanded inside quotes.
# shellcheck disable=SC2088 # a literal "~/" is what we are matching
case "$target" in
    "~") target="." ;;
    "~/"*) target="${target#\~/}" ;;
esac
target=${target:-.}

# --- rsync ------------------------------------------------------------------

if ! command -v rsync >/dev/null 2>&1; then
    echo "rsync not found, installing it with apt-get"
    sudo_cmd=()
    if [ "$(id -u)" -ne 0 ]; then
        sudo_cmd=(sudo)
    fi
    "${sudo_cmd[@]}" apt-get update -qq
    "${sudo_cmd[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsync >/dev/null
fi

# --- SSH setup (removed on exit, also on failure) ---------------------------

umask 077
workdir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/rsync-deploy.XXXXXX")
trap 'rm -rf "$workdir"' EXIT

normalize "$key" >"$workdir/key"
{
    normalize "$known_hosts"
    normalize "$proxy_known_hosts"
} >"$workdir/known_hosts"

{
    if [ -n "$proxy_host" ]; then
        normalize "$proxy_key" >"$workdir/proxy_key"

        echo "Host rsync-deploy-proxy"
        echo "    HostName $proxy_host"
        echo "    Port $proxy_port"
        echo "    User $proxy_username"
        echo "    IdentityFile \"$workdir/proxy_key\""
        echo
    fi

    echo "Host rsync-deploy-target"
    echo "    HostName $host"
    echo "    Port $port"
    echo "    User $username"
    echo "    IdentityFile \"$workdir/key\""
    if [ -n "$proxy_host" ]; then
        echo "    ProxyJump rsync-deploy-proxy"
    fi
    echo

    echo "Host *"
    echo "    IdentitiesOnly yes"
    echo "    StrictHostKeyChecking yes"
    echo "    UserKnownHostsFile \"$workdir/known_hosts\""
    echo "    GlobalKnownHostsFile /dev/null"
    echo "    CheckHostIP no"
    echo "    BatchMode yes"
    echo "    ConnectTimeout 30"
    echo "    ServerAliveInterval 15"
    echo "    LogLevel ERROR"
} >"$workdir/config"

chmod 600 "$workdir"/*

ssh_cmd=(ssh -F "$workdir/config")

# --- Exclusions -------------------------------------------------------------

rsync_args=(-az --delete --checksum --stats)

: >"$workdir/exclude"
while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [ -n "$line" ]; then
        printf '%s\n' "$line" >>"$workdir/exclude"
    fi
done <<<"$exclude"

if [ -s "$workdir/exclude" ]; then
    rsync_args+=("--exclude-from=$workdir/exclude")
fi
if [ -n "$exclude_from_path" ]; then
    rsync_args+=("--exclude-from=$exclude_from_path")
fi

# --- Deploy -----------------------------------------------------------------

echo "Creating '$target' on the server"
if ! "${ssh_cmd[@]}" rsync-deploy-target "mkdir -p -- $(shell_quote "$target")"; then
    fail "Could not connect to the server or create '$target'. Check the host, user, keys and that the known_hosts lines match the servers' host keys."
fi

echo "Sending '$source_dir' to '$target'"
rsync "${rsync_args[@]}" -e "ssh -F $(shell_quote "$workdir/config")" \
    "${source_dir%/}/" "rsync-deploy-target:${target%/}/" | tee "$workdir/rsync.log"

transferred=$(sed -n 's/^Number of regular files transferred: *\([0-9,]*\).*/\1/p' "$workdir/rsync.log" | tr -d ',')
transferred=${transferred:-0}

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "files_transferred=$transferred" >>"$GITHUB_OUTPUT"
fi

echo "Done: $transferred file(s) transferred"

#!/usr/bin/env bash
#
# Starts the e2e SSH servers:
#   - rsync-proxy: published on 127.0.0.1:2222, also on the internal network
#   - rsync-target: only on the internal network, reachable as "target" from
#     the proxy, never from the runner
#
# Each server accepts a different client key. Keys and known_hosts lines are
# exported to $GITHUB_ENV (or printed as shell exports when run locally).

set -euo pipefail

image=${IMAGE:-rsync-deploy-sshd}
network=rsync-deploy-internal
dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/rsync-deploy-e2e"

rm -rf "$dir"
mkdir -p "$dir"

ssh-keygen -q -t ed25519 -N "" -C proxy -f "$dir/proxy_key"
ssh-keygen -q -t ed25519 -N "" -C target -f "$dir/target_key"
ssh-keygen -q -t ed25519 -N "" -C wrong -f "$dir/wrong_host_key"

docker build -q -t "$image" "$(dirname "$0")/sshd" >/dev/null

docker network create --internal "$network" >/dev/null

docker run -d --name rsync-proxy -p 127.0.0.1:2222:22 \
    -e AUTHORIZED_KEY="$(cat "$dir/proxy_key.pub")" "$image" >/dev/null
docker network connect "$network" rsync-proxy

docker run -d --name rsync-target --network "$network" --network-alias target \
    -e AUTHORIZED_KEY="$(cat "$dir/target_key.pub")" "$image" >/dev/null

for container in rsync-proxy rsync-target; do
    for _ in $(seq 1 30); do
        if docker logs "$container" 2>&1 | grep -q "Server listening"; then
            break
        fi
        sleep 1
    done
    docker logs "$container" 2>&1 | grep -q "Server listening" || {
        docker logs "$container"
        echo "$container did not start" >&2
        exit 1
    }
done

host_key() {
    docker exec "$1" cat /etc/ssh/ssh_host_ed25519_key.pub | cut -d" " -f1,2
}

wrong_key=$(cut -d" " -f1,2 "$dir/wrong_host_key.pub")

emit() {
    local name=$1 value=$2
    if [ -n "${GITHUB_ENV:-}" ]; then
        {
            echo "$name<<E2E_EOF"
            echo "$value"
            echo "E2E_EOF"
        } >>"$GITHUB_ENV"
    else
        printf 'export %s=%q\n' "$name" "$value"
    fi
}

# Mask the private keys line by line, like GitHub does with real secrets, so the
# step env blocks don't print them.
if [ -n "${GITHUB_ENV:-}" ]; then
    for file in "$dir/proxy_key" "$dir/target_key"; do
        while IFS= read -r line; do
            case "$line" in
                "-----"*) ;;
                ?*) echo "::add-mask::$line" ;;
            esac
        done <"$file"
    done
fi

emit PROXY_KEY "$(cat "$dir/proxy_key")"
emit TARGET_KEY "$(cat "$dir/target_key")"
emit PROXY_KNOWN_HOSTS "[127.0.0.1]:2222 $(host_key rsync-proxy)"
emit TARGET_KNOWN_HOSTS "target $(host_key rsync-target)"
emit WRONG_PROXY_KNOWN_HOSTS "[127.0.0.1]:2222 $wrong_key"
emit WRONG_TARGET_KNOWN_HOSTS "target $wrong_key"

# The client keys only live in the environment from here on.
rm -rf "$dir"

#!/bin/sh
#
# Generates a host key unique to this container, authorizes the public key in
# AUTHORIZED_KEY for the "deploy" user and starts sshd in the foreground.

set -eu

: "${AUTHORIZED_KEY:?AUTHORIZED_KEY is required}"

ssh-keygen -q -t ed25519 -N "" -f /etc/ssh/ssh_host_ed25519_key

install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
printf '%s\n' "$AUTHORIZED_KEY" >/home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys

exec /usr/sbin/sshd -D -e

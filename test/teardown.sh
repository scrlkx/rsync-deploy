#!/usr/bin/env bash
# Removes what test/setup.sh created.
docker rm -f rsync-proxy rsync-target >/dev/null 2>&1 || true
docker network rm rsync-deploy-internal >/dev/null 2>&1 || true

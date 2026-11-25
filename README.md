# rsync-deploy

A GitHub Action to send files to a server with rsync over SSH, sending only what changed since the last deploy.
Useful for deploys of projects with large dependency folders (e.g., `vendor/`, `node_modules/`), and for servers that are only reachable through an SSH proxy (jump host).

## Features

- Incremental – Mirrors the source into a directory that persists on the server, so unchanged files aren't sent again
- Proxy-ready – Connects through a jump host with `ProxyJump`, with its own key, user and port, even when the target host name only resolves on the proxy side
- Strict – Checks the host key on every hop against the `known_hosts` lines you provide; never runs `ssh-keyscan` or disables checking
- Clean – Keys, SSH config and `known_hosts` live in a temporary directory that is removed when the action ends, even on failure
- Lightweight – A composite action that uses the runner's own `rsync` and OpenSSH, with no Docker or Node

## Basic Usage

```yaml
name: Deploy

on:
  push:
    branches:
      - main

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v7

      - name: Send to the server
        uses: scrlkx/rsync-deploy@v1
        with:
          host: ${{ vars.SSH_HOST }}
          port: ${{ vars.SSH_PORT }}
          username: ${{ vars.SSH_USER }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          known_hosts: ${{ vars.SSH_KNOWN_HOSTS }}
          exclude: |
            .git
          target: /srv/deploy/my-app
```

### Through an SSH proxy

```yaml
- name: Send to the server
  uses: scrlkx/rsync-deploy@v1
  with:
    proxy_host: ${{ env.SSH_PROXY_HOST }}
    proxy_port: ${{ env.SSH_PROXY_PORT }}
    proxy_username: ${{ env.SSH_PROXY_USER }}
    proxy_key: ${{ secrets.SSH_PROXY_PRIVATE_KEY }}
    proxy_known_hosts: ${{ vars.SSH_PROXY_KNOWN_HOSTS }}
    host: ${{ vars.SSH_HOST }}
    port: ${{ vars.SSH_PORT }}
    username: ${{ vars.SSH_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    known_hosts: ${{ vars.SSH_KNOWN_HOSTS }}
    exclude_from: .rsync-exclude
    exclude: |
      .git
      frontend/node_modules
    target: ${{ env.UNPACK_PATH }}
```

`host` is resolved by the proxy, so it can be a name that only exists on the proxy's network. The proxy and the target can use different keys.

## Inputs

| Name                | Description                                                                                       | Required             | Default |
| ------------------- | ------------------------------------------------------------------------------------------------- | -------------------- | ------- |
| `host`              | Target server host (as seen from the proxy, when there is one)                                    | Yes                  | —       |
| `port`              | Target server SSH port                                                                            | No                   | `22`    |
| `username`          | Target server SSH user                                                                            | Yes                  | —       |
| `key`               | Private key for the target server                                                                 | Yes                  | —       |
| `known_hosts`       | `known_hosts` line(s) for the target server — see [Host keys](#host-keys) below                   | Yes                  | —       |
| `proxy_host`        | SSH proxy (jump host). When empty, connects to the target directly                                | No                   | —       |
| `proxy_port`        | SSH proxy port                                                                                    | No                   | `22`    |
| `proxy_username`    | SSH proxy user                                                                                    | With `proxy_host`    | —       |
| `proxy_key`         | Private key for the SSH proxy                                                                     | With `proxy_host`    | —       |
| `proxy_known_hosts` | `known_hosts` line(s) for the SSH proxy                                                           | With `proxy_host`    | —       |
| `source`            | Local directory whose contents are sent                                                           | No                   | `./`    |
| `target`            | Remote directory that mirrors `source`. Created if missing — see [Target](#target) below          | Yes                  | —       |
| `exclude`           | Paths to exclude, one per line (e.g., `.git`)                                                     | No                   | —       |
| `exclude_from`      | Path, relative to `source`, of an exclude file in rsync format (e.g., `.rsync-exclude`)           | No                   | —       |

## Outputs

| Name                | Description                                                          |
| ------------------- | -------------------------------------------------------------------- |
| `files_transferred` | Number of regular files rsync transferred (`0` when nothing changed) |

## How it works

The action runs:

```sh
rsync -az --delete --checksum source/ target/
```

- The trailing slash on both sides makes `target` an exact mirror of `source`: files removed from `source` are removed from `target`
- `--checksum` compares file contents instead of modification times, because installing dependencies in CI rewrites the dates of every file
- Before sending, the action runs `mkdir -p` on the server to create `target`

`rsync` must be installed on the server. On the runner, the action installs it with `apt-get` if it is missing (e.g., on `ubuntu-slim`).

## Host keys

Both `known_hosts` and `proxy_known_hosts` take lines in the `known_hosts` format, and the connection fails if the server's key doesn't match. Get them once, from a machine that can reach the server, and store them as repository or organization variables:

```sh
ssh-keyscan -p <port> <host>
```

- For a host behind the proxy, run it on the proxy itself (or from any machine where the host is reachable under the same name the proxy uses)
- Use the same `host` and `port` you pass to the action. For ports other than 22, the lines start with `[host]:port`, which is what `ssh-keyscan -p` prints
- Compare the fingerprints (`ssh-keygen -lf <file>`) with the ones on the server (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`) before trusting them

## Target

`target` should be a directory used only by this action, kept on the server between deploys (e.g., `/srv/deploy/my-app`). A later step can then copy or `rsync` it into the application directory. If `target` is a temporary directory removed after every deploy, everything is sent again every time, and the deploy stops being incremental.

If `target` is the application directory itself, anything that only exists on the server — uploads, logs, local databases, `.env` files created there — **must** be listed in `exclude` or `exclude_from`. Otherwise `--delete` removes it.

## Exclusions

`exclude` and `exclude_from` can be used together, and both follow the rsync filter syntax:

- A pattern without `/` matches at any depth (`node_modules` excludes every `node_modules` folder)
- A pattern with `/` in the middle is matched against the full path from `source` (`frontend/node_modules`)
- A pattern starting with `/` is anchored to `source` (`/storage` excludes only the top-level `storage`)

Excluded paths are not sent, and files that already exist in those paths on the server are **not** deleted by `--delete`.

If `exclude_from` points to a file that doesn't exist, the action fails.

An exclude file that lists itself (e.g., `.rsync-exclude` containing `.rsync-exclude`) does not reach the target. Leave it out of its own list if a later step on the server needs to read it from there.

## Security

- The host key is checked on every hop with `StrictHostKeyChecking yes`, against only the lines given in `known_hosts` and `proxy_known_hosts`
- Each hop uses its own key (`IdentitiesOnly yes`), so the proxy never sees the target key
- Keys, SSH config and `known_hosts` are written with mode `600` to a directory under `$RUNNER_TEMP`, never to `~/.ssh`, and removed when the action ends, even when it fails
- Secrets are passed to the script through environment variables and are never printed

## License

GPL-3.0 License - see the [LICENSE](LICENSE) file for details

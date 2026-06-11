# ovpn webhook receiver

This directory contains the webhook entry point used for in-tree
`ovpn-net-next` checks.

The receiver is split into three pieces:

- `hooks.json.tmpl`: `adnanh/webhook` configuration for HTTP handling and
  GitHub signature validation.
- `github-webhook.sh`: parses GitHub `push` payloads, filters commits by
  ovpn-related paths, and invokes the dispatcher once per relevant commit.
- `dispatch-commit.sh`: computes the cache base and sends the
  `repository_dispatch` event to the CI repository.

By default only commits touching these paths are dispatched:

- `drivers/net/ovpn/`
- `Documentation/netlink/specs/ovpn.yaml`
- `include/uapi/linux/ovpn.h`
- `tools/testing/selftests/net/ovpn/`

## Setup

Install [`adnanh/webhook`](https://github.com/adnanh/webhook). Some distros
package it, so the package manager is enough there. If no package is available,
unpack the upstream release under `receiver/.tools/`, which is ignored by git:

```sh
mkdir -p receiver/.tools
curl -L \
  -o /tmp/webhook-linux-amd64.tar.gz \
  https://github.com/adnanh/webhook/releases/download/2.8.3/webhook-linux-amd64.tar.gz
tar -C receiver/.tools -xzf /tmp/webhook-linux-amd64.tar.gz
```

The examples below use the local `receiver/.tools/.../webhook` path. Replace it
with `webhook` if the binary is installed in `PATH`.

Create a bare mirror of the source tree. The dispatcher uses it to resolve
short commit IDs and find the nearest tracked branch for ccache reuse:

```sh
mkdir -p ~/ci-mirrors
git clone --mirror git@github.com:ralflici/ovpn-net-next.git \
  ~/ci-mirrors/ovpn-net-next.git
```

Start the receiver from the repository root:

```sh
WEBHOOK_SECRET='your-webhook-secret' \
GITHUB_TOKEN='your-dispatch-token' \
DISPATCH_REPOSITORY='ralflici/ovpn-kmod-ci' \
GIT_MIRROR_DIR="$HOME/ci-mirrors/ovpn-net-next.git" \
receiver/.tools/webhook-linux-amd64/webhook \
  -hooks receiver/hooks.json.tmpl \
  -template \
  -verbose \
  -nopanic \
  -urlprefix '' \
  -ip 127.0.0.1 \
  -port 3000
```

The GitHub webhook URL is the public endpoint plus `/github`. For example, when
using `cloudflared tunnel --url http://127.0.0.1:3000`, configure GitHub with:

```text
https://<cloudflared-host>/github
```

Use content type `application/json`, enable SSL verification, configure only the
`push` event, and use the same secret as `WEBHOOK_SECRET`.

`GITHUB_TOKEN` must be allowed to create `repository_dispatch` events in
`DISPATCH_REPOSITORY`.

## Manual dispatch

Use `dispatch-commit.sh` directly to re-run checks without sending a webhook:

```sh
GITHUB_TOKEN='your-dispatch-token' \
DISPATCH_REPOSITORY='ralflici/ovpn-kmod-ci' \
GIT_MIRROR_DIR="$HOME/ci-mirrors/ovpn-net-next.git" \
receiver/dispatch-commit.sh \
  --repo ralflici/ovpn-net-next \
  --ref refs/heads/development \
  --sha <commit>
```

`--sha` may be abbreviated as long as it resolves uniquely in `GIT_MIRROR_DIR`.

Without `--event`, both default events are dispatched:

- `ovpn-patch-check`
- `ovpn-selftest`

To dispatch only one workflow, pass `--event ovpn-patch-check` or
`--event ovpn-selftest`.

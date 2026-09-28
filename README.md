# privan-probe-agent

Probe agent for the PrivanVPN monitoring bot. It checks VPN servers from
wherever it runs (a region, an ISP, a hosting provider) and reports the
results to the bot. With agents in several places, the bot can tell a server
that is down from one that is only blocked for some networks.

The agent only probes. The bot decides what is up or down and sends
notifications.

## what it does

The agent long-polls the bot for a job. For each job it:

1. connects to the panel over TLS;
2. for every server in the job:
   - TCP connect to the server port, or ICMP ping for Hysteria (UDP/QUIC,
     where TCP proves nothing);
   - starts [xray-core](https://github.com/XTLS/Xray-core) with the server as
     the only outbound (VLESS REALITY or Hysteria);
   - fetches `https://www.gstatic.com/generate_204` through it and expects
     HTTP 204;
3. posts all results back and waits for the next job.

It needs no inbound ports. It only knows the bot URL and its own token. The
job carries the proxy configs of a dedicated probe user, which is what xray
needs to connect. Nothing else from the bot or the panel reaches the agent.

## protocol

Every request carries `Authorization: Bearer <agent token>`.

| method | path | |
|---|---|---|
| `GET` | `/probe/jobs/next?wait=<s>` | long-poll: `200` job, `204` nothing within `wait` (max 30s) |
| `POST` | `/probe/reports` | `{jobId, xrayVersion, results}`, answers `204` |

The models live in [`lib/protocol.dart`](lib/protocol.dart); the bot uses the
same package, so both sides share one definition.

## running

Get a token from the bot admin (`/agent_add <name>`), then:

```sh
docker run -d --name privan-probe-agent --restart unless-stopped \
  -e PROBE_API_URL=https://api.privan.network \
  -e PROBE_AGENT_TOKEN=<token> \
  ghcr.io/tangenx/privan-probe-agent
```

or with compose:

```yaml
services:
  probe-agent:
    image: ghcr.io/tangenx/privan-probe-agent
    restart: unless-stopped
    environment:
      PROBE_API_URL: https://api.privan.network
      PROBE_AGENT_TOKEN: <token>
```

| env | |
|---|---|
| `PROBE_API_URL` | bot HTTP API origin (required) |
| `PROBE_AGENT_TOKEN` | agent token from `/agent_add` (required) |
| `PROBE_AGENT_LOG_DIR` | xray configs and logs of failed runs, kept 2 days (default `/var/lib/probe-agent/xray`) |
| `XRAY_BINARY` | xray executable (default `xray` from `PATH`) |

The image runs as an unprivileged user. ICMP works through docker's default
`net.ipv4.ping_group_range`, so the container needs no extra capabilities.

## image

CI ([`.github/workflows/image.yml`](.github/workflows/image.yml)) builds
`linux/amd64` and `linux/arm64` images: xray v26.3.27, iputils-ping, and the
agent compiled with `dart build cli`. Pushes to `main` publish `latest`, tags
`vX.Y.Z` publish versions, and every image gets a signed build provenance
attestation. To check that an image was built by this repository's workflow:

```sh
gh attestation verify oci://ghcr.io/tangenx/privan-probe-agent:latest --owner tangenx
```

Manual multi-arch build and push:

```sh
docker login ghcr.io -u <user>   # token with write:packages
IMAGE=ghcr.io/<user>/privan-probe-agent scripts/publish.sh
```

Local run without docker (needs `xray` in `PATH`):

```sh
dart pub get
PROBE_API_URL=... PROBE_AGENT_TOKEN=... PROBE_AGENT_LOG_DIR=/tmp/probe-xray \
  dart run bin/probe_agent.dart
```

## license

[AGPL-3.0-only](LICENSE). Copyright (C) 2026 tangenx <me@tangenx.dev>.

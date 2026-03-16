# Cloudflare Tunnel Setup

This directory contains the files used by the `cloudflared` sidecar in the Podman pod.

The automation is handled by `cloudflared.sh`, which:

1. Verifies that the host `cloudflared` CLI is installed and logged in.
2. Creates or reuses a tunnel.
3. Ensures the DNS route exists for the requested hostname.
4. Syncs the tunnel credentials JSON into this directory.
5. Writes `config.yml` for the `cloudflared` container.

## Files In This Directory

- `cloudflared.sh`: setup and delete helper for the tunnel.
- `config.yml`: generated config consumed by the `cloudflared` container.
- `<TUNNEL_UUID>.json`: tunnel credentials copied from `~/.cloudflared/`.

## Typical Usage

You normally do not need to run `cloudflared.sh` directly because `setup_tfe.sh` calls it for you.

If you want to run it by itself:

```bash
./tfe/cloudflared/cloudflared.sh --hostname tfe5.munnep.com --tunnel-name tfe5-munnep-com
```

To remove the DNS route, tunnel, and local config artifacts:

```bash
./tfe/cloudflared/cloudflared.sh --hostname tfe5.munnep.com --tunnel-name tfe5-munnep-com --delete
```

## Generated Config

The script writes `config.yml` in this directory with the current tunnel ID and ingress settings. A typical file looks like this:

```yaml
tunnel: <TUNNEL_UUID>
credentials-file: /etc/cloudflared/creds/<TUNNEL_UUID>.json

originRequest:
  noTLSVerify: true
  originServerName: tfe5.munnep.com
  tlsTimeout: 30s

ingress:
  - hostname: tfe5.munnep.com
    service: https://127.0.0.1:8443
  - service: http_status:404
```

## Podman Mounting

The generated pod spec mounts this host directory:

```text
tfe/cloudflared
```

into the container at:

```text
/etc/cloudflared/creds
```

and mounts `config.yml` separately at:

```text
/etc/cloudflared/config.yml
```

That is why the credentials file in `config.yml` points to `/etc/cloudflared/creds/<TUNNEL_UUID>.json`.

## Verification

Useful commands:

```bash
cloudflared tunnel list
podman ps --format '{{.Names}}\t{{.Status}}'
podman logs -f terraform-enterprise-cloudflared
```

The tunnel is healthy when the sidecar starts without credential, config, or DNS routing errors.
# Cloudflare Tunnel Setup

This machine already has the `cloudflared` command installed.

This setup creates a Cloudflare tunnel for `tfe5.munnep.com` and connects it to
the `cloudflared` sidecar defined in [compose.yaml](/Users/patrick/git/tfe_fdo_lima_mounted_disk/tfe/compose.yaml).

## What Gets Created

Running `cloudflared tunnel create <name>` creates:

- a tunnel in your Cloudflare account
- a tunnel UUID
- a credentials file named `<TUNNEL_UUID>.json`

By default, the credentials file is written under `~/.cloudflared/` on the host.

## Create The Tunnel

Pick a tunnel name:

```bash
cloudflared tunnel create tfe5-munnep-com
```

Example output looks like this:

```text
Tunnel credentials written to /Users/<you>/.cloudflared/<TUNNEL_UUID>.json
Created tunnel tfe5-munnep-com with id <TUNNEL_UUID>
```

Save the tunnel UUID from that output.

## Create The DNS Route

Create the DNS route in Cloudflare so `tfe5.munnep.com` points to the tunnel:

```bash
cloudflared tunnel route dns tfe5-munnep-com tfe5.munnep.com
```

You can also use the tunnel UUID instead of the tunnel name.

## Copy The Credentials File Into This Project

Copy the generated credentials JSON into this directory:

```bash
cp ~/.cloudflared/<TUNNEL_UUID>.json /Users/patrick/git/tfe_fdo_lima_mounted_disk/tfe/cloudflared/
```

After this, you should have a file like:

```text
/Users/patrick/git/tfe_fdo_lima_mounted_disk/tfe/cloudflared/<TUNNEL_UUID>.json
```

## Update The Tunnel Config Used By Docker

Edit [config.yml](/Users/patrick/git/tfe_fdo_lima_mounted_disk/tfe/cloudflared/config.yml) and replace both placeholders:

- `REPLACE_WITH_TUNNEL_UUID`
- `REPLACE_WITH_TUNNEL_UUID.json`

The final file should look like this shape:

```yaml
tunnel: <TUNNEL_UUID>
credentials-file: /etc/cloudflared/creds/<TUNNEL_UUID>.json

originRequest:
	noTLSVerify: true
	originServerName: tfe5.munnep.com
	tlsTimeout: 30s

ingress:
	- hostname: tfe5.munnep.com
		service: https://tfe:443
	- service: http_status:404
```

## Why `/etc/cloudflared/creds/...` Is Correct

In [compose.yaml](/Users/patrick/git/tfe_fdo_lima_mounted_disk/tfe/compose.yaml), this host directory:

```text
/Users/patrick/git/tfe_fdo_lima_mounted_disk/tfe/cloudflared
```

is mounted into the container as:

```text
/etc/cloudflared/creds
```

So the JSON file must exist on the host in `tfe/cloudflared/`, and inside the container it will appear under `/etc/cloudflared/creds/`.

## Start The Stack

From the VM, in `/opt/tfe`, start the stack:

```bash
docker compose up -d
```

Or if your systemd service is already wired for Terraform Enterprise, restart it:

```bash
sudo systemctl restart terraform-enterprise
```

## Check The Tunnel Logs

To see whether `cloudflared` connected successfully:

```bash
docker compose logs -f cloudflared
```

You want to see the tunnel start without config or credential errors.

## Quick Verification

Check the local files:

```bash
ls -la /Users/patrick/git/tfe_fdo_lima_mounted_disk/tfe/cloudflared
```

Check the current tunnels on the host:

```bash
cloudflared tunnel list
```

## Summary

The host `cloudflared` CLI creates the tunnel and the credentials JSON.
The Docker `cloudflared` container does not create the tunnel by itself. It only runs the connector using the config and credentials you provide.
#!/usr/bin/env bash
set -Eeuo pipefail

# This script bootstraps Cloudflare Tunnel for local TFE use.
# It verifies cloudflared auth, creates or reuses a tunnel,
# ensures DNS routing, syncs the credentials JSON into this repo,
# and writes config.yml for the cloudflared sidecar.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yml"
LOCAL_CRED_DIR="${SCRIPT_DIR}"
HOSTNAME="tfe5.munnep.com"
TUNNEL_NAME="tfe5-munnep-com"
ORIGIN_SERVICE="https://127.0.0.1:8443"
CONTAINER_CREDS_DIR="/etc/cloudflared/creds"
NO_TLS_VERIFY="true"
NON_INTERACTIVE="false"
DELETE_MODE="false"

log() {
	printf '[cloudflared-setup] %s\n' "$*" >&2
}

die() {
	printf '[cloudflared-setup] ERROR: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
Usage: ./cloudflared.sh [options]

Options:
	--hostname <fqdn>          Public hostname to route through tunnel.
	--tunnel-name <name>       Tunnel name (created if missing).
	--service <url>            Origin service URL for ingress.
	--config-file <path>       Config file output path.
	--local-cred-dir <path>    Host directory to store tunnel credentials JSON.
	--container-cred-dir <p>   Container path where credentials are mounted.
	--delete                   Delete DNS route, tunnel, and local artifacts.
	--non-interactive          Do not trigger cloudflared login flow.
	-h, --help                 Show this help.

Examples:
	./cloudflared.sh
	./cloudflared.sh --hostname tfe5.munnep.com --tunnel-name tfe5-munnep-com
	./cloudflared.sh --service https://tfe:443
	./cloudflared.sh --delete
EOF
}

# Parse optional CLI overrides for hostname, tunnel, paths, and service target.
while [[ $# -gt 0 ]]; do
	case "$1" in
		--hostname)
			[[ $# -ge 2 ]] || die "Missing value for --hostname"
			HOSTNAME="$2"
			shift 2
			;;
		--tunnel-name)
			[[ $# -ge 2 ]] || die "Missing value for --tunnel-name"
			TUNNEL_NAME="$2"
			shift 2
			;;
		--service)
			[[ $# -ge 2 ]] || die "Missing value for --service"
			ORIGIN_SERVICE="$2"
			shift 2
			;;
		--config-file)
			[[ $# -ge 2 ]] || die "Missing value for --config-file"
			CONFIG_FILE="$2"
			shift 2
			;;
		--local-cred-dir)
			[[ $# -ge 2 ]] || die "Missing value for --local-cred-dir"
			LOCAL_CRED_DIR="$2"
			shift 2
			;;
		--container-cred-dir)
			[[ $# -ge 2 ]] || die "Missing value for --container-cred-dir"
			CONTAINER_CREDS_DIR="$2"
			shift 2
			;;
		--non-interactive)
			NON_INTERACTIVE="true"
			shift
			;;
		--delete)
			DELETE_MODE="true"
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "Unknown argument: $1"
			;;
	esac
done

# Validate required local dependencies and prepare output directory.
command -v cloudflared >/dev/null 2>&1 || die "cloudflared is not installed or not in PATH"
mkdir -p "${LOCAL_CRED_DIR}"

HOST_CF_DIR="${HOME}/.cloudflared"
HOST_CERT_FILE="${HOST_CF_DIR}/cert.pem"

# Ensure the local cloudflared login cert exists before tunnel operations.
ensure_cloudflared_login() {
	if [[ -f "${HOST_CERT_FILE}" ]]; then
		return 0
	fi

	if [[ "${NON_INTERACTIVE}" == "true" ]]; then
		die "No cloudflared cert file found at ${HOST_CERT_FILE}. Run 'cloudflared tunnel login' first."
	fi

	log "cloudflared is not logged in yet. Starting login flow..."
	cloudflared tunnel login
	[[ -f "${HOST_CERT_FILE}" ]] || die "Login completed but ${HOST_CERT_FILE} was not created"
}

# Read an existing tunnel ID by tunnel name from cloudflared list output.
tunnel_id_from_list() {
	cloudflared tunnel list 2>/dev/null \
		| awk -v tunnel_name="${TUNNEL_NAME}" 'NR > 1 && $2 == tunnel_name {print $1; exit}'
}

# Create a new tunnel and parse the UUID from cloudflared output.
create_tunnel_and_get_id() {
	local create_output
	create_output="$(cloudflared tunnel create "${TUNNEL_NAME}" 2>&1)" || {
		printf '%s\n' "${create_output}" >&2
		die "Failed to create tunnel '${TUNNEL_NAME}'"
	}

	# cloudflared usually prints: Created tunnel <name> with id <uuid>
	local parsed_id
	parsed_id="$(printf '%s\n' "${create_output}" | sed -n 's/.* with id \([0-9a-f-]\{36\}\).*/\1/p' | head -n1)"
	[[ -n "${parsed_id}" ]] || die "Tunnel was created but tunnel ID could not be parsed"
	printf '%s\n' "${parsed_id}"
}

# Reuse existing tunnel when present, otherwise create one.
ensure_tunnel() {
	local id
	id="$(tunnel_id_from_list || true)"

	if [[ -z "${id}" ]]; then
		log "Tunnel '${TUNNEL_NAME}' not found. Creating it now..."
		id="$(create_tunnel_and_get_id)"
	else
		log "Tunnel '${TUNNEL_NAME}' already exists."
	fi

	printf '%s\n' "${id}"
}

# Ensure a usable credentials JSON exists in the local project directory.
ensure_credentials_file() {
	local tunnel_id="$1"
	local host_cred_file="${HOST_CF_DIR}/${tunnel_id}.json"
	local local_cred_file="${LOCAL_CRED_DIR}/${tunnel_id}.json"

	if [[ -f "${host_cred_file}" ]]; then
		cp "${host_cred_file}" "${local_cred_file}"
		log "Credential file synced to ${local_cred_file}"
	elif [[ -f "${local_cred_file}" ]]; then
		log "Credential file already present at ${local_cred_file}"
	else
		die "Missing tunnel credential JSON. Expected ${host_cred_file} or ${local_cred_file}"
	fi

	printf '%s\n' "${local_cred_file}"
}

# Configure DNS route for the hostname; treat "already exists" as success.
ensure_dns_route() {
	local tunnel_ref="$1"

	set +e
	local output
	output="$(cloudflared tunnel route dns --overwrite-dns "${tunnel_ref}" "${HOSTNAME}" 2>&1)"
	local rc=$?
	set -e

	if [[ ${rc} -eq 0 ]]; then
		log "DNS route configured: ${HOSTNAME} -> ${tunnel_ref}"
		return 0
	fi

	if printf '%s' "${output}" | grep -qiE 'already exists|is already configured'; then
		log "DNS route already exists for ${HOSTNAME}"
		return 0
	fi

	printf '%s\n' "${output}" >&2
	die "Failed to configure DNS route for ${HOSTNAME}"
}

# Generate the sidecar config file with ingress and TLS options.
write_config() {
	local tunnel_id="$1"
	local cred_basename
	cred_basename="${tunnel_id}.json"

	cat > "${CONFIG_FILE}" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${CONTAINER_CREDS_DIR}/${cred_basename}

originRequest:
  noTLSVerify: ${NO_TLS_VERIFY}
  originServerName: ${HOSTNAME}
  tlsTimeout: 30s

ingress:
  - hostname: ${HOSTNAME}
    service: ${ORIGIN_SERVICE}
  - service: http_status:404
EOF

	log "Wrote tunnel config to ${CONFIG_FILE}"
}

# Delete DNS route for the hostname. Missing routes are treated as success.
delete_dns_route() {
	set +e
	local output
	output="$(cloudflared tunnel route dns --delete "${HOSTNAME}" 2>&1)"
	local rc=$?
	set -e

	if [[ ${rc} -eq 0 ]]; then
		log "Deleted DNS route for ${HOSTNAME}"
		return 0
	fi

	if printf '%s' "${output}" | grep -qiE 'not found|no route|does not exist'; then
		log "No DNS route found for ${HOSTNAME}; nothing to delete"
		return 0
	fi

	printf '%s\n' "${output}" >&2
	die "Failed to delete DNS route for ${HOSTNAME}"
}

# Delete tunnel by ID. Missing tunnel is treated as success.
delete_tunnel() {
	local tunnel_id="$1"

	if [[ -z "${tunnel_id}" ]]; then
		log "Tunnel '${TUNNEL_NAME}' not found; nothing to delete"
		return 0
	fi

	set +e
	local output
	output="$(cloudflared tunnel delete --force "${tunnel_id}" 2>&1)"
	local rc=$?
	if [[ ${rc} -ne 0 ]]; then
		output="$(cloudflared tunnel delete "${tunnel_id}" 2>&1)"
		rc=$?
	fi
	set -e

	if [[ ${rc} -eq 0 ]]; then
		log "Deleted tunnel ${TUNNEL_NAME} (${tunnel_id})"
		return 0
	fi

	if printf '%s' "${output}" | grep -qiE 'not found|does not exist'; then
		log "Tunnel already absent"
		return 0
	fi

	printf '%s\n' "${output}" >&2
	die "Failed to delete tunnel ${TUNNEL_NAME} (${tunnel_id})"
}

# Remove local and host credential JSON artifacts for the tunnel.
cleanup_credential_files() {
	local tunnel_id="$1"

	if [[ -n "${tunnel_id}" ]]; then
		rm -f "${LOCAL_CRED_DIR}/${tunnel_id}.json" "${HOST_CF_DIR}/${tunnel_id}.json"
		log "Removed credential files for tunnel ID ${tunnel_id}"
	else
		log "No tunnel ID resolved; skipped credential file deletion"
	fi
}

# Remove generated config file from this project directory.
cleanup_config_file() {
	rm -f "${CONFIG_FILE}"
	log "Removed config file ${CONFIG_FILE}"
}

# Full teardown flow: DNS route, tunnel, and local artifacts.
delete_flow() {
	local tunnel_id
	tunnel_id="$(tunnel_id_from_list || true)"

	if [[ -z "${tunnel_id}" && -f "${CONFIG_FILE}" ]]; then
		tunnel_id="$(awk '/^tunnel:/ {print $2; exit}' "${CONFIG_FILE}")"
	fi

	log "Verifying cloudflared local setup for delete operations..."
	ensure_cloudflared_login

	log "Deleting DNS route if present..."
	delete_dns_route

	log "Deleting tunnel if present..."
	delete_tunnel "${tunnel_id}"

	log "Cleaning local credential and config artifacts..."
	cleanup_credential_files "${tunnel_id}"
	cleanup_config_file

	cat <<EOF

Delete complete.

Tunnel Name: ${TUNNEL_NAME}
Hostname:    ${HOSTNAME}

Removed:
1) DNS route for ${HOSTNAME} (if present)
2) Tunnel ${TUNNEL_NAME} (if present)
3) Local credentials JSON in ${LOCAL_CRED_DIR}
4) Config file ${CONFIG_FILE}
EOF
}

# Execute setup flow in safe order and print actionable summary.
main() {
	if [[ "${DELETE_MODE}" == "true" ]]; then
		delete_flow
		return 0
	fi

	log "Verifying cloudflared local setup..."
	ensure_cloudflared_login

	log "Ensuring tunnel exists..."
	local tunnel_id
	tunnel_id="$(ensure_tunnel)"

	log "Ensuring local credentials file exists..."
	ensure_credentials_file "${tunnel_id}" >/dev/null

	log "Ensuring DNS route exists..."
	ensure_dns_route "${tunnel_id}"

	log "Updating config file..."
	write_config "${tunnel_id}"

	cat <<EOF

Setup complete.

Tunnel Name: ${TUNNEL_NAME}
Tunnel ID:   ${tunnel_id}
Hostname:    ${HOSTNAME}
Config File: ${CONFIG_FILE}

Next steps:
1) Ensure your podman volume mount includes ${LOCAL_CRED_DIR} -> ${CONTAINER_CREDS_DIR}
2) Restart the pod: podman kube play --replace tfe/compose.yaml
3) Check connector logs: podman logs -f terraform-enterprise-cloudflared
EOF
}

main "$@"

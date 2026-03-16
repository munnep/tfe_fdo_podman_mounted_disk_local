#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_SCRIPT="${ROOT_DIR}/tfe/certs/certs.sh"
CLOUDFLARED_SCRIPT="${ROOT_DIR}/tfe/cloudflared/cloudflared.sh"
COMPOSE_TEMPLATE="${ROOT_DIR}/tfe/compose_tfe.template"
COMPOSE_FILE="${ROOT_DIR}/tfe/compose.yaml"
CERTS_DIR="${ROOT_DIR}/tfe/certs"
INITIAL_USER_PAYLOAD="${ROOT_DIR}/tfe/tfe_initial_user.json"
ORG_PAYLOAD="${ROOT_DIR}/tfe/tfe_create_organization.json"
INITIAL_USER_OUTPUT="${ROOT_DIR}/tfe/tfe_initial_user_output.json"
ORG_OUTPUT="${ROOT_DIR}/tfe/tfe_create_organization_output.json"
TFE_CONTAINER_NAME="terraform-enterprise-terraform-enterprise"

HOSTNAME=""
TUNNEL_NAME=""
ORIGIN_SERVICE="https://127.0.0.1:8443"
DELETE_MODE="false"
RENDER_ONLY="false"
START_POD="true"
BOOTSTRAP="false"
NON_INTERACTIVE="false"
VALID_DAYS="365"
TFE_VERSION="1.2.0"

log() {
	printf '[setup-tfe] %s\n' "$*"
}

die() {
	printf '[setup-tfe] ERROR: %s\n' "$*" >&2
	exit 1
}

date_to_epoch() {
	local timestamp="$1"

	if date -j -u -f "%b %e %T %Y %Z" "${timestamp}" "+%s" >/dev/null 2>&1; then
		date -j -u -f "%b %e %T %Y %Z" "${timestamp}" "+%s"
		return 0
	fi

	date -u -d "${timestamp}" "+%s"
}

usage() {
	cat <<'EOF'
Usage: ./setup_tfe.sh --hostname <fqdn> [options]

Options:
	--hostname <fqdn>      Required DNS name for certs and tunnel.
	--tunnel-name <name>   Optional tunnel name. Default: hostname with dots replaced by dashes.
	--service <url>        Origin service for cloudflared ingress.
	--days <days>          Certificate validity period in days. Default: 365.
	--tfe-version <tag>    Terraform Enterprise image tag. Default: 1.2.0.
	--render-only          Only render tfe/compose.yaml from the template.
	--no-start             Do not start podman pod after setup.
	--bootstrap            Finalize setup: wait for TFE, create initial user, create org.
	--initial-user-json    Payload file for initial admin user API call.
	--organization-json    Payload file for organization creation API call.
	--delete               Delete tunnel + DNS route + local cloudflared artifacts.
	--non-interactive      Do not trigger cloudflared login flow.
	-h, --help             Show this help.

Examples:
	./setup_tfe.sh --hostname tfe5.munnep.com
	./setup_tfe.sh --hostname tfe5.munnep.com --tfe-version 1.1.0
	./setup_tfe.sh --hostname tfe5.munnep.com --tunnel-name tfe5-munnep-com
	./setup_tfe.sh --hostname tfe5.munnep.com --render-only
	./setup_tfe.sh --hostname tfe5.munnep.com --no-start
	./setup_tfe.sh --hostname tfe5.munnep.com --bootstrap
	./setup_tfe.sh --hostname tfe5.munnep.com --delete
EOF
}

wait_for_tfe_ready() {
	command -v curl >/dev/null 2>&1 || die "curl is required for bootstrap"

	log "Waiting for TFE endpoint to be ready: https://${HOSTNAME}/admin"
	while true; do
		local code
		code="$(curl -ksSI --max-time 20 -o /dev/null -w "%{http_code}" "https://${HOSTNAME}/admin" || true)"
		if [[ "${code}" == "200" || "${code}" == "301" ]]; then
			log "TFE is available (HTTP ${code}). Waiting 60s before bootstrap calls"
			sleep 60
			return 0
		fi

		log "TFE not ready yet (HTTP ${code:-n/a}). Retrying in 30s"
		sleep 30
	done
}

wait_for_certificate_validity() {
	command -v openssl >/dev/null 2>&1 || die "openssl is required for certificate validation"

	local cert_file="${CERTS_DIR}/bundle.pem"
	[[ -f "${cert_file}" ]] || die "Missing certificate bundle: ${cert_file}"

	local not_before
	not_before="$(openssl x509 -in "${cert_file}" -noout -startdate | cut -d= -f2-)"
	[[ -n "${not_before}" ]] || die "Could not read certificate start date from ${cert_file}"

	local cert_epoch
	local current_epoch
	cert_epoch="$(date_to_epoch "${not_before}")"
	current_epoch="$(date -u "+%s")"

	if (( current_epoch >= cert_epoch )); then
		log "Generated certificate is already valid"
		return 0
	fi

	local wait_seconds=$(( cert_epoch - current_epoch + 1 ))
	log "Generated certificate becomes valid at ${not_before}; waiting ${wait_seconds}s before starting Podman"
	sleep "${wait_seconds}"
}

bootstrap_tfe() {
	command -v podman >/dev/null 2>&1 || die "podman is required for bootstrap"
	command -v jq >/dev/null 2>&1 || die "jq is required for bootstrap"

	[[ -f "${INITIAL_USER_PAYLOAD}" ]] || die "Missing initial user payload: ${INITIAL_USER_PAYLOAD}"
	[[ -f "${ORG_PAYLOAD}" ]] || die "Missing organization payload: ${ORG_PAYLOAD}"

	wait_for_tfe_ready

	log "Getting initial activation token from ${TFE_CONTAINER_NAME}"
	local initial_token
	initial_token="$(podman exec "${TFE_CONTAINER_NAME}" tfectl admin token | tr -d '\r' | tail -n 1)"
	[[ -n "${initial_token}" ]] || die "Could not retrieve initial activation token"

	log "Creating initial admin user"
	curl -ksS \
		--header "Content-Type: application/json" \
		--request POST \
		--data @"${INITIAL_USER_PAYLOAD}" \
		--url "https://${HOSTNAME}/admin/initial-admin-user?token=${initial_token}" \
		| tee "${INITIAL_USER_OUTPUT}" >/dev/null

	local admin_token
	admin_token="$(jq -e -r '.token // empty' "${INITIAL_USER_OUTPUT}" 2>/dev/null || true)"
	[[ -n "${admin_token}" ]] || die "Failed to parse admin token from ${INITIAL_USER_OUTPUT}"

	log "Creating organization from ${ORG_PAYLOAD}"
	local org_http
	org_http="$(curl -ksS \
		--header "Authorization: Bearer ${admin_token}" \
		--header "Content-Type: application/vnd.api+json" \
		--request POST \
		--data @"${ORG_PAYLOAD}" \
		--output "${ORG_OUTPUT}" \
		--write-out "%{http_code}" \
		"https://${HOSTNAME}/api/v2/organizations")"

	if [[ "${org_http}" != "200" && "${org_http}" != "201" ]]; then
		die "Organization creation failed with HTTP ${org_http}. See ${ORG_OUTPUT}"
	fi

	log "Bootstrap completed"
}

render_compose_file() {
	[[ -f "${COMPOSE_TEMPLATE}" ]] || die "Missing compose template: ${COMPOSE_TEMPLATE}"

	local rendered
	rendered="$(<"${COMPOSE_TEMPLATE}")"
	rendered="${rendered//__TFE_HOSTNAME__/${HOSTNAME}}"
	rendered="${rendered//__TFE_VERSION__/${TFE_VERSION}}"
	rendered="${rendered//__PROJECT_ROOT__/${ROOT_DIR}}"
	printf '%s\n' "${rendered}" > "${COMPOSE_FILE}"
	log "Rendered compose file ${COMPOSE_FILE} from template"
}

delete_podman_stack() {
	if ! command -v podman >/dev/null 2>&1; then
		log "podman not found; skipping pod teardown"
		return 0
	fi

	if [[ ! -f "${COMPOSE_FILE}" ]]; then
		log "Compose file ${COMPOSE_FILE} not present; skipping pod teardown"
		return 0
	fi

	set +e
	local output
	output="$(cd "${ROOT_DIR}" && podman kube down tfe/compose.yaml 2>&1)"
	local rc=$?
	set -e

	if [[ ${rc} -eq 0 ]]; then
		log "Podman stack removed"
		return 0
	fi

	if printf '%s' "${output}" | grep -qiE 'no such pod|not found|no resources'; then
		log "Podman stack already absent"
		return 0
	fi

	printf '%s\n' "${output}" >&2
	die "Failed to remove podman stack"
}

delete_cert_files() {
	rm -f \
		"${CERTS_DIR}/cert.pem" \
		"${CERTS_DIR}/bundle.pem" \
		"${CERTS_DIR}/key.pem"
	log "Removed generated certificate files from ${CERTS_DIR}"
}

start_podman_stack() {
	command -v podman >/dev/null 2>&1 || die "podman is not installed or not in PATH"
	[[ -f "${COMPOSE_FILE}" ]] || die "Compose file ${COMPOSE_FILE} not found"

	set +e
	local output
	output="$(cd "${ROOT_DIR}" && podman kube play --replace tfe/compose.yaml 2>&1)"
	local rc=$?
	set -e

	if [[ ${rc} -eq 0 ]]; then
		log "Podman stack started"
		printf '%s\n' "${output}"
		return 0
	fi

	printf '%s\n' "${output}" >&2
	die "Failed to start podman stack"
}

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
		--days)
			[[ $# -ge 2 ]] || die "Missing value for --days"
			VALID_DAYS="$2"
			shift 2
			;;
		--tfe-version)
			[[ $# -ge 2 ]] || die "Missing value for --tfe-version"
			TFE_VERSION="$2"
			shift 2
			;;
		--render-only)
			RENDER_ONLY="true"
			shift
			;;
		--no-start)
			START_POD="false"
			shift
			;;
		--bootstrap)
			BOOTSTRAP="true"
			shift
			;;
		--initial-user-json)
			[[ $# -ge 2 ]] || die "Missing value for --initial-user-json"
			INITIAL_USER_PAYLOAD="$2"
			shift 2
			;;
		--organization-json)
			[[ $# -ge 2 ]] || die "Missing value for --organization-json"
			ORG_PAYLOAD="$2"
			shift 2
			;;
		--delete)
			DELETE_MODE="true"
			shift
			;;
		--non-interactive)
			NON_INTERACTIVE="true"
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

[[ -n "${HOSTNAME}" ]] || die "--hostname is required"

if [[ -z "${TUNNEL_NAME}" ]]; then
	TUNNEL_NAME="${HOSTNAME//./-}"
fi


LICENSE_FILE="${ROOT_DIR}/license_location/license.pem"
[[ -f "${CERTS_SCRIPT}" ]] || die "Missing script: ${CERTS_SCRIPT}"
[[ -f "${CLOUDFLARED_SCRIPT}" ]] || die "Missing script: ${CLOUDFLARED_SCRIPT}"
[[ -f "${COMPOSE_TEMPLATE}" ]] || die "Missing compose template: ${COMPOSE_TEMPLATE}"
[[ -f "${LICENSE_FILE}" ]] || die "Missing license file: ${LICENSE_FILE}. Please place your TFE license at this path."

if [[ "${DELETE_MODE}" == "true" ]]; then
	log "Removing podman stack if present"
	delete_podman_stack

	log "Removing generated certificates"
	delete_cert_files

	log "Running cloudflared delete flow for ${HOSTNAME}"
	bash "${CLOUDFLARED_SCRIPT}" \
		--hostname "${HOSTNAME}" \
		--tunnel-name "${TUNNEL_NAME}" \
		--service "${ORIGIN_SERVICE}" \
		--delete \
		$( [[ "${NON_INTERACTIVE}" == "true" ]] && printf '%s' '--non-interactive' )
	log "Delete flow complete."
	exit 0
fi

log "Rendering compose.yaml for ${HOSTNAME}"
render_compose_file

if [[ "${RENDER_ONLY}" == "true" ]]; then
	log "Render-only mode complete."
	exit 0
fi

log "Generating certificates for ${HOSTNAME}"
bash "${CERTS_SCRIPT}" --hostname "${HOSTNAME}" --days "${VALID_DAYS}"

log "Checking certificate validity window"
wait_for_certificate_validity

log "Configuring cloudflared tunnel for ${HOSTNAME}"
bash "${CLOUDFLARED_SCRIPT}" \
	--hostname "${HOSTNAME}" \
	--tunnel-name "${TUNNEL_NAME}" \
	--service "${ORIGIN_SERVICE}" \
	$( [[ "${NON_INTERACTIVE}" == "true" ]] && printf '%s' '--non-interactive' )

if [[ "${START_POD}" == "true" ]]; then
	log "Starting podman stack"
	start_podman_stack
else
	log "Skipping podman startup due to --no-start"
fi

if [[ "${BOOTSTRAP}" == "true" ]]; then
	log "Running bootstrap phase"
	bootstrap_tfe
else
	log "Skipping bootstrap phase"
fi

cat <<EOF

Setup complete.

Hostname:    ${HOSTNAME}
Tunnel Name: ${TUNNEL_NAME}
Compose File: ${COMPOSE_FILE}
Cert Script: ${CERTS_SCRIPT}
Tunnel Script: ${CLOUDFLARED_SCRIPT}
TFE Version: ${TFE_VERSION}
Podman Start: ${START_POD}
Bootstrap: ${BOOTSTRAP}
EOF

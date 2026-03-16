#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Certificate identity configuration.
DOMAIN="tfe5.munnep.com"
CA_SUBJECT="/C=CN/ST=GD/L=SZ/O=PATJE, Inc./CN=PATJE CA"
VALID_DAYS="365"

# Output paths.
CA_KEY="${SCRIPT_DIR}/ca.key"
CA_CERT="${SCRIPT_DIR}/ca.crt"
SERVER_KEY="${SCRIPT_DIR}/key.pem"
SERVER_CSR="${SCRIPT_DIR}/server.csr"
SERVER_CERT="${SCRIPT_DIR}/server.crt"
CERT_PEM="${SCRIPT_DIR}/cert.pem"
BUNDLE_PEM="${SCRIPT_DIR}/bundle.pem"

format_cert_time() {
	local offset_days="$1"
	local offset_spec

	if [[ "${offset_days}" == [+-]* ]]; then
		offset_spec="${offset_days}d"
	else
		offset_spec="+${offset_days}d"
	fi

	if date -u -v"${offset_spec}" "+%Y%m%d%H%M%SZ" >/dev/null 2>&1; then
		date -u -v"${offset_spec}" "+%Y%m%d%H%M%SZ"
		return 0
	fi

	date -u -d "${offset_days} days" "+%Y%m%d%H%M%SZ"
}

usage() {
	cat <<'EOF'
Usage: ./certs.sh [options]

Options:
	--hostname <fqdn>   DNS name for certificate CN and SAN.
	--days <days>       Certificate validity period. Default: 365.
	-h, --help          Show this help.

Example:
	./certs.sh --hostname tfe5.munnep.com
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--hostname)
			[[ $# -ge 2 ]] || { echo "Missing value for --hostname" >&2; exit 1; }
			DOMAIN="$2"
			shift 2
			;;
		--days)
			[[ $# -ge 2 ]] || { echo "Missing value for --days" >&2; exit 1; }
			VALID_DAYS="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown argument: $1" >&2
			exit 1
			;;
	esac
done

SERVER_SUBJECT="/C=CN/ST=GD/L=SZ/O=PATJE, Inc./CN=${DOMAIN}"
NOT_BEFORE="$(format_cert_time -1)"
NOT_AFTER="$(format_cert_time "${VALID_DAYS}")"

echo "Generating CA key and certificate..."
openssl genrsa -out "${CA_KEY}" 2048
openssl req -new -x509 \
	-key "${CA_KEY}" \
	-not_before "${NOT_BEFORE}" \
	-not_after "${NOT_AFTER}" \
	-subj "${CA_SUBJECT}" \
	-out "${CA_CERT}"

echo "Generating server key and CSR..."
openssl req -newkey rsa:2048 -nodes \
	-keyout "${SERVER_KEY}" \
	-subj "${SERVER_SUBJECT}" \
	-out "${SERVER_CSR}"

echo "Signing server certificate with CA..."
openssl x509 -req \
	-in "${SERVER_CSR}" \
	-CA "${CA_CERT}" \
	-CAkey "${CA_KEY}" \
	-CAcreateserial \
	-not_before "${NOT_BEFORE}" \
	-not_after "${NOT_AFTER}" \
	-extfile <(printf "subjectAltName=DNS:%s" "${DOMAIN}") \
	-out "${SERVER_CERT}"

echo "Building full-chain outputs..."
cat "${SERVER_CERT}" "${CA_CERT}" > "${CERT_PEM}"
cat "${SERVER_CERT}" "${CA_CERT}" > "${BUNDLE_PEM}"

echo "Cleaning temporary files..."
rm -f "${SERVER_CSR}" "${SERVER_CERT}" "${CA_CERT}" "${CA_KEY}" "${SCRIPT_DIR}/ca.srl"

echo "Done. Generated files: ${SERVER_KEY}, ${CERT_PEM}, ${BUNDLE_PEM}"

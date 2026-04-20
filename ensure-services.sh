#!/usr/bin/env bash
set -euo pipefail

# ensure-services.sh
# Garantiza que los servicios systemd cruciales (cloudflared, ttyd y filebrowser)
# estén habilitados y activos. Permite añadir servicios extra como argumentos y
# admite un modo --dry-run para validar sin aplicar cambios.

DRY_RUN=0
FORCE_RESTART=0
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TTYD_PORT="${TTYD_PORT:-3000}"
FILEBROWSER_PORT="${FILEBROWSER_PORT:-8080}"
INVOKER_USER="${SUDO_USER:-}"
USER_HOME=""
CLOUDFLARE_CONFIG_PATH="${CLOUDFLARE_CONFIG_PATH:-}"

declare -a EXTRA_SERVICES=()
declare -a TARGET_SERVICES=()
declare -A SEEN_SERVICES=()
declare -a TTYD_TUNNELS=()
declare -a FILEBROWSER_TUNNELS=()
declare -a TTYD_TUNNEL_ENDPOINTS=()
declare -a FILEBROWSER_TUNNEL_ENDPOINTS=()
TTYD_AUTH_USER="${TTYD_AUTH_USER:-}"
TTYD_AUTH_PASSWORD="${TTYD_AUTH_PASSWORD:-}"
TTYD_AUTH_SOURCE=""

TTYD_BASE_PATH="${TTYD_BASE_PATH:-/ttyd}"
FILEBROWSER_BASEURL="${FILEBROWSER_BASEURL:-/files}"

LAST_CURL_STATUS=0
LAST_CURL_MESSAGE=""
ACTIVE_TUNNEL_CONFIG_VALUE=""
MANAGED_TUNNEL_INFO_FILE=""
MANAGED_TUNNEL_NAME=""
MANAGED_TUNNEL_ID=""
MANAGED_TUNNEL_CRED_FILE=""

function log() {
	printf '[ensure-services] %s\n' "$*"
}

function run_as_invoker() {
	if [[ $(id -u) -eq 0 && -n "${INVOKER_USER}" && "${INVOKER_USER}" != "root" ]]; then
		sudo -u "${INVOKER_USER}" -H "$@"
	else
		"$@"
	fi
}

function normalize_base_path() {
	local input="$1"
	if [[ -z "${input}" ]]; then
		echo "/"
		return
	fi
	if [[ "${input}" != /* ]]; then
		input="/${input}"
	fi
	if [[ "${input}" != "/" ]]; then
		input="${input%/}"
	fi
	echo "${input}"
}

function append_trailing_slash() {
	local path="$1"
	if [[ -z "${path}" || "${path}" == "/" ]]; then
		echo "/"
	else
		echo "${path}/"
	fi
}

function normalize_ingress_path() {
	local raw="$1"
	raw="${raw//\"/}"
	raw=$(echo "${raw}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	if [[ -z "${raw}" ]]; then
		echo ""
		return
	fi
	raw="${raw%%\*}"
	raw=$(normalize_base_path "${raw}")
	echo "${raw}"
}

TTYD_BASE_PATH=$(normalize_base_path "${TTYD_BASE_PATH}")
FILEBROWSER_BASEURL=$(normalize_base_path "${FILEBROWSER_BASEURL}")


function curl_check() {
	local url="$1"
	local desc="$2"
	local attempts="${3:-5}"
	local quiet_fail="${4:-0}"
	shift 4
	local curl_args=("$@")

	if [[ ${DRY_RUN} -eq 1 ]]; then
		log "[dry-run] Verificar ${desc} en ${url}"
		LAST_CURL_STATUS=0
		LAST_CURL_MESSAGE=""
		return 0
	fi

	local attempt
	local last_status=0
	local last_output=""
	for (( attempt=1; attempt<=attempts; attempt++ )); do
		last_output=$(curl --silent --show-error --fail --max-time 10 --connect-timeout 5 "${curl_args[@]}" -o /dev/null "${url}" 2>&1)
		last_status=$?
		if [[ ${last_status} -eq 0 ]]; then
			LAST_CURL_STATUS=0
			LAST_CURL_MESSAGE=""
			log "${desc}: acceso OK (${url})"
			return 0
		fi
		log "${desc}: intento ${attempt}/${attempts} fallido (${url})"
		if [[ -n "${last_output}" ]]; then
			log "    Detalle curl (código ${last_status}): ${last_output}"
		fi
		if (( attempt < attempts )); then
			sleep 2
		fi
	done

	LAST_CURL_STATUS=${last_status}
	LAST_CURL_MESSAGE="${last_output}"
	if [[ ${quiet_fail} -eq 0 ]]; then
		log "${desc}: no accesible (${url})"
		if [[ -n "${last_output}" ]]; then
			log "    Último error curl (código ${last_status}): ${last_output}"
		fi
	fi
	return 1
}

function command_exists() {
	command -v "$1" >/dev/null 2>&1
}

function infer_ttyd_credentials() {
	if [[ -n "${TTYD_AUTH_USER}" && -n "${TTYD_AUTH_PASSWORD}" ]]; then
		TTYD_AUTH_SOURCE="env"
		return
	fi

	if [[ -z "${TTYD_AUTH_USER}" || -z "${TTYD_AUTH_PASSWORD}" ]]; then
		local show_output creds
		show_output=$(SYSTEMD_PAGER='' systemctl show ttyd.service -p ExecStart 2>/dev/null || true)
		if [[ -n "${show_output}" ]]; then
			creds=$(echo "${show_output}" | sed -n 's/.*--credential[[:space:]]\+\([^[:space:]]\+\).*/\1/p')
			if [[ -n "${creds}" && "${creds}" == *":"* ]]; then
				local user_part="${creds%%:*}"
				local pass_part="${creds#*:}"
				if [[ -z "${TTYD_AUTH_USER}" ]]; then
					TTYD_AUTH_USER="${user_part}"
				fi
				if [[ -z "${TTYD_AUTH_PASSWORD}" ]]; then
					TTYD_AUTH_PASSWORD="${pass_part}"
				fi
				TTYD_AUTH_SOURCE="systemd"
			fi
		fi
	fi

	if [[ -z "${TTYD_AUTH_USER}" || -z "${TTYD_AUTH_PASSWORD}" ]]; then
		TTYD_AUTH_USER="${TTYD_AUTH_USER:-pi}"
		TTYD_AUTH_PASSWORD="${TTYD_AUTH_PASSWORD:-}"
		if [[ -z "${TTYD_AUTH_SOURCE}" ]]; then
			TTYD_AUTH_SOURCE="defaults"
		fi
	fi
}

function parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--dry-run)
				DRY_RUN=1
				;;
			--restart)
				FORCE_RESTART=1
				;;
			--help|-h)
				usage
				exit 0
				;;
			--)
				shift
				EXTRA_SERVICES+=("$@")
				break
				;;
			-*)
				echo "Opción desconocida: $1" >&2
				usage
				exit 1
				;;
			*)
				EXTRA_SERVICES+=("$1")
				;;
		esac
		shift
	done
}

function init_invoker_context() {
	if [[ -z "${INVOKER_USER}" ]]; then
		INVOKER_USER=$(logname 2>/dev/null || whoami)
	fi

	USER_HOME=$(getent passwd "${INVOKER_USER}" | cut -d: -f6 2>/dev/null || true)
	if [[ -z "${USER_HOME}" ]]; then
		USER_HOME="/home/${INVOKER_USER}"
	fi
	MANAGED_TUNNEL_INFO_FILE="${USER_HOME}/.cloudflared/managed-tunnel.json"

	if [[ -n "${CLOUDFLARE_CONFIG:-}" ]]; then
		CLOUDFLARE_CONFIG_PATH="${CLOUDFLARE_CONFIG}"
	elif [[ -n "${CLOUDFLARE_CONFIG_PATH}" && -f "${CLOUDFLARE_CONFIG_PATH}" ]]; then
		:
	else
		local candidates=(
			"/etc/cloudflared/config.yml"
			"${USER_HOME}/.cloudflared/config.yml"
			"${USER_HOME}/.config/cloudflared/config.yml"
		)
		for candidate in "${candidates[@]}"; do
			if [[ -f "${candidate}" ]]; then
				CLOUDFLARE_CONFIG_PATH="${candidate}"
				break
			fi
		done
	fi
}

function ensure_root() {
	if [[ ${DRY_RUN} -eq 1 ]]; then
		return
	fi
	if [[ $(id -u) -ne 0 ]]; then
		echo "Este script debe ejecutarse con privilegios de administrador (sudo)." >&2
		exit 1
	fi
}

function ensure_systemctl_available() {
	if ! command_exists systemctl; then
		echo "systemctl no está disponible en este sistema. Se requiere systemd." >&2
		exit 1
	fi
}

function ensure_required_tools() {
	if [[ ${DRY_RUN} -eq 1 ]]; then
		return
	fi
	if ! command_exists curl; then
		echo "Se requiere 'curl' para las comprobaciones HTTP." >&2
		exit 1
	fi
}

function add_service() {
	local svc="$1"
	[[ -z "${svc}" ]] && return
	if [[ -z "${SEEN_SERVICES[${svc}]:-}" ]]; then
		TARGET_SERVICES+=("${svc}")
		SEEN_SERVICES["${svc}"]=1
	fi
}

function unit_exists() {
	local svc="$1"
	local output status
	set +e
	output=$(systemctl list-unit-files "${svc}" --type=service --no-pager --no-legend 2>/dev/null)
	status=$?
	set -e
	if [[ ${status} -ne 0 ]]; then
		echo "${output}"
		return 1
	fi
	[[ -n "${output}" ]]
}

function enable_service() {
	local svc="$1"
	local state status
	set +e
	state=$(systemctl is-enabled "${svc}" 2>/dev/null)
	status=$?
	set -e

	if [[ ${status} -eq 0 && ${state} == "enabled" ]]; then
		log "${svc}: ya estaba habilitado."
		return 0
	fi

	if [[ ${state} == "static" ]]; then
		log "${svc}: unidad 'static'; no se habilita (esto es normal)."
		return 0
	fi

	if [[ ${DRY_RUN} -eq 1 ]]; then
		log "[dry-run] Habilitar ${svc}"
		return 0
	fi

	if ! systemctl enable "${svc}"; then
		log "${svc}: error al habilitar."
		return 1
	fi
	log "${svc}: habilitado."
	return 0
}

function start_or_restart_service() {
	local svc="$1"
	local active status

	set +e
	systemctl is-active "${svc}" >/dev/null 2>&1
	status=$?
	set -e

	if [[ ${FORCE_RESTART} -eq 1 ]]; then
		status=3
	fi

	if [[ ${status} -eq 0 ]]; then
		log "${svc}: ya está activo."
		return 0
	fi

	local action="start"
	if [[ ${FORCE_RESTART} -eq 1 ]]; then
		action="restart"
	elif [[ ${status} -eq 3 ]]; then
		action="restart"
	fi

	if [[ ${DRY_RUN} -eq 1 ]]; then
		log "[dry-run] ${action^} ${svc}"
		return 0
	fi

	if ! systemctl "${action}" "${svc}"; then
		log "${svc}: fallo en systemctl ${action}. Consultando estado..."
		systemctl status "${svc}" --no-pager || true
		return 1
	fi

	set +e
	systemctl is-active "${svc}" >/dev/null 2>&1
	active=$?
	set -e
	if [[ ${active} -ne 0 ]]; then
		log "${svc}: sigue inactivo tras intentar ${action}."
		systemctl status "${svc}" --no-pager || true
		return 1
	fi

	log "${svc}: ${action} correcto."
	return 0
}

function ensure_service_active() {
	local svc="$1"
	log "--- Gestionando ${svc} ---"

	if ! unit_exists "${svc}"; then
		log "${svc}: unidad no encontrada."
		case "${svc}" in
			ttyd.service)
				log "Sugerencia: ejecuta ${SCRIPT_DIR}/ensure-ttyd.sh para instalarlo."
				;;
			filebrowser.service)
				log "Sugerencia: ejecuta ${SCRIPT_DIR}/ensure-filebrowser.sh para instalarlo."
				;;
			cloudflared*.service)
				log "Sugerencia: crea o habilita un servicio cloudflared correspondiente (ver ensure-cloudflared-login.sh)."
				;;
		esac
		return 1
	fi

	local failures=0
	if ! enable_service "${svc}"; then
		failures=1
	fi
	if ! start_or_restart_service "${svc}"; then
		failures=1
	fi

	return ${failures}
}

function collect_tunnel_hostnames() {
	TTYD_TUNNELS=()
	FILEBROWSER_TUNNELS=()
	TTYD_TUNNEL_ENDPOINTS=()
	FILEBROWSER_TUNNEL_ENDPOINTS=()
	ACTIVE_TUNNEL_CONFIG_VALUE=""

	if [[ -z "${CLOUDFLARE_CONFIG_PATH}" || ! -f "${CLOUDFLARE_CONFIG_PATH}" ]]; then
		if [[ -n "${CLOUDFLARE_CONFIG_PATH}" ]]; then
			log "No se encontró archivo de configuración de cloudflared en ${CLOUDFLARE_CONFIG_PATH}."
		fi
		return
	fi

	local current_hostname=""
	local current_path=""
	while IFS= read -r raw_line; do
		local line
		line=$(echo "${raw_line}" | sed 's/^[[:space:]]*//')
		if [[ "${line}" == -* ]]; then
			line="${line#-}"
			line=$(echo "${line}" | sed 's/^[[:space:]]*//')
		fi
		if [[ -z "${line}" || "${line}" == \#* ]]; then
			continue
		fi
		case "${line}" in
			tunnel:*)
				if [[ -z "${ACTIVE_TUNNEL_CONFIG_VALUE}" ]]; then
					ACTIVE_TUNNEL_CONFIG_VALUE="${line#tunnel:}"
					ACTIVE_TUNNEL_CONFIG_VALUE="${ACTIVE_TUNNEL_CONFIG_VALUE//\"/}"
					ACTIVE_TUNNEL_CONFIG_VALUE=$(echo "${ACTIVE_TUNNEL_CONFIG_VALUE}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
				fi
				;;
			hostname:*)
				current_hostname="${line#hostname:}"
				current_hostname="${current_hostname//\"/}"
				current_hostname=$(echo "${current_hostname}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
				current_path=""
				;;
			path:*)
				current_path="${line#path:}"
				current_path=$(normalize_ingress_path "${current_path}")
				;;
			service:*)
				local service_value
				service_value="${line#service:}"
				service_value="${service_value//\"/}"
				service_value=$(echo "${service_value}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
				if [[ -n "${current_hostname}" ]]; then
					local endpoint_path="${current_path:-/}"
					if [[ "${service_value}" == http://localhost:${TTYD_PORT}* || "${service_value}" == http://127.0.0.1:${TTYD_PORT}* || "${service_value}" == https://localhost:${TTYD_PORT}* || "${service_value}" == https://127.0.0.1:${TTYD_PORT}* ]]; then
						if [[ " ${TTYD_TUNNELS[*]} " != *" ${current_hostname} "* ]]; then
							TTYD_TUNNELS+=("${current_hostname}")
						fi
						local ttyd_key="${current_hostname}|${endpoint_path}"
						local exists=0
						for existing in "${TTYD_TUNNEL_ENDPOINTS[@]}"; do
							if [[ "${existing}" == "${ttyd_key}" ]]; then
								exists=1
								break
							fi
						done
						if [[ ${exists} -eq 0 ]]; then
							TTYD_TUNNEL_ENDPOINTS+=("${ttyd_key}")
						fi
					elif [[ "${service_value}" == http://localhost:${FILEBROWSER_PORT}* || "${service_value}" == http://127.0.0.1:${FILEBROWSER_PORT}* || "${service_value}" == https://localhost:${FILEBROWSER_PORT}* || "${service_value}" == https://127.0.0.1:${FILEBROWSER_PORT}* ]]; then
						if [[ " ${FILEBROWSER_TUNNELS[*]} " != *" ${current_hostname} "* ]]; then
							FILEBROWSER_TUNNELS+=("${current_hostname}")
						fi
						local fb_key="${current_hostname}|${endpoint_path}"
						local fb_exists=0
						for existing in "${FILEBROWSER_TUNNEL_ENDPOINTS[@]}"; do
							if [[ "${existing}" == "${fb_key}" ]]; then
								fb_exists=1
								break
							fi
						done
						if [[ ${fb_exists} -eq 0 ]]; then
							FILEBROWSER_TUNNEL_ENDPOINTS+=("${fb_key}")
						fi
					fi
				fi
				current_hostname=""
				current_path=""
				;;
			*)
				;;
		esac
	done < "${CLOUDFLARE_CONFIG_PATH}"

	if [[ ${#TTYD_TUNNELS[@]} -gt 0 ]]; then
		local -a ttyd_print=()
		local endpoint
		for endpoint in "${TTYD_TUNNEL_ENDPOINTS[@]}"; do
			local host path
			IFS='|' read -r host path <<< "${endpoint}"
			if [[ -z "${path}" || "${path}" == "/" ]]; then
				ttyd_print+=("${host}/")
			else
				ttyd_print+=("${host}${path}")
			fi
		done
		log "Endpoints de túnel detectados para ttyd: ${ttyd_print[*]}"
	fi
	if [[ ${#FILEBROWSER_TUNNELS[@]} -gt 0 ]]; then
		local -a fb_print=()
		local fb_endpoint
		for fb_endpoint in "${FILEBROWSER_TUNNEL_ENDPOINTS[@]}"; do
			local host path
			IFS='|' read -r host path <<< "${fb_endpoint}"
			if [[ -z "${path}" || "${path}" == "/" ]]; then
				fb_print+=("${host}/")
			else
				fb_print+=("${host}${path}")
			fi
		done
		log "Endpoints de túnel detectados para filebrowser: ${fb_print[*]}"
	fi
}

function load_managed_tunnel_metadata() {
	if [[ -z "${MANAGED_TUNNEL_INFO_FILE}" || ! -f "${MANAGED_TUNNEL_INFO_FILE}" ]]; then
		return
	fi
	if ! command_exists python3; then
		return
	fi

	local result
	result=$(python3 - "${MANAGED_TUNNEL_INFO_FILE}" <<'PY'
import json
import sys

path = sys.argv[1]

try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)

print(str(data.get("name", "")))
print(str(data.get("id", "")))
print(str(data.get("credential_file", "")))
PY
	) || return

	local -a metadata
	mapfile -t metadata <<< "${result}"
	MANAGED_TUNNEL_NAME="${metadata[0]:-}"
	MANAGED_TUNNEL_ID="${metadata[1]:-}"
	MANAGED_TUNNEL_CRED_FILE="${metadata[2]:-}"
}

function get_tunnel_identifier() {
	if [[ -n "${ACTIVE_TUNNEL_CONFIG_VALUE}" ]]; then
		printf '%s' "${ACTIVE_TUNNEL_CONFIG_VALUE}"
		return 0
	fi
	if [[ -n "${MANAGED_TUNNEL_NAME}" ]]; then
		printf '%s' "${MANAGED_TUNNEL_NAME}"
		return 0
	fi
	if [[ -n "${MANAGED_TUNNEL_ID}" ]]; then
		printf '%s' "${MANAGED_TUNNEL_ID}"
		return 0
	fi
	return 1
}

function resolve_hostname() {
	local host="$1"
	if [[ -z "${host}" ]]; then
		return 1
	fi
	if command_exists dig; then
		local result
		result=$(dig +short "${host}" cname 2>/dev/null)
		if [[ -n "${result}" ]]; then
			printf '%s' "${result//$'\n'/ }"
			return 0
		fi
	fi
	if command_exists host; then
		local result
		result=$(host "${host}" 2>/dev/null | awk '/has address/ {print $4}' | paste -sd' ' -)
		if [[ -n "${result}" ]]; then
			printf '%s' "${result}"
			return 0
		fi
	fi
	if command_exists nslookup; then
		local result
		result=$(nslookup "${host}" 2>/dev/null | awk '/^Address: / {print $2}' | paste -sd' ' -)
		if [[ -n "${result}" ]]; then
			printf '%s' "${result}"
			return 0
		fi
	fi
	if ! command_exists python3; then
		return 1
	fi
	local output
	output=$(python3 - "${host}" <<'PY'
import socket
import sys

host = sys.argv[1]

try:
    infos = socket.getaddrinfo(host, None)
except Exception:
    sys.exit(1)

seen = []
for info in infos:
    addr = info[4][0]
    if addr not in seen:
        seen.append(addr)

if not seen:
    sys.exit(1)

print(" ".join(seen))
PY
	) || return 1
	printf '%s' "${output}"
	return 0
}

function attempt_dns_repair() {
	local host="$1"
	local desc="$2"
	if [[ ${DRY_RUN} -eq 1 ]]; then
		log "[dry-run] Intentar reparación DNS para ${host}"
		return 1
	fi
	if ! command_exists cloudflared; then
		log "${desc} túnel ${host}: no se puede reparar DNS porque 'cloudflared' no está instalado."
		return 1
	fi
	local identifier
	identifier=$(get_tunnel_identifier) || true
	if [[ -z "${identifier}" ]]; then
		log "${desc} túnel ${host}: no se pudo determinar el tunnel para reparación DNS."
		return 1
	fi

	log "${desc} túnel ${host}: reaplicando ruta DNS mediante cloudflared (túnel ${identifier})."
	local route_cmd=(cloudflared tunnel route dns --overwrite-dns "${identifier}" "${host}")
	if ! run_as_invoker "${route_cmd[@]}"; then
		log "${desc} túnel ${host}: fallo al ejecutar cloudflared tunnel route dns."
		return 1
	fi

	log "${desc} túnel ${host}: ruta DNS solicitada, verificando resolución..."
	local attempt ips
	for (( attempt=1; attempt<=5; attempt++ )); do
		if ips=$(resolve_hostname "${host}"); then
			log "${desc} túnel ${host}: DNS responde tras reparación -> ${ips}"
			return 0
		fi
		sleep 2
	done

	log "${desc} túnel ${host}: DNS sigue sin resolverse tras el intento de reparación."
	return 1
}

function check_tunnel_host() {
	local host="$1"
	local desc="$2"
	local path="$3"
	shift 3
	local curl_extra=("$@")

	if [[ -z "${path}" ]]; then
		path="/"
	fi
	local request_path
	request_path=$(append_trailing_slash "${path}")

	local https_url="https://${host}${request_path}"
	local http_url="http://${host}${request_path}"

	if curl_check "${https_url}" "${desc} túnel ${host}${path}" 3 1 "${curl_extra[@]}"; then
		return 0
	fi

	log "${desc} túnel ${host}${path}: HTTPS falló, probando HTTP."
	if curl_check "${http_url}" "${desc} túnel ${host}${path}" 3 1 "${curl_extra[@]}"; then
		return 0
	fi

	local attempted_fix=0
	if [[ ${LAST_CURL_STATUS} -eq 6 || "${LAST_CURL_MESSAGE}" == *"Could not resolve host"* ]]; then
		log "${desc} túnel ${host}${path}: fallo por resolución DNS (curl code ${LAST_CURL_STATUS})."
		if attempt_dns_repair "${host}" "${desc}"; then
			attempted_fix=1
			if curl_check "${https_url}" "${desc} túnel ${host}${path} (post-reparación)" 2 1 "${curl_extra[@]}"; then
				return 0
			fi
			if curl_check "${http_url}" "${desc} túnel ${host}${path} (post-reparación)" 2 1 "${curl_extra[@]}"; then
				return 0
			fi
		fi
	fi

	if [[ ${attempted_fix} -eq 1 ]]; then
		log "${desc} túnel ${host}${path}: inaccesible tras intentar reparación automática."
	else
		log "${desc} túnel ${host}${path}: no accesible."
	fi
	if [[ -n "${LAST_CURL_MESSAGE}" ]]; then
		log "    Último error reportado por curl: ${LAST_CURL_MESSAGE}"
	fi
	return 1
}

function verify_local_access() {
	local overall=0

	if [[ -n "${SEEN_SERVICES[ttyd.service]:-}" ]]; then
		local -a auth_args=()
		if [[ -n "${TTYD_AUTH_USER}" && -n "${TTYD_AUTH_PASSWORD}" ]]; then
			auth_args+=(--user "${TTYD_AUTH_USER}:${TTYD_AUTH_PASSWORD}")
		fi
		local ttyd_request_path
		ttyd_request_path=$(append_trailing_slash "${TTYD_BASE_PATH}")
		if ! curl_check "http://127.0.0.1:${TTYD_PORT}${ttyd_request_path}" "ttyd (localhost)" 5 0 "${auth_args[@]}"; then
			overall=1
		fi
	fi

	if [[ -n "${SEEN_SERVICES[filebrowser.service]:-}" ]]; then
		local fb_request_path
		fb_request_path=$(append_trailing_slash "${FILEBROWSER_BASEURL}")
		if ! curl_check "http://127.0.0.1:${FILEBROWSER_PORT}${fb_request_path}" "filebrowser (localhost)" 5 0; then
			overall=1
		fi
	fi

	return ${overall}
}

function verify_tunnel_access() {
	if [[ ${DRY_RUN} -eq 1 ]]; then
		if [[ -n "${SEEN_SERVICES[ttyd.service]:-}" ]]; then
			log "[dry-run] Verificar acceso vía túnel para ttyd (${#TTYD_TUNNEL_ENDPOINTS[@]} endpoints)"
		fi
		if [[ -n "${SEEN_SERVICES[filebrowser.service]:-}" ]]; then
			log "[dry-run] Verificar acceso vía túnel para filebrowser (${#FILEBROWSER_TUNNEL_ENDPOINTS[@]} endpoints)"
		fi
		return 0
	fi

	local overall=0

	if [[ -n "${SEEN_SERVICES[ttyd.service]:-}" ]]; then
		local -a tunnel_auth_args=()
		if [[ -n "${TTYD_AUTH_USER}" && -n "${TTYD_AUTH_PASSWORD}" ]]; then
			tunnel_auth_args+=(--user "${TTYD_AUTH_USER}:${TTYD_AUTH_PASSWORD}")
		fi
		if [[ ${#TTYD_TUNNEL_ENDPOINTS[@]} -eq 0 ]]; then
			log "ttyd: no se encontraron hostnames de túnel en ${CLOUDFLARE_CONFIG_PATH}; omitiendo verificación remota."
		else
			local endpoint
			for endpoint in "${TTYD_TUNNEL_ENDPOINTS[@]}"; do
				local host path
				IFS='|' read -r host path <<< "${endpoint}"
				if ! check_tunnel_host "${host}" "ttyd" "${path}" "${tunnel_auth_args[@]}"; then
					overall=1
				fi
			done
		fi
	fi

	if [[ -n "${SEEN_SERVICES[filebrowser.service]:-}" ]]; then
		if [[ ${#FILEBROWSER_TUNNEL_ENDPOINTS[@]} -eq 0 ]]; then
			log "filebrowser: no se encontraron hostnames de túnel en ${CLOUDFLARE_CONFIG_PATH}; omitiendo verificación remota."
		else
			local endpoint
			for endpoint in "${FILEBROWSER_TUNNEL_ENDPOINTS[@]}"; do
				local host path
				IFS='|' read -r host path <<< "${endpoint}"
				if ! check_tunnel_host "${host}" "filebrowser" "${path}"; then
					overall=1
				fi
			done
		fi
	fi

	return ${overall}
}

function collect_cloudflared_units() {
	local manual_units=()
	local discovered_units=()

	if [[ -n "${CLOUDFLARED_SERVICES:-}" ]]; then
		read -r -a manual_units <<< "${CLOUDFLARED_SERVICES}"
	fi

	if [[ ${#manual_units[@]} -gt 0 ]]; then
		for svc in "${manual_units[@]}"; do
			add_service "${svc}"
		done
		return
	fi

	local status=0
	set +e
	mapfile -t discovered_units < <(systemctl list-unit-files --type=service --no-pager --no-legend 2>/dev/null | awk '{print $1}')
	status=$?
	set -e

	if [[ ${status} -ne 0 ]]; then
		log "No se pudieron listar las unidades de systemd para detectar cloudflared."
		return
	fi

	local found=0
	for unit in "${discovered_units[@]}"; do
		if [[ ${unit} == cloudflared@.service ]]; then
			continue
		fi
		if [[ ${unit} == cloudflared*.service ]]; then
			add_service "${unit}"
			found=1
		fi
	done

	if [[ ${found} -eq 0 ]]; then
		log "No se detectaron unidades cloudflared*.service. Define CLOUDFLARED_SERVICES si usas un nombre personalizado."
	fi
}

function main() {
	parse_args "$@"
	init_invoker_context
	ensure_root
	ensure_systemctl_available
	ensure_required_tools
	infer_ttyd_credentials
	if [[ -n "${TTYD_AUTH_USER}" && -n "${TTYD_AUTH_PASSWORD}" ]]; then
		log "ttyd: verificación HTTP con autenticación básica (origen: ${TTYD_AUTH_SOURCE})"
	fi

	add_service "ttyd.service"
	add_service "filebrowser.service"

	collect_cloudflared_units
	collect_tunnel_hostnames
	load_managed_tunnel_metadata
	if [[ -n "${MANAGED_TUNNEL_NAME}" || -n "${ACTIVE_TUNNEL_CONFIG_VALUE}" ]]; then
		local identifier
		identifier=$(get_tunnel_identifier 2>/dev/null || true)
		if [[ -n "${identifier}" ]]; then
			log "Túnel gestionado detectado: ${identifier}"
		fi
	fi

	for svc in "${EXTRA_SERVICES[@]}"; do
		add_service "${svc}"
	done

	if [[ ${#TARGET_SERVICES[@]} -eq 0 ]]; then
		log "No hay servicios para procesar."
		exit 0
	fi

	if [[ ${DRY_RUN} -eq 0 ]]; then
		systemctl daemon-reload || true
	else
		log "[dry-run] systemctl daemon-reload"
	fi

	local service_failed=0
	for svc in "${TARGET_SERVICES[@]}"; do
		if ! ensure_service_active "${svc}"; then
			service_failed=1
		fi
	done

	local availability_failed=0
	if ! verify_local_access; then
		availability_failed=1
	fi
	if ! verify_tunnel_access; then
		availability_failed=1
	fi

	if (( service_failed != 0 || availability_failed != 0 )); then
		if (( service_failed != 0 )); then
			log "Algunos servicios no pudieron activarse correctamente."
		fi
		if (( availability_failed != 0 )); then
			log "Fallas detectadas al verificar accesibilidad en localhost o túnel."
		fi
		exit 1
	fi

	log "Servicios activos y accesibles mediante localhost y sus túneles."
}

main "$@"


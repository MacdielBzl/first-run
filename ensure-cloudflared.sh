#!/usr/bin/env bash
set -euo pipefail

# ensure-cloudflared-login.sh
# Comprueba si existe el certificado de cloudflared para el usuario que invocó
# (respeta SUDO_USER para llamadas con sudo). Si no existe, ejecuta
# `cloudflared login` como ese usuario.

DEFAULT_CERT_REL=".cloudflared/cert.pem"

# Determine invoking (original) user: prefer SUDO_USER when run under sudo
INVOKER_USER="${SUDO_USER:-}"
if [[ -z "${INVOKER_USER}" ]]; then
  INVOKER_USER="$(whoami)"
fi

# Resolve home dir for invoker
USER_HOME="$(getent passwd "${INVOKER_USER}" | cut -d: -f6 2>/dev/null || true)"
if [[ -z "${USER_HOME}" ]]; then
  USER_HOME="${HOME:-/home/${INVOKER_USER}}"
fi

CERT_FILE="${USER_HOME}/${DEFAULT_CERT_REL}"
CONFIG_DIR="$(dirname "${CERT_FILE}")"

LOCAL_TUNNEL_INFO_FILE="${CONFIG_DIR}/managed-tunnel.json"
LAST_CONFIGURED_TUNNEL_NAME=""
LAST_CONFIGURED_TUNNEL_ID=""
LAST_CONFIGURED_CRED_FILE=""

function run_as_invoker() {
  if [[ "$(whoami)" == "${INVOKER_USER}" ]]; then
    "$@"
  else
    sudo -u "${INVOKER_USER}" -H "$@"
  fi
}

function select_dns_lookup_tool() {
  if command -v dig >/dev/null 2>&1; then
    echo "dig"
  elif command -v host >/dev/null 2>&1; then
    echo "host"
  elif command -v nslookup >/dev/null 2>&1; then
    echo "nslookup"
  else
    echo ""
  fi
}

function resolve_cname_with_tool() {
  local tool="$1"
  local hostname="$2"
  local result=""

  case "${tool}" in
    dig)
      result=$(dig +short "${hostname}" cname 2>/dev/null | head -n1)
      ;;
    host)
      result=$(host -t cname "${hostname}" 2>/dev/null | awk '/is an alias for/ {print $NF; exit}')
      ;;
    nslookup)
      result=$(nslookup -type=CNAME "${hostname}" 2>/dev/null | awk -F'= ' '/canonical name/ {print $2; exit}')
      ;;
    *)
      result=""
      ;;
  esac

  result=$(echo "${result}" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')
  echo "${result}"
}

function collect_hostnames_from_config_file() {
  local config_file="$1"
  local _result_ref="$2"

  if [[ ! -f "${config_file}" ]]; then
    return 1
  fi

  local -n result_ref="${_result_ref}"
  result_ref=()

  local current_hostname=""
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
      hostname:*)
        current_hostname="${line#hostname:}"
        current_hostname="${current_hostname//\"/}"
        current_hostname=$(echo "${current_hostname}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        ;;
      service:*)
        if [[ -n "${current_hostname}" ]]; then
          local exists=0
          local h
          for h in "${result_ref[@]}"; do
            if [[ "${h}" == "${current_hostname}" ]]; then
              exists=1
              break
            fi
          done
          if [[ ${exists} -eq 0 ]]; then
            result_ref+=("${current_hostname}")
          fi
        fi
        current_hostname=""
        ;;
      *)
        ;;
    esac
  done < "${config_file}"

  return 0
}

function derive_zone_from_hostname() {
  local hostname="$1"
  IFS='.' read -r -a parts <<< "${hostname}"
  local count=${#parts[@]}
  if (( count >= 2 )); then
    echo "${parts[count-2]}.${parts[count-1]}"
  else
    echo "${hostname}"
  fi
}

function ensure_dns_records() {
  local tunnel_name="$1"
  local tunnel_id="$2"
  shift 2
  local hostnames=("$@")

  if [[ ${#hostnames[@]} -eq 0 ]]; then
    return 0
  fi

  local dns_tool
  dns_tool=$(select_dns_lookup_tool)
  if [[ -z "${dns_tool}" ]]; then
    echo "No se encontraron herramientas (dig, host, nslookup) para verificar DNS." >&2
    return 1
  fi

  local expected_target=""
  if [[ -n "${tunnel_id}" && "${tunnel_id}" =~ ^[0-9a-fA-F-]{32,}$ ]]; then
    expected_target="${tunnel_id,,}.cfargotunnel.com"
  fi

  echo
  echo "Verificando registros DNS para el tunnel '${tunnel_name}'..."

  local host
  for host in "${hostnames[@]}"; do
    local current_target
    current_target=$(resolve_cname_with_tool "${dns_tool}" "${host}" | head -n1)

    if [[ -n "${current_target}" ]]; then
      if [[ -n "${expected_target}" ]]; then
        if [[ "${current_target}" == "${expected_target}" ]]; then
          echo "  - ${host}: OK -> ${current_target}"
          continue
        fi
      elif [[ "${current_target}" == *.cfargotunnel.com ]]; then
        echo "  - ${host}: OK -> ${current_target}"
        continue
      fi
    fi

    if [[ -z "${current_target}" ]]; then
      echo "  - ${host}: sin registro CNAME hacia el tunnel."
    else
      echo "  - ${host}: apunta a ${current_target}, no al tunnel actual."
    fi

    read -rp "    ¿Deseas crear/actualizar el CNAME ahora? [Y/N]: " update_dns
    if [[ ! "${update_dns}" =~ ^[yY]$ ]]; then
      continue
    fi

    local route_cmd=(cloudflared tunnel route dns)
    if [[ -n "${current_target}" && -n "${expected_target}" && "${current_target}" != "${expected_target}" ]]; then
      route_cmd+=(--overwrite-dns)
    fi
    route_cmd+=("${tunnel_name}" "${host}")

    if run_as_invoker "${route_cmd[@]}"; then
      echo "    Registro DNS solicitado. Esperando propagación..."
      local dns_wait=0
      local dns_confirmed=0
      while (( dns_wait < 30 )); do
        sleep 5
        dns_wait=$((dns_wait + 5))
        current_target=$(resolve_cname_with_tool "${dns_tool}" "${host}" | head -n1)
        if [[ -n "${current_target}" ]]; then
          echo "    Nuevo destino: ${current_target}"
          dns_confirmed=1
          break
        fi
      done
      if (( dns_confirmed == 0 )); then
        echo "    No se pudo confirmar el CNAME para ${host} tras ${dns_wait}s. La propagación DNS puede tardar varios minutos." >&2
      fi
    else
      echo "    No se pudo crear el registro DNS para ${host}." >&2
    fi
  done

  echo "Verificación de DNS completada."
  return 0
}

function load_local_tunnel_metadata() {
  local _name_ref="$1"
  local _id_ref="$2"
  local _cred_ref="$3"

  if [[ -z "${_name_ref}" || -z "${_id_ref}" || -z "${_cred_ref}" ]]; then
    return 1
  fi
  if [[ ! -f "${LOCAL_TUNNEL_INFO_FILE}" ]]; then
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  local result
  result=$(python3 - "${LOCAL_TUNNEL_INFO_FILE}" <<'PY'
import json
import sys

path = sys.argv[1]

try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)

name = str(data.get("name", ""))
tunnel_id = str(data.get("id", ""))
cred = str(data.get("credential_file", ""))

print(name)
print(tunnel_id)
print(cred)
PY
  ) || return 1

  mapfile -t _metadata_lines <<< "${result}"
  local -n name_ref="${_name_ref}"
  local -n id_ref="${_id_ref}"
  local -n cred_ref="${_cred_ref}"
  name_ref="${_metadata_lines[0]:-}"
  id_ref="${_metadata_lines[1]:-}"
  cred_ref="${_metadata_lines[2]:-}"
  return 0
}

function save_local_tunnel_metadata() {
  local tunnel_name="$1"
  local tunnel_id="$2"
  local cred_file="$3"

  if [[ -z "${tunnel_name}" && -z "${tunnel_id}" ]]; then
    return 1
  fi

  mkdir -p "${CONFIG_DIR}"

  if ! command -v python3 >/dev/null 2>&1; then
    echo "No se pudo guardar metadata del tunnel: python3 no está disponible." >&2
    return 1
  fi

  if ! python3 - "${LOCAL_TUNNEL_INFO_FILE}" "${tunnel_name}" "${tunnel_id}" "${cred_file}" <<'PY'
import json
import os
import sys
import time

path, name, tunnel_id, cred = sys.argv[1:5]
data = {
    "name": name,
    "id": tunnel_id,
    "credential_file": cred,
    "updated_at": int(time.time())
}

tmp_path = path + ".tmp"
with open(tmp_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False)
    fh.write("\n")

os.replace(tmp_path, path)
PY
  then
    return 1
  fi
  if [[ $(id -u) -eq 0 ]]; then
    chown "${INVOKER_USER}:" "${LOCAL_TUNNEL_INFO_FILE}" 2>/dev/null || true
  fi
  chmod 600 "${LOCAL_TUNNEL_INFO_FILE}" 2>/dev/null || true
  return 0
}

function clear_local_tunnel_metadata() {
  if [[ -f "${LOCAL_TUNNEL_INFO_FILE}" ]]; then
    rm -f "${LOCAL_TUNNEL_INFO_FILE}" 2>/dev/null || true
  fi
  LAST_CONFIGURED_TUNNEL_NAME=""
  LAST_CONFIGURED_TUNNEL_ID=""
  LAST_CONFIGURED_CRED_FILE=""
}

function discover_local_tunnel_metadata() {
  local _name_ref="$1"
  local _id_ref="$2"
  local _cred_ref="$3"

  if [[ -z "${_name_ref}" || -z "${_id_ref}" || -z "${_cred_ref}" ]]; then
    return 1
  fi
  if [[ ! -d "${CONFIG_DIR}" ]]; then
    return 1
  fi

  local -a _cred_files=()
  mapfile -t _cred_files < <(find "${CONFIG_DIR}" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null)
  if [[ ${#_cred_files[@]} -eq 0 ]]; then
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  local result
  result=$(python3 - "${_cred_files[@]}" <<'PY'
import json
import os
import sys

paths = sys.argv[1:]
best = None

for path in paths:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        data = {}

    tunnel_id = str(data.get("TunnelID") or "").strip()
    tunnel_name = str(data.get("TunnelName") or "").strip()
    if not tunnel_id:
        base = os.path.basename(path)
        if base.endswith(".json"):
            tunnel_id = base[:-5]
        else:
            tunnel_id = base

    mtime = 0.0
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        pass

    candidate = (mtime, tunnel_id, tunnel_name, path)

    if not tunnel_id:
        continue

    if best is None or candidate[0] > best[0]:
        best = candidate

if best is None:
    sys.exit(1)

_, tunnel_id, tunnel_name, path = best
print(tunnel_id)
print(tunnel_name)
print(path)
PY
  ) || return 1

  mapfile -t _metadata_lines <<< "${result}"
  local discovered_id="${_metadata_lines[0]:-}"
  local discovered_name="${_metadata_lines[1]:-}"
  local discovered_cred="${_metadata_lines[2]:-}"

  if [[ -z "${discovered_id}" ]]; then
    return 1
  fi

  local -n name_ref="${_name_ref}"
  local -n id_ref="${_id_ref}"
  local -n cred_ref="${_cred_ref}"

  id_ref="${discovered_id}"
  name_ref="${discovered_name}"
  cred_ref="${discovered_cred}"
  return 0
}

function ensure_local_tunnel_metadata() {
  local loaded_name=""
  local loaded_id=""
  local loaded_cred=""

  if load_local_tunnel_metadata loaded_name loaded_id loaded_cred; then
    LAST_CONFIGURED_TUNNEL_NAME="${loaded_name}"
    LAST_CONFIGURED_TUNNEL_ID="${loaded_id}"
    LAST_CONFIGURED_CRED_FILE="${loaded_cred}"
    return 0
  fi

  local discovered_name=""
  local discovered_id=""
  local discovered_cred=""
  if discover_local_tunnel_metadata discovered_name discovered_id discovered_cred; then
    LAST_CONFIGURED_TUNNEL_NAME="${discovered_name}"
    LAST_CONFIGURED_TUNNEL_ID="${discovered_id}"
    LAST_CONFIGURED_CRED_FILE="${discovered_cred}"
    save_local_tunnel_metadata "${LAST_CONFIGURED_TUNNEL_NAME}" "${LAST_CONFIGURED_TUNNEL_ID}" "${LAST_CONFIGURED_CRED_FILE}" || true
    return 0
  fi

  LAST_CONFIGURED_TUNNEL_NAME=""
  LAST_CONFIGURED_TUNNEL_ID=""
  LAST_CONFIGURED_CRED_FILE=""
  return 1
}

function report_local_tunnel_credentials() {
  local -a cred_files=()

  if [[ -d "${CONFIG_DIR}" ]]; then
    while IFS= read -r -d '' cred_file; do
      cred_files+=("${cred_file}")
    done < <(find "${CONFIG_DIR}" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null || true)
  fi

  local managed_name="${LAST_CONFIGURED_TUNNEL_NAME}"
  local managed_id="${LAST_CONFIGURED_TUNNEL_ID}"
  local managed_cred="${LAST_CONFIGURED_CRED_FILE}"
  if [[ -z "${managed_id}" && -z "${managed_name}" ]]; then
    if ! load_local_tunnel_metadata managed_name managed_id managed_cred; then
      discover_local_tunnel_metadata managed_name managed_id managed_cred || true
    fi
  fi

  if [[ ${#cred_files[@]} -eq 0 ]]; then
    if [[ -n "${managed_id}" || -n "${managed_name}" ]]; then
      echo "Se encontró metadata local, pero no archivos *.json en ${CONFIG_DIR}."
    else
      echo "No se encontraron credenciales locales (*.json) en ${CONFIG_DIR}."
    fi
    return 0
  fi

  echo "Credenciales locales detectadas en ${CONFIG_DIR}:"
  local cred_file base_name tunnel_hint descriptor
  for cred_file in "${cred_files[@]}"; do
    base_name=$(basename "${cred_file}")
    tunnel_hint="${base_name%.json}"
    if [[ -z "${tunnel_hint}" || "${tunnel_hint}" == "${base_name}" ]]; then
      tunnel_hint="(ID desconocido)"
    fi
    descriptor="${tunnel_hint}"
    if [[ -n "${managed_id}" && "${tunnel_hint}" == "${managed_id}" ]]; then
      descriptor+=" [gestionado por este script]"
    elif [[ -n "${managed_cred}" && "${cred_file}" == "${managed_cred}" ]]; then
      descriptor+=" [gestionado por este script]"
    elif [[ -n "${managed_name}" && "${managed_name}" == "${tunnel_hint}" ]]; then
      descriptor+=" [gestionado por este script]"
    fi
    printf '  - %s (archivo: %s)\n' "${descriptor}" "${cred_file}"
  done

  return 0
}

function delete_dns_records_for_hostnames() {
  local -a hostnames=("$@")

  if [[ ${#hostnames[@]} -eq 0 ]]; then
    echo "No hay hostnames para eliminar en Cloudflare; se omite esta parte."
    return 0
  fi

  local token="${CF_API_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"
  if [[ -z "${token}" ]]; then
    read -rp "Proporciona un API Token de Cloudflare con permisos DNS (Enter para omitir): " token_input
    if [[ -z "${token_input}" ]]; then
      echo "No se proporcionó token; se omite la eliminación de registros DNS." >&2
      return 1
    fi
    token="${token_input}"
  fi

  local -a host_zone_pairs=()
  local host
  for host in "${hostnames[@]}"; do
    if [[ -z "${host}" ]]; then
      continue
    fi
    local default_zone
    default_zone=$(derive_zone_from_hostname "${host}")
    local zone_input=""
    read -rp "Zona de Cloudflare para ${host} [${default_zone}]: " zone_input
    local zone_name
    if [[ -z "${zone_input}" ]]; then
      zone_name="${default_zone}"
    else
      zone_name="${zone_input}"
    fi
    if [[ -z "${zone_name}" ]]; then
      echo "  - Omitiendo ${host} (zona vacía)." >&2
      continue
    fi
    host_zone_pairs+=("${host}|${zone_name}")
  done

  if [[ ${#host_zone_pairs[@]} -eq 0 ]]; then
    echo "No se especificaron zonas; se omite la eliminación de registros DNS." >&2
    return 1
  fi

  set +e
  # Pass token via environment variable to avoid exposing it in the process list
  CF_DNS_TOKEN="${token}" python3 - "${host_zone_pairs[@]}" <<'PY'
import json
import os
import sys
import urllib.parse
import urllib.request


def api_request(token, method, url, data=None):
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    req = urllib.request.Request(url, method=method, headers=headers)
    if data is not None:
        if isinstance(data, (dict, list)):
            data = json.dumps(data).encode("utf-8")
        elif isinstance(data, str):
            data = data.encode("utf-8")
        req.data = data
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = resp.read()
            return resp.status, body
    except urllib.error.HTTPError as err:
        return err.code, err.read()
    except Exception as exc:  # pragma: no cover - best effort logging
        return None, str(exc).encode()


def main():
    if len(sys.argv) < 2:
        return 0
    token = os.environ.get("CF_DNS_TOKEN", "")
    if not token:
        print("[dns-remove] CF_DNS_TOKEN no está definido.", file=sys.stderr)
        return 1
    pairs = sys.argv[1:]
    zone_cache = {}
    success = True

    for pair in pairs:
        if "|" not in pair:
            print(f"[dns-remove] Formato inválido: {pair}", file=sys.stderr)
            success = False
            continue
        hostname, zone_name = pair.split("|", 1)
        hostname = hostname.strip()
        zone_name = zone_name.strip()
        if not hostname or not zone_name:
            print(f"[dns-remove] Datos incompletos: {pair}", file=sys.stderr)
            success = False
            continue

        if zone_name not in zone_cache:
            params = urllib.parse.urlencode({"name": zone_name, "status": "active", "page": 1, "per_page": 1})
            status, body = api_request(token, "GET", f"https://api.cloudflare.com/client/v4/zones?{params}")
            if status != 200:
                print(f"[dns-remove] No se pudo obtener zone_id para {zone_name}: HTTP {status}", file=sys.stderr)
                zone_cache[zone_name] = None
                success = False
                continue
            data = json.loads(body.decode("utf-8"))
            if not data.get("success") or not data.get("result"):
                print(f"[dns-remove] Zona {zone_name} no encontrada o sin permisos.", file=sys.stderr)
                zone_cache[zone_name] = None
                success = False
                continue
            zone_cache[zone_name] = data["result"][0]["id"]

        zone_id = zone_cache.get(zone_name)
        if not zone_id:
            print(f"[dns-remove] Omitiendo {hostname}: falta zone_id.", file=sys.stderr)
            success = False
            continue

        params = urllib.parse.urlencode({"type": "CNAME", "name": hostname})
        status, body = api_request(token, "GET", f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records?{params}")
        if status != 200:
            print(f"[dns-remove] No se pudo listar DNS de {hostname}: HTTP {status}", file=sys.stderr)
            success = False
            continue
        data = json.loads(body.decode("utf-8"))
        records = data.get("result") or []
        if not records:
            print(f"[dns-remove] No se encontró CNAME para {hostname}.")
            continue

        for record in records:
            record_id = record.get("id")
            if not record_id:
                continue
            status, body = api_request(token, "DELETE", f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{record_id}")
            if status != 200:
                print(f"[dns-remove] Error al eliminar {hostname}: HTTP {status}", file=sys.stderr)
                success = False
                continue
            try:
                resp_data = json.loads(body.decode("utf-8"))
            except Exception:
                resp_data = {"success": status == 200}
            if resp_data.get("success"):
                print(f"[dns-remove] Eliminado {hostname}.")
            else:
                print(f"[dns-remove] La API no confirmó la eliminación de {hostname}.", file=sys.stderr)
                success = False

    if success:
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
PY
  local dns_status=$?
  set -e

  if [[ ${dns_status} -ne 0 ]]; then
    echo "Algunas eliminaciones de DNS no se completaron correctamente." >&2
    return 1
  fi

  echo "Registros DNS eliminados (o no existían)."
  return 0
}

function configure_tunnel() {
  local tunnel_name="$1"
  local provided_id="${2:-}"
  local provided_cred_file="${3:-}"

  if [[ -z "${tunnel_name}" ]]; then
    echo "Nombre de tunnel no proporcionado." >&2
    return 1
  fi

  local tunnel_id="${provided_id}"
  if [[ -z "${tunnel_id}" ]]; then
    tunnel_id=$(run_as_invoker cloudflared tunnel list 2>/dev/null | awk -v name="${tunnel_name}" '$2==name {print $1; exit}')
  fi

  if [[ -z "${tunnel_id}" ]]; then
    echo "Advertencia: no se pudo determinar el ID del tunnel automáticamente." >&2
    tunnel_id="${tunnel_name}"
  fi

  local cred_file="${provided_cred_file}"
  if [[ -z "${cred_file}" || ! -f "${cred_file}" ]]; then
    local expected_cred="${CONFIG_DIR}/${tunnel_id}.json"
    if [[ -f "${expected_cred}" ]]; then
      cred_file="${expected_cred}"
    else
      cred_file=""
    fi
  fi

  if [[ -z "${cred_file}" ]]; then
    cred_file=$(find "${CONFIG_DIR}" -maxdepth 1 -type f -name '*.json' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | awk '{print $2}' || true)
    if [[ -z "${cred_file}" ]]; then
      echo "No se pudo determinar la ruta del archivo de credenciales. Revisa el contenido de ${CONFIG_DIR}." >&2
    fi
  fi

  if [[ -n "${cred_file}" ]]; then
    echo "Archivo de credenciales: ${cred_file}"
    if [[ -f "${cred_file}" ]]; then
      if [[ $(id -u) -eq 0 ]]; then
        chown "${INVOKER_USER}:" "${cred_file}" 2>/dev/null || echo "No se pudo ajustar la propiedad de ${cred_file}" >&2
      fi
      chmod 600 "${cred_file}" 2>/dev/null || echo "No se pudo ajustar los permisos (600) de ${cred_file}" >&2
    fi
  fi

  local config_created=0
  local config_path=""
  local -a ingress_hosts=()
  local -a ingress_paths=()
  local -a ingress_services=()
  local base_hostname=""

  echo
  read -rp "¿Quieres generar un archivo config.yml para este tunnel? [Y/N]: " create_config
  if [[ "${create_config}" =~ ^[yY]$ ]]; then
    local default_config="${CONFIG_DIR}/config.yml"
    ingress_hosts=()
    ingress_paths=()
    ingress_services=()
    while true; do
      read -rp "Ruta del archivo config [${default_config}]: " config_input
      if [[ -z "${config_input}" ]]; then
        config_path="${default_config}"
      else
        config_path="${config_input}"
      fi

      if [[ "${config_path}" != /* ]]; then
        config_path="$(pwd)/${config_path}"
      fi

      local config_dirname
      config_dirname=$(dirname "${config_path}")
      if [[ ! -d "${config_dirname}" ]]; then
        if ! mkdir -p "${config_dirname}" 2>/dev/null; then
          echo "No se pudo crear el directorio ${config_dirname}. Ingresa otra ruta." >&2
          continue
        fi
        if [[ $(id -u) -eq 0 ]]; then
          chown "${INVOKER_USER}:" "${config_dirname}" 2>/dev/null || true
        fi
      fi

      if [[ -f "${config_path}" ]]; then
        read -rp "${config_path} ya existe. ¿Deseas sobrescribirlo? [Y/N]: " overwrite
        if [[ ! "${overwrite}" =~ ^[yY]$ ]]; then
          echo "Introduce otra ruta o presiona Enter para cancelar." >&2
          continue
        fi
      fi
      break
    done

    local default_loglevel="info"
    read -rp "Nivel de log [${default_loglevel}]: " loglevel_input
    local config_loglevel
    if [[ -z "${loglevel_input}" ]]; then
      config_loglevel="${default_loglevel}"
    else
      config_loglevel="${loglevel_input}"
    fi

    local default_metrics="127.0.0.1:45678"
    read -rp "Endpoint de métricas [${default_metrics}]: " metrics_input
    local config_metrics
    if [[ -z "${metrics_input}" ]]; then
      config_metrics="${default_metrics}"
    else
      config_metrics="${metrics_input}"
    fi

    local default_pidfile="${CONFIG_DIR}/cloudflared.pid"
    read -rp "Ruta del pidfile [${default_pidfile}]: " pidfile_input
    local config_pidfile
    if [[ -z "${pidfile_input}" ]]; then
      config_pidfile="${default_pidfile}"
    else
      config_pidfile="${pidfile_input}"
    fi

    local default_autoupdate="24h"
    read -rp "Frecuencia de autoupdate [${default_autoupdate}]: " autoupdate_input
    local config_autoupdate
    if [[ -z "${autoupdate_input}" ]]; then
      config_autoupdate="${default_autoupdate}"
    else
      config_autoupdate="${autoupdate_input}"
    fi

    local default_retries="5"
    read -rp "Número de reintentos [${default_retries}]: " retries_input
    local config_retries
    if [[ -z "${retries_input}" ]]; then
      config_retries="${default_retries}"
    else
      config_retries="${retries_input}"
    fi

    local default_retry_interval="10s"
    read -rp "Intervalo entre reintentos [${default_retry_interval}]: " retry_interval_input
    local config_retry_interval
    if [[ -z "${retry_interval_input}" ]]; then
      config_retry_interval="${default_retry_interval}"
    else
      config_retry_interval="${retry_interval_input}"
    fi

    local default_connections="4"
    read -rp "Conexiones simultáneas [${default_connections}]: " connections_input
    local config_connections
    if [[ -z "${connections_input}" ]]; then
      config_connections="${default_connections}"
    else
      config_connections="${connections_input}"
    fi
    while true; do
      read -rp "Hostname base (ej. app.tudominio.com): " base_hostname
      if [[ -z "${base_hostname}" ]]; then
        echo "Debes proporcionar un hostname base." >&2
        continue
      fi
      if [[ "${base_hostname}" != *.* ]]; then
        echo "El hostname debe incluir un dominio completo (ej. sub.dominio.com)." >&2
        continue
      fi
      break
    done

    ingress_hosts=("${base_hostname}")

    local route_index=0
    while true; do
      local prompt_suffix=""
      if [[ ${route_index} -gt 0 ]]; then
        prompt_suffix=" (Enter para finalizar)"
      fi

      local default_path
      local default_service
      if [[ ${route_index} -eq 0 ]]; then
        default_path="/*"
        default_service="http://localhost:3000"
      elif [[ ${route_index} -eq 1 ]]; then
        default_path="/filebrowser/*"
        default_service="http://localhost:8080"
      else
        default_path="/servicio-${route_index}/*"
        default_service="http://localhost:8000"
      fi

      read -rp "Ruta a publicar${prompt_suffix} [${default_path}]: " path_input
      if [[ -z "${path_input}" ]]; then
        if [[ ${route_index} -eq 0 ]]; then
          echo "Debes registrar al menos una ruta." >&2
          continue
        fi
        break
      fi

      local route_path="${path_input}"
      if [[ "${route_path}" != /* ]]; then
        echo "La ruta debe comenzar con '/' (ej. /ttyd/*)." >&2
        continue
      fi

      read -rp "Servicio/local URL para ${route_path} [${default_service}]: " service_input
      local service_target
      if [[ -z "${service_input}" ]]; then
        service_target="${default_service}"
      else
        service_target="${service_input}"
      fi
      if [[ "${service_target}" != *"://"* ]]; then
        service_target="http://${service_target}"
      fi

      ingress_paths+=("${route_path}")
      ingress_services+=("${service_target}")
      ((route_index++))
    done

    local cred_file_placeholder
    if [[ -z "${cred_file}" ]]; then
      cred_file_placeholder="${CONFIG_DIR}/${tunnel_id}.json"
    else
      cred_file_placeholder="${cred_file}"
    fi

    {
      echo "tunnel: ${tunnel_id}"
      echo "credentials-file: ${cred_file_placeholder}"
      echo "loglevel: ${config_loglevel}"
      echo "metrics: ${config_metrics}"
      echo "pidfile: ${config_pidfile}"
      echo "autoupdate-freq: ${config_autoupdate}"
      echo "retries: ${config_retries}"
      echo "retry-interval: ${config_retry_interval}"
      echo "connections: ${config_connections}"
      echo ""
      echo "ingress:"
      local idx
      for idx in "${!ingress_services[@]}"; do
        printf '  - hostname: %s\n' "${base_hostname}"
        if [[ -n "${ingress_paths[$idx]}" ]]; then
          printf '    path: %s\n' "${ingress_paths[$idx]}"
        fi
        printf '    service: %s\n' "${ingress_services[$idx]}"
      done
      echo "  - service: http_status:404"
    } > "${config_path}"

    if [[ $(id -u) -eq 0 ]]; then
      chown "${INVOKER_USER}:" "${config_path}" 2>/dev/null || true
    fi
    chmod 640 "${config_path}" 2>/dev/null || true

    echo "Archivo de configuración creado en ${config_path}"
    config_created=1
  fi

  if [[ ${config_created} -eq 1 ]]; then
    echo
    read -rp "¿Quieres instalar el servicio systemd para este tunnel? [Y/N]: " install_service
    if [[ "${install_service}" =~ ^[yY]$ ]]; then
      if [[ $(id -u) -ne 0 ]]; then
        echo "Para instalar un servicio systemd necesitas permisos de administrador. Ejecuta este script con sudo o crea un servicio de usuario manualmente." >&2
      else
        local cloudflared_bin
        cloudflared_bin=$(command -v cloudflared || echo /usr/local/bin/cloudflared)
        local service_name="cloudflared-${tunnel_name}.service"
        local service_path="/etc/systemd/system/${service_name}"
        local log_path="/var/log/cloudflared-${tunnel_name}.log"

        cat > "${service_path}" <<EOF
[Unit]
Description=Cloudflare Tunnel: ${tunnel_name}
After=network.target

[Service]
Type=simple
User=${INVOKER_USER}
Environment=LOG_FILE=${log_path}
ExecStart=${cloudflared_bin} tunnel --config ${config_path} run ${tunnel_name}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

        chmod 644 "${service_path}"
        touch "${log_path}" 2>/dev/null || true
        chown "${INVOKER_USER}:" "${log_path}" 2>/dev/null || true
        systemctl daemon-reload
        echo "Servicio systemd creado en ${service_path}"

        read -rp "¿Quieres habilitar e iniciar el servicio ahora? [Y/N]: " enable_service
        if [[ "${enable_service}" =~ ^[yY]$ ]]; then
          if systemctl enable --now "${service_name}"; then
            echo "Servicio ${service_name} habilitado e iniciado."
          else
            echo "No se pudo habilitar/iniciar ${service_name}. Revisa los mensajes de systemctl." >&2
          fi
        else
          echo "Puedes habilitarlo más tarde con: sudo systemctl enable --now ${service_name}"
        fi
      fi
    fi
  fi

  local -a dns_hostnames=()
  if [[ ${config_created} -eq 1 ]]; then
    dns_hostnames=("${ingress_hosts[@]}")
  else
    if [[ -z "${config_path}" ]]; then
      if [[ -f "${CONFIG_DIR}/config.yml" ]]; then
        config_path="${CONFIG_DIR}/config.yml"
      fi
    fi

    if [[ -n "${config_path}" && -f "${config_path}" ]]; then
      collect_hostnames_from_config_file "${config_path}" dns_hostnames || true
    fi
  fi

  if [[ ${#dns_hostnames[@]} -gt 0 ]]; then
    if ! ensure_dns_records "${tunnel_name}" "${tunnel_id}" "${dns_hostnames[@]}"; then
      echo "No se pudo completar la verificación DNS automáticamente." >&2
    fi
  else
    echo "No se encontraron hostnames configurados; se omite la verificación DNS."
  fi

  LAST_CONFIGURED_TUNNEL_NAME="${tunnel_name}"
  LAST_CONFIGURED_TUNNEL_ID="${tunnel_id}"
  LAST_CONFIGURED_CRED_FILE="${cred_file}"

  return 0
}

function create_new_tunnel() {
  while true; do
    read -rp "Nombre del tunnel (Enter para cancelar): " tunnel_name
    if [[ -z "${tunnel_name}" ]]; then
      echo "Operación cancelada por el usuario."
      return 1
    fi

    echo "Creando tunnel '${tunnel_name}'..."

    set +e
    local tunnel_output
    tunnel_output=$(run_as_invoker cloudflared tunnel create "${tunnel_name}" 2>&1)
    local status=$?
    set -e
    if [[ ${status} -eq 0 ]]; then
      printf '%s\n' "${tunnel_output}"
      echo "Tunnel '${tunnel_name}' creado correctamente."

      local tunnel_id
      tunnel_id=$(printf '%s\n' "${tunnel_output}" | awk '/with id/ {print $NF}' | tail -n1)
      # Fallback: if parsing cloudflared output failed, query the tunnel list
      if [[ -z "${tunnel_id}" ]]; then
        tunnel_id=$(run_as_invoker cloudflared tunnel list 2>/dev/null | awk -v name="${tunnel_name}" '$2==name {print $1; exit}')
      fi
      local cred_file=""
      if [[ -n "${tunnel_id}" ]]; then
        cred_file="${CONFIG_DIR}/${tunnel_id}.json"
      fi

      if configure_tunnel "${tunnel_name}" "${tunnel_id}" "${cred_file}"; then
        save_local_tunnel_metadata "${LAST_CONFIGURED_TUNNEL_NAME}" "${LAST_CONFIGURED_TUNNEL_ID}" "${LAST_CONFIGURED_CRED_FILE}" || true
        return 0
      fi
      return 1
    fi

    printf '%s\n' "${tunnel_output}" >&2
    if echo "${tunnel_output}" | grep -qi "already exists"; then
      echo "Ya existe un tunnel con el nombre '${tunnel_name}'." >&2
      read -rp "¿Quieres usar ese tunnel existente ahora? [Y/N]: " use_existing
      if [[ "${use_existing}" =~ ^[yY]$ ]]; then
        if configure_tunnel "${tunnel_name}" "" ""; then
          return 0
        fi
        return 1
      fi
      echo "Intenta con otro nombre o selecciona la opción de usar un tunnel existente." >&2
    else
      echo "No se pudo crear el tunnel '${tunnel_name}'. Puedes intentar con otro nombre o presionar Enter para cancelar." >&2
    fi
  done
}

function choose_tunnel() {
  local _id_ref="$1"
  local _name_ref="$2"

  if [[ -z "${_id_ref}" || -z "${_name_ref}" ]]; then
    echo "choose_tunnel requiere variables de salida." >&2
    return 1
  fi

  local -n id_ref="${_id_ref}"
  local -n name_ref="${_name_ref}"
  id_ref=""
  name_ref=""

  local -a tunnel_entries=()
  local json_output=""
  json_output=$(run_as_invoker cloudflared tunnel list -o json 2>/dev/null || true)
  if [[ -n "${json_output}" && "${json_output}" != "[]" ]]; then
    mapfile -t tunnel_entries < <(
      printf '%s' "${json_output}" | python3 - <<'PY'
import json
import sys


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 1

    if not isinstance(data, list):
        return 1

    for item in data:
        if not isinstance(item, dict):
            continue

        tunnel_id = str(item.get("id") or "").strip()
        name = str(item.get("name") or "").strip()
        deleted_at = str(item.get("deleted_at") or "").strip()

        if not tunnel_id or not name:
            continue
        if deleted_at and deleted_at != "0001-01-01T00:00:00Z":
            # Skip deleted tunnels
            continue
        print(f"{tunnel_id}|{name}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
    ) || true
  fi

  if [[ ${#tunnel_entries[@]} -eq 0 ]]; then
    mapfile -t tunnel_entries < <(run_as_invoker cloudflared tunnel list 2>/dev/null | awk 'NR>1 && NF>=2 {print $1 "|" $2}')
  fi

  local filtered_entries=()
  local entry
  for entry in "${tunnel_entries[@]}"; do
    IFS='|' read -r entry_id entry_name <<< "${entry}"
    entry_id=$(echo "${entry_id}" | tr -d '[:space:]')
    entry_name=$(echo "${entry_name}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ -z "${entry_id}" || -z "${entry_name}" ]]; then
      continue
    fi
    if [[ "${entry_id}" == "ID" && "${entry_name}" == "NAME" ]]; then
      continue
    fi
    filtered_entries+=("${entry_id}|${entry_name}")
  done

  tunnel_entries=("${filtered_entries[@]}")

  if [[ ${#tunnel_entries[@]} -eq 0 ]]; then
    echo "No se encontraron tunnels existentes para ${INVOKER_USER}."
    return 2
  fi
  echo "Tunnels disponibles:"
  local idx
  for idx in "${!tunnel_entries[@]}"; do
    IFS='|' read -r entry_id entry_name <<< "${tunnel_entries[$idx]}"
    local display_index=$((idx + 1))
    printf '  [%d] %s (ID: %s)\n' "${display_index}" "${entry_name}" "${entry_id}"
  done

  read -rp "Selecciona un tunnel por número, nombre o ID (Enter para cancelar): " selection
  if [[ -z "${selection}" ]]; then
    echo "Operación cancelada por el usuario."
    return 1
  fi

  local selected_id=""
  local selected_name=""
  if [[ "${selection}" =~ ^[0-9]+$ ]]; then
    local selection_index=$((selection - 1))
    if (( selection_index >= 0 && selection_index < ${#tunnel_entries[@]} )); then
      IFS='|' read -r selected_id selected_name <<< "${tunnel_entries[$selection_index]}"
    fi
  fi

  if [[ -z "${selected_id}" ]]; then
    for entry in "${tunnel_entries[@]}"; do
      IFS='|' read -r entry_id entry_name <<< "${entry}"
      if [[ "${selection}" == "${entry_name}" || "${selection}" == "${entry_id}" ]]; then
        selected_id="${entry_id}"
        selected_name="${entry_name}"
        break
      fi
    done
  fi

  if [[ -z "${selected_id}" ]]; then
    echo "Selección no válida." >&2
    return 1
  fi

  id_ref="${selected_id}"
  name_ref="${selected_name}"
  return 0
}

function select_existing_tunnel() {
  local selected_id=""
  local selected_name=""

  choose_tunnel selected_id selected_name
  local choose_status=$?
  case ${choose_status} in
    0)
      ;;
    2)
      return 2
      ;;
    *)
      return 1
      ;;
  esac

  local cred_file="${CONFIG_DIR}/${selected_id}.json"
  if [[ ! -f "${cred_file}" ]]; then
    cred_file=""
  fi

  if configure_tunnel "${selected_name}" "${selected_id}" "${cred_file}"; then
    return 0
  fi
  return 1
}

function delete_tunnel_flow() {
  ensure_local_tunnel_metadata || true

  local managed_name="${LAST_CONFIGURED_TUNNEL_NAME}"
  local managed_id="${LAST_CONFIGURED_TUNNEL_ID}"
  local managed_cred="${LAST_CONFIGURED_CRED_FILE}"

  if [[ -z "${managed_id}" && -z "${managed_name}" ]]; then
    if ! load_local_tunnel_metadata managed_name managed_id managed_cred; then
      if ! discover_local_tunnel_metadata managed_name managed_id managed_cred; then
        echo "No se encontró información sobre un tunnel gestionado por este script." >&2
        echo "Crea uno nuevo con la opción [N] antes de intentar eliminarlo." >&2
        return 2
      fi
    fi
  fi

  local selected_id="${managed_id}"
  local selected_name="${managed_name}"
  local credential_hint="${managed_cred}"

  if [[ -z "${selected_id}" && -n "${credential_hint}" ]]; then
    if [[ -f "${credential_hint}" ]]; then
      selected_id="$(basename "${credential_hint}")"
      selected_id="${selected_id%.json}"
    fi
  fi

  if [[ -z "${selected_name}" && -n "${selected_id}" ]]; then
    selected_name="${selected_id}"
  fi

  if [[ -z "${selected_name}" && -z "${selected_id}" ]]; then
    echo "La metadata local no contiene nombre ni ID del tunnel. No se puede continuar." >&2
    return 2
  fi

  echo "Se eliminará el tunnel gestionado por este script:"
  echo "  Nombre: ${selected_name:-"(desconocido)"}"
  echo "  ID: ${selected_id:-"(desconocido)"}"
  if [[ -n "${credential_hint}" ]]; then
    echo "  Credencial local: ${credential_hint}"
  fi
  echo "Esta acción eliminará el tunnel en Cloudflare, sus credenciales locales,"
  echo "archivos de configuración asociados y los registros DNS CNAME que apunten a él."
  read -rp "¿Continuar con la eliminación? [y/N]: " confirm_delete
  if [[ ! "${confirm_delete}" =~ ^[yY]$ ]]; then
    echo "Operación cancelada."
    return 1
  fi

  local -a config_matches=()
  if [[ -d "${CONFIG_DIR}" ]]; then
    while IFS= read -r cfg_file; do
      if [[ -f "${cfg_file}" ]]; then
        local matches=0
        if [[ -n "${selected_id}" ]] && grep -Eq "^[[:space:]]*tunnel:[[:space:]]*${selected_id}" "${cfg_file}"; then
          matches=1
        elif [[ -n "${selected_name}" ]] && grep -Eq "^[[:space:]]*tunnel:[[:space:]]*${selected_name}" "${cfg_file}"; then
          matches=1
        fi
        if (( matches == 1 )); then
          config_matches+=("${cfg_file}")
        fi
      fi
    done < <(find "${CONFIG_DIR}" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null)
  fi

  while true; do
    read -rp "Ruta adicional de config a considerar (Enter para continuar): " extra_cfg
    if [[ -z "${extra_cfg}" ]]; then
      break
    fi
    if [[ -f "${extra_cfg}" ]]; then
      local matches=0
      if [[ -n "${selected_id}" ]] && grep -Eq "^[[:space:]]*tunnel:[[:space:]]*${selected_id}" "${extra_cfg}"; then
        matches=1
      elif [[ -n "${selected_name}" ]] && grep -Eq "^[[:space:]]*tunnel:[[:space:]]*${selected_name}" "${extra_cfg}"; then
        matches=1
      fi
      if (( matches == 1 )); then
        config_matches+=("${extra_cfg}")
      else
        echo "  - ${extra_cfg} no parece referenciar este tunnel (se omite)."
      fi
    else
      echo "  - ${extra_cfg} no existe (se omite)."
    fi
  done

  declare -A seen_files=()
  local unique_configs=()
  local cfg
  for cfg in "${config_matches[@]}"; do
    if [[ -n "${cfg}" && -z "${seen_files[${cfg}]:-}" ]]; then
      unique_configs+=("${cfg}")
      seen_files["${cfg}"]=1
    fi
  done
  config_matches=("${unique_configs[@]}")

  local -a dns_hostnames=()
  for cfg in "${config_matches[@]}"; do
    local -a file_hosts=()
    if collect_hostnames_from_config_file "${cfg}" file_hosts; then
      local h
      for h in "${file_hosts[@]}"; do
        if [[ -z "${h}" ]]; then
          continue
        fi
        local already=0
        local existing
        for existing in "${dns_hostnames[@]}"; do
          if [[ "${existing}" == "${h}" ]]; then
            already=1
            break
          fi
        done
        if (( already == 0 )); then
          dns_hostnames+=("${h}")
        fi
      done
    fi
  done

  if [[ ${#dns_hostnames[@]} -eq 0 ]]; then
    local manual_hosts=""
    read -rp "No se detectaron hostnames automáticamente. Escribe hostnames separados por espacio (Enter para omitir): " manual_hosts
    if [[ -n "${manual_hosts}" ]]; then
      read -ra manual_array <<< "${manual_hosts}"
      local mh
      for mh in "${manual_array[@]}"; do
        if [[ -z "${mh}" ]]; then
          continue
        fi
        local exists=0
        local existing
        for existing in "${dns_hostnames[@]}"; do
          if [[ "${existing}" == "${mh}" ]]; then
            exists=1
            break
          fi
        done
        if (( exists == 0 )); then
          dns_hostnames+=("${mh}")
        fi
      done
    fi
  fi

  if [[ ${#dns_hostnames[@]} -gt 0 ]]; then
    echo "Hostnames candidatos a eliminar: ${dns_hostnames[*]}"
    delete_dns_records_for_hostnames "${dns_hostnames[@]}" || true
  else
    echo "No se eliminarán registros DNS (no se proporcionaron hostnames)."
  fi

  echo "Eliminando tunnel remoto en Cloudflare..."
  local delete_status=1
  if [[ -n "${selected_id}" ]]; then
    set +e
    run_as_invoker cloudflared tunnel delete "${selected_id}"
    delete_status=$?
    set -e
  fi
  if [[ ${delete_status} -ne 0 && -n "${selected_name}" ]]; then
    echo "No se pudo eliminar el tunnel usando su ID. Intentando por nombre..." >&2
    set +e
    run_as_invoker cloudflared tunnel delete "${selected_name}"
    delete_status=$?
    set -e
  fi

  if [[ ${delete_status} -ne 0 && -n "${selected_id}" ]]; then
    echo "Eliminación fallida, ejecutando 'cloudflared tunnel cleanup ${selected_id}' para cerrar conexiones activas..." >&2
    set +e
    run_as_invoker cloudflared tunnel cleanup "${selected_id}"
    local cleanup_status=$?
    set -e
    if [[ ${cleanup_status} -eq 0 ]]; then
      if [[ -n "${selected_id}" ]]; then
        set +e
        run_as_invoker cloudflared tunnel delete "${selected_id}"
        delete_status=$?
        set -e
      fi
      if [[ ${delete_status} -ne 0 && -n "${selected_name}" ]]; then
        echo "Intentando nuevamente eliminar el tunnel por nombre tras cleanup..." >&2
        set +e
        run_as_invoker cloudflared tunnel delete "${selected_name}"
        delete_status=$?
        set -e
      fi
    else
      echo "No se pudo ejecutar 'cloudflared tunnel cleanup'. Código ${cleanup_status}." >&2
    fi
  fi

  local display_label="${selected_name:-${selected_id:-desconocido}}"

  if [[ ${delete_status} -eq 0 ]]; then
    echo "Tunnel '${display_label}' eliminado de Cloudflare."
  else
    echo "No se pudo eliminar el tunnel '${display_label}' en Cloudflare. Revisa manualmente." >&2
  fi

  local -a credential_candidates=()
  if [[ -n "${selected_id}" ]]; then
    credential_candidates+=("${CONFIG_DIR}/${selected_id}.json")
  fi
  if [[ -n "${selected_name}" && "${selected_name}" != "${selected_id}" ]]; then
    credential_candidates+=("${CONFIG_DIR}/${selected_name}.json")
  fi

  if [[ -n "${credential_hint}" ]]; then
    credential_candidates+=("${credential_hint}")
  fi

  declare -A seen_creds=()
  local cred_path
  for cred_path in "${credential_candidates[@]}"; do
    if [[ -f "${cred_path}" && -z "${seen_creds[${cred_path}]:-}" ]]; then
      read -rp "¿Eliminar credencial ${cred_path}? [Y/N]: " remove_cred
      if [[ "${remove_cred}" =~ ^[yY]$ ]]; then
        rm -f "${cred_path}" && echo "  - Credencial eliminada."
      else
        echo "  - Conservando ${cred_path}."
      fi
      seen_creds["${cred_path}"]=1
    fi
  done

  for cfg in "${config_matches[@]}"; do
    if [[ -f "${cfg}" ]]; then
      read -rp "¿Eliminar el archivo de configuración ${cfg}? [Y/N]: " remove_cfg
      if [[ "${remove_cfg}" =~ ^[yY]$ ]]; then
        rm -f "${cfg}" && echo "  - Configuración ${cfg} eliminada."
      else
        echo "  - Conservando ${cfg}."
      fi
    fi
  done

  if command -v systemctl >/dev/null 2>&1; then
    if [[ $(id -u) -eq 0 ]]; then
      declare -A seen_services=()
      local -a service_candidates=()
      local base_service=""
      if [[ -n "${selected_name}" ]]; then
        service_candidates+=("cloudflared-${selected_name}.service")
      fi
      if [[ -n "${selected_id}" && "${selected_id}" != "${selected_name}" ]]; then
        service_candidates+=("cloudflared-${selected_id}.service")
      fi

      if [[ -n "${credential_hint}" || -n "${selected_id}" || -n "${selected_name}" ]]; then
        while IFS= read -r unit_path; do
          base_service=$(basename "${unit_path}")
          if [[ -n "${selected_id}" ]] && grep -Eq "run[[:space:]]+${selected_id}" "${unit_path}"; then
            service_candidates+=("${base_service}")
            continue
          fi
          if [[ -n "${selected_name}" ]] && grep -Eq "run[[:space:]]+${selected_name}" "${unit_path}"; then
            service_candidates+=("${base_service}")
            continue
          fi
          if [[ -n "${credential_hint}" ]] && grep -Fq "${credential_hint}" "${unit_path}"; then
            service_candidates+=("${base_service}")
            continue
          fi
        done < <(find /etc/systemd/system -maxdepth 1 -type f -name 'cloudflared-*.service' 2>/dev/null || true)
      fi

      local -a unique_services=()
      for base_service in "${service_candidates[@]}"; do
        if [[ -z "${base_service}" ]]; then
          continue
        fi
        if [[ -z "${seen_services[${base_service}]:-}" ]]; then
          unique_services+=("${base_service}")
          seen_services["${base_service}"]=1
        fi
      done

      if [[ ${#unique_services[@]} -gt 0 ]]; then
        echo "Deteniendo y verificando la eliminación de servicios systemd asociados al tunnel..."
      fi

      local -a lingering_services=()
      local svc
      for svc in "${unique_services[@]}"; do
        if [[ -z "${svc}" ]]; then
          continue
        fi
        local list_output
        list_output=$(systemctl list-unit-files "${svc}" --type=service --no-legend 2>/dev/null || true)
        if [[ -z "${list_output//[[:space:]]/}" ]]; then
          continue
        fi

        echo "  - Procesando ${svc}"
        set +e
        systemctl disable --now "${svc}" >/dev/null 2>&1
        local disable_status=$?
        set -e
        if [[ ${disable_status} -eq 0 ]]; then
          echo "    Servicio detenido y deshabilitado."
        else
          echo "    No se pudo detener/deshabilitar ${svc}." >&2
        fi

        local service_path="/etc/systemd/system/${svc}"
        local removed_unit_file=0
        if [[ -f "${service_path}" ]]; then
          if rm -f "${service_path}"; then
            removed_unit_file=1
            echo "    Archivo ${service_path} eliminado."
          fi
        fi

        local log_path="/var/log/${svc%.service}.log"
        if [[ -f "${log_path}" ]]; then
          rm -f "${log_path}" && echo "    Log ${log_path} eliminado."
        fi

        if [[ ${removed_unit_file} -eq 1 ]]; then
          systemctl daemon-reload >/dev/null 2>&1 || true
        fi

        set +e
        local verify_output
        verify_output=$(systemctl list-unit-files "${svc}" --type=service --no-legend 2>/dev/null || true)
        local has_unit=0
        if [[ -n "${verify_output//[[:space:]]/}" ]]; then
          has_unit=1
        fi
        systemctl status "${svc}" --no-pager >/dev/null 2>&1
        local status_status=$?
        set -e
        local unit_missing=0
        if [[ ${status_status} -eq 4 ]]; then
          unit_missing=1
        fi
        if [[ ${has_unit} -eq 0 && ${unit_missing} -eq 1 ]]; then
          echo "    Verificación: ${svc} eliminado correctamente de systemd."
        else
          echo "    Advertencia: ${svc} sigue registrado en systemd tras el intento de eliminación." >&2
          lingering_services+=("${svc}")
        fi
      done

      if [[ ${#unique_services[@]} -gt 0 ]]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
      fi

      if [[ ${#lingering_services[@]} -gt 0 ]]; then
        echo "Algunos servicios podrían continuar activos pese al intento automático:" >&2
        local lingering
        for lingering in "${lingering_services[@]}"; do
          echo "  - ${lingering}" >&2
        done
        echo "Ejecuta 'systemctl disable --now <servicio>' manualmente para completar la limpieza." >&2
      fi
    else
      echo "Se detectó la opción de eliminar servicios, pero no tienes privilegios para hacerlo. Ejecuta con sudo para removerlos." >&2
    fi
  fi

  if [[ ${delete_status} -eq 0 ]]; then
    clear_local_tunnel_metadata
    echo "Limpieza completada. Puedes crear un nuevo tunnel desde cero."
    return 0
  fi

  return 1
}

function use_existing_tunnel() {
  while true; do
    local status
    select_existing_tunnel
    status=$?
    case ${status} in
      0)
        return 0
        ;;
      1)
        read -rp "¿Quieres intentar de nuevo? [Y/N]: " retry_choice
        if [[ ! "${retry_choice}" =~ ^[yY]$ ]]; then
          return 1
        fi
        ;;
      2)
        read -rp "¿Quieres crear uno nuevo ahora? [Y/N]: " create_now
        if [[ "${create_now}" =~ ^[yY]$ ]]; then
          return 2
        fi
        return 1
        ;;
      *)
        return 1
        ;;
    esac
  done
}

function ensure_certificate() {
  echo "Invoking user: ${INVOKER_USER}"
  echo "Looking for cert: ${CERT_FILE}"

  if [[ -f "${CERT_FILE}" ]]; then
    echo "Certificado ya existe en ${CERT_FILE}."
    return 0
  fi

  echo "No se encontró certificado. Ejecutando 'cloudflared login' como ${INVOKER_USER}..."

  mkdir -p "${CONFIG_DIR}"
  if [[ $(id -u) -eq 0 ]]; then
    chown "${INVOKER_USER}:" "${CONFIG_DIR}" 2>/dev/null || true
  fi

  local login_cmd=(cloudflared login)
  if command -v timeout >/dev/null 2>&1; then
    login_cmd=(timeout 300 cloudflared login)
    echo "Esperando respuesta de 'cloudflared login' (máx. 5 minutos)..."
  fi
  if ! run_as_invoker "${login_cmd[@]}"; then
    echo "Error ejecutando 'cloudflared login'. Revisa los mensajes anteriores." >&2
    return 1
  fi

  if [[ -f "${CERT_FILE}" ]]; then
    echo "Login completado y certificado guardado en ${CERT_FILE}"
    return 0
  fi

  echo "No se encontró ${CERT_FILE} después del login. Comprueba la salida de cloudflared para errores." >&2
  return 1
}

if ! ensure_certificate; then
  exit 1
fi

ensure_local_tunnel_metadata || true
report_local_tunnel_credentials

echo

while true; do
  mode=""
  while true; do
    echo "Opciones disponibles:"
    echo "  [N] Crear un nuevo tunnel"
    echo "  [E] Usar un tunnel existente"
    echo "  [D] Eliminar un tunnel"
    echo "  [Q] Salir sin cambios"
  read -rp "Selecciona una opción [N/E/D/Q]: " mode_input
    if [[ -z "${mode_input}" ]]; then
      mode_input="N"
    fi
    case "${mode_input}" in
      [nN])
        mode="create"
        break
        ;;
      [eE])
        mode="existing"
        break
        ;;
      [dD])
        mode="delete"
        break
        ;;
      [qQ])
        echo "No se realizarán cambios."
        exit 0
        ;;
      *)
        echo "Opción no válida. Intenta nuevamente." >&2
        ;;
    esac
  done

  if [[ "${mode}" == "create" ]]; then
    create_new_tunnel
    create_status=$?
    if [[ ${create_status} -eq 0 ]]; then
      exit 0
    fi
    continue
  fi

  if [[ "${mode}" == "delete" ]]; then
    delete_tunnel_flow
    delete_status=$?
    if [[ ${delete_status} -eq 0 ]]; then
      read -rp "¿Deseas eliminar otro tunnel? [Y/N]: " delete_again
      if [[ "${delete_again}" =~ ^[yY]$ ]]; then
        continue
      fi
      read -rp "¿Quieres crear un nuevo tunnel ahora? [Y/N]: " create_after_delete
      if [[ "${create_after_delete}" =~ ^[yY]$ ]]; then
        create_new_tunnel
        if [[ $? -eq 0 ]]; then
          exit 0
        fi
        continue
      fi
      echo "Operación completada."
      exit 0
    else
      read -rp "¿Intentar eliminar otro tunnel? [Y/N]: " retry_delete
      if [[ "${retry_delete}" =~ ^[yY]$ ]]; then
        continue
      fi
      echo "Regresando al menú principal."
      continue
    fi
  fi

  use_existing_tunnel
  existing_status=$?
  case ${existing_status} in
    0)
      exit 0
      ;;
    2)
      create_new_tunnel
      if [[ $? -eq 0 ]]; then
        exit 0
      fi
      continue
      ;;
    *)
      continue
      ;;
  esac
done

exit 0

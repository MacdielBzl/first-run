#!/usr/bin/env bash
set -euo pipefail

: "${HEARTBEAT_URL:=}"
: "${HEARTBEAT_TOKEN:=}"
: "${CLOUDFLARED_HOST_CMD:=/usr/bin/cloudflared tunnel info}"
: "${CLOUDFLARED_CONFIG_PATH:=}"
: "${TUNNEL_HOST_OVERRIDE:=}"
: "${HEARTBEAT_ROUTES:=}"
: "${HEARTBEAT_ACTIVE:=true}"
: "${CURL_TIMEOUT:=10}"
: "${LOG_FILE:=}"

METRIC_FIELDS=()
METRICS_OBJECT=""

log() {
    local message="$1"
    local timestamp
    timestamp="$(date +"%Y-%m-%d %H:%M:%S")"
    if [[ -n "${LOG_FILE}" ]]; then
        printf '%s %s\n' "${timestamp}" "${message}" | tee -a "${LOG_FILE}"
    else
        printf '%s %s\n' "${timestamp}" "${message}"
    fi
}

fail() {
    log "error: $1"
    exit "${2:-1}"
}

require_command() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        fail "command '${cmd}' is required but not found" 1
    fi
}

require_prerequisites() {
    require_command curl
    require_command cloudflared
}

trim() {
    local trimmed
    trimmed="${1}"
    trimmed="${trimmed#${trimmed%%[![:space:]]*}}"
    trimmed="${trimmed%${trimmed##*[![:space:]]}}"
    printf '%s' "${trimmed}"
}

lowercase() {
    printf '%s' "${1,,}"
}

normalize_active_flag() {
    local normalized
    normalized="$(lowercase "$(trim "${HEARTBEAT_ACTIVE}")")"
    case "${normalized}" in
        1|true|yes|on)
            printf 'true'
            ;;
        0|false|no|off)
            printf 'false'
            ;;
        *)
            fail "invalid HEARTBEAT_ACTIVE value '${HEARTBEAT_ACTIVE}' (expected boolean string)" 1
            ;;
    esac
}

escape_json_string() {
    local raw="$1"
    raw="${raw//\\/\\\\}"
    raw="${raw//\"/\\\"}"
    printf '%s' "${raw}"
}

read_temperature_c() {
    local temp_path="/sys/class/thermal/thermal_zone0/temp"
    local raw
    if [[ -r "${temp_path}" ]]; then
        raw="$(<"${temp_path}")"
        if [[ -n "${raw}" ]]; then
            awk -v val="${raw}" 'BEGIN { printf "%.2f", val / 1000 }'
            return 0
        fi
    fi
    if command -v vcgencmd >/dev/null 2>&1; then
        raw="$(vcgencmd measure_temp 2>/dev/null || true)"
        raw="$(printf '%s' "${raw}" | grep -Eo '[0-9]+\.[0-9]+')"
        if [[ -n "${raw}" ]]; then
            printf '%s' "${raw}"
            return 0
        fi
    fi
    return 1
}

read_cpu_load_percent() {
    if [[ ! -r /proc/stat ]]; then
        return 1
    fi
    local stat1 stat2
    stat1="$(grep '^cpu ' /proc/stat 2>/dev/null || true)"
    if [[ -z "${stat1}" ]]; then
        return 1
    fi
    sleep 0.5
    stat2="$(grep '^cpu ' /proc/stat 2>/dev/null || true)"
    if [[ -z "${stat2}" ]]; then
        return 1
    fi
    awk -v s1="${stat1}" -v s2="${stat2}" '
        function sum(arr, start, n,    i, total) {
            total = 0
            for (i=start; i<=n; i++) {
                total += arr[i]
            }
            return total
        }
        BEGIN {
            split(s1, a, " ")
            split(s2, b, " ")
            n = length(a)
            total1 = 0
            total2 = 0
            for (i = 2; i <= n; i++) {
                total1 += a[i]
                total2 += b[i]
            }
            idle1 = a[5] + a[6]
            idle2 = b[5] + b[6]
            diff_total = total2 - total1
            diff_idle = idle2 - idle1
            if (diff_total <= 0) {
                exit 1
            }
            usage = (diff_total - diff_idle) / diff_total * 100
            printf "%.2f", usage
        }
    '
}

read_memory_usage_mb() {
    if [[ ! -r /proc/meminfo ]]; then
        return 1
    fi
    awk '
        /^MemTotal:/ { total=$2 }
        /^MemAvailable:/ { available=$2 }
        END {
            if (total > 0 && available >= 0) {
                used = total - available
                printf "%d %d", used/1024, total/1024
            } else {
                exit 1
            }
        }
    ' /proc/meminfo
}

read_storage_usage_gb() {
    local used size
    if ! read -r used size < <(df -B1 --output=used,size / 2>/dev/null | tail -n 1); then
        return 1
    fi
    if [[ -z "${used}" || -z "${size}" ]]; then
        return 1
    fi
    awk -v u="${used}" -v s="${size}" 'BEGIN { printf "%.2f %.2f", u/1024/1024/1024, s/1024/1024/1024 }'
}

# Collect system metrics for heartbeat payload.
collect_metrics() {
    METRIC_FIELDS=()
    METRICS_OBJECT=""

    local temp cpu usage_mem usage_storage

    if temp="$(read_temperature_c)"; then
        METRIC_FIELDS+=("\"temperatureC\":${temp}")
    fi

    if cpu="$(read_cpu_load_percent)"; then
        METRIC_FIELDS+=("\"cpuLoadPercent\":${cpu}")
    fi

    if usage_mem="$(read_memory_usage_mb)"; then
        local mem_used mem_total
        read -r mem_used mem_total <<< "${usage_mem}"
        METRIC_FIELDS+=("\"memoryUsedMb\":${mem_used}")
        METRIC_FIELDS+=("\"memoryTotalMb\":${mem_total}")
    fi

    if usage_storage="$(read_storage_usage_gb)"; then
        local storage_used storage_total
        read -r storage_used storage_total <<< "${usage_storage}"
        METRIC_FIELDS+=("\"storageUsedGb\":${storage_used}")
        METRIC_FIELDS+=("\"storageTotalGb\":${storage_total}")
    fi

    if [[ ${#METRIC_FIELDS[@]} -eq 0 ]]; then
        return 1
    fi

    local metrics_json
    metrics_json="$(IFS=','; printf '%s' "${METRIC_FIELDS[*]}")"
    METRICS_OBJECT="{${metrics_json}}"
    return 0
}

cloudflared_config_paths() {
    local paths=()
    if [[ -n "${CLOUDFLARED_CONFIG_PATH}" ]]; then
        paths+=("${CLOUDFLARED_CONFIG_PATH}")
    fi
    paths+=("${HOME}/.cloudflared/config.yml" "/etc/cloudflared/config.yml")
    printf '%s\n' "${paths[@]}"
}

resolve_routes_from_config() {
    local collected=()
    local -A seen=()
    local path
    while IFS= read -r path; do
        if [[ -f "${path}" ]]; then
            while IFS= read -r route_line; do
                route_line="$(trim "${route_line}")"
                if [[ -n "${route_line}" && -z "${seen["${route_line}"]+x}" ]]; then
                    collected+=("${route_line}")
                    seen["${route_line}"]=1
                fi
            done < <(awk -F': *' 'BEGIN{IGNORECASE=1} {key=$1; gsub(/^[[:space:]-]+/,"",key); if (tolower(key)=="path") {print $2}}' "${path}" 2>/dev/null)
        fi
    done < <(cloudflared_config_paths)

    if [[ ${#collected[@]} -eq 0 ]]; then
        return 1
    fi
    printf '%s' "$(IFS=','; printf '%s' "${collected[*]}")"
    return 0
}

build_routes_json() {
    local routes_value="${HEARTBEAT_ROUTES}"
    if [[ -z "${routes_value}" ]]; then
        if routes_value="$(resolve_routes_from_config)"; then
            :
        fi
    fi
    if [[ -z "${routes_value}" ]]; then
        return 1
    fi
    local IFS=','
    read -r -a routes <<< "${routes_value}"
    local filtered=()
    local route trimmed escaped
    for route in "${routes[@]}"; do
        trimmed="$(trim "${route}")"
        if [[ -n "${trimmed}" ]]; then
            escaped="$(escape_json_string "${trimmed}")"
            filtered+=("\"${escaped}\"")
        fi
    done
    if [[ "${#filtered[@]}" -eq 0 ]]; then
        return 1
    fi
    local joined
    joined="$(IFS=','; printf '%s' "${filtered[*]}")"
    printf '[%s]' "${joined}"
    return 0
}

# Detect tunnel hostname via cloudflared metrics output with fallbacks.
resolve_hostname_from_config() {
    local hostname_from_cfg=""
    local path
    while IFS= read -r path; do
        if [[ -f "${path}" ]]; then
            hostname_from_cfg="$(awk -F': *' 'BEGIN{IGNORECASE=1} {key=$1; gsub(/^[[:space:]-]+/,"",key); if (tolower(key)=="hostname") {print $2; exit}}' "${path}" 2>/dev/null || true)"
            hostname_from_cfg="$(trim "${hostname_from_cfg}")"
            if [[ -n "${hostname_from_cfg}" ]]; then
                break
            fi
        fi
    done < <(cloudflared_config_paths)

    printf '%s' "${hostname_from_cfg}"
}

# Detect tunnel hostname via cloudflared metrics output with fallbacks.
resolve_hostname() {
    if [[ -n "${TUNNEL_HOST_OVERRIDE}" ]]; then
        printf '%s' "${TUNNEL_HOST_OVERRIDE}"
        return 0
    fi

    local host_line=""
    local cmd_status=0
    local cmd_output=""
    set +e
    cmd_output="$(${CLOUDFLARED_HOST_CMD} 2>/dev/null)"
    cmd_status=$?
    set -e
    if [[ ${cmd_status} -eq 0 ]]; then
        host_line="$(printf '%s' "${cmd_output}" | awk -F': *' '/hostname:/ {print $2; exit}')"
        host_line="$(trim "${host_line}")"
    fi

    if [[ -z "${host_line}" ]]; then
        host_line="$(resolve_hostname_from_config)"
        host_line="$(trim "${host_line}")"
    fi

    if [[ -z "${host_line}" ]]; then
        host_line="$(hostname -f 2>/dev/null || true)"
        host_line="$(trim "${host_line}")"
    fi

    if [[ -z "${host_line}" ]]; then
        fail "unable to determine tunnel hostname (set TUNNEL_HOST_OVERRIDE to bypass detection)" 1
    fi

    printf '%s' "${host_line}"
}

# Prepare heartbeat payload with normalized hostname and optional routes list.
prepare_payload() {
    local hostname
    hostname="$(resolve_hostname)"
    hostname="$(lowercase "${hostname}")"

    if [[ -z "${hostname}" ]]; then
        fail "detected hostname is empty" 1
    fi

    local active_flag
    active_flag="$(normalize_active_flag)"

    local fields=()
    fields+=("\"hostname\":\"$(escape_json_string "${hostname}")\"")
    fields+=("\"active\":${active_flag}")

    local routes_json
    if routes_json="$(build_routes_json)"; then
        fields+=("\"routes\":${routes_json}")
    fi

    if collect_metrics; then
        if [[ ${#METRIC_FIELDS[@]} -gt 0 ]]; then
            fields+=("${METRIC_FIELDS[@]}")
        fi
        if [[ -n "${METRICS_OBJECT}" ]]; then
            fields+=("\"metrics\":${METRICS_OBJECT}")
        fi
    fi

    local joined
    joined="$(IFS=','; printf '%s' "${fields[*]}")"
    printf '{%s}' "${joined}"
}

send_heartbeat() {
    if [[ -z "${HEARTBEAT_URL}" ]]; then
        fail "HEARTBEAT_URL is required" 1
    fi
    if [[ -z "${HEARTBEAT_TOKEN}" ]]; then
        fail "HEARTBEAT_TOKEN is required" 1
    fi

    local payload
    payload="$(prepare_payload)"

    log "sending heartbeat to ${HEARTBEAT_URL}"
    log "payload: ${payload}"

    local tmp_body
    tmp_body="$(mktemp)"
    trap '[[ -n ${tmp_body-} ]] && rm -f "${tmp_body}"' EXIT

    local attempt=1
    local max_attempts=3
    local backoff=1

    # Retry on 5xx or transient curl failures with exponential backoff.
    while [[ ${attempt} -le ${max_attempts} ]]; do
        local http_code curl_exit
        set +e
        http_code=$(curl -sS -m "${CURL_TIMEOUT}" \
            -w '%{http_code}' \
            -H 'Content-Type: application/json' \
            -H "x-device-token: ${HEARTBEAT_TOKEN}" \
            -X POST \
            -d "${payload}" \
            -o "${tmp_body}" \
            "${HEARTBEAT_URL}")
        curl_exit=$?
        set -e

        local body
        body="$(cat "${tmp_body}")"

        if [[ ${curl_exit} -ne 0 ]]; then
            log "curl execution failed on attempt ${attempt} (exit ${curl_exit}), retrying in ${backoff}s"
        elif [[ "${http_code}" == 200 ]]; then
            log "heartbeat ok (attempt ${attempt})"
            printf '%s\n' "${body}"
            return 0
        elif [[ "${http_code}" =~ ^4 ]]; then
            log "client error ${http_code} on attempt ${attempt}: ${body}"
            exit 2
        elif [[ "${http_code}" =~ ^5 ]]; then
            log "server error ${http_code} on attempt ${attempt}: ${body}"
        else
            log "unexpected response ${http_code} on attempt ${attempt}: ${body}"
            exit 3
        fi

        if [[ ${attempt} -lt ${max_attempts} ]]; then
            sleep "${backoff}"
            backoff=$((backoff * 2))
        fi
        attempt=$((attempt + 1))
    done

    log "heartbeat failed after ${max_attempts} attempts"
    exit 3
}

require_prerequisites
send_heartbeat

# Cron example:
# */2 * * * * /bin/bash /opt/esm/heartbeat-report.sh

#!/usr/bin/env bash
#
# Project:    oc-min-gather
# Executable: min-gather
# Description: High-speed OpenShift & HCP diagnostic snapshot with ICSP/IDMS auto-discovery.
#

set -u

WINDOW_MINUTES="${WINDOW_MINUTES:-30}"
TIMEOUT_SEC="${TIMEOUT_SEC:-10}"
CHECK_DNS="${CHECK_DNS:-kubernetes.default.svc}"

if command -v oc >/dev/null 2>&1; then
    CLI="oc"
elif command -v kubectl >/dev/null 2>&1; then
    CLI="kubectl"
else
    echo "Error: Neither 'oc' nor 'kubectl' found in PATH." >&2
    exit 1
fi

if ! ${CLI} whoami >/dev/null 2>&1; then
    echo "Error: Cluster unauthenticated. Please run 'oc login' first." >&2
    exit 1
fi

TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'mg.XXXXXX')
trap 'rm -rf "${TMP_DIR}"' EXIT

run_safe() {
    if command -v timeout >/dev/null 2>&1; then
        timeout --kill-after=1s "${TIMEOUT_SEC}s" \
            "${CLI}" --request-timeout="${TIMEOUT_SEC}s" "$@"
    else
        "${CLI}" --request-timeout="${TIMEOUT_SEC}s" "$@"
    fi
}

probe_endpoint() {
    local target="$1"
    local host="${target%%:*}"
    local port="${target##*:}"
    [[ "${host}" == "${port}" ]] && port=443

    if command -v curl >/dev/null 2>&1; then
        if curl -s -k --connect-timeout 2 -m 3 -o /dev/null "https://${host}:${port}" 2>/dev/null || \
           curl -s -k --connect-timeout 2 -m 3 -o /dev/null "http://${host}:${port}" 2>/dev/null; then
            echo "OK"
            return
        fi
    fi

    if timeout 2 bash -c "</dev/tcp/${host}/${port}" 2>/dev/null; then
        echo "OK"
    else
        echo "FAIL"
    fi
}

# Fetch bearer token for raw API endpoints
AUTH_TOKEN=$(${CLI} whoami -t 2>/dev/null || cat /var/run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null || echo "")

# 1. Parallel API collection
run_safe get clusterversion version -o jsonpath='{.status.history[0].version}{"\t"}{.spec.clusterID}{"\t"}{.spec.channel}{"\t"}{range .status.conditions[?(@.type=="Progressing")]}{.status}{" "}{.message}{end}{"\t"}{range .status.conditions[?(@.type=="Upgradeable")]}{.status}{end}{"\t"}{range .status.availableUpdates[*]}{.version}{" "}{end}{"\n"}' > "${TMP_DIR}/cv" 2>"${TMP_DIR}/cv.err" &
run_safe get infrastructure cluster -o jsonpath='{.status.platformStatus.type}{"\t"}{.status.controlPlaneTopology}{"\n"}' > "${TMP_DIR}/infra" 2>"${TMP_DIR}/infra.err" &
run_safe get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[*]}{.type}={.status}{" "}{end}{"\n"}{end}' > "${TMP_DIR}/nodes" 2>"${TMP_DIR}/nodes.err" &
run_safe get co -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[*]}{.type}={.status}{" "}{end}{"\n"}{end}' > "${TMP_DIR}/co" 2>"${TMP_DIR}/co.err" &
run_safe get mcp -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[*]}{.type}={.status}{" "}{end}{"\n"}{end}' > "${TMP_DIR}/mcp" 2>"${TMP_DIR}/mcp.err" &
run_safe get csv -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' > "${TMP_DIR}/csv" 2>"${TMP_DIR}/csv.err" &
run_safe get pods -A --no-headers > "${TMP_DIR}/pods" 2>"${TMP_DIR}/pods.err" &
run_safe get pvc -A --no-headers > "${TMP_DIR}/pvc" 2>"${TMP_DIR}/pvc.err" &
run_safe get events -A --field-selector type=Warning -o jsonpath='{range .items[*]}{.reason}{"\t"}{.series.lastObservedTime}{"\t"}{.lastTimestamp}{"\t"}{.eventTime}{"\t"}{.count}{"\n"}{end}' > "${TMP_DIR}/events" 2>"${TMP_DIR}/events.err" &

# Monitoring proxy alert check with token header
if [[ -n "${AUTH_TOKEN}" ]]; then
    run_safe get --raw "/api/v1/namespaces/openshift-monitoring/services/https:prometheus-k8s:9091/proxy/api/v1/alerts" --token="${AUTH_TOKEN}" > "${TMP_DIR}/alerts" 2>"${TMP_DIR}/alerts.err" &
else
    run_safe get --raw "/api/v1/namespaces/openshift-monitoring/services/https:prometheus-k8s:9091/proxy/api/v1/alerts" > "${TMP_DIR}/alerts" 2>"${TMP_DIR}/alerts.err" &
fi

run_safe get ds ovnkube-node -n openshift-ovn-kubernetes -o jsonpath='{.status.desiredNumberScheduled}{"\t"}{.status.numberReady}{"\n"}' > "${TMP_DIR}/ovn" 2>"${TMP_DIR}/ovn.err" &
run_safe get storagecluster -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.cephClusteredConditions[?(@.type=="Ready")].status}{"\n"}{end}' > "${TMP_DIR}/odf" 2>"${TMP_DIR}/odf.err" &

# Auto-detect System Image Registry route & Mirror Sets (IDMS / ITMS / ICSP)
run_safe get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' > "${TMP_DIR}/sys_reg" 2>/dev/null &
run_safe get idms,itms,icsp -o jsonpath='{range .items[*].spec.imageDigestMirrors[*].mirrors[*]}{@}{"\n"}{end}{range .items[*].spec.repositoryDigestMirrors[*].mirrors[*]}{@}{"\n"}{end}' > "${TMP_DIR}/mirrors" 2>/dev/null &

# DNS Reachability Probe
(
    if timeout 2 getent hosts "${CHECK_DNS}" >/dev/null 2>&1; then
        echo "OK" > "${TMP_DIR}/probe_dns"
    else
        echo "FAIL" > "${TMP_DIR}/probe_dns"
    fi
) &

wait

# 2. Resolve Registries & Run Reachability Probes
# System Registry
RESOLVED_SYS_REG=$(cat "${TMP_DIR}/sys_reg" 2>/dev/null || echo "")
if [[ -z "${RESOLVED_SYS_REG}" ]]; then
    RESOLVED_SYS_REG="${SYSTEM_REGISTRY:-image-registry.openshift-image-registry.svc:5000}"
fi
PROBE_SYS_STATUS=$(probe_endpoint "${RESOLVED_SYS_REG}")

# Mirror / External Registries
RESOLVED_MIRRORS=$(awk -F'/' '{print $1}' "${TMP_DIR}/mirrors" 2>/dev/null | sort -u | sed '/^$/d')
if [[ -z "${RESOLVED_MIRRORS}" ]]; then
    RESOLVED_MIRRORS=$(echo "${ADDITIONAL_REGISTRIES:-quay.io:443,registry.redhat.io:443}" | tr ',' '\n')
fi

EXTRA_REGS_LINES=""
EXTRA_REGS_TOTAL=0
EXTRA_REGS_FAILED=0

while read -r reg_addr; do
    reg_trimmed=$(echo "${reg_addr}" | tr -d ' ')
    [[ -z "${reg_trimmed}" ]] && continue
    st=$(probe_endpoint "${reg_trimmed}")
    (( EXTRA_REGS_TOTAL++ )) || true
    [[ "${st}" != "OK" ]] && (( EXTRA_REGS_FAILED++ )) || true
    EXTRA_REGS_LINES+=$'\n'"   └ $(printf "%-32s %s" "${reg_trimmed}:" "${st}")"
done <<< "${RESOLVED_MIRRORS}"

# 3. Parse Cluster Identity & Updates
if [[ -s "${TMP_DIR}/cv" ]]; then
    IFS=$'\t' read -r RAW_VER RAW_ID CHANNEL PROG_INFO UPGRADEABLE AVAIL_UPDATES < "${TMP_DIR}/cv" || true
    VERSION="${RAW_VER:-Unknown}"
    CLUSTER_ID="${RAW_ID:-Unknown}"
    CHANNEL="${CHANNEL:-None/Disconnected}"

    if [[ "${PROG_INFO}" =~ ^True ]]; then
        UPDATE_STATUS="In Progress (${PROG_INFO#True })"
    elif [[ -n "${AVAIL_UPDATES// /}" ]]; then
        AVAIL_COUNT=$(echo "${AVAIL_UPDATES}" | wc -w | tr -d ' ')
        LATEST_AVAIL=$(echo "${AVAIL_UPDATES}" | awk '{print $NF}')
        UPDATE_STATUS="${AVAIL_COUNT} Pending (Latest: ${LATEST_AVAIL} on ${CHANNEL})"
    else
        UPDATE_STATUS="Up to date (${CHANNEL})"
    fi

    [[ "${UPGRADEABLE}" == "False" ]] && UPDATE_STATUS="${UPDATE_STATUS} [Upgrade Blocked]"
else
    VERSION="Unavailable"
    CLUSTER_ID="Unavailable"
    UPDATE_STATUS="Unavailable"
fi

PLATFORM="Unknown"
CP_TOPOLOGY="Unknown"
if [[ -s "${TMP_DIR}/infra" ]]; then
    IFS=$'\t' read -r PLATFORM CP_TOPOLOGY < "${TMP_DIR}/infra" || true
    PLATFORM="${PLATFORM:-None}"
fi

IS_HCP=false
[[ "${CP_TOPOLOGY}" =~ External|HostedControlPlane ]] && IS_HCP=true

# 4. Nodes: Total (NotReady, Under Pressure)
if [[ -s "${TMP_DIR}/nodes" ]]; then
    TOTAL_NODES=$(wc -l < "${TMP_DIR}/nodes" | tr -d ' ')
    READY_NODES=$(grep -c "Ready=True" "${TMP_DIR}/nodes" || true)
    NOT_READY_NODES=$(( TOTAL_NODES - READY_NODES ))
    
    PRESSURE_NODES=$(awk -F'\t' '$2 ~ /DiskPressure=True/ || $2 ~ /MemoryPressure=True/ || $2 ~ /PIDPressure=True/ {print $1}' "${TMP_DIR}/nodes")
    PRESSURE_COUNT=$(echo "${PRESSURE_NODES}" | grep -c . || true)
    
    NODES_SUMMARY="${TOTAL_NODES} Total (${NOT_READY_NODES} NotReady, ${PRESSURE_COUNT} Under Pressure)"
else
    NODES_SUMMARY="Unavailable"
fi

# 5. MachineConfigPools: Total (Degraded, Updating)
if [[ "${IS_HCP}" == "true" ]]; then
    MCP_SUMMARY="N/A (Hosted Control Plane)"
elif [[ -s "${TMP_DIR}/mcp" ]]; then
    TOTAL_MCP=$(wc -l < "${TMP_DIR}/mcp" | tr -d ' ')
    MCP_DEGRADED_COUNT=$(awk -F'\t' '$2 ~ /Degraded=True/' "${TMP_DIR}/mcp" | wc -l | tr -d ' ')
    MCP_UPDATING_COUNT=$(awk -F'\t' '$2 ~ /Updating=True/' "${TMP_DIR}/mcp" | wc -l | tr -d ' ')
    MCP_SUMMARY="${TOTAL_MCP} Total (${MCP_DEGRADED_COUNT} Degraded, ${MCP_UPDATING_COUNT} Updating)"
else
    MCP_SUMMARY="0 Total"
fi

# 6. Cluster Operators: Total (Degraded, Unavailable)
if [[ -s "${TMP_DIR}/co" ]]; then
    TOTAL_CO=$(wc -l < "${TMP_DIR}/co" | tr -d ' ')
    DEGRADED_CO_COUNT=$(awk -F'\t' '$2 ~ /Degraded=True/' "${TMP_DIR}/co" | wc -l | tr -d ' ')
    UNAVAIL_CO_COUNT=$(awk -F'\t' '$2 ~ /Available=False/' "${TMP_DIR}/co" | wc -l | tr -d ' ')
    ERR_CO_LIST=$(awk -F'\t' '$2 ~ /Degraded=True/ || $2 ~ /Available=False/ {print $1}' "${TMP_DIR}/co" | sort -u)
    ERR_CO_COUNT=$(echo "${ERR_CO_LIST}" | grep -c . || true)
    CO_SUMMARY="${TOTAL_CO} Total (${DEGRADED_CO_COUNT} Degraded, ${UNAVAIL_CO_COUNT} Unavailable)"
else
    CO_SUMMARY="Unavailable"
    ERR_CO_COUNT=0
    ERR_CO_LIST=""
fi

# 7. Installed Operators: Total (Failed)
if [[ -s "${TMP_DIR}/csv" ]]; then
    TOTAL_CSV=$(wc -l < "${TMP_DIR}/csv" | tr -d ' ')
    ERR_CSV_LIST=$(awk -F'\t' '$2 != "Succeeded" {print $1}' "${TMP_DIR}/csv")
    ERR_CSV_COUNT=$(echo "${ERR_CSV_LIST}" | grep -c . || true)
    CSV_SUMMARY="${TOTAL_CSV} Total (${ERR_CSV_COUNT} Failed)"
else
    CSV_SUMMARY="0 Total (0 Failed)"
    ERR_CSV_COUNT=0
    ERR_CSV_LIST=""
fi

# 8. OVN-Kubernetes: Total (NotReady)
if [[ -s "${TMP_DIR}/ovn" ]]; then
    IFS=$'\t' read -r OVN_DESIRED OVN_READY < "${TMP_DIR}/ovn" || true
    OVN_DESIRED="${OVN_DESIRED:-0}"
    OVN_READY="${OVN_READY:-0}"
    OVN_NOT_READY=$(( OVN_DESIRED - OVN_READY ))
    OVN_SUMMARY="${OVN_DESIRED} Total (${OVN_NOT_READY} NotReady)"
else
    OVN_SUMMARY="N/A (Hosted Control Plane or Not Found)"
fi

# 9. ODF / Ceph StorageCluster: Total (Degraded)
if [[ -s "${TMP_DIR}/odf" ]]; then
    TOTAL_ODF=$(wc -l < "${TMP_DIR}/odf" | tr -d ' ')
    ERR_ODF=$(awk -F'\t' '$2 != "Ready" && $2 != "PhaseReady" || $3 == "False"' "${TMP_DIR}/odf" | wc -l | tr -d ' ')
    ODF_SUMMARY="${TOTAL_ODF} Total (${ERR_ODF} Degraded)"
else
    ODF_SUMMARY="Not Installed"
fi

# 10. PersistentVolumeClaims: Total (Unbound)
if [[ -s "${TMP_DIR}/pvc" ]]; then
    TOTAL_PVC=$(wc -l < "${TMP_DIR}/pvc" | tr -d ' ')
    UNBOUND_PVC=$(grep -v " Bound " "${TMP_DIR}/pvc" | grep -c . || true)
    PVC_SUMMARY="${TOTAL_PVC} Total (${UNBOUND_PVC} Unbound)"
else
    PVC_SUMMARY="0 Total (0 Unbound)"
fi

# 11. Prometheus Alerts
CRIT_ALERTS="0"
WARN_ALERTS="0"
CRIT_NAMES=""
if [[ -s "${TMP_DIR}/alerts" && ! -s "${TMP_DIR}/alerts.err" ]]; then
    eval "$(awk -v RS='{"labels":{' '
      /"state":"firing"/ {
        name = ""
        severity = ""
        if (match($0, /"alertname":"([^"]+)"/, arr)) name = arr[1]
        if (match($0, /"severity":"([^"]+)"/, arr)) severity = arr[1]

        if (severity == "critical") {
          crit_count++
          if (name != "" && !seen[name]++) crit_names = (crit_names == "" ? name : crit_names " " name)
        } else if (severity == "warning") {
          warn_count++
        }
      }
      END { printf "CRIT_ALERTS=%d\nWARN_ALERTS=%d\nCRIT_NAMES=\"%s\"\n", crit_count, warn_count, crit_names }
    ' "${TMP_DIR}/alerts" 2>/dev/null)"
    TOTAL_ALERTS=$(( CRIT_ALERTS + WARN_ALERTS ))
    ALERT_SUMMARY="${TOTAL_ALERTS} Total (${CRIT_ALERTS} Critical, ${WARN_ALERTS} Warning)"
else
    ALERT_SUMMARY="Unavailable (Missing RBAC / Unreachable)"
fi

# 12. Pod Anomalies
if [[ -f "${TMP_DIR}/pods" && ! -s "${TMP_DIR}/pods.err" ]]; then
    CRASHLOOP=$(grep -c "CrashLoopBackOff" "${TMP_DIR}/pods" || true)
    IMAGEPULL=$(grep -c -E "ImagePullBackOff|ErrImagePull" "${TMP_DIR}/pods" || true)
    CREATE_ERR=$(grep -c "CreateContainerConfigError" "${TMP_DIR}/pods" || true)
    PENDING=$(awk '$4 == "Pending"' "${TMP_DIR}/pods" | wc -l | tr -d ' ')
    FAILED=$(awk '$4 ~ /Error|Failed/' "${TMP_DIR}/pods" | wc -l | tr -d ' ')
else
    CRASHLOOP="?"; IMAGEPULL="?"; CREATE_ERR="?"; PENDING="?"; FAILED="?"
fi

# 13. Warning Events (In-memory Awk)
if [[ -s "${TMP_DIR}/events" ]]; then
    FORMATTED_WARNINGS=$(
      awk -F'\t' -v window="${WINDOW_MINUTES}" '
        BEGIN { now = systime(); cutoff = now - (window * 60) }
        {
          reason = $1
          if (!reason || reason == "DNSConfigForming") next
          ts = ($2 ? $2 : ($3 ? $3 : $4))
          if (!ts) next
          split(ts, a, "[-T:Z]")
          event_epoch = mktime(a[1] " " a[2] " " a[3] " " a[4] " " a[5] " " a[6], 1)
          if (event_epoch >= cutoff) reasons[reason] += ($5 ? $5 : 1)
        }
        END { for (r in reasons) printf "%d\t%s\n", reasons[r], r }
      ' "${TMP_DIR}/events" | sort -rn | head -n 5 | awk -F'\t' '{print " - " $2 ": " $1 " occurrences"}'
    )
    [[ -z "${FORMATTED_WARNINGS}" ]] && FORMATTED_WARNINGS=" - None detected"
else
    FORMATTED_WARNINGS=" - Timed out or no events available"
fi

PROBE_DNS_STATUS=$(cat "${TMP_DIR}/probe_dns" 2>/dev/null || echo "FAIL")

# Print Summary
cat <<EOF
=== min-gather summary ===
Cluster ID:          ${CLUSTER_ID}
Platform:            ${PLATFORM}$([[ "${IS_HCP}" == "true" ]] && echo " (HostedControlPlane)")
Cluster Version:     ${VERSION}
Update Status:       ${UPDATE_STATUS}

Cluster Health:
 - Nodes:                     ${NODES_SUMMARY}
 - MachineConfigPools:        ${MCP_SUMMARY}
 - Cluster Operators:         ${CO_SUMMARY}
$([[ ${ERR_CO_COUNT} -gt 0 ]] && echo "   └ Error Operators:         $(echo ${ERR_CO_LIST} | tr '\n' ' ')")
 - Installed Operators:       ${CSV_SUMMARY}
$([[ ${ERR_CSV_COUNT} -gt 0 ]] && echo "   └ Error Operators:         $(echo ${ERR_CSV_LIST} | tr '\n' ' ')")
 - OVN-Kubernetes Nodes:      ${OVN_SUMMARY}
 - ODF / Ceph Clusters:       ${ODF_SUMMARY}
 - Storage PVCs:              ${PVC_SUMMARY}
 - Firing Alerts:             ${ALERT_SUMMARY}
$([[ ${CRIT_ALERTS} -gt 0 && -n "${CRIT_NAMES}" ]] && echo "   └ Critical Alerts:         ${CRIT_NAMES}")

Reachability:
 - DNS Resolution:            ${PROBE_DNS_STATUS} (${CHECK_DNS})
 - System Registry:           ${PROBE_SYS_STATUS} (${RESOLVED_SYS_REG})
 - Mirror / Registries:       ${EXTRA_REGS_TOTAL} Total (${EXTRA_REGS_FAILED} Failed)${EXTRA_REGS_LINES}

Pod Anomalies:
 - CrashLoopBackOff:          ${CRASHLOOP}
 - ImagePullBackOff:          ${IMAGEPULL}
 - CreateContainerConfigErr:  ${CREATE_ERR}
 - Pending Pods:              ${PENDING}
 - Failed Pods:               ${FAILED}

Top 5 Warning Events (Last ${WINDOW_MINUTES}m):
${FORMATTED_WARNINGS}
==========================
EOF
# oc-min-gather (`min-gather`)

A high-speed, read-only diagnostic snapshot collector for OpenShift and Hosted Control Planes (HyperShift). 
It aggregates core cluster health, degraded operators, update states, pod anomalies, active alerts, and network 
reachability into a standardized, ticket-ready Markdown block in **under 1 second**.

## Key Features

* **Sub-Second Execution:** Queries control plane endpoints concurrently in the background; processes events and dates in memory via single-pass `awk`.
* **Zero Dependencies:** Pure Bash, GNU `awk`, and standard coreutils (`timeout`, `getent`). No Python or third-party binaries required.
* **HCP & OLM Aware:** Supports Hosted Control Planes (HyperShift) by handling decoupled node pools and external control plane topologies gracefully.
* **Strict Timeouts:** API queries enforce native timeouts alongside OS-level process bounds so stuck clusters or broken proxies never hang the script.
* **Read-Only & Secure:** Gathers only high-level status counts and names—no secrets, ConfigMaps, or sensitive environment variables are extracted.


## Quickstart (One-Liner)

Run directly against your current `oc` / `kubectl` login context without cloning the repo:

```bash
curl -sSL https://raw.githubusercontent.com/dm0dev/oc-min-gather/main/min-gather | bash

```

To pass environment overrides inline:

```bash
curl -sSL https://raw.githubusercontent.com/dm0dev/oc-min-gather/main/min-gather | \
  CHECK_DNS="api.cluster.example.com" \
  ADDITIONAL_REGISTRIES="quay.io:443,registry.redhat.io:443" \
  bash

```

---

## Manual Installation

1. Download the script:
```bash
curl -sSL -o min-gather https://raw.githubusercontent.com/dm0dev/oc-min-gather/main/min-gather
chmod +x min-gather

```


2. (Optional) Move to your system PATH:
```bash
sudo mv min-gather /usr/local/bin/

```



---

## Usage

Ensure you are logged into your cluster (`oc whoami`), then run:

```bash
min-gather

```

### CLI Options

| Flag                         | Description                         | Default                              |
|------------------------------|-------------------------------------|--------------------------------------|
| `-d, --dns <host>`           | Target host for DNS lookup check    | `api.crc.testing`                    |
| `-r, --registry <host:port>` | Core system registry endpoint       | In-cluster route                     |
| `-e, --extra-regs <list>`    | Comma-separated external registries | `quay.io:443,registry.redhat.io:443` |
| `-w, --window <mins>`        | Time window for warning events      | `30`                                 |
| `-t, --timeout <secs>`       | Timeout limit per API call          | `3`                                  |
| `-h, --help`                 | Show usage options                  |                                      |

All options can also be configured via environment variables (`CHECK_DNS`, `SYSTEM_REGISTRY`, `ADDITIONAL_REGISTRIES`, `WINDOW_MINUTES`, `TIMEOUT_SEC`).

---

## Customer Support Workflow

When filing an incident ticket with the SRE team:

1. Run `min-gather`.
2. Copy the generated summary block from your terminal.
3. Paste it directly into the ticket description (Jira, ServiceNow, Slack, or GitHub Issues).

### Example Output

```text
=== min-gather summary ===
Cluster ID:          4443463b-5ae3-485f-962f-5ccef820f922
Platform:            BareMetal (HostedControlPlane)
Cluster Version:     4.22.14
Update Status:       Up to date (fast-4.22)

Cluster Health:
 - Nodes:                     6 Total (0 NotReady, 0 Under Pressure)
 - MachineConfigPools:        N/A (Hosted Control Plane)
 - Cluster Operators:         24 Total (0 Degraded, 0 Unavailable)
 - Installed Operators:       4 Total (1 Failed)
   └ Error Operators:         openshift-operators/elasticsearch-operator.v5.8.1
 - OVN-Kubernetes Nodes:      6 Total (0 NotReady)
 - ODF / Ceph Clusters:       1 Total (0 Degraded)
 - Storage PVCs:              18 Total (0 Unbound)
 - Firing Alerts:             3 Total (1 Critical, 2 Warning)
   └ Critical Alerts:         KubeNodeNotReady

Reachability:
 - DNS Resolution:            OK (api.crc.testing)
 - System Registry:           OK (default-route-openshift-image-registry.apps-crc.testing:443)
 - External Registries:       2 Total (0 Failed)
   └ quay.io:443:             OK
   └ registry.redhat.io:443:  OK

Pod Anomalies:
 - CrashLoopBackOff:          0
 - ImagePullBackOff:          0
 - CreateContainerConfigErr:  0
 - Pending Pods:              0
 - Failed Pods:               0

Top 5 Warning Events (Last 30m):
 - FailedMount: 4 occurrences
==========================

```


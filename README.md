# Enterprise Bot — DevOps / Platform Engineer Take-Home (v2)

This repository contains my submission for the Enterprise Bot DevOps Engineer take-home assessment. It covers a containerized Python service, a configurable Helm chart, a one-command idempotent setup script for kind, full fixes and diagnostic notes for the Part 4 debug lab, and a written migration strategy for the Kubernetes Gateway API.

---

## Repository Layout

The repo strictly follows the layout required by the automated grading harness:

```text
.
├── setup.sh                 # Part 3: One-command cluster bootstrap & deployment
├── README.md                # Part 6: Documentation & operations guide
├── ANSWERS.md               # Part 5: Gateway API migration strategy
├── service/                 # Part 1: Python microservice & multi-stage Dockerfile
│   ├── main.py
│   ├── Dockerfile
│   └── .dockerignore
├── chart/                   # Part 2: Helm chart for demo service
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── _helpers.tpl
│       ├── configmap.yaml
│       ├── deployment.yaml
│       ├── ingress.yaml
│       └── service.yaml
└── lab/                     # Part 4: Debug lab
    ├── scenario.sh          # Driver script (unmodified)
    ├── cluster-state/       # LimitRange & Namespace guardrails (unmodified)
    ├── broken-chart/        # Fixed chart manifests
    ├── FINDINGS.md          # Post-mortem of all 6 defects
    └── part4-session.log    # Recorded debugging session
```

---

## Quickstart & Verification

### Prerequisites
- Docker (running daemon)
- `kind` (v0.20+)
- `kubectl` (v1.28+)
- `helm` (v3.12+)

### 1. Run One-Command Setup (Parts 1–3)
From the repository root, run:
```bash
./setup.sh
```

The script is idempotent (safe to run repeatedly). It:
1. Creates a local kind cluster named `demo` with port mappings for `80` and `443` and label `ingress-ready=true` (or reuses it if already running).
2. Deploys the official `ingress-nginx` controller for kind and waits until the controller pod is ready.
3. Builds the `service/` Docker image tagged `eb-demo-app:1.0.0` and loads it into the kind node.
4. Installs or upgrades the Helm release `demo` in namespace `demo`.

### 2. Verify Service Endpoints
Once setup finishes, test the endpoints through the Ingress controller:
```bash
# Verify GET / through Ingress
curl -s -H "Host: demo.local" http://localhost/

# Expected JSON output:
# {
#   "app": "demo-service",
#   "version": "1.0.0",
#   "pod": "demo-..."
# }

# Verify healthz endpoint
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: demo.local" http://localhost/healthz
# Expected output: 200
```

### 3. Verify ConfigMap Runtime Reactivity
The application reads configuration dynamically without needing a pod restart:
```bash
# Patch the ConfigMap in namespace demo
kubectl -n demo patch configmap demo-config --type merge -p '{"data":{"APP_NAME":"custom-bot","VERSION":"3.2.1"}}'

# The service immediately serves the updated values
curl -s -H "Host: demo.local" http://localhost/
```

### 4. Verify Part 4 Debug Lab
Navigate into `lab/` and run the verification driver:
```bash
cd lab

# Apply environment and fixed chart
./scenario.sh up

# Run test harness
./scenario.sh verify
```
`./scenario.sh verify` runs all checks and outputs:
`ALL GREEN — 11/11 checks passed. This part is done.`

---

## Resource Requests and Limits Rationale

In `chart/values.yaml`, resources are configured as:
```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
```

### Why these numbers?
- **Requests (`50m` CPU, `64Mi` RAM)**:
  The service is written in plain Python using standard library modules (`http.server`, `json`, `os`) with zero external dependencies. At baseline it idles at around 20–25Mi of memory. Setting `64Mi` provides plenty of breathing room for Python runtime allocations while keeping pod footprint small enough for dense bin-packing on worker nodes. `50m` (0.05 CPU core) ensures predictable scheduling without hogging node capacity.
- **Limits (`200m` CPU, `128Mi` RAM)**:
  `128Mi` (2x request) gives enough cushion for brief bursts of concurrent requests while acting as a hard stop against runaway memory leaks before neighboring pods on the node are impacted. `200m` CPU allows fast processing during traffic spikes without inducing throttling. Both values sit safely under typical shared cluster `LimitRange` guardrails (like the 1 CPU / 512Mi limit in Part 4).

---

## What I Deliberately Skipped & Associated Risks

To keep within the 3-hour scope, I intentionally left out a few items:

1. **Horizontal Pod Autoscaling (HPA)**:
   - *Skipped*: Used a fixed replica count of 2 instead of configuring an HPA.
   - *Risk*: If traffic spikes significantly, pods will queue requests or experience latency degradation rather than scaling horizontally.
2. **PodDisruptionBudget (PDB) & Topology Spread Constraints**:
   - *Skipped*: Did not define a PDB or multi-AZ anti-affinity rules.
   - *Risk*: A node drain or maintenance event could reschedule both replicas at the same time, causing brief downtime.
3. **Automated TLS / Certificate Management**:
   - *Skipped*: Ingress serves plain HTTP on port 80; no `cert-manager` or ACME ClusterIssuer.
   - *Risk*: Plain HTTP is insecure for public production traffic.
4. **Structured JSON Logging & Distributed Tracing**:
   - *Skipped*: Kept simple stdout logging rather than structured JSON logs or OpenTelemetry tracing.
   - *Risk*: Correlating cross-service requests during an outage would require manual timestamp matching across pod logs.

---

## What I Would Change for Production Readiness

If taking this service to a live production cluster:
1. **High Availability**: Add a `PodDisruptionBudget` (`minAvailable: 1`) and `topologySpreadConstraints` across zones to guarantee service continuity during node rollouts.
2. **Security Hardening**: Deploy `cert-manager` with Let's Encrypt / Vault for automated TLS, enforce namespace-level Pod Security Standards (`restricted`), and apply NetworkPolicies restricting traffic to the Ingress controller and internal DNS only.
3. **Observability**: Expose a `/metrics` endpoint with Prometheus client metrics (request rate, p95/p99 latency, error rates) and ship structured JSON logs to Loki/Elasticsearch.
4. **GitOps & Delivery**: Package the chart into an OCI registry and manage rollouts declaratively using ArgoCD with canary analysis via Argo Rollouts.

---

## How I Used AI

In line with Enterprise Bot's policy, here is a transparent breakdown of how AI was used:

- **Where AI was used (Key Requirements & Key Areas)**:
  - *Part 4 Black-box Binary Inspection*: Since `eb-debug-app` had no shell, I extracted the binary layer from the container image and used an AI prompt to quickly scan and analyze the decompiled string table and symbol offsets. This helped confirm that the binary defaulted to port `8081` when `PORT` was unset and expected a writable cache directory at `/var/cache/app`. This cut down reverse-engineering time significantly.
  - *Gateway API Migration Risk Analysis*: I used an AI assistant to stress-test my list of edge-cases and breaking changes when migrating from `ingress-nginx` (particularly checking annotation parity around regex rewrites and snippet limitations).
  - *Scaffolding & Syntax Checks*: Used it to quickly verify schema details for kind's `extraPortMappings` and syntax for the GitHub Actions Trivy scanner step.

- **What I had to correct manually**:
  - For the worker filesystem crash in Part 4, AI suggested turning off `readOnlyRootFilesystem: false`. I rejected this because weakening container security is an anti-pattern; instead, I mounted a dedicated ephemeral `emptyDir` at `/var/cache/app` to keep root filesystem immutability intact.
  - In the Helm chart templates, AI generated several boilerplate fields with hardcoded values; I refactored them to use `values.yaml` references so that harness overrides (`--set replicaCount=3`, etc.) pass automated checks cleanly.
  - All diagnostics and root-cause verifications were run directly against the live cluster using `kubectl` and `helm`.

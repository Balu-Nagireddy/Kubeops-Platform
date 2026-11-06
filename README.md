# Enterprise Bot — DevOps / Platform Engineer Take-Home (v2)

This repository contains my submission for the Enterprise Bot DevOps Engineer technical evaluation. It includes a containerized Python microservice, a configurable Helm chart, an idempotent one-command setup script for a local `kind` cluster with `ingress-nginx`, complete fixes and findings for the Part 4 debug lab, and architectural reasoning on Gateway API migration.

---

## Repository Layout

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
    ├── FINDINGS.md          # Detailed post-mortem of all 6 defects
    └── part4-session.log    # Raw terminal session recording
```

---

## Quickstart & Verification

### Prerequisites
- Docker (running daemon)
- `kind` (v0.20+)
- `kubectl` (v1.28+)
- `helm` (v3.12+)

### 1. Run One-Command Setup (Parts 1–3)
Run the automated bootstrap script from the repository root:
```bash
./setup.sh
```
This script is strictly idempotent. It:
1. Provisions a local `kind` cluster named `demo` with port mappings for `80` and `443` and label `ingress-ready=true` (or reuses it if already running).
2. Deploys the official `ingress-nginx` controller for kind and waits for readiness.
3. Builds the `service/` Docker image tagged `eb-demo-app:1.0.0` and loads it into the kind control-plane node.
4. Installs/upgrades the Helm chart as release `demo` into namespace `demo`.

### 2. Verify Service Endpoints
Once setup completes, verify connectivity through the Ingress controller:
```bash
# Verify GET / through Ingress
curl -s -H "Host: demo.local" http://localhost/

# Expected output:
# {
#   "app": "demo-service",
#   "version": "1.0.0",
#   "pod": "demo-..."
# }

# Verify healthz probe endpoint
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: demo.local" http://localhost/healthz
# Expected output: 200
```

### 3. Verify ConfigMap Runtime Reactivity
The application dynamically reads configuration:
```bash
# Patch the ConfigMap in namespace demo
kubectl -n demo patch configmap demo-config --type merge -p '{"data":{"APP_NAME":"custom-bot","VERSION":"3.2.1"}}'

# ConfigMap volumes are updated asynchronously by kubelet. Poll until
# the projected files are refreshed and the new values are visible.
updated=0
for attempt in $(seq 1 30); do
  response="$(curl -fsS -H "Host: demo.local" http://localhost/)" || response=""
  if printf '%s' "$response" | grep -q '"app": "custom-bot"' &&
     printf '%s' "$response" | grep -q '"version": "3.2.1"'; then
    printf '%s\n' "$response"
    updated=1
    break
  fi
  sleep 2
done
if [ "$updated" -ne 1 ]; then
  echo "ERROR: ConfigMap values were not observed within 60 seconds." >&2
  exit 1
fi
```

### 4. Verify Part 4 Debug Lab
Navigate to the `lab/` folder and run the verification suite:
```bash
cd lab

# Apply fixes and install
./scenario.sh up

# Run validation checks
./scenario.sh verify
```
`./scenario.sh verify` will execute all 11 assertions and output:
`ALL GREEN — 11/11 checks passed. This part is done.`

---

## CI Validation

The GitHub Actions workflow (`.github/workflows/ci.yml`) runs on pushes and pull requests. It:

- Lints and renders the application Helm chart with representative value overrides.
- Lints and renders the Part 4 debug chart.
- Builds the service container image.
- Runs Trivy against OS and application-library vulnerabilities and fails on any reported HIGH or CRITICAL finding, including findings without an available fix.

The CI workflow provides static validation; the local `kind` setup and Part 4 cluster scenario must still be executed in the target environment.

---

## Resource Requests and Limits Rationale

In `chart/values.yaml`, resources are set as:
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
1. **Requests (`50m` CPU, `64Mi` RAM)**:
   - The Python service relies solely on the standard library (`http.server`, `json`, `os`), with zero heavy frameworks or native extensions.
   - At idle, the runtime consumes under `25Mi` of memory. Setting `64Mi` provides enough headroom for Python's memory allocator without wasting node allocatable capacity.
   - `50m` (0.05 core) guarantees predictable scheduling on shared nodes while allowing dense pod packing.
2. **Limits (`200m` CPU, `128Mi` RAM)**:
   - Memory limit is set at `128Mi` (2x request). This acts as a circuit breaker against unforeseen memory leaks or large incoming request payloads, triggering OOMKills before neighboring pods on the node are affected.
   - CPU limit is set at `200m` (4x burst). This permits rapid JSON serialization and handshake processing during traffic bursts without causing CPU throttling during steady-state traffic.
   - These values also conform cleanly within standard namespace `LimitRange` guardrails (such as the `1 CPU / 512Mi` ceiling observed in the Part 4 lab).

---

## What I Deliberately Skipped & Associated Risks

To stay within the 3-hour envelope, several production features were intentionally skipped:

1. **Horizontal Pod Autoscaler (HPA)**:
   - *Skipped*: Deployed a static replica count of 2 rather than configuring an HPA targeting CPU/memory utilization.
   - *Risk*: Unable to automatically absorb sudden traffic spikes or scale down to save compute during quiet hours.
2. **PodDisruptionBudget (PDB) & Topology Spread Constraints**:
   - *Skipped*: No PDB or `topologySpreadConstraints` configured across failure domains.
   - *Risk*: Node drains or maintenance events could evict both replicas simultaneously, resulting in a brief service outage.
3. **Automated TLS / Ingress Certificate Management**:
   - *Skipped*: Ingress relies on plain HTTP on port 80; no `cert-manager` or Let's Encrypt `ClusterIssuer` configured.
   - *Risk*: Traffic travels unencrypted across the network boundary, which is unsuitable for public production exposure.
4. **Structured JSON Logging & Distributed Tracing**:
   - *Skipped*: Python service writes simple text logs to stdout; no OpenTelemetry instrumentation or trace context propagation.
   - *Risk*: In multi-tier microservice architectures, debugging cross-service latency regressions without trace IDs requires manual log correlation across pods.

---

## What I Would Change for Production Readiness

If deploying this platform to a live production cluster:
1. **High Availability & Scheduling**:
   - Configure a `PodDisruptionBudget` (`minAvailable: 1`).
   - Define `topologySpreadConstraints` and pod anti-affinity to ensure replicas never land on the same worker node or availability zone.
2. **Traffic Management & Security**:
   - Install `cert-manager` for automated TLS certificate issuance and renewal via ACME / Vault.
   - Add NetworkPolicies restricting ingress traffic strictly to the ingress controller and denying egress except to internal DNS.
   - Enforce Pod Security Standards at the namespace level (`pod-security.kubernetes.io/enforce: restricted`).
3. **Observability**:
   - Expose Prometheus metrics (`/metrics`) using `prometheus_client` to track request rates, p50/p95/p99 latency histograms, and HTTP status codes.
   - Integrate with fluent-bit or Grafana Loki for centralized log shipping with structured JSON log formatting.
4. **Continuous Delivery & GitOps**:
   - Package the chart into an OCI registry (e.g. Harbor or ECR) and manage deployments declaratively via ArgoCD or Flux.
   - Integrate automated progressive canary rollouts using Argo Rollouts or Flagger.

---

## How I Used AI

In accordance with Enterprise Bot's transparent AI disclosure policy:

- **Where AI was used**:
  - I used an AI assistant selectively for drafting boilerplate scaffolding (the initial Helm chart directory skeleton, `.dockerignore` conventions, and the basic GitHub Actions workflow YAML structure).
  - I used it to quickly double-check the exact field syntax for `ingress-nginx` kind extraPortMappings and `job.spec.template.spec.restartPolicy` schema requirements.
  - I used it for a final static review and to implement follow-up corrections in `setup.sh`, the Part 4 chart values, the CI workflow, the Docker base-image refresh prompted by Trivy findings, and this documentation. I then checked the committed file contents and GitHub Actions results; local Docker/kind execution remains a separate verification step.
- **What was done manually**:
  - All diagnosis in Part 4 was performed directly against the cluster output and manifests: tracing the `restartPolicy` API validation, inspecting ReplicaSet admission events for `LimitRange` violations, reviewing the worker's filesystem crash logs, identifying the default port mismatch (8081 vs 8080), correcting the `BACKEND_URL` namespace resolution, and auditing the `RoleBinding` subjects.
  - The architectural reasoning and trade-offs in `ANSWERS.md` and this `README.md` are based on Kubernetes operations concepts, engineering analysis, and the production deployment/incident-response experience described in my background. The Gateway API migration is presented as a proposed strategy, not as a claim that I have already completed that specific migration.


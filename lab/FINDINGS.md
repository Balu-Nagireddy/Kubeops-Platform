# Findings — Part 4 debug lab

Fill in one entry per defect you find. Paste the *actual* output you saw —
we cross-check it against your session recording and your git diff, and the
diagnostic path matters more to us than the fix itself.

Before you start investigating, begin recording:
`script -q part4-session.log` (or `asciinema rec part4-session.cast`), and
commit that file alongside this one.

---

## Defect 1: Migration Job Invalid RestartPolicy

**Symptom** (what you observed — paste the real command output):
Initial installation via `./scenario.sh up` failed during Helm release installation:
```text
==> applying cluster environment (cluster-state/)
namespace/debug-lab unchanged
limitrange/debug-lab-guardrails unchanged
==> installing the broken chart
Error: INSTALLATION FAILED: unable to build kubernetes objects from release manifest: error validating "": error validating data: ValidationError(Job.spec.template.spec.restartPolicy): unsupported value: "Always": supported values: "OnFailure", "Never"

helm reported an error. That is not your machine misbehaving —
it is part of the exercise. Read the error; it is evidence.
```

**Cause** (the actual root cause, not the symptom restated):
In `lab/broken-chart/templates/migrate-job.yaml`, the Job pod specification defined `spec.template.spec.restartPolicy: Always`. Under the Kubernetes Batch API specification (`batch/v1`), Job controller pods represent finite, terminating tasks and strictly prohibit `restartPolicy: Always`. Allowed values are only `OnFailure` or `Never`. The Kubernetes API server schema validation rejected the manifest outright, blocking the Helm release from rendering and installing into the cluster.

**Fix** (what you changed, and why this over alternatives):
Updated `lab/broken-chart/templates/migrate-job.yaml` line 16 from `restartPolicy: Always` to `restartPolicy: OnFailure`.
*Why this over alternatives:* `OnFailure` allows Kubernetes to retry the migration pod if transient errors occur up to `backoffLimit` (configured as 2 in `values.yaml`), whereas `Never` would terminate the pod permanently on any exit failure without automated retries.

**How I found it** (the sequence of commands/reasoning that led you here):
1. Executed `./scenario.sh up` and immediately observed Helm failure `ValidationError(Job.spec.template.spec.restartPolicy): unsupported value: "Always"`.
2. Inspected `lab/broken-chart/templates/migrate-job.yaml` around line 16.
3. Confirmed standard Kubernetes Batch API specifications require `OnFailure` or `Never`.

---

## Defect 2: Metrics Deployment Exceeds Namespace LimitRange Guardrails

**Symptom:**
After resolving Defect 1, the chart deployed, but `./scenario.sh verify` reported `metrics` deployment not ready:
```text
  FAIL  deployment metrics: 0/1 ready
```
Checking the deployment events and replica set via `kubectl -n debug-lab describe deploy metrics`:
```text
Events:
  Type    Reason             Age   From                   Message
  ----    ------             ----  ----                   -------
  Normal  ScalingReplicaSet  35s   deployment-controller  Scaled up replica set metrics-7988849b89 to 1

$ kubectl -n debug-lab describe rs -l app=metrics
Events:
  Type     Reason        Age   From                   Message
  ----     ------        ----  ----                   -------
  Warning  FailedCreate  40s   replicaset-controller  Error creating: pods "metrics-7988849b89-h6874" is forbidden: [maximum cpu usage per Container is 1, but limit is 4, maximum cpu usage per Container is 1, but request is 2]
```

**Cause:**
`lab/cluster-state/limits.yaml` establishes a hard ceiling via `LimitRange/debug-lab-guardrails` of `max.cpu: "1"` per container. However, `lab/broken-chart/values.yaml` configured `metrics.resources.requests.cpu: "2"` and `metrics.resources.limits.cpu: "4"`. The Admission Controller denied pod creation because the requested and limit CPU resources exceeded the namespace guardrails.

**Fix:**
Adjusted `metrics.resources` in `lab/broken-chart/values.yaml` to request `50m` CPU (matching default requests) and limit `200m` CPU (matching default limits), well under the `1` CPU ceiling.

**How I found it:**
1. Ran `./scenario.sh verify` and noticed `deployment metrics: 0/1 ready`.
2. Ran `kubectl -n debug-lab get pods -l app=metrics` (no pods existed).
3. Ran `kubectl -n debug-lab describe rs -l app=metrics` and inspected the ReplicaSet `Events`, which revealed the admission webhook error: `maximum cpu usage per Container is 1, but limit is 4`.
4. Cross-referenced `lab/cluster-state/limits.yaml` to confirm the enforced ceiling.

---

## Defect 3: Worker Deployment CrashLoopBackOff Due to Read-Only Filesystem

**Symptom:**
The worker pod repeatedly crashed with status `CrashLoopBackOff`:
```text
$ kubectl -n debug-lab get pods -l app=worker
NAME                      READY   STATUS             RESTARTS      AGE
worker-659f8c67cb-x9g8m   0/1     CrashLoopBackOff   3 (35s ago)   85s

$ kubectl -n debug-lab logs deployment/worker --previous
FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system — the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)
```

**Cause:**
`lab/broken-chart/templates/worker.yaml` sets `securityContext.readOnlyRootFilesystem: true` to enforce container immutability. At startup, the worker service initializes a local cache at `/var/cache/app`. Because no writable volume was mounted at that path, `mkdir` failed with `read-only file system`, prompting the application process to immediately terminate with a fatal error.

**Fix:**
Added an `emptyDir` volume named `cache-dir` to the worker pod specification and mounted it at `/var/cache/app` via `volumeMounts`.
*Why this over alternatives:* Disabling `readOnlyRootFilesystem: true` would weaken the security posture of the workload. Mounting a dedicated ephemeral `emptyDir` volume preserves container filesystem immutability while providing the necessary scratch storage for the cache.

**How I found it:**
1. Observed `1 pod(s) in CrashLoopBackOff` during `./scenario.sh verify`.
2. Ran `kubectl -n debug-lab get pods` and identified the culprit as `worker-*`.
3. Executed `kubectl -n debug-lab logs deployment/worker` and `kubectl -n debug-lab describe pod -l app=worker`.
4. Read the fatal log message explaining that `/var/cache/app` must be writable.

---

## Defect 4: Workloads Defaulting to Port 8081 Due to Missing PORT Environment Variable

**Symptom:**
All deployments showed readiness probe timeouts and failures, and in-cluster probes to port 8080 failed:
```text
$ kubectl -n debug-lab describe deploy backend
Events:
  Warning  Unhealthy  12s (x6 over 42s)  kubelet  Readiness probe failed: Get "http://10.244.0.12:8080/healthz": dial tcp 10.244.0.12:8080: connect: connection refused

$ ./scenario.sh verify
  FAIL  backend does not answer on http://backend:8080/healthz
```
Inspecting the startup logs of the pods:
```text
$ kubectl -n debug-lab logs deployment/backend
eb-debug-app 1.0.1 starting: mode=api pod=backend-5dfbdc57cb-w8z9k listening on :8081 (image default is 8081; set PORT to override)
```

**Cause:**
The application binary defaults to listening on port `8081` unless overridden by the `PORT` environment variable (`image default is 8081; set PORT to override`). The Helm chart templates configured `containerPort: {{ .Values.common.port }}` (8080) and probed `http://...:8080/healthz`, and the Services forwarded traffic to port 8080. However, the chart templates never passed `PORT` to the containers' environment variables. As a result, the application listened on port 8081 while Kubernetes sent readiness probes and service traffic to port 8080, causing connection refused errors.

**Fix:**
1. Added `- name: PORT, value: {{ .Values.common.port | quote }}` to the container `env` block in `backend.yaml`, `gateway.yaml`, `worker.yaml`, `reporter.yaml`, and `metrics.yaml`.
2. Added `PORT: "8080"` to the `env` mappings in `lab/broken-chart/values.yaml` for consistency.

**How I found it:**
1. Ran `kubectl -n debug-lab describe pod -l app=backend` and saw `Readiness probe failed: ... dial tcp 10.244.0.12:8080: connect: connection refused`.
2. Checked application stdout logs via `kubectl -n debug-lab logs deployment/backend` and immediately saw: `listening on :8081 (image default is 8081; set PORT to override)`.
3. Checked `templates/backend.yaml` and `values.yaml` and found `PORT` was never passed to the process.

---

## Defect 5: Gateway Configured with Wrong Backend URL Namespace

**Symptom:**
Gateway pod was running and ready, but `./scenario.sh verify` reported:
```text
  FAIL  gateway /status does not report backend=ok
```
Probing the gateway endpoint directly from a test pod or port-forward:
```text
$ kubectl -n debug-lab exec deploy/gateway -- curl -s http://localhost:8080/status
{"backend":"error: dial tcp: lookup backend.default.svc on 10.96.0.10:53: no such host","mode":"gateway","status":"degraded"}
```

**Cause:**
In `lab/broken-chart/values.yaml`, `gateway.env.BACKEND_URL` was configured as `"http://backend.default.svc:8080"`. The entire platform runs in the `debug-lab` namespace. When the gateway queried Kubernetes DNS for `backend.default.svc`, CoreDNS returned `NXDOMAIN` because no backend service exists in the `default` namespace.

**Fix:**
In `lab/broken-chart/values.yaml`, updated `gateway.env.BACKEND_URL` to `"http://backend:8080"` (or `"http://backend.debug-lab.svc:8080"`).

**How I found it:**
1. Ran `./scenario.sh verify` and noticed `gateway /status does not report backend=ok`.
2. Checked `lab/broken-chart/values.yaml` under `gateway.env` and noticed `backend.default.svc:8080`.
3. Executed the verify busybox probe command manually: `wget -q -O- http://gateway.debug-lab.svc/status`, which displayed connection lookup failure for `backend.default.svc`.

---

## Defect 6: Reporter RBAC RoleBinding Subject Mismatch

**Symptom:**
`./scenario.sh verify` failed with:
```text
  FAIL  ServiceAccount debug-lab/reporter cannot list pods
  FAIL  reporter /report does not return a pod count
```
Testing authorization with `kubectl auth can-i`:
```text
$ kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:reporter
no
```
Checking the reporter application logs:
```text
$ kubectl -n debug-lab logs deployment/reporter
pod list failed: pods is forbidden: User "system:serviceaccount:debug-lab:reporter" cannot list resource "pods" in API group "" in the namespace "debug-lab"
```

**Cause:**
In `lab/broken-chart/templates/rbac.yaml`, the `RoleBinding` `reporter-read` bound the Role to `name: default`:
```yaml
subjects:
  - kind: ServiceAccount
    name: default
    namespace: {{ .Release.Namespace }}
```
However, `lab/broken-chart/templates/reporter.yaml` specifies `serviceAccountName: reporter`. Because the RoleBinding was granted to the namespace's default service account rather than the `reporter` service account, the reporter pod had no authorization to list pods.

**Fix:**
In `lab/broken-chart/templates/rbac.yaml`, updated `subjects[0].name` from `default` to `reporter`.

**How I found it:**
1. Observed `./scenario.sh verify` failing check 4 (`ServiceAccount debug-lab/reporter cannot list pods`) and check 5 (`reporter /report does not return a pod count`).
2. Ran `kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:reporter`, which returned `no`.
3. Inspected `lab/broken-chart/templates/rbac.yaml` and compared the `ServiceAccount` resource (`name: reporter`) with the `RoleBinding.subjects[0].name` (`name: default`), revealing the copy-paste naming bug.

---

## Final Verification

After applying the fixes, re-ran `./scenario.sh up` and `./scenario.sh verify`:
```text
==> verifying goal state in namespace debug-lab
  PASS  migrate Job completed
  PASS  deployment backend: 1/1 ready
  PASS  deployment gateway: 1/1 ready
  PASS  deployment worker: 1/1 ready
  PASS  deployment reporter: 1/1 ready
  PASS  deployment metrics: 1/1 ready
  PASS  no pods in CrashLoopBackOff
  PASS  ServiceAccount debug-lab/reporter can list pods
  PASS  backend answers on http://backend:8080/healthz
  PASS  gateway /status reports backend=ok
  PASS  reporter /report sees pods in the namespace

ALL GREEN — 11/11 checks passed. This part is done.
```

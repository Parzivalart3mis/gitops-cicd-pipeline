# Architecture

## Overview

This project implements a **GitOps CI/CD pipeline** on top of Kubernetes. The core idea is that Git is the **single source of truth** for what should be running in every environment. No deployment tool pushes directly to Kubernetes — instead, a controller (ArgoCD) inside the cluster continuously pulls the desired state from Git and reconciles it with reality.

```
Git Repository ──── (desired state) ────► ArgoCD ──── (reconcile) ────► Kubernetes
                                              ▲
                                         polls every 3 min
```

## Component Breakdown

### Application Layer (`apps/`)

| Component | Technology | Purpose |
|-----------|-----------|---------|
| Backend   | Python FastAPI | REST API with `/healthz`, `/readyz`, `/metrics`, and CRUD endpoints |
| Frontend  | Nginx + HTML/JS | Serves the static UI and reverse-proxies `/backend/*` to the backend Service; shows the deployed version |

Both applications are stateless and designed to be horizontally scalable.

### Continuous Integration (`.github/workflows/ci.yml`)

On every push to `master` (and on pull requests, up to the security scan):

1. **backend / frontend / manifests** (parallel) — `ruff`, `mypy`, `pytest` (≥80% coverage of application code); build the frontend image, `nginx -t` it and smoke-test its security headers and `/backend` proxy; render every overlay with `scripts/ci/validate-manifests.sh` and run `shellcheck`
2. **security-scan** — Trivy filesystem scan (fixable CRITICAL/HIGH and committed secrets fail the build), `pip-audit`, `kubesec` scoring. All blocking.
3. **build-and-push** — Multi-stage build (the backend's test stage runs inside it), smoke test of the built container, Trivy image scan, *then* push to GHCR as `:<sha>`, `:<branch>`, `:latest`
4. **update-manifests** — `scripts/ci/push-overlay-change.sh` runs `scripts/set-image-tag.sh` on `k8s/overlays/dev` (image tag + the `git_sha` that `/healthz` reports) and pushes the commit, retrying on the latest tip if another workflow pushed first

The last step is the **GitOps trigger**: the manifest commit notifies ArgoCD that something changed. Every third-party action is pinned to a commit SHA.

### Continuous Delivery (`argocd/`)

ArgoCD is a Kubernetes controller. It watches the Git repository and ensures the cluster state matches what's declared in `k8s/overlays/<environment>/`.

**Sync modes by environment:**

| Environment | Auto-sync | Self-heal | Rationale |
|-------------|-----------|-----------|-----------|
| dev         | ✅ ON      | ✅ ON      | Fast feedback; drift is auto-corrected |
| staging     | ❌ OFF     | ❌ OFF     | Requires human approval before QA env changes |
| prod        | ❌ OFF     | ❌ OFF     | Requires explicit sign-off; weekend sync window blocked |

### Manifest Management (`k8s/`)

Kustomize is used for all application manifests:

```
k8s/
├── base/           ← shared configuration (deployment, service, HPA, PDB, NetworkPolicy)
└── overlays/
    ├── dev/        ← 1 replica, low resources, debug logging, auto-sync
    ├── staging/    ← 2 replicas, production-like resources, manual sync
    └── prod/       ← 3 replicas, higher resources, strict PDB, manual sync
```

Each overlay uses **strategic merge patches** to override only the fields that differ from the base. The `images[]` section is where CI writes the new image tag.

**Why Kustomize over Helm?**
- No templating language — pure YAML diffs are easier to review in PRs
- Built into `kubectl` since v1.14 — zero extra tooling for operators
- Overlays compose naturally with GitOps (each overlay = one Git path)
- Helm is used for _third-party_ tools (ArgoCD, Prometheus) where charts are well-maintained

### Observability (`observability/`)

| Tool | Purpose |
|------|---------|
| Prometheus | Collects metrics from pods (via `prometheus.io/scrape` annotations and ServiceMonitors) |
| Grafana | Visualises metrics; pre-loaded with CI/CD and application health dashboards |
| Loki + Grafana Alloy | Alloy tails `gitops-*` pod logs through the Kubernetes API and ships them to Loki; query them in Grafana |
| AlertManager | Routes Prometheus alerts (pod restarts, error rates, sync failures; Argo CD metrics are scraped via a ServiceMonitor) |
| metrics-server | Supplies the CPU/memory metrics the HorizontalPodAutoscalers scale on |

### Security (`security/`)

| Control | Implementation |
|---------|---------------|
| Image scanning | Trivy scans both source code and final Docker images in CI; `pip-audit` checks Python dependencies |
| Secrets management | Bitnami Sealed Secrets — only encrypted `SealedSecret` objects live in Git |
| Admission control | OPA Gatekeeper enforces: required labels, no `:latest` tags in staging/prod, resource limits |
| Manifest scoring | `kubesec` scores both Deployments; a negative score fails the build |
| Network isolation | Kubernetes `NetworkPolicy` restricts pod-to-pod traffic (frontend → backend only) |
| Non-root containers | All pods run with `runAsNonRoot: true` and drop all Linux capabilities |

## Data Flow

```
User Request
    │
    ▼
Nginx Ingress Controller
    │  (routes by hostname)
    ├──► <env>.gitops.local ──► Frontend Pod (Nginx, port 8080)
    │                              │  static UI; the browser calls /backend/api/v1/items
    │                              │  on the SAME origin, and Nginx proxies it in-cluster:
    │                              ▼
    └──► api.<env>.gitops.local ──► Backend Service ──► Backend Pod (FastAPI, port 8000)
                                                         │
                                                         ├──► /metrics → Prometheus scrapes (in-cluster only)
                                                         ├──► /healthz → Kubernetes liveness probe
                                                         └──► /readyz  → Kubernetes readiness probe
```

## Networking

- **Ingress**: All external traffic enters via the Nginx Ingress controller. Each environment has its own hosts (`<env>.gitops.local` for the UI, `api.<env>.gitops.local` for the API), patched in by its overlay.
- **Same-origin API calls**: the browser never addresses the backend directly. It calls `/backend/...` on the frontend's origin and the frontend's Nginx proxies to `http://backend:8000`. This works identically through the Ingress and through `kubectl port-forward`, needs no CORS, and keeps cluster-internal DNS names out of the browser (where they can't resolve).
- **Services**: ClusterIP services handle pod-to-pod routing within the cluster
- **NetworkPolicy**: Default-deny with explicit allow rules:
  - Ingress controller → frontend (port 8080)
  - Frontend → backend (port 8000)
  - Prometheus (monitoring namespace) → backend (port 8000)
  - DNS egress allowed for all pods (UDP/TCP 53)

## Rollback Strategy

Three rollback mechanisms exist, in order of preference:

1. **GitOps rollback** (preferred): Run the `rollback.yml` workflow → it updates the overlay with an old tag → ArgoCD syncs → creates a full audit trail in Git history
2. **kubectl rollout undo**: `kubectl rollout undo deployment/backend -n gitops-dev` — fast but creates drift between Git and the cluster (anti-pattern in GitOps)
3. **git revert**: Revert the manifest commit in Git — ArgoCD auto-syncs dev; staging and prod need a manual sync

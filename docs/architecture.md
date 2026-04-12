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
| Frontend  | Nginx + HTML/JS | Serves static UI, calls backend API, shows deployment version |

Both applications are stateless and designed to be horizontally scalable.

### Continuous Integration (`.github/workflows/ci.yml`)

Four jobs run in sequence on every push to `main`:

1. **lint-and-test** — Runs `ruff`, `mypy`, `pytest` (≥80% coverage required), and validates Kustomize overlays
2. **security-scan** — Trivy filesystem scan, Python `safety` check, `kubesec` manifest scoring
3. **build-and-push** — Multi-stage Docker build, pushes to GHCR with tags `:<sha>`, `:<branch>`, `:latest`
4. **update-manifests** — Runs `kustomize edit set image` on `k8s/overlays/dev`, commits the change back

The last step is the **GitOps trigger**: the manifest commit notifies ArgoCD that something changed.

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
| Loki + Promtail | Aggregates structured JSON logs from all pods |
| AlertManager | Routes Prometheus alerts (pod restarts, error rates, sync failures) |

### Security (`security/`)

| Control | Implementation |
|---------|---------------|
| Image scanning | Trivy scans both source code and final Docker images in CI |
| Secrets management | Bitnami Sealed Secrets — only encrypted `SealedSecret` objects live in Git |
| Admission control | OPA Gatekeeper enforces: required labels, no `:latest` tags in staging/prod, resource limits |
| Manifest scoring | `kubesec` scores all Kubernetes manifests; negative scores fail the build |
| Network isolation | Kubernetes `NetworkPolicy` restricts pod-to-pod traffic (frontend → backend only) |
| Non-root containers | All pods run with `runAsNonRoot: true` and drop all Linux capabilities |

## Data Flow

```
User Request
    │
    ▼
Nginx Ingress Controller
    │  (routes by hostname/path)
    ├──► Frontend Pod (Nginx, port 8080)
    │        │  (browser fetches /api/v1/items)
    │        ▼
    └──► Backend Pod (FastAPI, port 8000)
              │
              ├──► /metrics → Prometheus scrapes
              ├──► /healthz → Kubernetes liveness probe
              └──► /readyz  → Kubernetes readiness probe
```

## Networking

- **Ingress**: All external traffic enters via the Nginx Ingress controller
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
3. **git revert**: Revert the manifest commit in Git — ArgoCD detects and syncs automatically

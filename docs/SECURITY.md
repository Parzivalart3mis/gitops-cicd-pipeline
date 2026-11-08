# Security

## Principles

1. **Defence in depth**: Multiple independent security layers; no single control is relied upon exclusively.
2. **Least privilege**: Each component has only the permissions it needs.
3. **Shift left**: Security checks run in CI before any code reaches a cluster.
4. **No secrets in Git**: Only encrypted `SealedSecret` objects are committed.
5. **Immutable artefacts**: Docker images are tagged with git SHAs (immutable) not `:latest` (mutable).

## Controls by Layer

### Source Code (CI)

| Control | Tool | What it catches |
|---------|------|----------------|
| Dependency CVE scan | `pip-audit` (Python) | Known CVEs in runtime and dev pip packages. Blocking |
| Source code scan | Trivy fs scan | Committed secrets, fixable CRITICAL/HIGH CVEs in dependency manifests. Blocking; full report also uploaded as SARIF |
| Linting | `ruff`, `mypy`, `shellcheck` | Code quality issues that can cause runtime errors |
| Manifest checks | `kubesec`, `scripts/ci/validate-manifests.sh` | Kubernetes misconfigurations; invalid image names, unmatched image overrides, tag/version drift |

### CI Supply Chain

| Control | Implementation |
|---------|---------------|
| Pinned actions | Every third-party action is pinned to a full commit SHA (version in a trailing comment) |
| Pinned tools | kustomize and kubesec downloads are version-pinned and SHA-256 verified; Python tools pinned in `requirements-dev.txt`; Helm charts pinned in `scripts/versions.env` |
| Least-privilege tokens | Workflows default to `contents: read`; jobs request `packages: write` / `contents: write` / `issues: write` only where needed; read-only jobs don't persist the token |
| No input injection | `workflow_dispatch` inputs reach shell and JavaScript only through `env:`; image tags are validated against a SHA pattern |
| Scan before push | Images are built locally, smoke-tested and Trivy-scanned before anything is pushed to GHCR |

### Docker Image

| Control | Implementation |
|---------|---------------|
| Non-root user | Backend: UID/GID 1000 (`USER 1000:1000`), matching the Deployment's `runAsUser`. Frontend: the image's `nginx` user (UID 101) |
| Multi-stage build | The backend's production stage copies its source out of the test stage, so the tests always run and a failure fails the build; pytest & co. never ship in the runtime image |
| Image CVE scan | Trivy scans the image before it is pushed (fixable CRITICAL = build fails) |
| Base images | Tracked minor tags (`python:3.12-slim`, `nginx:1.30-alpine`) so each CI build picks up upstream security rebuilds; Alpine packages are additionally upgraded at build time |
| HEALTHCHECK | Dockerfile `HEALTHCHECK` mirrors Kubernetes liveness probe |
| No `:latest` in prod | OPA Gatekeeper policy `block-latest-tag` enforces explicit SHA tags |

### Kubernetes Pod

| Control | Manifest field |
|---------|---------------|
| Non-root UID | `securityContext.runAsNonRoot: true`, `runAsUser: 1000` |
| No privilege escalation | `allowPrivilegeEscalation: false` |
| Read-only root filesystem | `readOnlyRootFilesystem: true` (backend uses `/tmp` emptyDir) |
| Drop all capabilities | `capabilities.drop: [ALL]` |
| Seccomp profile | `seccompProfile.type: RuntimeDefault` |
| No default SA token | `automountServiceAccountToken: false` on ServiceAccount |
| Resource limits | CPU and memory limits on every container (enforced by OPA) |

### Cluster Networking

| Control | Implementation |
|---------|---------------|
| Default deny | `NetworkPolicy` with `podSelector: {}` blocks all traffic by default |
| Explicit allow rules | Frontend → backend (8000), Ingress → frontend (8080) |
| Namespace isolation | Three separate namespaces (dev/staging/prod) with RBAC |

### Secrets Management

**Never commit plaintext secrets to Git.** The workflow (cluster must be running):

1. Seal the secret for an environment:
   ```bash
   make seal-secret ENV=dev NAME=app-secrets DATA="api-key=@./api-key.txt"
   ```
   `key=@file` reads the value from a file, keeping it out of shell history. The script builds the Secret client-side, encrypts it with `kubeseal` against the in-cluster controller (`kube-system/sealed-secrets-controller`), writes `k8s/overlays/dev/app-secrets.sealedsecret.yaml`, and adds it to the overlay's kustomization. The plaintext never touches disk or Git.
2. Commit and push the overlay; Argo CD applies the `SealedSecret`.
3. The controller decrypts it into a regular `Secret`, accessible only to pods in that namespace.

Ciphertext only decrypts in the cluster that sealed it, and every fresh Kind cluster generates a new key, so re-run `make seal-secret` after recreating the cluster. See `security/sealed-secrets/example-sealedsecret.yaml` for the format.

**Why Sealed Secrets instead of Vault?**
For a single-team portfolio project, Sealed Secrets has a much simpler operational footprint than Vault. Vault requires HA storage, token management, and renewal logic. Sealed Secrets is a single controller with no external dependencies. The encryption model (asymmetric key, controller holds private key) is sound for this scope.

### Admission Control (OPA Gatekeeper)

Three policies enforced at admission time (before any resource is created):

1. **RequireLabels**: All Deployments and Services must have `app` and `team` labels
2. **BlockLatestTag**: Containers in staging/prod cannot use `:latest` image tag
3. **RequireResourceLimits**: All containers must specify CPU and memory requests and limits

Violations are rejected at the API server level — the resource is never created.

### ArgoCD RBAC

The `gitops-demo` AppProject restricts:
- **Source repos**: Only this repository can be used as a source
- **Destinations**: Only `gitops-dev`, `gitops-staging`, `gitops-prod` namespaces (not `argocd`, `kube-system`, etc.)
- **Resource kinds**: Explicit whitelist of allowed Kubernetes resource types

## Security Checklist (run before production use)

- [ ] Seal real secrets with `make seal-secret` (and back up the controller's key if the cluster is long-lived)
- [ ] Add required reviewers to the `prod` GitHub Environment (gates `promote.yml`)
- [ ] Verify all repoURL fields in argocd/ and k8s/ point to your forked repository
- [ ] Disable ArgoCD anonymous access (remove `auth.anonymous` from Grafana values too)
- [ ] Set a strong ArgoCD admin password (not the generated one)
- [ ] Enable TLS on the ArgoCD ingress
- [ ] Configure Alertmanager to send alerts to a real Slack/PagerDuty channel
- [ ] Review and tighten `NetworkPolicy` rules for your specific traffic patterns
- [ ] Enable audit logging on the Kubernetes API server
- [ ] Configure image pull secrets if using a private registry

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
| Dependency CVE scan | `safety` (Python) | Known CVEs in pip packages |
| Source code scan | Trivy fs scan | Hardcoded secrets, CVEs in vendored deps |
| Linting | `ruff`, `mypy` | Code quality issues that can cause runtime errors |
| Manifest scoring | `kubesec` | Kubernetes misconfigurations (non-root, caps, limits) |

### Docker Image

| Control | Implementation |
|---------|---------------|
| Non-root user | `adduser --system appuser; USER appuser` in Dockerfile |
| Multi-stage build | Test stage runs first; production stage contains only runtime artifacts |
| Image CVE scan | Trivy scans the final image after build (CRITICAL severity = build fails) |
| Pinned base image | `python:3.12.4-slim` (exact version, not `python:3.12`) |
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

**Never commit plaintext secrets to Git.** The workflow:

1. Create a Kubernetes Secret locally:
   ```bash
   kubectl create secret generic app-secrets \
     --from-literal=api-key=my-secret \
     --dry-run=client -o yaml > /tmp/secret.yaml
   ```
2. Seal it with kubeseal:
   ```bash
   ./scripts/seal-secret.sh gitops-dev app-secrets api-key=my-secret
   ```
3. Commit the `SealedSecret` YAML to Git.
4. The Sealed Secrets controller decrypts it in-cluster.
5. The resulting Kubernetes `Secret` is only accessible to pods in that namespace.

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

- [ ] Replace placeholder `SealedSecret` values with real encrypted secrets
- [ ] Verify all repoURL fields in argocd/ and k8s/ point to your forked repository
- [ ] Disable ArgoCD anonymous access (remove `auth.anonymous` from Grafana values too)
- [ ] Set a strong ArgoCD admin password (not the generated one)
- [ ] Enable TLS on the ArgoCD ingress
- [ ] Configure Alertmanager to send alerts to a real Slack/PagerDuty channel
- [ ] Review and tighten `NetworkPolicy` rules for your specific traffic patterns
- [ ] Enable audit logging on the Kubernetes API server
- [ ] Configure image pull secrets if using a private registry

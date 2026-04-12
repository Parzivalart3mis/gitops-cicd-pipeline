# Environment Promotion

## Promotion Chain

```
dev  ──► staging  ──► prod
```

Every image starts in `dev` and must pass through `staging` before reaching `prod`. Direct `dev → prod` promotion is blocked by the `promote.yml` workflow.

## Promotion Steps

### 1. Dev → Staging

**Trigger**: Manual `workflow_dispatch` on `promote.yml`

**Required inputs**:
- `source_env`: `dev`
- `target_env`: `staging`
- `image_tag`: The git SHA currently running in dev (e.g., `a1b2c3d`)

**What happens**:
1. Workflow validates the promotion path (`dev → staging` is allowed)
2. Optionally verifies the image exists in GHCR
3. Runs `kustomize edit set image` on `k8s/overlays/staging/`
4. Commits the change: `chore(promote): dev → staging [a1b2c3d]`
5. Pushes to `main`
6. Prints instructions to sync ArgoCD for staging

**Post-promotion**: A human must trigger ArgoCD sync for staging (auto-sync is OFF):
```bash
argocd app sync gitops-demo-staging
# or via ArgoCD UI → gitops-demo-staging → Sync
```

### 2. Staging → Prod

**Trigger**: Manual `workflow_dispatch` on `promote.yml`

**Required inputs**:
- `source_env`: `staging`
- `target_env`: `prod`
- `image_tag`: The git SHA verified in staging

**Additional gate**: The AppProject `syncWindows` blocks weekend prod deployments (configurable).

**What happens**: Same as dev → staging, but targets `k8s/overlays/prod/`.

## How to Find the Current Image Tag

```bash
# What's running in dev right now?
kubectl get deployment backend -n gitops-dev \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# What's the tag in the dev kustomization?
grep newTag k8s/overlays/dev/kustomization.yaml

# What version does /healthz report?
curl http://backend.gitops.local/healthz | jq .version
```

## Blocked Promotion Paths

| Path | Allowed? | Reason |
|------|---------|--------|
| dev → staging | ✅ | Standard promotion |
| staging → prod | ✅ | Standard promotion |
| dev → prod | ❌ | Must validate in staging first |
| prod → anything | ❌ | Production is the terminal environment |
| X → X (same env) | ❌ | No-op, blocked to prevent accidents |

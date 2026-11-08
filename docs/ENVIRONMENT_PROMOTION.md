# Environment Promotion

## Promotion Chain

```
dev  ──► staging  ──► prod
```

Every image starts in `dev` and must pass through `staging` before reaching `prod`. Direct `dev → prod` promotion is blocked by the `promote.yml` workflow.

## Promotion Steps

### 1. Dev → Staging

**Trigger**: Manual `workflow_dispatch` on `promote.yml`

**Inputs**:
- `source_env`: `dev`
- `target_env`: `staging`
- `image_tag` (optional): leave empty to promote whatever dev is running. If you fill it in, it must equal the tag dev runs: only a tested tag can be promoted.

**What happens**:
1. Workflow validates the promotion path (`dev → staging` is allowed)
2. Reads the tag dev actually deploys (`scripts/get-image-tag.sh`, from the rendered overlay) and checks it is a SHA, not `latest`
3. Verifies both images exist in GHCR (fails if not)
4. Runs `scripts/set-image-tag.sh` on `k8s/overlays/staging/`, which sets the image tags **and** the `git_sha` / `frontend_version` the app reports
5. Commits `chore(promote): dev → staging [a1b2c3d]` and pushes to `master`
6. Writes the sync instructions to the run summary

The promote job runs in the GitHub Environment named after the target (`staging` / `prod`). Add required reviewers to the `prod` environment (Settings → Environments) to require approval before a prod promotion is committed.

**Post-promotion**: A human must trigger ArgoCD sync for staging (auto-sync is OFF):
```bash
argocd app sync gitops-demo-staging
# or via ArgoCD UI → gitops-demo-staging → Sync
```

### 2. Staging → Prod

**Trigger**: Manual `workflow_dispatch` on `promote.yml`

**Inputs**:
- `source_env`: `staging`
- `target_env`: `prod`
- `image_tag` (optional): defaults to the tag staging runs

**Additional gates**: optional GitHub Environment reviewers on `prod` (see above), and the AppProject `syncWindows` blocks automatic prod syncs on weekends. Manual syncs stay allowed (`manualSync: true`) so an emergency rollback is never blocked.

**What happens**: Same as dev → staging, but targets `k8s/overlays/prod/`.

## How to Find the Current Image Tag

```bash
# What's running in dev right now?
kubectl get deployment backend -n gitops-dev \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# What tag does the dev overlay deploy? (renders the overlay)
scripts/get-image-tag.sh k8s/overlays/dev

# What version does /healthz report? (needs the /etc/hosts line from `make hosts`)
curl http://api.dev.gitops.local/healthz | jq .version
```

## Blocked Promotion Paths

| Path | Allowed? | Reason |
|------|---------|--------|
| dev → staging | ✅ | Standard promotion |
| staging → prod | ✅ | Standard promotion |
| dev → prod | ❌ | Must validate in staging first |
| prod → anything | ❌ | Production is the terminal environment |
| X → X (same env) | ❌ | No-op, blocked to prevent accidents |
| any tag other than the one the source runs | ❌ | Only what was tested in the source environment can move forward |

# Rollback Procedures

## When to Rollback

Roll back when:
- A deployed version causes elevated error rates (>5% 5xx responses)
- Pod crash loops appear after a deployment
- A critical bug is reported in production that wasn't caught in staging
- Response latency degrades significantly after a deployment

## Method 1: GitOps Rollback (Recommended)

Uses the `rollback.yml` GitHub Actions workflow. This is the **preferred method** because it:
- Is fully auditable (creates a git commit + a GitHub Issue)
- Keeps Git as the source of truth
- Works identically for all environments

**Steps**:
1. Go to GitHub → Actions → Rollback → Run workflow
2. Set `environment`: the environment to roll back (dev/staging/prod)
3. Set `target_tag`: the git SHA of the last known-good version
4. Set `reason`: a brief description (for the audit issue)
5. Click Run

The workflow:
1. Updates `k8s/overlays/<env>/kustomization.yaml` with the old tag
2. Commits: `chore(rollback): <env> → <tag> reason: <reason>`
3. Pushes to main
4. Creates a GitHub Issue documenting the incident

For **dev** (auto-sync ON): ArgoCD detects the commit within ~3 minutes and syncs automatically.
For **staging/prod** (manual sync): Run `argocd app sync gitops-demo-<env>` or use the ArgoCD UI.

**Finding the last-known-good SHA**:
```bash
# Git history of the overlay
git log --oneline k8s/overlays/prod/kustomization.yaml

# ArgoCD sync history
argocd app history gitops-demo-prod
```

## Method 2: kubectl rollout undo (Fast, but creates drift)

```bash
kubectl rollout undo deployment/backend -n gitops-prod
kubectl rollout undo deployment/frontend -n gitops-prod

# Verify
kubectl rollout status deployment/backend -n gitops-prod
```

**WARNING**: This creates **drift** between Git and the cluster. ArgoCD's `selfHeal` will revert it in dev. For staging/prod (no selfHeal), you must immediately run Method 1 to bring Git back in sync, or the next ArgoCD sync will re-apply the broken version.

## Method 3: git revert

```bash
# Find the commit that introduced the bad version
git log --oneline k8s/overlays/prod/kustomization.yaml

# Revert it
git revert <commit-sha>
git push origin main
```

ArgoCD will detect the new commit and sync the reverted version.

## Verifying a Rollback

```bash
# Check pod rollout status
kubectl rollout status deployment/backend -n gitops-prod

# Confirm the version via health endpoint
curl http://backend.gitops.local/healthz | jq '{version, environment}'

# Check ArgoCD sync status
argocd app get gitops-demo-prod
```

## MTTR Target

With GitOps rollback:
- Time to detect (Grafana alert): ~2 minutes
- Time to trigger rollback workflow: ~1 minute
- Time for ArgoCD to sync: ~3 minutes (dev auto) / ~2 minutes (manual trigger)
- Time for rolling update to complete: ~2 minutes

**Target MTTR: < 10 minutes**

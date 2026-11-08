# Troubleshooting

## High Pod Restart Rate

**Symptom**: `kube_pod_container_status_restarts_total` alert fires; pods in `CrashLoopBackOff`.

**Diagnosis**:
```bash
kubectl describe pod <pod-name> -n gitops-dev
kubectl logs <pod-name> -n gitops-dev --previous
```

**Common causes**:
- **OOMKill**: Memory limit too low → increase `resources.limits.memory` in overlay patch
- **Failed startup probe**: App takes longer than expected → increase `startupProbe.failureThreshold`
- **Bad config**: Missing environment variable → check ConfigMap values
- **Image pull error**: Wrong image tag or missing registry credentials (see *Pods stuck in InvalidImageName / ImagePullBackOff*)

## Deployment Replicas Mismatch

**Symptom**: `DeploymentReplicasMismatch` alert; `kubectl get deployment` shows `READY 1/3`.

**Diagnosis**:
```bash
kubectl get events -n gitops-prod --sort-by='.lastTimestamp' | tail -20
kubectl describe deployment backend -n gitops-prod
```

**Common causes**:
- **Insufficient cluster resources**: No nodes have enough CPU/memory → `kubectl describe nodes`
- **PodDisruptionBudget blocking scale**: `kubectl get pdb -n gitops-prod`
- **Image not found**: GHCR credentials expired or image tag doesn't exist

## ArgoCD Application Out of Sync

**Symptom**: ArgoCD UI shows `OutOfSync`; sync status alert fires.

**Diagnosis**:
```bash
argocd app diff gitops-demo-dev
argocd app get gitops-demo-dev
```

**Common causes**:
- **Auto-sync failing repeatedly**: Check ArgoCD logs: `kubectl logs -l app.kubernetes.io/name=argocd-server -n argocd`
- **OPA Gatekeeper blocking**: A new resource violates a policy → check events: `kubectl get events -n gitops-dev`
- **Git authentication failed**: Update repo credentials in ArgoCD settings
- **Kustomize build error**: Run locally: `kustomize build k8s/overlays/dev`

## kustomize build Fails

**Symptom**: CI's *Manifests & scripts* job fails at "Validate Kustomize overlays".

**Run locally**:
```bash
make validate-manifests     # = scripts/ci/validate-manifests.sh
```

**Common causes**:
- Missing resource file referenced in `kustomization.yaml`
- Patch references a field that doesn't exist in the base
- Invalid YAML syntax, or a deprecated field (warnings fail the check)
- An `images[]` entry whose `name` doesn't exactly match the image in `k8s/base` (case included): Kustomize silently ignores it
- `git_sha` / `frontend_version` edited by hand: always change tags with `scripts/set-image-tag.sh`

## Pods stuck in InvalidImageName / ImagePullBackOff

**Check**: `kubectl get deployment backend -n gitops-dev -o jsonpath='{..image}'`

- **Uppercase characters** in the image path → `InvalidImageName`. Registry paths must be lowercase (`ghcr.io/parzivalart3mis/...`), and overlay `images[]` names must match the base exactly.
- **Tag doesn't exist in GHCR** (or the package is private): images are pulled anonymously, so GHCR packages must be public (Package settings → Change visibility).
- **`latest` in staging/prod**: Gatekeeper rejects it by design until a SHA is promoted (`promote.yml`).

## Ingress Hostnames Don't Resolve

**Symptom**: `curl http://dev.gitops.local` → `Could not resolve host`.

**Fix**: map the hosts to localhost once (`make hosts` prints the line), or use `make port-forward` instead:
```bash
echo '127.0.0.1 dev.gitops.local api.dev.gitops.local staging.gitops.local api.staging.gitops.local prod.gitops.local api.prod.gitops.local' | sudo tee -a /etc/hosts
```

## HPA Shows `<unknown>` Targets

**Symptom**: `kubectl get hpa -n gitops-dev` shows `cpu: <unknown>/70%`.

**Cause**: metrics-server isn't running (or is still starting). `make setup` installs it with `--kubelet-insecure-tls`, which Kind needs: `kubectl get deployment metrics-server -n kube-system`.

## Frontend Can't Reach Backend

**Symptom**: The UI shows "Backend Unreachable".

The browser calls `/backend/...` on the frontend's own origin; the frontend's Nginx proxies that to `backend_upstream` (`http://backend:8000`). A cluster-internal URL in `backend_url` can never work: the browser runs outside the cluster.

**Check**:
```bash
# Does the proxy reach the backend? (expects JSON with "version")
kubectl exec -it deployment/frontend -n gitops-dev -- wget -qO- http://localhost:8080/backend/healthz

# Is the backend itself healthy?
kubectl exec -it deployment/frontend -n gitops-dev -- wget -qO- http://backend:8000/healthz

# Are backend_url (/backend) and backend_upstream set?
kubectl get configmap frontend-config -n gitops-dev -o yaml
kubectl logs deployment/frontend -n gitops-dev | grep entrypoint
```

If the first command returns HTML instead of JSON, the image predates the `/backend` proxy: let CI build and deploy a new frontend image.

## CI Pipeline: Manifest Commit Can't Be Pushed

**Symptom**: `update-manifests`, `promote` or `rollback` fails with `could not push after 5 attempts` or `protected branch hook declined`.

**Cause**: `master` is protected and `GITHUB_TOKEN` may not push to it. Allow GitHub Actions to bypass the rule (repository ruleset bypass list), or push with a GitHub App / deploy-key token. Concurrent pushes by other workflows are already handled: the script re-applies the change on the new tip and retries.

## CI Pipeline: Image Push Fails

**Symptom**: `build-and-push` job fails with `unauthorized` or `denied`.

**Fix**: Ensure the repository's `GITHUB_TOKEN` has `packages: write` permission. Check `.github/workflows/ci.yml` → `build-and-push.permissions.packages: write`.

Also ensure the package visibility on GHCR is set correctly (public for portfolio demos).

## Sealed Secrets: Secret Not Created

**Symptom**: Pod fails with `secret "app-secrets" not found`.

**Check**:
```bash
kubectl get sealedsecrets -n gitops-dev
kubectl describe sealedsecret app-secrets -n gitops-dev
kubectl logs -l app.kubernetes.io/name=sealed-secrets -n kube-system
```

**Common cause**: The SealedSecret was encrypted with a different controller key than the one running in the cluster (e.g. the Kind cluster was recreated). Re-seal it: `make seal-secret ENV=dev NAME=app-secrets DATA="api-key=@./api-key.txt"`.

## OPA Gatekeeper Blocking a Valid Resource

**Symptom**: `kubectl apply` returns `admission webhook ... denied the request`.

**Check which policy is blocking**:
```bash
kubectl get constrainttemplate
kubectl describe K8sRequiredLabels require-app-labels
```

**Fix**: Either add the required labels to the resource, or temporarily set the constraint to `enforcementAction: warn` while debugging:
```bash
kubectl patch K8sRequiredLabels require-app-labels \
  --type merge -p '{"spec":{"enforcementAction":"warn"}}'
```
Remember to set it back to `deny` afterwards.

## Kind Cluster: NodePort Not Accessible

**Symptom**: `http://localhost:30080` returns `Connection refused`.

**Check**: Ensure the Kind cluster was created with the `extraPortMappings` config in `setup-cluster.sh`. If you created the cluster manually, recreate it.

**Alternative**: Use port-forwarding:
```bash
make port-forward
# ArgoCD → http://localhost:8080
# Grafana → http://localhost:3000
```

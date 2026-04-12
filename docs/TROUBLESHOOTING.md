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
- **Image pull error**: Wrong image tag or missing registry credentials

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

**Symptom**: CI pipeline fails at "Validate Kustomize builds" step.

**Run locally**:
```bash
kustomize build k8s/overlays/dev
kustomize build k8s/overlays/staging
kustomize build k8s/overlays/prod
```

**Common causes**:
- Missing resource file referenced in `kustomization.yaml`
- Patch references a field that doesn't exist in the base
- Invalid YAML syntax

## Frontend Can't Reach Backend

**Symptom**: Browser console shows CORS errors or `Failed to fetch`.

**Check**:
```bash
# Is the backend service reachable?
kubectl exec -it deployment/frontend -n gitops-dev -- \
  wget -qO- http://backend.gitops-dev.svc.cluster.local:8000/healthz

# Is the BACKEND_URL ConfigMap correct?
kubectl get configmap frontend-config -n gitops-dev -o yaml
```

**Fix**: Update `backend_url` in `k8s/overlays/dev/patches/env-config.yaml`.

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

**Common cause**: The SealedSecret was encrypted with a different controller key than the one running in the cluster (e.g., you rotated keys or reinstalled). Re-seal with `./scripts/seal-secret.sh`.

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

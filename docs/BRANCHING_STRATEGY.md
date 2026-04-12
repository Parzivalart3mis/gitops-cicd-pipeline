# Branching Strategy

## Model: GitHub Flow (simplified trunk-based)

This project uses **GitHub Flow** — a simple, trunk-based model optimised for continuous delivery.

```
main ──────────────────────────────────────────────────────► (always deployable to dev)
  │
  ├── feature/add-search-endpoint ──► PR ──► merge to main ──► CI triggers
  ├── fix/healthz-timeout          ──► PR ──► merge to main ──► CI triggers
  └── chore/update-base-image      ──► PR ──► merge to main ──► CI triggers
```

## Branch Rules

| Branch | Protection | Who merges |
|--------|-----------|-----------|
| `main` | Required: CI passing, 1 approval | Team members via PR |
| `feature/*` | None | Developer (short-lived) |
| `fix/*` | None | Developer (short-lived) |
| `chore/*` | None | Developer or bot |

## Automated Commits

The CI pipeline creates two types of automated commits to `main`:

1. **`chore(deploy): update dev images to <SHA>`** — created by `update-manifests` job after every successful push to main
2. **`chore(promote): dev → staging [<SHA>]`** — created by `promote.yml` workflow
3. **`chore(rollback): <env> → <SHA>`** — created by `rollback.yml` workflow

These commits use a bot identity (`github-actions[bot]`) and follow [Conventional Commits](https://www.conventionalcommits.org/) format.

## Why Not GitOps-specific Branches (e.g., `env/dev`, `env/prod`)?

Some GitOps setups use separate branches per environment (one branch per cluster target). We use a **single-branch, overlay-based** approach instead because:

- One branch = one PR review process = simpler mental model
- Kustomize overlays provide the same isolation as separate branches
- Easier to see the full history of all environments in `git log`
- ArgoCD supports `targetRevision: main` with different `path:` values per Application

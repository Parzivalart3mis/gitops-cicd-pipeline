# Branching Strategy

## Model: GitHub Flow (simplified trunk-based)

This project uses **GitHub Flow** — a simple, trunk-based model optimised for continuous delivery.

```
master ────────────────────────────────────────────────────► (always deployable to dev)
  │
  ├── feature/add-search-endpoint ──► PR ──► merge to master ──► CI triggers
  ├── fix/healthz-timeout          ──► PR ──► merge to master ──► CI triggers
  └── chore/update-base-image      ──► PR ──► merge to master ──► CI triggers
```

## Branch Rules

| Branch | Protection | Who merges |
|--------|-----------|-----------|
| `master` | Required: CI passing, 1 approval | Team members via PR (bot commits: see below) |
| `feature/*` | None | Developer (short-lived) |
| `fix/*` | None | Developer (short-lived) |
| `chore/*` | None | Developer or bot |

## Automated Commits

The pipeline creates three types of automated commits to `master`:

1. **`chore(deploy): update dev images to <SHA>`** — created by the `update-manifests` job after every successful push to master
2. **`chore(promote): dev → staging [<SHA>]`** — created by `promote.yml` workflow
3. **`chore(rollback): <env> → <SHA>`** — created by `rollback.yml` workflow

These commits use a bot identity (`github-actions[bot]`) and follow [Conventional Commits](https://www.conventionalcommits.org/) format. They are made by `scripts/ci/push-overlay-change.sh`, which re-applies the change on the latest tip of `master` and retries if another workflow pushed first, so concurrent deploys, promotions and rollbacks never conflict.

**Branch protection and bot commits:** the workflows push directly to `master` with `GITHUB_TOKEN`. If you protect `master` with required reviews or status checks, also allow GitHub Actions to bypass them (a ruleset bypass for the GitHub Actions app, or a GitHub App / deploy-key token used by the push step); otherwise every deploy push is rejected. Pushes made with `GITHUB_TOKEN` don't trigger new workflow runs, so the bot commits cannot loop.

## Why Not GitOps-specific Branches (e.g., `env/dev`, `env/prod`)?

Some GitOps setups use separate branches per environment (one branch per cluster target). We use a **single-branch, overlay-based** approach instead because:

- One branch = one PR review process = simpler mental model
- Kustomize overlays provide the same isolation as separate branches
- Easier to see the full history of all environments in `git log`
- ArgoCD supports `targetRevision: master` with different `path:` values per Application

# Landing Page — GitOps CI/CD Pipeline

A static, single-file landing page for the [GitOps CI/CD Pipeline](../README.md) project,
designed to be hosted on **Vercel** as a portfolio piece.

- `index.html` — the entire page (HTML, CSS, and a few lines of JS inlined; no build step, no dependencies)
- `vercel.json` — clean URLs + security headers

## Deploy to Vercel

### Option A — Vercel Dashboard (recommended)

1. Go to [vercel.com/new](https://vercel.com/new) and import the GitHub repo
   `Parzivalart3mis/gitops-cicd-pipeline`.
2. Under **Root Directory**, click **Edit** and select `web`.
3. Framework Preset: **Other** (it's a static site — no build needed).
   Leave *Build Command* empty and *Output Directory* empty.
4. Click **Deploy**.

Vercel serves `index.html` directly. Pushes that change `web/` redeploy automatically; `ignoreCommand` in `vercel.json` skips builds for every other commit, including the CI bot's manifest commits.

### Option B — Vercel CLI

```bash
npm i -g vercel
cd web
vercel        # preview deployment
vercel --prod # production deployment
```

## Local preview

It's a plain static file — open it directly, or serve it:

```bash
cd web
python3 -m http.server 5173
# open http://localhost:5173
```

## Customising

- **Contact links** live in the `<footer>`. Update the LinkedIn URL (currently a placeholder)
  and any other links to your own profiles.
- Colors and spacing are driven by CSS custom properties in the `:root` block at the top of
  `index.html`.

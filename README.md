# Secure Software Supply Chain for OWASP Juice Shop with the JFrog Platform

This fork of [OWASP Juice Shop](https://github.com/juice-shop/juice-shop) demonstrates a secure CI pipeline that builds, tests, packages and releases the application as a Docker image, with the JFrog Platform as the single source of truth for every artifact.

> Juice Shop is deliberately insecure. A well-configured pipeline should flag it, which makes it a good test of the controls below. The original project README is kept in `README.upstream.md`.

## The idea in one line

**One trusted path in, one evidence trail out.** Every dependency enters through Artifactory, every build is recorded, and nothing reaches production without passing an Xray security gate.

## Architecture

```
 developer push
      │
      ▼
 GitHub Actions ──resolve npm──▶ juiceshop-npm-virtual ──▶ juiceshop-npm-remote ──▶ npmjs.org
      │        ──pull base────▶ juiceshop-docker-virtual ─▶ juiceshop-gcr-remote ──▶ gcr.io (distroless)
      │
      ├─ compile + test
      ├─ docker build
      ├─ push ───────────────▶ juiceshop-docker-dev-local
      ├─ publish build-info ─▶ Artifactory Builds (git, deps, env, artifacts)
      ├─ Xray build scan ────▶ policy "Fail build"?  ── yes ─▶ pipeline stops
      │                                               └─ no ─▶ promote
      └─ promote (copy) ─────▶ juiceshop-docker-prod-local ──▶ Kubernetes
```

## Repository layout in Artifactory

Names follow JFrog's recommended convention `<team>-<technology>-<maturity>-<locator>`.

| Repository | Type | Purpose |
| --- | --- | --- |
| `juiceshop-npm-remote` | Remote (npm) | Proxies and caches registry.npmjs.org |
| `juiceshop-npm-virtual` | Virtual (npm) | Single resolution URL for all npm dependencies |
| `juiceshop-gcr-remote` | Remote (Docker) | Proxies and caches gcr.io, for the distroless base image |
| `juiceshop-docker-dev-local` | Local (Docker) | Every CI build lands here first |
| `juiceshop-docker-prod-local` | Local (Docker) | Only images that passed the Xray gate, promoted from dev |
| `juiceshop-docker-virtual` | Virtual (Docker) | Single pull URL (aggregates the gcr remote and prod) |

Why this layout:

- **Remote repositories** cache upstream packages, so builds keep working if a public registry is slow or down, and every external component is visible to Xray.
- **Virtual repositories** give pipelines one stable URL, so upstream sources can change without touching any pipeline.
- **Separate dev and prod local repositories** make promotion explicit: the prod repository only ever contains images that passed policy, and can be the only one Kubernetes is allowed to pull from.

## Pipeline (`.github/workflows/secure-pipeline.yml`)

| Step | What happens | Requirement covered |
| --- | --- | --- |
| Route npm through Artifactory | `jf npmc` for the root project, plus npm user config for Juice Shop's nested frontend install | Secure dependency resolution |
| Compile | `jf npm install` (records every dependency in build-info), then `npm run build:server` | Compile the code |
| Test | `npm run test:server` | Run the tests |
| Package | `jf docker pull` of the base image through Artifactory, then `docker build` | Runnable Docker image |
| Push | `jf docker push` to `juiceshop-docker-dev-local`, attached to build-info | Repository management |
| Publish build-info | Git commit, dependencies, environment variables, artifacts | Traceability and auditability |
| Xray scan | Full vulnerability report of the image, kept as a run artifact (JSON) | Xray scan |
| Quality gate | `jf build-scan --fail=true` fails the run on any policy marked "Fail Build" | Quality gate |
| Promote | `jf rt build-promote` copies the image to `juiceshop-docker-prod-local` with status `released` | Controlled release |

### Design decisions and trade-offs

- **Compile in CI, package in Docker.** Juice Shop's upstream Dockerfile runs `npm install` inside `docker build`, which fetches from npmjs.org directly and hides those dependencies from build-info. Building in CI keeps every package on the governed path and in the audit trail.
- **Distroless base image.** No shell or package manager, which shrinks the OS attack surface. It is pulled through Artifactory and recorded as a build dependency.
- **Node 24 in CI to match the Node 24 runtime**, because Juice Shop includes native modules.
- **Server-side unit tests only.** Frontend (Karma) and API tests were left out to keep CI runtime reasonable for this exercise.
- **Access token rather than OIDC.** Used for speed here; in production I would use GitHub OIDC so no long-lived credential is stored.

## Quality gate and exceptions

Xray configuration:

- **Policy** `juiceshop-security-gate`: security rule, minimum severity Critical, action *Fail Build*.
- **Watch** `juiceshop-watch`: applies the policy to the `juice-shop` build and to `juiceshop-docker-dev-local`.

Because Juice Shop is intentionally vulnerable, the first runs **fail at the gate by design**. Promotion past the gate happens only through an Xray **ignore rule**: a documented, time-boxed risk acceptance with a justification, recorded in the platform. Exceptions are governed in the security tool, not by a pipeline flag a developer could flip.

## Traceability

For any image tag `N` you can answer, from the JFrog Platform alone:

- Which commit built it (build-info VCS section)
- Which exact npm packages and base image went into it (build-info dependencies)
- Which CI run produced it, and with what environment (build-info environment)
- Which vulnerabilities it contains, and whether it passed policy (Xray)
- When and why it was promoted to production (promotion status and comment)

The CycloneDX SBOM of the image is exported from Xray (Artifactory > `juiceshop-docker-dev-local` > `juice-shop` > tag > Xray Data > Export SBOM > CycloneDX).

## How to run

### From the JFrog registry

```bash
docker login <JF_HOST>
docker run -d --name juice-shop -p 3000:3000 <JF_HOST>/juiceshop-docker-prod-local/juice-shop:<BUILD_NUMBER>
# open http://localhost:3000
```

### From the image archive

```bash
docker load -i juice-shop-<BUILD_NUMBER>.tar
docker run -d --name juice-shop -p 3000:3000 <JF_HOST>/juiceshop-docker-dev-local/juice-shop:<BUILD_NUMBER>
```

### On Kubernetes

See `k8s/deployment.yaml` for the pull secret command, then:

```bash
kubectl apply -f k8s/deployment.yaml
kubectl port-forward svc/juice-shop 3000:3000
```

## Reproducing the pipeline

1. Create the repositories in the table above and enable Xray indexing on the Docker local repositories and the `juice-shop` build.
2. Create the Xray policy and watch described above.
3. In GitHub, set the variables `JF_URL`, `JF_HOST`, `JF_USER` and the secret `JF_ACCESS_TOKEN`.
4. Push to `master` or run the workflow manually from the Actions tab.

## Deliverables

| Deliverable | Location |
| --- | --- |
| Pipeline descriptor | `.github/workflows/secure-pipeline.yml` |
| Dockerfile | `Dockerfile` (with `.dockerignore`) |
| Deployment file | `k8s/deployment.yaml` |
| Run command | "How to run" above |
| Xray scan export (JSON) | Attached to the submission email, and as an artifact on each pipeline run |
| CycloneDX SBOM | Attached to the submission email |

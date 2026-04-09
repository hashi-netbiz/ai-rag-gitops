# Product Requirements Document
# ArgoCD GitOps CI/CD Pipeline for RAG RBAC Chatbot

**Version:** 1.0  
**Date:** 2026-04-03  
**Status:** Draft  
**Repos:** `hashi-netbiz/ai-rag-project` (app) · `hashi-netbiz/ai-rag-gitops` (manifests)

---

## 1. Executive Summary

The RAG RBAC Chatbot already ships a robust 8-stage DevSecOps CI pipeline (secret scanning, SAST, SCA, unit tests, frontend lint, Docker build, container scanning, E2E tests, and ECR push). The final `gitops-update` job in the pipeline is an acknowledged stub with TODO placeholders. This project completes the deployment loop by implementing a full GitOps continuous delivery system using ArgoCD on AWS EKS.

The implementation introduces two purpose-built GitHub Actions workflows — a PR validation workflow (`ci.yml`) and a post-merge deployment workflow (`deploy.yml`) — replacing the current monolithic `ci-cd.yml`. A separate GitOps repository (`hashi-netbiz/ai-rag-gitops`) holds all Kubernetes manifests structured with Kustomize (base + environment overlays). ArgoCD, installed on a single EKS cluster, continuously reconciles the cluster state against the GitOps repo, auto-deploying to staging and requiring manual approval before promoting to production.

The core value proposition is a fully auditable, Git-driven deployment pipeline: every change to staging or production is a traceable Git commit, every rollback is a `git revert`, and every promotion to production requires an explicit human approval recorded in GitHub's environment audit log.

**MVP Goal:** A developer pushes code → CI validates and pushes an immutable image to ECR → manifests in the GitOps repo are automatically updated → ArgoCD deploys to EKS staging within minutes → a named approver promotes to production via a workflow dispatch with full audit trail.

---

## 2. Mission

**Mission Statement:** Deliver every validated code change to production safely, traceably, and repeatably — with Git as the single source of truth for cluster state and GitHub as the approval gate.

**Core Principles:**

1. **Git is the source of truth** — No manual `kubectl apply`. Every cluster change is a Git commit in `hashi-netbiz/ai-rag-gitops`.
2. **Immutable artifacts** — Docker images are tagged with commit SHAs (`sha-<40-char>`). Once built, images are never mutated.
3. **Secrets never in Git** — All runtime secrets live in AWS Secrets Manager; External Secrets Operator syncs them to Kubernetes at runtime.
4. **Fail fast on PRs, deploy confidently on merge** — PRs get full security and quality gates. Post-merge deploys only after all gates have already passed.
5. **Production changes require human approval** — Auto-sync is enabled for staging; production always requires a named reviewer via GitHub Environments.

---

## 3. Target Users

### Persona 1: Application Developer
- **Role:** Writes feature code, opens PRs, monitors CI results
- **Technical level:** Comfortable with Git and Docker; minimal Kubernetes exposure
- **Needs:** Fast PR feedback, clear CI failure messages, confidence that merging to main will deploy to staging automatically
- **Pain points:** Manually deploying to test environments, unclear what failed and why

### Persona 2: DevOps / Platform Engineer
- **Role:** Maintains CI/CD pipeline, manages EKS cluster, handles promotions to production
- **Technical level:** Deep AWS, Kubernetes, and GitHub Actions expertise
- **Needs:** Auditable deployments, easy rollback, secrets managed outside Git, consistent environments
- **Pain points:** Snowflake deployments, undocumented manual steps, secrets in CI logs

### Persona 3: Engineering Lead / Approver
- **Role:** Reviews and approves production deployments
- **Technical level:** Moderate — understands deployment risk but not necessarily cluster internals
- **Needs:** Clear promotion UI, audit trail of who approved what and when, ability to reject or defer a deployment
- **Pain points:** Ad-hoc approvals over Slack with no record, unclear what is actually being deployed

---

## 4. MVP Scope

### Core Functionality
- ✅ Split `ci-cd.yml` into `ci.yml` (PR validation) and `deploy.yml` (post-merge deployment)
- ✅ PR workflow: secret scan, SAST, SCA, unit tests, frontend lint, Docker build, container scan
- ✅ Deploy workflow: E2E tests, ECR push (SHA tag + staging-latest), DAST, GitOps repo update
- ✅ Kustomize manifests: base templates + staging and production overlays
- ✅ ArgoCD Application resources: staging (auto-sync) and production (manual sync)
- ✅ Manual production promotion via `promote-prod.yml` with GitHub Environments approval gate
- ✅ CORS origins configurable via `ALLOWED_ORIGINS` env var (no image rebuild per environment)
- ✅ Rolling update deployment strategy (zero-downtime)

### Technical
- ✅ EKS cluster provisioned via Terraform (single cluster, two namespaces: `rag-staging`, `rag-prod`)
- ✅ EKS Pod Identity associations for External Secrets Operator and AWS Load Balancer Controller
- ✅ External Secrets Operator syncing from AWS Secrets Manager to Kubernetes Secrets
- ✅ AWS Load Balancer Controller for ALB ingress
- ✅ HorizontalPodAutoscaler for backend (min 2, max 5) and frontend (min 2, max 4)
- ✅ Non-root container execution (backend UID 1001, frontend `node` user)
- ✅ Liveness and readiness probes on `/health` (backend) and `/` (frontend)

### Integration
- ✅ ECR image tagging: `sha-<github.sha>` (immutable, prod-safe) + `staging-latest` (mutable, staging)
- ✅ `kustomize edit set image` in CI to update staging overlay image tag
- ✅ ArgoCD polls GitOps repo every 3 minutes (or webhook-triggered)
- ✅ Existing GitHub secrets (`GITOPS_REPO`, `GITOPS_TOKEN`) used by updated gitops-update job
- ✅ Existing OIDC role (`arn:aws:iam::891612574910:role/github-actions`) reused for ECR push and ECR tag validation

### Deployment
- ✅ One-time bootstrap runbook (`argocd/bootstrap.sh`) for cluster setup
- ✅ ArgoCD dashboard accessible internally (behind ALB, not public)
- ✅ Rollback via `argocd app rollback` (quick) or re-running `promote-prod.yml` with previous SHA (deliberate)

### Out of Scope (Future Phases)
- ❌ Multi-cluster setup (separate staging and production clusters)
- ❌ Blue-green or canary deployments (Argo Rollouts)
- ❌ Service mesh (Istio, Linkerd)
- ❌ Automated smoke tests triggered post-ArgoCD sync (requires ArgoCD notification hooks)
- ❌ GitOps repo CI/CD validation (linting Kustomize manifests on PR)
- ❌ Slack/PagerDuty ArgoCD sync notifications
- ❌ Terraform remote state locking (DynamoDB) — can be added after initial apply
- ❌ Multi-region deployment
- ❌ Cost optimisation (Spot instances, Karpenter)
- ❌ Secrets rotation automation

---

## 5. User Stories

### US-1: Automated PR Validation
**As a developer**, I want every pull request to automatically run linting, tests, security scans, and a Docker build **so that** I get fast feedback before code review begins and the team never merges broken or vulnerable code.

*Example:* Alice pushes a feature branch, opens a PR to main. Within 5 minutes she sees green checkmarks for: secret scan, SAST, SCA, unit tests, frontend typecheck, Docker build, and container scan. A critical Trivy finding would surface as a failed check with a link to the SARIF report in the Security tab.

### US-2: Automatic Staging Deployment on Merge
**As a developer**, I want merging to main to automatically deploy my change to the staging environment **so that** I can verify the change works end-to-end without any manual steps.

*Example:* Bob merges a PR at 2pm. The `deploy.yml` workflow runs E2E tests, pushes the image as `sha-abc123` and `staging-latest` to ECR, then commits an updated `k8s/staging/kustomization.yaml` to the GitOps repo. ArgoCD detects the commit within 3 minutes and rolls out the new pods to `rag-staging`. Bob checks the staging URL at 2:10pm and his change is live.

### US-3: Immutable Image Traceability
**As a DevOps engineer**, I want every Docker image to be tagged with its commit SHA **so that** I can always trace exactly which code is running in any environment.

*Example:* An incident occurs in production. The DevOps engineer runs `kubectl get deployment backend -n rag-prod -o jsonpath='{.spec.template.spec.containers[0].image}'` and sees `sha-d4f8e2a`. They run `git show d4f8e2a` in the app repo and immediately know what code is deployed.

### US-4: Manual Production Promotion with Approval
**As an engineering lead**, I want to approve production deployments with a named sign-off **so that** there is a clear, immutable audit record of who promoted what and when.

*Example:* Carol (DevOps engineer) triggers `promote-prod.yml` with input `sha-d4f8e2a`. The workflow pauses for approval. Dave (engineering lead) sees a notification, reviews the change, and clicks Approve. The workflow resumes, updates `k8s/prod/kustomization.yaml`, commits `"chore: promote sha-d4f8e2a to prod [approved by dave]"`, and pushes to the GitOps repo. ArgoCD detects the change and syncs after a manual trigger from the ArgoCD UI.

### US-5: Safe Rollback
**As a DevOps engineer**, I want to roll back a production deployment quickly **so that** a bad release does not stay live while a fix is prepared.

*Example:* A deployment causes elevated error rates. The engineer runs `argocd app rollback rag-prod` to instantly revert to the previous ArgoCD history entry (no new Git commit needed for speed). For a deliberate, audited rollback they re-run `promote-prod.yml` with the last known-good SHA.

### US-6: Secrets Never in Git
**As a security-conscious engineer**, I want all production secrets stored in AWS Secrets Manager and injected at runtime by External Secrets Operator **so that** secrets are never committed to any repository and are centrally rotatable.

*Example:* The `GROQ_API_KEY` is stored in AWS Secrets Manager under `rag-project/backend`. The `externalsecret-backend.yaml` manifest (safe to commit — contains no secret values) instructs ESO to create a Kubernetes `Secret` named `backend-secrets` in the `rag-staging` namespace. The backend `Deployment` consumes it via `envFrom: secretRef`. Rotating the key requires only updating the Secrets Manager value — no manifest changes, no redeploy.

### US-7: Environment-Specific CORS Without Image Rebuilds
**As a DevOps engineer**, I want the backend CORS allowed origins to be configurable per environment via an environment variable **so that** the same Docker image runs correctly in local dev, staging, and production without rebuilds.

*Example:* `ALLOWED_ORIGINS` defaults to `http://localhost:3000,http://localhost:3001` in `.env`. The staging Kustomize overlay patches it to `https://staging.cloudnetbiz.com`. Production patches it to `https://cloudnetbiz.com`. A developer's local environment is unaffected.

### US-8: Infrastructure as Code
**As a DevOps engineer**, I want the EKS cluster, Pod Identity associations, and Secrets Manager resources defined in Terraform **so that** the entire infrastructure can be reproduced, peer-reviewed, and versioned.

*Example:* A new environment is needed. The engineer sets `vpc_id`, `private_subnet_ids`, and `public_subnet_ids` in `terraform.tfvars` (pointing to the existing VPC), then runs `terraform apply`. The EKS cluster, node group, Pod Identity associations, subnet tags, and Secrets Manager secret shells are created in under 15 minutes with no changes to the existing VPC. They then populate the secret values manually and run `bootstrap.sh`.

---

## 6. Core Architecture & Patterns

### High-Level Architecture

```
Developer
  │
  ├─ git push → feature branch
  ├─ PR opened → ci.yml (validation only, no ECR push)
  └─ PR merged to main → deploy.yml
                              │
                    ┌─────────▼──────────┐
                    │  GitHub Actions    │
                    │  deploy.yml        │
                    │  1. E2E tests      │
                    │  2. docker push    │──► ECR (sha-*, staging-latest)
                    │  3. DAST           │
                    │  4. gitops-update  │──► hashi-netbiz/ai-rag-gitops
                    └────────────────────┘        │
                                                  │ git commit (kustomize image tag)
                                            ┌─────▼──────────────┐
                                            │  ArgoCD             │
                                            │  (polls every 3m)  │
                                            └─────┬───────────────┘
                                                  │
                              ┌───────────────────┼───────────────────┐
                              │                   │                   │
                    ┌─────────▼──────┐  ┌─────────▼────────────────┐  │
                    │  rag-staging   │  │  rag-prod (manual sync)  │  │
                    │  auto-sync ON  │  │  requires promote-prod   │  │
                    └────────────────┘  └──────────────────────────┘  │
                                                                       │
                                              promote-prod.yml ────────┘
                                              (workflow_dispatch +
                                               GitHub Env approval)
```

### Repository Structure

**App Repo (`hashi-netbiz/ai-rag-project`):**
```
.github/
  workflows/
    ci.yml              ← PR validation (no ECR push)
    deploy.yml          ← post-merge deploy + gitops update
    promote-prod.yml    ← manual production promotion with approval gate
backend/
  app/
    config.py           ← add: allowed_origins field
    main.py             ← change: read ALLOWED_ORIGINS from settings
  .env.example          ← add: ALLOWED_ORIGINS entry
```

**GitOps Repo (`hashi-netbiz/ai-rag-gitops`):**
```
terraform/              ← EKS, Pod Identity associations, Secrets Manager IaC
k8s/
  base/
    backend/            ← Deployment, Service, HPA
    frontend/           ← Deployment, Service, HPA
  staging/              ← Kustomize overlay (1 replica, staging-latest tag, staging ingress)
  prod/                 ← Kustomize overlay (2 replicas, sha tag, prod ingress)
secrets/
  externalsecret-backend.yaml   ← ESO ExternalSecret (no secret values in file)
argocd/
  project.yaml          ← AppProject
  staging-app.yaml      ← Application (auto-sync)
  prod-app.yaml         ← Application (manual sync)
  bootstrap.sh          ← one-time cluster setup runbook
README.md
```

### Key Design Patterns

- **Two-repo GitOps** — App repo owns code and CI; GitOps repo is the cluster's source of truth. Prevents CI loops and enables access control separation.
- **Kustomize base + overlays** — Base defines shared manifests; overlays patch environment-specific values (replicas, image tags, ingress hosts, CORS origins).
- **Immutable SHA image tags** — `sha-<github.sha>` guarantees each image maps to exactly one commit. `staging-latest` is a mutable convenience tag for staging auto-sync only.
- **EKS Pod Identity** — AWS permissions scoped to individual K8s service accounts via `aws_eks_pod_identity_association`. No ServiceAccount annotations or OIDC conditions required for pod-level access.
- **External Secrets Operator** — Kubernetes-native bridge between AWS Secrets Manager and pod environment variables. ExternalSecret manifests are safe to commit (no values).
- **GitHub Environments + Required Reviewers** — Production promotion is blocked by a named approval enforced by GitHub, creating an immutable audit record.

---

## 7. Features

### Feature 1: PR Validation Workflow (`ci.yml`)
- **Trigger:** `on: pull_request: branches: [main]`
- **Steps:** Gitleaks → path detection → SonarCloud (SAST + pytest coverage) → OWASP SCA → unit tests → frontend lint/typecheck → Docker build (no push) → Trivy container scan
- **Output:** GitHub PR status checks — all must pass before merge is allowed
- **Key behaviour:** Docker image is built with `sha-${{ github.sha }}` tag and saved as a `.tar` artifact; Trivy scans the artifact; image is NOT pushed to ECR (saves cost on every PR)

### Feature 2: Post-Merge Deploy Workflow (`deploy.yml`)
- **Trigger:** `on: push: branches: [main]`
- **Steps:** Path detection → E2E tests (full docker-compose stack) → docker push to ECR → DAST (OWASP ZAP) → gitops-update
- **ECR tags pushed:** `sha-${{ github.sha }}` (immutable) + `staging-latest` (mutable)
- **gitops-update step:** Clones `ai-rag-gitops`, runs `kustomize edit set image` on `k8s/staging/kustomization.yaml` for changed services only (backend and/or frontend, based on path detection), commits `[skip ci]`, pushes

### Feature 3: Production Promotion Workflow (`promote-prod.yml`)
- **Trigger:** `workflow_dispatch` with inputs: `image_sha` (required), `services` (backend/frontend/both), `deploy_reason` (optional)
- **Approval gate:** Job runs inside `environment: production`; GitHub blocks execution until a required reviewer approves
- **Steps:** Validate `image_sha` exists in ECR → checkout GitOps repo → `kustomize edit set image` on `k8s/prod/kustomization.yaml` → commit `"chore: promote sha-X to prod [approved by $actor]"` → push → ArgoCD detects change → manual sync in ArgoCD UI
- **Rollback:** Re-run with previous known-good SHA (same approval gate applies)

### Feature 4: ArgoCD Applications
- **staging-app:** Auto-sync enabled (`prune: true`, `selfHeal: true`), targets `rag-staging` namespace, source path `k8s/staging`
- **prod-app:** No automated sync, targets `rag-prod` namespace, source path `k8s/prod`; requires manual `argocd app sync rag-prod` or ArgoCD UI click after GitOps repo commit

### Feature 5: Secrets Management via ESO
- Single AWS Secrets Manager secret (`rag-project/backend`) holds all 10 backend env vars as JSON keys
- `externalsecret-backend.yaml` instructs ESO to create a K8s `Secret` named `backend-secrets`
- Backend `Deployment` uses `envFrom: secretRef: name: backend-secrets`
- ESO syncs every 1 hour; secret values rotated in Secrets Manager without redeployment

### Feature 6: Environment-Configurable CORS
- `ALLOWED_ORIGINS` env var read by `backend/app/config.py` via Pydantic `BaseSettings`
- Default: `http://localhost:3000,http://localhost:3001` (local dev unchanged)
- Kustomize staging patch: `https://staging.cloudnetbiz.com`
- Kustomize production patch: `https://cloudnetbiz.com`

---

## 8. Technology Stack

### Infrastructure
| Technology | Version | Purpose |
|---|---|---|
| AWS EKS | 1.28+ | Managed Kubernetes cluster (installed into existing VPC) |
| AWS VPC | — | Existing VPC — referenced via `vpc_id` variable, not created by Terraform |
| AWS ECR | — | Container registry (existing) |
| AWS Secrets Manager | — | Runtime secret storage |
| Terraform | 1.6+ | IaC for EKS, Pod Identity associations, Secrets Manager, subnet tagging |
| AWS Load Balancer Controller | 2.7.x | ALB ingress for EKS |

### GitOps & CD
| Technology | Version | Purpose |
|---|---|---|
| ArgoCD | 2.10.x | GitOps continuous delivery controller |
| External Secrets Operator | 0.9.x | Secrets Manager → Kubernetes Secret bridge |
| Kustomize | 5.x | Kubernetes manifest templating (overlays) |

### CI (GitHub Actions)
| Technology | Version | Purpose |
|---|---|---|
| GitHub Actions | — | CI/CD workflow runner |
| Gitleaks | v2 | Secret scanning |
| SonarCloud | — | SAST + coverage |
| OWASP Dependency-Check | — | SCA |
| Trivy | 0.35.x | Container vulnerability scanning |
| OWASP ZAP | — | DAST |
| `yq` / Kustomize CLI | — | YAML manifest updates in gitops-update job |

### Application (Existing — No Changes)
| Technology | Version | Purpose |
|---|---|---|
| Python | 3.11+ | Backend language |
| FastAPI | — | REST API framework |
| uv | — | Python package manager |
| Next.js | 15 | Frontend (App Router) |
| Node.js | 24 | Frontend runtime |
| Docker | — | Containerisation |

### Node Group
| Parameter | Value |
|---|---|
| Instance type | `t3.medium` (2 vCPU, 4 GB) |
| Min nodes | 2 |
| Max nodes | 6 |
| Architecture | Single cluster, two namespaces |

---

## 9. Security & Configuration

### Authentication & Authorization
- **GitHub Actions → AWS:** OIDC role assumption (`arn:aws:iam::891612574910:role/github-actions`) — no long-lived AWS credentials in GitHub secrets
- **ArgoCD → GitOps repo:** `GITOPS_TOKEN` GitHub PAT (fine-grained, write access to `ai-rag-gitops` only, 90-day rotation recommended)
- **ESO → Secrets Manager:** EKS Pod Identity — IAM role `rag-eso-pod-identity`, associated to the `external-secrets` service account in the `external-secrets` namespace via `aws_eks_pod_identity_association`. No ServiceAccount annotation required.
- **ALB Controller → AWS:** EKS Pod Identity — IAM role `rag-alb-controller-pod-identity`, associated to the `aws-load-balancer-controller` service account in `kube-system`.
- **Production deployments:** GitHub Environments + required reviewers — enforced by GitHub, not application code

### EKS Pod Identity vs IRSA
EKS Pod Identity (GA Nov 2023) is used in place of IRSA for all pod-level AWS access:

| Aspect | IRSA | EKS Pod Identity (chosen) |
|---|---|---|
| Trust policy | References OIDC provider + service account | References `pods.eks.amazonaws.com` only |
| ServiceAccount annotation | Required | Not needed |
| Association mechanism | IAM role trust policy condition | `aws_eks_pod_identity_association` Terraform resource |
| OIDC provider for pods | Yes | No |
| EKS add-on required | No | Yes — `eks-pod-identity-agent` DaemonSet |

> The OIDC provider is still provisioned — but exclusively for GitHub Actions → AWS authentication. It plays no role in pod-level IAM access.

### Configuration (Environment Variables)

**Backend runtime (all from AWS Secrets Manager via ESO):**
```
GROQ_API_KEY, GOOGLE_API_KEY, PINECONE_API_KEY, PINECONE_INDEX_NAME
JWT_SECRET_KEY, JWT_ALGORITHM, JWT_EXPIRE_MINUTES
LANGCHAIN_API_KEY, LANGCHAIN_TRACING_V2, LANGCHAIN_PROJECT
```

**Backend: configurable per environment (Kustomize overlay env var):**
```
ALLOWED_ORIGINS=https://staging.cloudnetbiz.com   # staging
ALLOWED_ORIGINS=https://cloudnetbiz.com            # production
```

**Frontend runtime (Kustomize overlay env var, not a secret):**
```
FASTAPI_BASE_URL=http://backend.rag-staging.svc.cluster.local:8000   # staging
FASTAPI_BASE_URL=http://backend.rag-prod.svc.cluster.local:8000      # production
```

**GitHub secrets required (app repo):**
```
GITOPS_REPO            — URL of hashi-netbiz/ai-rag-gitops (already set)
GITOPS_TOKEN           — GitHub PAT with write access to GitOps repo (already set)
SONAR_TOKEN            — SonarCloud (already set)
GROQ_API_KEY           — for E2E and DAST jobs (already set)
GOOGLE_API_KEY         — for E2E and DAST jobs (already set)
PINECONE_API_KEY       — for E2E and DAST jobs (already set)
PINECONE_INDEX_NAME    — for E2E and DAST jobs (already set)
JWT_SECRET_KEY         — for E2E and DAST jobs (already set)
LANGCHAIN_API_KEY      — for E2E and DAST jobs (already set)
```

### Security Scope
**In scope:**
- ✅ No secrets in any Git repository
- ✅ Non-root container execution
- ✅ EKS Pod Identity (least-privilege AWS access per service account, no ServiceAccount annotations)
- ✅ Immutable production image tags
- ✅ Named human approval for every production deployment
- ✅ OIDC for GitHub Actions → AWS (no static credentials)

**Out of scope (future):**
- ❌ Network policies between pods
- ❌ Pod security admission enforcement
- ❌ mTLS between services (service mesh)
- ❌ Automated secret rotation

### Deployment Considerations
- **ECR tag mutability:** Backend and frontend ECR repos must be set to `MUTABLE` to allow re-pushing `staging-latest`. Production safety is preserved because prod always references the immutable `sha-*` tag.
- **Rolling updates:** `maxSurge: 1`, `maxUnavailable: 0` ensures zero-downtime deployments.
- **ArgoCD not publicly exposed:** ArgoCD server is behind an internal ALB, not reachable from the internet.

---

## 10. API Specification

_No new APIs introduced by this project. The existing FastAPI endpoints remain unchanged. See the existing `PRD.md` for the application API specification._

---

## 11. Success Criteria

### MVP Success Definition
A developer can push code to a feature branch, open a PR, receive automated CI feedback within 10 minutes, merge to main, and see the change running on the staging EKS cluster within 5 minutes of the merge — all without any manual kubectl commands or direct AWS console interaction.

### Functional Requirements
- ✅ `ci.yml` runs on every PR and reports all check results to the GitHub PR status UI
- ✅ A failed lint, test, SAST, SCA, or container scan blocks PR merge
- ✅ `deploy.yml` triggers automatically on every push to main
- ✅ ECR receives both `sha-<github.sha>` and `staging-latest` tags for each changed service
- ✅ `k8s/staging/kustomization.yaml` in the GitOps repo is updated with the new SHA within 2 minutes of ECR push
- ✅ ArgoCD detects the GitOps repo change and begins staging sync within 3 minutes
- ✅ Staging deployment completes (pods Running, health checks passing) within 5 minutes of ArgoCD sync start
- ✅ `promote-prod.yml` blocks execution until a required reviewer approves in the GitHub UI
- ✅ Production deployment is triggered only by a commit to `k8s/prod/kustomization.yaml` (no direct kubectl)
- ✅ All 10 backend env vars are available inside the pod via ESO-managed Kubernetes Secret
- ✅ `ALLOWED_ORIGINS` is injected correctly per environment; CORS requests from the frontend succeed
- ✅ `argocd app rollback rag-prod` reverts production to the previous state within 2 minutes
- ✅ `terraform apply` in a clean AWS account reproduces the EKS cluster, Pod Identity associations, and Secrets Manager secret shells with no manual AWS console steps

### Quality Indicators
- Existing 52-unit-test suite continues passing at ≥89% coverage
- No secrets appear in any Git repository commit history
- All existing E2E tests (42/42) pass in the deploy workflow before ECR push
- ArgoCD UI shows both staging and production apps as `Synced` and `Healthy` after initial bootstrap

### User Experience Goals
- Developer has zero new steps to deploy to staging — merging a PR is sufficient
- Production promotion UI is a single `workflow_dispatch` form with clear input labels
- Rollback is a single CLI command or workflow re-run, not a hotfix PR cycle

---

## 12. Implementation Phases

### Phase 1: Infrastructure (Terraform)
**Goal:** Provision the EKS cluster and supporting AWS infrastructure.

**Deliverables:**
- ✅ `terraform/` directory in `ai-rag-gitops` with all `.tf` files
- ✅ `vpc.tf` — data sources for existing VPC and subnets (no VPC creation); `aws_ec2_tag` resources to apply EKS and ALB subnet discovery tags (`kubernetes.io/role/elb`, `kubernetes.io/role/internal-elb`, `kubernetes.io/cluster/<name>`)
- ✅ `variables.tf` — `vpc_id`, `private_subnet_ids`, `public_subnet_ids` as required input variables
- ✅ EKS cluster (`t3.medium`, min 2 / max 6 nodes) deployed into existing private subnets
- ✅ EKS Pod Identity associations: `rag-eso-pod-identity` (ESO), `rag-alb-controller-pod-identity` (ALB Controller)
- ✅ AWS Secrets Manager secret shell: `rag-project/backend`
- ✅ Terraform remote state in S3

**Validation:** `terraform apply` completes without errors; `kubectl get nodes` shows 2+ Ready nodes; private subnets show correct EKS tags in the AWS console.

**Manual step:** Populate 10 secret values in AWS Secrets Manager console.

---

### Phase 2: GitOps Repository (Kustomize + ArgoCD Manifests)
**Goal:** Populate `ai-rag-gitops` with Kubernetes manifests and ArgoCD Application resources.

**Deliverables:**
- ✅ `k8s/base/` — backend and frontend Deployment, Service, HPA
- ✅ `k8s/staging/` — Kustomize overlay (1 replica, staging image tag placeholder, ingress)
- ✅ `k8s/prod/` — Kustomize overlay (2 replicas, prod image tag placeholder, ingress)
- ✅ `secrets/externalsecret-backend.yaml` — ESO ExternalSecret resource
- ✅ `argocd/staging-app.yaml` and `argocd/prod-app.yaml`
- ✅ `argocd/project.yaml` and `argocd/bootstrap.sh`

**Validation:** `kustomize build k8s/staging` and `kustomize build k8s/prod` produce valid YAML with no errors.

---

### Phase 3: Cluster Bootstrap
**Goal:** Install cluster add-ons and register ArgoCD applications.

**Deliverables:**
- ✅ AWS Load Balancer Controller installed and healthy in `kube-system`
- ✅ External Secrets Operator installed and healthy in `external-secrets`
- ✅ `ClusterSecretStore` created and connected to AWS Secrets Manager
- ✅ ArgoCD installed in `argocd` namespace; GitOps repo registered
- ✅ `rag-staging` and `rag-prod` namespaces created
- ✅ ArgoCD staging app synced and Healthy; prod app registered (OutOfSync, awaiting first promotion)
- ✅ `kubectl get externalsecrets -n rag-staging` shows `READY: True`

**Validation:** Staging frontend accessible via staging ALB URL; `/health` returns `{"status":"ok"}`.

---

### Phase 4: CI Refactor + Production Promotion Workflow
**Goal:** Replace `ci-cd.yml` with purpose-built workflows and implement production gate.

**Deliverables:**
- ✅ `ci.yml` (PR validation) — all existing security and quality gates preserved
- ✅ `deploy.yml` (post-merge) — E2E, ECR push (SHA + staging-latest), DAST, gitops-update
- ✅ `gitops-update` job fully implemented (no TODOs)
- ✅ `promote-prod.yml` with `workflow_dispatch`, ECR validation, GitOps update, approval gate
- ✅ GitHub Environment `production` configured with required reviewer(s)
- ✅ `backend/app/config.py` — `allowed_origins` field added
- ✅ `backend/app/main.py` — line 19 updated to use `settings.allowed_origins`
- ✅ `backend/.env.example` — `ALLOWED_ORIGINS` entry added

**Validation:** Merge a test PR to main; confirm staging ECR image updated, GitOps commit made, ArgoCD syncs. Then run `promote-prod.yml` and confirm approval gate fires before GitOps prod commit.

---

## 13. Future Considerations

### Post-MVP Enhancements
- **Argo Rollouts:** Blue-green or canary deployments for the backend service — enables instant traffic cutover and automated analysis (Prometheus metrics) before full promotion
- **ArgoCD Notifications:** Slack/email alerts on sync success, failure, or OutOfSync state
- **GitOps repo CI:** Validate Kustomize manifests on PRs to `ai-rag-gitops` (kustomize build, kubeval, conftest)
- **Automated smoke tests post-deploy:** ArgoCD post-sync hook running a lightweight health check suite against the staging ALB
- **Terraform remote state locking:** DynamoDB table for concurrent-apply safety
- **Secrets rotation:** AWS Secrets Manager automatic rotation integrated with ESO refresh interval
- **Cost optimisation:** Karpenter node provisioner or Spot instances for non-production workloads

### Integration Opportunities
- **Observability stack:** Prometheus + Grafana deployed to EKS via Helm; backend `/metrics` endpoint for request latency, error rate, pod memory
- **Centralised logging:** AWS CloudWatch Container Insights or Loki + Grafana
- **Multi-environment:** Add a `dev` namespace with continuous deploy from a `develop` branch
- **OIDC SSO for ArgoCD:** Replace admin password with GitHub OAuth via ArgoCD's built-in Dex OIDC integration

---

## 14. Risks & Mitigations

### Risk 1: ECR Immutable Tags Block `staging-latest` Push
**Likelihood:** High (ECR repos already confirmed as immutable from commit `baee723`)  
**Impact:** `deploy.yml` fails on the `staging-latest` push; staging never auto-deploys  
**Mitigation:** Run `aws ecr put-image-tag-mutability --image-tag-mutability MUTABLE` on both ECR repos before the first deploy workflow runs. Production safety is preserved because prod exclusively uses the immutable `sha-*` tag.

### Risk 2: ArgoCD Sync Fails Due to Missing Secrets
**Likelihood:** Medium (ESO must be fully configured before ArgoCD syncs)  
**Impact:** Backend pods crash-loop because `backend-secrets` K8s Secret does not exist  
**Mitigation:** Bootstrap order enforces ESO installation → ClusterSecretStore creation → Secrets Manager values populated → ArgoCD Application applied. Validate `kubectl get externalsecrets` shows `READY: True` before declaring bootstrap complete.

### Risk 3: `GITOPS_TOKEN` PAT Expiry Breaks CI
**Likelihood:** Medium (GitHub fine-grained PATs have a maximum 1-year TTL, recommended 90 days)  
**Impact:** `gitops-update` and `promote-prod.yml` jobs fail silently or with auth errors  
**Mitigation:** Set a calendar reminder 2 weeks before PAT expiry to rotate. Consider using a GitHub App with installation token for longer-lived, automatically-rotating credentials.

### Risk 4: Terraform State Corruption
**Likelihood:** Low (S3 backend is durable)  
**Impact:** Infrastructure drift; dangerous to re-apply  
**Mitigation:** Enable S3 versioning on the state bucket. Add DynamoDB state locking in Phase 2 iteration. Never run `terraform apply` locally without confirming no CI apply is in progress.

### Risk 5: CORS Misconfiguration Breaks Frontend in EKS
**Likelihood:** Medium (new env-var-driven CORS is a behaviour change)  
**Impact:** Frontend receives CORS errors; all API calls fail  
**Mitigation:** The `ALLOWED_ORIGINS` default preserves local dev behaviour. Staging deployment validates CORS before production is ever promoted. The E2E test suite in `deploy.yml` exercises actual API calls through the frontend proxy, catching CORS mismatches pre-deploy.

---

## 15. Appendix

### Related Documents
- `PRD.md` — Original RAG RBAC Chatbot product requirements
- `.github/workflows/ci-cd.yml` — Existing monolithic CI/CD pipeline (to be replaced)
- `.agents/plans/phase-4-rag-pipeline.md` — RAG pipeline implementation plan
- `.claude/plans/lazy-dazzling-music.md` — GitOps implementation plan (this project's planning artifact)

### Key Dependencies
| Dependency | Location | Notes |
|---|---|---|
| `GITOPS_REPO` secret | `hashi-netbiz/ai-rag-project` GitHub secrets | URL of `ai-rag-gitops` repo |
| `GITOPS_TOKEN` secret | `hashi-netbiz/ai-rag-project` GitHub secrets | PAT with write access to GitOps repo |
| OIDC role | `arn:aws:iam::891612574910:role/github-actions` | Already provisioned; used for ECR push |
| ECR backend repo | `891612574910.dkr.ecr.us-east-1.amazonaws.com/hashi-netbiz/ai-rag-project/backend` | Already exists |
| ECR frontend repo | `891612574910.dkr.ecr.us-east-1.amazonaws.com/hashi-netbiz/ai-rag-project/frontend` | Already exists |
| GitOps repo | `github.com/hashi-netbiz/ai-rag-gitops` | Already created, currently empty |

### Existing AWS Networking (Pre-provisioned — not managed by Terraform)
| Resource | ID |
|---|---|
| VPC | `vpc-081f05b7937f52b5f` |
| Public Subnet 1 | `subnet-0e9276611273865b0` |
| Public Subnet 2 | `subnet-0a454082366c3f5e8` |
| Private Subnet 1 | `subnet-004736621a8b7e673` |
| Private Subnet 2 | `subnet-0af8c9e6d54c3ada4` |

EKS node groups deploy into the **private subnets**. The AWS Load Balancer Controller creates internet-facing ALBs in the **public subnets** (for the frontend) and internal ALBs in the **private subnets** (for the backend). Terraform applies the required subnet discovery tags without modifying any other VPC configuration.

### ECR Image Tagging Reference
| Tag | Mutability | Used By | Updated By |
|---|---|---|---|
| `sha-<github.sha>` | Immutable | Production, staging (via kustomize) | `deploy.yml` |
| `staging-latest` | Mutable | Staging convenience reference | `deploy.yml` |
| `v1.<run_number>` | Immutable | Legacy (retained for human readability) | `deploy.yml` (keep existing) |


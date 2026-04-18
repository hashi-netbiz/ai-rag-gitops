# CLAUDE.md — ai-rag-gitops

> Place this file at the root of the `hashi-netbiz/ai-rag-gitops` repository.
> It provides guidance to Claude Code when working in this GitOps repository.

## Project Overview

The `ai-rag-gitops` repository is the **single source of truth for cluster state** of the RAG RBAC
Chatbot deployment on AWS EKS. ArgoCD watches this repo continuously and reconciles the EKS cluster
to match what is committed here. Application source code lives in `hashi-netbiz/ai-rag-project`.

**Golden rule:** No direct `kubectl apply` in production. Every cluster change is a Git commit here.

---

## Tech Stack

| Technology | Version | Purpose |
|---|---|---|
| Terraform | 1.6+ | IaC — EKS cluster, Pod Identity associations, Secrets Manager, subnet tagging |
| Kustomize | 5.x | Kubernetes manifest templating — base resources + environment overlays |
| ArgoCD | 2.10.x | GitOps CD controller — watches this repo, syncs EKS cluster |
| External Secrets Operator | 0.9.x | Syncs AWS Secrets Manager secrets → Kubernetes Secrets |
| AWS EKS | 1.28+ | Managed Kubernetes (single cluster, two namespaces) |
| AWS Secrets Manager | — | Runtime secret storage for all backend env vars |
| AWS Load Balancer Controller | 2.7.x | Provisions ALBs from Kubernetes Ingress resources |
| EKS Pod Identity | — | Pod-level AWS IAM access (replaces IRSA — no ServiceAccount annotations) |

---

## AWS Infrastructure

| Resource | Value |
|---|---|
| AWS Account | `891612574910` |
| Region | `us-east-1` |
| VPC | `vpc-0c3dacd09cc795f09` (pre-existing, not managed here) |
| Public Subnets | `subnet-05cab62ff26b40541`, `subnet-065bc06ec556127ca` |
| Private Subnets | `subnet-004736621a8b7e673`, `subnet-0af8c9e6d54c3ada4` |
| EKS Staging Namespace | `rag-staging` |
| EKS Production Namespace | `rag-prod` |
| Secrets Manager Secret | `rag-project/backend` (all 10 backend env vars as JSON) |
| Domain | `cloudnetbiz.com` (staging: `staging.cloudnetbiz.com`) |

---

## Commands

```bash
# Terraform — initialise (first time, or after provider changes)
cd terraform && terraform init

# Terraform — preview changes
cd terraform && terraform plan

# Terraform — apply (provisions EKS, subnet tags, Pod Identity, Secrets Manager shells)
cd terraform && terraform apply

# Kustomize — preview staging manifests (dry-run, no cluster needed)
kustomize build k8s/staging

# Kustomize — preview production manifests
kustomize build k8s/prod

# Kustomize — update image tag (done by CI, not manually)
cd k8s/staging && kustomize edit set image \
  891612574910.dkr.ecr.us-east-1.amazonaws.com/hashi-netbiz/ai-rag-project/backend:sha-<SHA>

# ArgoCD — access UI (internal ALB only — use port-forward)
kubectl port-forward svc/argocd-server -n argocd 8080:443
# then open https://localhost:8080

# ArgoCD — list apps
argocd app list

# ArgoCD — check staging sync status
argocd app get rag-staging

# ArgoCD — manually sync production (after promote-prod.yml updates manifests)
argocd app sync rag-prod

# ArgoCD — rollback production to previous history entry (fast, no Git commit)
argocd app rollback rag-prod

# ArgoCD — wait for production sync and health
argocd app wait rag-prod --sync --health --timeout 300

# Bootstrap — one-time cluster setup (run once after terraform apply)
bash argocd/bootstrap.sh

# Teardown — destroy all cluster components then run terraform destroy
# (orders deletion carefully so ALB Controller removes ALBs before infra is gone)
GITOPS_CONFIRM=yes bash argocd/teardown.sh

# Rebuild — full destroy + re-provision (teardown → terraform apply → bootstrap)
GITOPS_CONFIRM=yes GITOPS_TOKEN=<PAT> bash argocd/rebuild.sh

# kubectl — check staging pods
kubectl get pods -n rag-staging

# kubectl — check ESO secret sync status
kubectl get externalsecrets -n rag-staging

# kubectl — check production deployment
kubectl get deployment -n rag-prod
```

---

## Project Structure

```
ai-rag-gitops/
├── terraform/                   # AWS infrastructure IaC
│   ├── main.tf                  # AWS provider, S3 backend for remote state
│   ├── variables.tf             # vpc_id, subnet IDs, cluster_name, region, instance type
│   ├── vpc.tf                   # Data sources for existing VPC + subnets; subnet tag resources
│   ├── eks.tf                   # aws_eks_cluster, aws_eks_node_group, eks-pod-identity-agent addon
│   ├── iam.tf                   # OIDC provider (GitHub Actions only); Pod Identity IAM roles
│   ├── secrets.tf               # aws_secretsmanager_secret shell for rag-project/backend
│   ├── outputs.tf               # cluster_endpoint, cluster_name
│   ├── versions.tf              # required_providers with version pins
│   └── terraform.tfvars         # ← GITIGNORED — contains real VPC/subnet IDs
│
├── k8s/                         # Kubernetes manifests (Kustomize)
│   ├── base/                    # Shared templates — no env-specific values here
│   │   ├── backend/
│   │   │   ├── deployment.yaml  # image: placeholder (overridden by overlay)
│   │   │   ├── service.yaml     # ClusterIP, port 8000
│   │   │   ├── hpa.yaml         # min 2, max 5, CPU 70%
│   │   │   └── kustomization.yaml
│   │   └── frontend/
│   │       ├── deployment.yaml  # FASTAPI_BASE_URL from overlay patch
│   │       ├── service.yaml     # ClusterIP, port 3001
│   │       ├── hpa.yaml         # min 2, max 4, CPU 70%
│   │       └── kustomization.yaml
│   │
│   ├── staging/                 # Staging overlay (auto-synced by ArgoCD)
│   │   ├── kustomization.yaml   # ← CI updates image tags here via kustomize edit set image
│   │   └── ingress.yaml         # ALB, host: staging.cloudnetbiz.com (public subnets)
│   │                            # Note: no patch-replicas.yaml — base HPA minReplicas: 2 governs
│   │
│   └── prod/                    # Production overlay (manual sync only)
│       ├── kustomization.yaml   # ← promote-prod.yml updates image tags here
│       ├── patch-replicas.yaml  # Reserved for pre-scaling above HPA minimum (currently no effect)
│       └── ingress.yaml         # ALB, host: cloudnetbiz.com (public subnets)
│
├── secrets/
│   └── externalsecret-backend.yaml  # ClusterSecretStore + two ExternalSecrets (rag-staging + rag-prod)
│                                    # Both namespaces pull from rag-project/backend in Secrets Manager
│                                    # Creates K8s Secret "backend-secrets" in each namespace
│
├── argocd/
│   ├── project.yaml             # AppProject scoping source repos + dest namespaces
│   ├── staging-app.yaml         # Application: path=k8s/staging, auto-sync ON
│   ├── prod-app.yaml            # Application: path=k8s/prod, manual sync only
│   └── bootstrap.sh             # One-time ordered setup runbook (see Bootstrap section)
│
├── .gitignore                   # Must include: terraform.tfvars, .terraform/, *.tfstate*
└── CLAUDE.md                    # This file
```

---

## Architecture

### Data Flow: Code → Cluster

```
hashi-netbiz/ai-rag-project
  └─ push to main → deploy.yml
                      └─ builds image → ECR (sha-<SHA> + staging-latest)
                      └─ gitops-update job
                            └─ kustomize edit set image → k8s/staging/kustomization.yaml
                            └─ git commit + push to THIS REPO
                                  └─ ArgoCD detects change (polls every 3 min)
                                        └─ auto-syncs → rag-staging namespace ✅

  promote-prod.yml (manual, approval-gated)
    └─ kustomize edit set image → k8s/prod/kustomization.yaml
    └─ git commit + push to THIS REPO
          └─ ArgoCD detects change
                └─ manual sync → rag-prod namespace ✅
```

### Secrets Flow

```
AWS Secrets Manager: rag-project/backend (JSON with 10 keys)
  └─ External Secrets Operator (Pod Identity: rag-eso-pod-identity)
        └─ ExternalSecret resource (secrets/externalsecret-backend.yaml)
              └─ Kubernetes Secret: "backend-secrets" (created at runtime, never in Git)
                    └─ backend Deployment: envFrom: secretRef: backend-secrets
```

### Pod Identity (not IRSA)

EKS Pod Identity is used for all pod-level AWS access. No ServiceAccount annotations needed.
Associations are managed in Terraform `iam.tf` via `aws_eks_pod_identity_association`.

| Role | Namespace | Service Account | AWS Permission |
|---|---|---|---|
| `rag-eso-pod-identity` | `external-secrets` | `external-secrets` | `secretsmanager:GetSecretValue` on `rag-project/*` |
| `rag-alb-controller-pod-identity` | `kube-system` | `aws-load-balancer-controller` | ALB management policy |

---

## Kustomize Patterns

### Never Put Env-Specific Values in Base

`k8s/base/` resources use placeholder values. Overlays patch everything environment-specific:
- Image tags (updated by CI via `kustomize edit set image`)
- Ingress hostnames (`ingress.yaml` per overlay)
- `ALLOWED_ORIGINS` env var (patch in each overlay's `deployment.yaml` patch)
- `FASTAPI_BASE_URL` env var (points to backend ClusterIP in the correct namespace)

### Image Tag Convention

| Tag | Mutability | Updated By | Used In |
|---|---|---|---|
| `sha-<github.sha>` | Immutable | `deploy.yml` (CI) | Both overlays (via kustomize) |
| `staging-latest` | Mutable | `deploy.yml` (CI) | ECR convenience only |

`kustomization.yaml` always references the SHA tag, not `staging-latest`.

### Validating Manifests Locally

Always run `kustomize build` before committing manifest changes:
```bash
kustomize build k8s/staging | kubectl apply --dry-run=client -f -
kustomize build k8s/prod    | kubectl apply --dry-run=client -f -
```

---

## Terraform Patterns

### No VPC Resources Created Here

The VPC (`vpc-081f05b7937f52b5f`) and subnets are pre-existing. `vpc.tf` only:
1. Reads existing resources via data sources
2. Tags subnets for EKS and ALB Controller discovery

Do **not** add `aws_vpc`, `aws_subnet`, `aws_internet_gateway`, or `aws_route_table` resources.

### terraform.tfvars Is Gitignored

Real subnet IDs and VPC ID live in `terraform.tfvars` (gitignored). Use `TF_VAR_` environment
variables or a secrets manager for CI-driven applies. Never commit `terraform.tfvars`.

### State Backend

Remote state lives in S3. Run `terraform init` before any plan/apply. The S3 bucket and key are
defined in `main.tf` backend block. Never delete or move state files manually.

### Pod Identity Add-on Order

The `eks-pod-identity-agent` EKS addon must be active before `aws_eks_pod_identity_association`
resources are useful. Terraform handles this via `depends_on` in `iam.tf`.

---

## ArgoCD Patterns

### Staging: Auto-Sync, Production: Manual-Sync

- **Staging** (`staging-app.yaml`): `automated.prune: true`, `automated.selfHeal: true`
  — Any commit to `k8s/staging/` triggers an automatic cluster sync.
- **Production** (`prod-app.yaml`): No `automated` block
  — ArgoCD detects the OutOfSync state but does NOT auto-apply. Requires explicit
  `argocd app sync rag-prod` or a click in the ArgoCD UI after the `promote-prod.yml` commit.

### Do Not Edit ArgoCD Application Resources Directly in the Cluster

All ArgoCD configuration (`project.yaml`, `staging-app.yaml`, `prod-app.yaml`) is committed here.
Changes to ArgoCD config should be made via Git commit, not `kubectl edit` or the ArgoCD UI.

### Rollback Strategies

| Method | Speed | Git Commit? | Use When |
|---|---|---|---|
| `argocd app rollback rag-prod` | Instant | No | Emergency — reverts to previous ArgoCD history |
| Re-run `promote-prod.yml` with old SHA | ~5 min | Yes (audited) | Deliberate rollback with approval |

---

## Bootstrap (One-Time Setup)

Run `argocd/bootstrap.sh` after `terraform apply` completes. The script is ordered — each step
depends on the previous completing successfully.

1. `aws eks update-kubeconfig` — configure local kubectl
2. Install AWS Load Balancer Controller (Helm, `kube-system`)
3. Install External Secrets Operator (Helm, `external-secrets`)
4. Create namespaces: `kubectl create namespace rag-staging && kubectl create namespace rag-prod`
5. Apply `secrets/externalsecret-backend.yaml` — creates ClusterSecretStore + both ExternalSecrets
   (namespaces must exist first or the apply will fail)
6. Install ArgoCD (official stable manifest, `argocd` namespace)
7. Register GitOps repo in ArgoCD using `GITOPS_TOKEN` PAT (kubectl create secret — never in Git)
8. `kubectl apply -f argocd/project.yaml -f argocd/staging-app.yaml -f argocd/prod-app.yaml -n argocd`

Bootstrap is idempotent for steps 2-3 and 5 (Helm upgrade --install). Steps 6-8 may error if already
exists — inspect and skip safely.

---

## Security Rules

- **Never commit secret values** — `terraform.tfvars`, `.env`, kubeconfig, ArgoCD passwords
- **Never annotate ServiceAccounts with IAM role ARNs** — use Pod Identity associations in Terraform
- **Never commit plain Kubernetes Secrets** — only `ExternalSecret` resources (no data.* values)
- **`terraform.tfvars` must be in `.gitignore`** — check before every commit
- **Production changes require the `promote-prod.yml` approval gate** — no direct commits to `k8s/prod/`

---

## Key Files

| File | Purpose |
|---|---|
| `terraform/vpc.tf` | Subnet tagging for EKS/ALB — only file touching the existing VPC |
| `terraform/iam.tf` | Pod Identity roles + associations — edit here to change AWS permissions |
| `k8s/staging/kustomization.yaml` | Updated by CI on every merge — source of staging image tags |
| `k8s/prod/kustomization.yaml` | Updated by `promote-prod.yml` — source of production image tags |
| `secrets/externalsecret-backend.yaml` | ESO bridge to Secrets Manager — edit to add/remove backend secrets |
| `argocd/staging-app.yaml` | ArgoCD staging app config — auto-sync policy lives here |
| `argocd/prod-app.yaml` | ArgoCD production app config — no automated sync |
| `argocd/bootstrap.sh` | One-time cluster setup runbook |
| `argocd/teardown.sh` | Ordered cluster + infra destruction (prevents ALB leaks) |
| `argocd/rebuild.sh` | Full destroy + re-provision wrapper (teardown → apply → bootstrap) |

---

## On-Demand Context

| Topic | Location |
|---|---|
| Full CI/CD implementation plan | `hashi-netbiz/ai-rag-project/.claude/plans/lazy-dazzling-music.md` |
| GitOps pipeline PRD | `hashi-netbiz/ai-rag-project/NEW_PRD.md` |
| Application source code + app CLAUDE.md | `hashi-netbiz/ai-rag-project` |
| ArgoCD docs | https://argo-cd.readthedocs.io/en/stable/ |
| External Secrets Operator docs | https://external-secrets.io/latest/ |
| EKS Pod Identity docs | https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html |

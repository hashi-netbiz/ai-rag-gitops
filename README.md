# ai-rag-gitops

GitOps repository for the **RAG RBAC Chatbot** — the single source of truth for cluster state on AWS EKS. ArgoCD watches this repo and reconciles the cluster to match every commit.

Application source code lives in [hashi-netbiz/ai-rag-project](https://github.com/hashi-netbiz/ai-rag-project).

---

## Architecture Overview

```text
hashi-netbiz/ai-rag-project
  └─ push to main → GitHub Actions (deploy.yml)
                      ├─ builds Docker image → ECR (sha-<SHA>)
                      └─ updates k8s/staging/kustomization.yaml (image tag)
                            └─ ArgoCD auto-syncs → rag-staging namespace

  promote-prod.yml (manual, approval-gated)
    └─ updates k8s/prod/kustomization.yaml
          └─ ArgoCD manual sync → rag-prod namespace
```

### Secrets Flow

```text
AWS Secrets Manager: rag-project/backend
  └─ External Secrets Operator (EKS Pod Identity)
        └─ ExternalSecret → Kubernetes Secret "backend-secrets"
              └─ backend Deployment (envFrom)
```

---

## Tech Stack

| Technology | Version | Purpose |
| --- | --- | --- |
| Terraform | 1.6+ | EKS cluster, IAM, Secrets Manager, subnet tagging |
| Kustomize | 5.x | Kubernetes manifest templating (base + overlays) |
| ArgoCD | 2.10.x | GitOps CD controller |
| External Secrets Operator | 0.9.x | AWS Secrets Manager → Kubernetes Secrets |
| AWS EKS | 1.28+ | Managed Kubernetes |
| AWS Load Balancer Controller | 2.7.x | ALB provisioning from Ingress resources |
| EKS Pod Identity | — | Pod-level AWS IAM access |

---

## Prerequisites

Before you begin, ensure you have the following installed and configured:

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) — authenticated with an account that has EKS, IAM, EC2, and Secrets Manager permissions
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.6
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/) >= 3.x
- [Kustomize](https://kubectl.docs.kubernetes.io/installation/kustomize/) >= 5.x
- [ArgoCD CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) (optional, for CLI-based management)
- A GitHub Personal Access Token (PAT) with `repo` scope — used by ArgoCD to poll this repo

### AWS Prerequisites

- A pre-existing VPC with at least 2 public and 2 private subnets
- Public subnets tagged: `kubernetes.io/role/elb = 1`
- Private subnets tagged: `kubernetes.io/role/internal-elb = 1`
- An S3 bucket for Terraform remote state (update `terraform/main.tf` backend block)

---

## Installation Guide

### Step 1 — Clone the repository

```bash
git clone https://github.com/hashi-netbiz/ai-rag-gitops.git
cd ai-rag-gitops
```

### Step 2 — Configure Terraform variables

Create `terraform/terraform.tfvars` (this file is gitignored — never commit it):

```hcl
vpc_id             = "vpc-xxxxxxxxxxxxxxxxx"
public_subnet_ids  = ["subnet-xxxxxxxxxxxxxxxxx", "subnet-xxxxxxxxxxxxxxxxx"]
private_subnet_ids = ["subnet-xxxxxxxxxxxxxxxxx", "subnet-xxxxxxxxxxxxxxxxx"]
cluster_name       = "rag-cluster"
region             = "us-east-1"
instance_type      = "t3.medium"
```

### Step 3 — Provision AWS infrastructure

```bash
cd terraform
terraform init
terraform plan
terraform apply
cd ..
```

This provisions:

- EKS cluster and managed node group
- IAM roles for Pod Identity (ESO + ALB Controller)
- Subnet tags for EKS and ALB Controller discovery
- AWS Secrets Manager secret shell (`rag-project/backend`)

### Step 4 — Populate secrets in AWS Secrets Manager

After `terraform apply`, populate the secret with your backend environment variables:

```bash
aws secretsmanager put-secret-value \
  --secret-id rag-project/backend \
  --secret-string '{
    "DATABASE_URL": "...",
    "API_KEY": "...",
    "OPENAI_API_KEY": "...",
    "SECRET_KEY": "..."
  }'
```

Add all required keys as a single JSON object. External Secrets Operator will unpack each key into the pod environment automatically.

### Step 5 — Bootstrap the cluster

Set your GitHub PAT and run the bootstrap script:

```bash
export GITOPS_TOKEN=<your-github-pat>
bash argocd/bootstrap.sh
```

The script runs in order:

| Step | Action |
| --- | --- |
| 1 | Configures `kubectl` via `aws eks update-kubeconfig` |
| 2 | Installs AWS Load Balancer Controller (Helm, `kube-system`) |
| 3 | Installs External Secrets Operator (Helm, `external-secrets`) |
| 4 | Creates `rag-staging` and `rag-prod` namespaces |
| 5 | Applies `secrets/externalsecret-backend.yaml` (ClusterSecretStore + ExternalSecrets) |
| 6 | Installs ArgoCD (`argocd` namespace) |
| 7 | Registers this GitOps repo in ArgoCD using the PAT |
| 8 | Applies ArgoCD project, staging app, and prod app |

Bootstrap is idempotent for Helm steps — safe to re-run if interrupted.

### Step 6 — Verify the deployment

```bash
# Check pods in staging
kubectl get pods -n rag-staging

# Check ArgoCD sync status
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080
# Get initial admin password:
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d

# Check secret sync
kubectl get externalsecrets -n rag-staging
```

---

## Project Structure

```text
ai-rag-gitops/
├── terraform/          # AWS infrastructure (EKS, IAM, Secrets Manager)
├── k8s/
│   ├── base/           # Shared Kustomize templates (no env-specific values)
│   ├── staging/        # Staging overlay — auto-synced by ArgoCD
│   └── prod/           # Production overlay — manual sync only
├── secrets/
│   └── externalsecret-backend.yaml   # ESO ClusterSecretStore + ExternalSecrets
└── argocd/
    ├── project.yaml        # ArgoCD AppProject
    ├── staging-app.yaml    # Auto-sync, prune + selfHeal enabled
    ├── prod-app.yaml       # Manual sync only
    ├── bootstrap.sh        # One-time cluster setup
    ├── teardown.sh         # Ordered cluster + infra destruction
    └── rebuild.sh          # Full destroy + re-provision
```

---

## Environments

| Environment | Namespace | Sync | URL |
| --- | --- | --- | --- |
| Staging | `rag-staging` | Automatic (on every commit) | `staging.cloudnetbiz.com` |
| Production | `rag-prod` | Manual (via `promote-prod.yml`) | `cloudnetbiz.com` |

---

## Promoting to Production

Production deployments are triggered by `promote-prod.yml` in the application repo, which requires manual approval. After the workflow commits the updated image tag:

```bash
# Trigger the sync
argocd app sync rag-prod

# Wait for completion
argocd app wait rag-prod --sync --health --timeout 300
```

### Rolling back production

```bash
# Fast rollback to previous ArgoCD history entry (no Git commit)
argocd app rollback rag-prod
```

---

## Teardown

To destroy the cluster and all AWS infrastructure:

```bash
GITOPS_CONFIRM=yes bash argocd/teardown.sh
cd terraform && terraform destroy
```

The teardown script deletes resources in the correct order to ensure the ALB Controller removes load balancers before the underlying VPC infrastructure is torn down.

---

## Security Notes

- **Never commit secret values** — use AWS Secrets Manager and ExternalSecret resources only
- **Never annotate ServiceAccounts with IAM role ARNs** — Pod Identity is configured via Terraform
- **`terraform.tfvars` is gitignored** — verify before every commit
- **Production changes require the `promote-prod.yml` approval gate**

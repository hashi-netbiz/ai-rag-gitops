#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="rag-cluster"
REGION="us-east-1"
GITOPS_REPO="https://github.com/hashi-netbiz/ai-rag-gitops"

echo "==> Step 1: Configure kubectl"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"

echo "==> Step 2: Install AWS Load Balancer Controller"
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller

echo "==> Step 3: Install External Secrets Operator"
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace

echo "==> Step 4: Create application namespaces"
kubectl create namespace rag-staging --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace rag-prod --dry-run=client -o yaml | kubectl apply -f -

echo "==> Step 5: Apply ExternalSecret resources (namespaces must exist first)"
kubectl apply -f secrets/externalsecret-backend.yaml

echo "==> Step 6: Install ArgoCD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=120s

echo "==> Step 7: Register GitOps repo in ArgoCD"
if [ -z "${GITOPS_TOKEN:-}" ]; then
  echo "ERROR: GITOPS_TOKEN env var must be set"
  exit 1
fi
kubectl create secret generic argocd-repo-gitops \
  -n argocd \
  --from-literal=url="$GITOPS_REPO" \
  --from-literal=username=git \
  --from-literal=password="$GITOPS_TOKEN" \
  --dry-run=client -o yaml | \
  kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml | \
  kubectl apply -f -

echo "==> Step 8: Apply ArgoCD project and applications"
kubectl apply -f argocd/project.yaml -n argocd
kubectl apply -f argocd/staging-app.yaml -n argocd
kubectl apply -f argocd/prod-app.yaml -n argocd

echo "==> Bootstrap complete"
echo "    Access ArgoCD UI: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "    Initial admin password: kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"

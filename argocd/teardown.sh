#!/usr/bin/env bash
# teardown.sh — ordered destruction of the RAG cluster and all AWS infrastructure.
#
# ORDER MATTERS:
#   1. Stop ArgoCD from reconciling (delete apps + project)
#   2. Delete Ingress resources so the ALB Controller removes the ALBs from AWS
#      before the controller itself is removed
#   3. Clear ExternalSecret finalizers — the ESO controller is removed in the
#      next step; if finalizers are left in place the application namespaces
#      will get stuck in Terminating indefinitely
#   4. Delete ESO CRDs — prevents the external-secrets namespace from getting
#      stuck in Terminating after the controller is uninstalled
#   5. Uninstall Helm releases (ArgoCD, ESO, ALB Controller)
#   6. Delete application namespaces
#   7. terraform destroy — safe now that in-cluster controllers have cleaned up
#      AWS resources
#
# Usage:
#   GITOPS_CONFIRM=yes bash argocd/teardown.sh
#
# WARNING: This is irreversible. All cluster state and AWS resources managed by
# Terraform will be destroyed. The S3 remote state bucket is NOT deleted.
set -euo pipefail

CLUSTER_NAME="rag-cluster"
REGION="us-east-1"

# ── Safety gate ──────────────────────────────────────────────────────────────
if [ "${GITOPS_CONFIRM:-}" != "yes" ]; then
  echo "ERROR: Set GITOPS_CONFIRM=yes to confirm you want to destroy everything."
  exit 1
fi

echo "==> Configuring kubectl for cluster: $CLUSTER_NAME"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"

# ── Step 1: Stop ArgoCD reconciliation ───────────────────────────────────────
echo "==> Step 1: Deleting ArgoCD applications and project"
kubectl delete application rag-prod    -n argocd --ignore-not-found
kubectl delete application rag-staging -n argocd --ignore-not-found
kubectl delete appproject  rag-project -n argocd --ignore-not-found

# ── Step 2: Delete Ingress resources (triggers ALB deletion by the controller) ──
echo "==> Step 2: Deleting Ingress resources (ALB Controller will remove ALBs)"
kubectl delete ingress --all -n rag-prod    --ignore-not-found
kubectl delete ingress --all -n rag-staging --ignore-not-found

echo "    Waiting up to 3 min for ALBs to be deprovisioned..."
DEADLINE=$(( $(date +%s) + 180 ))
while true; do
  ALB_COUNT=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName, \`rag\`)].LoadBalancerArn" \
    --output text 2>/dev/null | wc -w || echo 0)
  if [ "$ALB_COUNT" -eq 0 ]; then
    echo "    ALBs removed."
    break
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "WARNING: Timed out waiting for ALBs to be removed. You may need to"
    echo "         delete them manually in the AWS console before terraform destroy."
    break
  fi
  echo "    $ALB_COUNT ALB(s) still present — waiting 15s..."
  sleep 15
done

# ── Step 3: Clear ExternalSecret finalizers ───────────────────────────────────
# The ESO controller is removed in Step 5. If ExternalSecret resources still
# carry their finalizers when the controller is gone, Kubernetes cannot complete
# namespace deletion (the finalizer handler never runs). Clear them now while
# the controller is still alive.
echo "==> Step 3: Clearing ExternalSecret finalizers before ESO is removed"
for NS in rag-staging rag-prod; do
  for ES in $(kubectl get externalsecret -n "$NS" -o name 2>/dev/null); do
    echo "    Patching $ES in $NS"
    kubectl patch "$ES" -n "$NS" --type=merge \
      -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
  done
done

# ── Step 4: Delete ESO CRDs ───────────────────────────────────────────────────
# Removing CRDs before the ESO Helm uninstall prevents the external-secrets
# namespace from getting stuck in Terminating (CRD finalizers block namespace
# deletion when the controller is already gone).
echo "==> Step 4: Deleting ESO CRDs"
kubectl delete crd \
  externalsecrets.external-secrets.io \
  clustersecretstores.external-secrets.io \
  secretstores.external-secrets.io \
  --ignore-not-found 2>/dev/null || true

# ── Step 5: Uninstall Helm releases ──────────────────────────────────────────
echo "==> Step 5: Uninstalling Helm releases"
helm uninstall aws-load-balancer-controller -n kube-system     --ignore-not-found 2>/dev/null || true
helm uninstall external-secrets            -n external-secrets --ignore-not-found 2>/dev/null || true
helm uninstall argocd                      -n argocd           --ignore-not-found 2>/dev/null || true

# ArgoCD is installed via kubectl apply (not Helm) in bootstrap.sh, so also try:
kubectl delete -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --ignore-not-found 2>/dev/null || true

# ── Step 6: Delete namespaces ────────────────────────────────────────────────
echo "==> Step 6: Deleting namespaces"
for NS in rag-staging rag-prod external-secrets argocd; do
  kubectl delete namespace "$NS" --ignore-not-found
done

echo "    Waiting for namespaces to terminate..."
for NS in rag-staging rag-prod external-secrets argocd; do
  kubectl wait --for=delete namespace/"$NS" --timeout=120s 2>/dev/null || true
done

# ── Step 7: Terraform destroy ────────────────────────────────────────────────
echo "==> Step 7: Running terraform destroy"
cd "$(dirname "$0")/../terraform"
terraform init -reconfigure
terraform destroy -auto-approve

echo ""
echo "==> Teardown complete."
echo "    The S3 state bucket (ai-rag-terraform-state) was NOT deleted."
echo "    Run 'bash argocd/rebuild.sh' to rebuild from scratch."

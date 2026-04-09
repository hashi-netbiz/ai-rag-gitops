#!/usr/bin/env bash
# rebuild.sh — full destroy + re-provision of the RAG cluster.
#
# This is a convenience wrapper that runs teardown.sh followed by:
#   1. terraform apply  (re-creates all AWS infrastructure)
#   2. bootstrap.sh     (re-installs all cluster components)
#
# Usage:
#   GITOPS_CONFIRM=yes GITOPS_TOKEN=<PAT> bash argocd/rebuild.sh
#
# Required env vars:
#   GITOPS_CONFIRM  — must be "yes" (passed through to teardown.sh)
#   GITOPS_TOKEN    — GitHub PAT for ArgoCD to access the GitOps repo (passed to bootstrap.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "${GITOPS_CONFIRM:-}" != "yes" ]; then
  echo "ERROR: Set GITOPS_CONFIRM=yes to confirm the full destroy + rebuild."
  exit 1
fi

if [ -z "${GITOPS_TOKEN:-}" ]; then
  echo "ERROR: GITOPS_TOKEN must be set (GitHub PAT for ArgoCD repo access)."
  exit 1
fi

# ── Phase 1: Tear down ───────────────────────────────────────────────────────
echo "========================================"
echo " PHASE 1: TEARDOWN"
echo "========================================"
bash "$SCRIPT_DIR/teardown.sh"

# ── Phase 2: Provision infrastructure ────────────────────────────────────────
echo ""
echo "========================================"
echo " PHASE 2: TERRAFORM APPLY"
echo "========================================"
cd "$SCRIPT_DIR/../terraform"
terraform init -reconfigure
terraform apply -auto-approve

# ── Phase 3: Bootstrap cluster ────────────────────────────────────────────────
echo ""
echo "========================================"
echo " PHASE 3: BOOTSTRAP"
echo "========================================"
bash "$SCRIPT_DIR/bootstrap.sh"

echo ""
echo "========================================"
echo " REBUILD COMPLETE"
echo "========================================"
echo "  Staging:    https://staging.cloudnetbiz.com  (auto-synced by ArgoCD)"
echo "  Production: https://cloudnetbiz.com          (manual sync required)"
echo "  ArgoCD UI:  kubectl port-forward svc/argocd-server -n argocd 8080:443"

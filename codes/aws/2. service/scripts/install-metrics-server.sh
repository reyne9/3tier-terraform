#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(dirname "$SCRIPT_DIR")"
CLUSTER_NAME=$(terraform -chdir="$TF_DIR" output -raw eks_cluster_name)
REGION=$(terraform -chdir="$TF_DIR" output -raw aws_region)
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update
helm repo update metrics-server
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system --wait --timeout 5m
kubectl rollout status deployment/metrics-server -n kube-system --timeout=300s

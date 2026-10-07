#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(dirname "$SCRIPT_DIR")"
for tool in terraform aws kubectl helm; do
  command -v "$tool" >/dev/null || { echo "Missing: $tool" >&2; exit 1; }
done

CLUSTER_NAME=$(terraform -chdir="$TF_DIR" output -raw eks_cluster_name)
REGION=$(terraform -chdir="$TF_DIR" output -raw aws_region)
ROLE_ARN=$(terraform -chdir="$TF_DIR" output -raw petclinic_was_role_arn)
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"

helm repo add aws-secrets-manager https://aws.github.io/secrets-store-csi-driver-provider-aws --force-update
helm repo update aws-secrets-manager
helm upgrade --install secrets-provider-aws aws-secrets-manager/secrets-store-csi-driver-provider-aws \
  --namespace kube-system --set secrets-store-csi-driver.syncSecret.enabled=true \
  --wait --timeout 10m

kubectl apply -f "$TF_DIR/k8s-manifests/namespaces.yaml"
kubectl apply -f "$TF_DIR/k8s-manifests/was/service-account.yaml"
kubectl annotate serviceaccount petclinic-was -n was \
  "eks.amazonaws.com/role-arn=$ROLE_ARN" --overwrite
kubectl apply -f "$TF_DIR/k8s-manifests/was/secret-provider-class.yaml"
kubectl get crd secretproviderclasses.secrets-store.csi.x-k8s.io

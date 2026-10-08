#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(dirname "$SCRIPT_DIR")"
AKS_NAME=$(terraform -chdir="$TF_DIR" output -raw aks_cluster_name)
RESOURCE_GROUP=$(terraform -chdir="$TF_DIR" output -raw resource_group_name)
KEY_VAULT_NAME=$(terraform -chdir="$TF_DIR" output -raw petclinic_key_vault_name)
CSI_CLIENT_ID=$(terraform -chdir="$TF_DIR" output -raw key_vault_csi_client_id)
TENANT_ID=$(terraform -chdir="$TF_DIR" output -raw tenant_id)
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --overwrite-existing
kubectl apply -f "$TF_DIR/k8s-manifests/namespaces.yaml"
cat <<EOF | kubectl apply -f -
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: petclinic-db
  namespace: was
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "true"
    userAssignedIdentityID: "$CSI_CLIENT_ID"
    keyvaultName: "$KEY_VAULT_NAME"
    tenantId: "$TENANT_ID"
    objects: |
      array:
        - |
          objectName: petclinic-db-url
          objectType: secret
          objectAlias: db-url
        - |
          objectName: petclinic-db-username
          objectType: secret
          objectAlias: db-username
        - |
          objectName: petclinic-db-password
          objectType: secret
          objectAlias: db-password
  secretObjects:
    - secretName: db-credentials
      type: Opaque
      data:
        - objectName: db-url
          key: url
        - objectName: db-username
          key: username
        - objectName: db-password
          key: password
EOF
# Deploy Services before Nginx tries to resolve the WAS upstream.
kubectl apply -f "$TF_DIR/k8s-manifests/was/service.yaml"
kubectl apply -f "$TF_DIR/k8s-manifests/was/deployment.yaml"
kubectl apply -f "$TF_DIR/k8s-manifests/web/service.yaml"
kubectl apply -k "$TF_DIR/k8s-manifests"
kubectl rollout status deployment/was-spring -n was --timeout=600s
kubectl rollout status deployment/web-nginx -n web --timeout=300s
echo "Web/WAS 배포 완료. setup-ingress.sh를 실행해 App Gateway를 연결하세요."

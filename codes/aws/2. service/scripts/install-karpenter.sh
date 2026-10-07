#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(dirname "$SCRIPT_DIR")"
KARPENTER_VERSION=1.14.1
TEMPLATE_SHA256=7ffeb01f04b5da482ef43087830de00a476098416e3b4576c38239ef1b0bef4b
for tool in terraform aws kubectl helm curl jq shasum; do
  command -v "$tool" >/dev/null || { echo "Missing: $tool" >&2; exit 1; }
done

CLUSTER_NAME=$(terraform -chdir="$TF_DIR" output -raw eks_cluster_name)
REGION=$(terraform -chdir="$TF_DIR" output -raw aws_region)
ACCOUNT_ID=$(terraform -chdir="$TF_DIR" output -raw aws_account_id)
ROLE_NAME="${CLUSTER_NAME}-karpenter"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
NODE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
AUTH_MODE=$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER_NAME" --query cluster.accessConfig.authenticationMode --output text)
[[ "$AUTH_MODE" == API_AND_CONFIG_MAP || "$AUTH_MODE" == API ]] || {
  echo "EKS authentication_mode must allow API access entries. Apply Terraform first." >&2
  exit 1
}

curl -fsSL "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" \
  -o "$WORK_DIR/karpenter.yaml"
echo "$TEMPLATE_SHA256  $WORK_DIR/karpenter.yaml" | shasum -a 256 -c -
aws cloudformation deploy --region "$REGION" --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file "$WORK_DIR/karpenter.yaml" --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}"

OIDC_PROVIDER=$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER_NAME" --query cluster.identity.oidc.issuer --output text)
OIDC_PROVIDER=${OIDC_PROVIDER#https://}
jq -n --arg oidc "$OIDC_PROVIDER" --arg account "$ACCOUNT_ID" '{
  Version: "2012-10-17", Statement: [{Effect: "Allow",
  Principal: {Federated: ("arn:aws:iam::" + $account + ":oidc-provider/" + $oidc)},
  Action: "sts:AssumeRoleWithWebIdentity", Condition: {StringEquals: {
    ($oidc + ":aud"): "sts.amazonaws.com",
    ($oidc + ":sub"): "system:serviceaccount:kube-system:karpenter"
  }}}]}' > "$WORK_DIR/trust.json"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "file://$WORK_DIR/trust.json"
else
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "file://$WORK_DIR/trust.json" >/dev/null
fi
for policy in NodeLifecycle IAMIntegration EKSIntegration Interruption ResourceDiscovery ZonalShift; do
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/KarpenterController${policy}Policy-${CLUSTER_NAME}"
done

if ! aws eks describe-access-entry --region "$REGION" --cluster-name "$CLUSTER_NAME" \
  --principal-arn "$NODE_ROLE_ARN" >/dev/null 2>&1; then
  aws eks create-access-entry --region "$REGION" --cluster-name "$CLUSTER_NAME" \
    --principal-arn "$NODE_ROLE_ARN" --type EC2_LINUX >/dev/null
fi

kubectl create serviceaccount karpenter -n kube-system --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount karpenter -n kube-system "eks.amazonaws.com/role-arn=$ROLE_ARN" --overwrite
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "$KARPENTER_VERSION" --namespace kube-system \
  --set serviceAccount.create=false --set serviceAccount.name=karpenter \
  --set "settings.clusterName=$CLUSTER_NAME" --set "settings.interruptionQueue=$CLUSTER_NAME" \
  --wait --timeout 10m
kubectl rollout status deployment/karpenter -n kube-system --timeout=300s

sed "s/CLUSTER_NAME_PLACEHOLDER/$CLUSTER_NAME/g" "$TF_DIR/k8s-manifests/karpenter/nodepool.yaml" | kubectl apply -f -
kubectl get nodepool,ec2nodeclass

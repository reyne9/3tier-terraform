#!/usr/bin/env bash
# Verify the intended GitOps revision before testing the public request path.
set -euo pipefail
for tool in curl jq; do
  command -v "$tool" >/dev/null || { echo "Missing: $tool" >&2; exit 1; }
done
: "${ARGOCD_SERVER:?Set ARGOCD_SERVER (HTTPS URL)}"
: "${ARGOCD_TOKEN:?Set a read-only Argo CD application token}"
: "${ARGOCD_APP:?Set ARGOCD_APP}"
: "${GITOPS_REVISION:?Set the manifest commit SHA}"
: "${REGISTRY_USER:?Set REGISTRY_USER}"
: "${IMAGE_TAG:?Set the image commit SHA}"
: "${APP_URL:?Set APP_URL}"
[[ "$ARGOCD_SERVER" == https://* && "$APP_URL" == https://* ]] || {
  echo 'Argo CD and application URLs must use HTTPS.' >&2; exit 1;
}
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
chmod 700 "$WORK_DIR"
# Keep the token out of command arguments and logs.
umask 077
printf 'Authorization: Bearer %s\n' "$ARGOCD_TOKEN" > "$WORK_DIR/auth.header"
for attempt in $(seq 1 30); do
  if curl --fail --silent --show-error --max-time 15 \
    --header "@$WORK_DIR/auth.header" \
    "${ARGOCD_SERVER%/}/api/v1/applications/${ARGOCD_APP}?refresh=normal" > "$WORK_DIR/app.json"; then
    if jq -e --arg revision "$GITOPS_REVISION" \
      --arg web "$REGISTRY_USER/petclinic-web:$IMAGE_TAG" \
      --arg was "$REGISTRY_USER/petclinic-was:$IMAGE_TAG" '
      .status.sync.status == "Synced" and
      .status.sync.revision == $revision and
      .status.health.status == "Healthy" and
      ((.status.summary.images // []) | index($web) != null and index($was) != null)
    ' "$WORK_DIR/app.json" >/dev/null; then
      curl --fail --silent --show-error --max-time 15 "${APP_URL%/}/vets.html" >/dev/null
      echo "Verified GitOps revision $GITOPS_REVISION and images $IMAGE_TAG."
      exit 0
    fi
  fi
  sleep 20
done
echo 'Expected GitOps revision/images did not become Synced and Healthy.' >&2
exit 1

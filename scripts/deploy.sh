#!/usr/bin/env bash
# One-shot deployment: runs every step from README.md in order.
#   1. CFK operator   2. certificates   3. secrets   4. render manifests
#   5. Confluent Platform   6. rolebindings + demo topic   7. Gateway
# Re-running is safe; existing certificates are kept.
source "$(dirname "$0")/lib.sh"
require_tools kubectl helm openssl keytool envsubst
load_config
SCRIPTS="$ROOT_DIR/scripts"

info "1/7 Confluent for Kubernetes operator"
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"
helm repo add confluentinc https://packages.confluent.io/helm >/dev/null 2>&1 || true
helm repo update confluentinc >/dev/null
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes -n "$NAMESPACE" --wait

info "2/7 Certificates"
if [[ -f "$CERT_DIR/ca.pem" ]]; then
  info "Reusing existing certificates in $CERT_DIR"
else
  "$SCRIPTS/generate-certs.sh"
fi

info "3/7 Secrets"
"$SCRIPTS/create-secrets.sh"

info "4/7 Render manifests"
"$SCRIPTS/render.sh"

info "5/7 Confluent Platform (takes ~10 minutes)"
kubectl apply -f "$MANIFEST_DIR/confluent-platform.yaml"
for cr in kraftcontroller/kraftcontroller kafka/kafka; do
  info "Waiting for $cr ..."
  kubectl wait "$cr" -n "$NAMESPACE" --for=jsonpath='{.status.phase}'=RUNNING --timeout=20m
done

info "6/7 Rolebindings and demo topic"
kubectl apply -f "$MANIFEST_DIR/rbac/operator-rolebinding.yaml" \
              -f "$MANIFEST_DIR/rbac/sso-admin-rolebinding.yaml" \
              -f "$MANIFEST_DIR/rbac/gateway-client-rolebindings.yaml"
kubectl apply -f "$MANIFEST_DIR/topic.yaml"

info "Waiting for controlcenter ..."
kubectl wait controlcenter/controlcenter -n "$NAMESPACE" --for=jsonpath='{.status.phase}'=RUNNING --timeout=20m

info "7/7 Gateway"
kubectl apply -f "$MANIFEST_DIR/gateway.yaml"
kubectl wait gateway/confluent-gateway -n "$NAMESPACE" --for=jsonpath='{.status.phase}'=RUNNING --timeout=10m

info "Deployment complete."
cat <<EOF

  Test the gateway end to end:   ./scripts/test-gateway.sh
  Open Control Center:           kubectl port-forward controlcenter-0 9021:9021 -n $NAMESPACE
                                 then browse to https://localhost:9021 and "Log in via SSO"
EOF

#!/usr/bin/env bash
# Creates (or updates) every Kubernetes secret the manifests reference.
# Safe to re-run, e.g. after rotating a client secret in config.env.
source "$(dirname "$0")/lib.sh"
require_tools kubectl
load_config

[[ -f "$CERT_DIR/ca.pem" ]] || die "No certificates found. Run scripts/generate-certs.sh first."
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

# ---- TLS: one secret per component, all signed by the same CA ----------------
for pair in tls-kafka:kafka tls-controlcenter:controlcenter gateway-tls:gateway; do
  secret=${pair%%:*} name=${pair#*:}
  apply_secret "$secret" \
    --from-file=fullchain.pem="$CERT_DIR/$name-fullchain.pem" \
    --from-file=privkey.pem="$CERT_DIR/$name-key.pem" \
    --from-file=cacerts.pem="$CERT_DIR/ca.pem"
done

# ---- MDS token signing keys --------------------------------------------------
apply_secret mds-token \
  --from-file=mdsTokenKeyPair.pem="$CERT_DIR/mds-tokenkeypair.pem" \
  --from-file=mdsPublicKey.pem="$CERT_DIR/mds-publickey.pem"

# ---- OAuth / OIDC client credentials -----------------------------------------
# Values go through process substitution so they never appear in `ps`.
# Service client: brokers, MDS, operator.
apply_secret oauth-credentials \
  --from-file=oauth.txt=<(printf 'clientId=%s\nclientSecret=%s\n' "$OAUTH_CLIENT_ID" "$OAUTH_CLIENT_SECRET")

# SSO client: Control Center login.
apply_secret oidccredential \
  --from-file=oidcClientSecret.txt=<(printf 'clientId=%s\nclientSecret=%s\n' "$OIDC_CLIENT_ID" "$OIDC_CLIENT_SECRET")

# ---- Gateway auth swap ---------------------------------------------------------
# Maps the client-certificate principal to "<clientId><separator><clientSecret>".
apply_secret file-store-config --from-literal=separator=/
apply_secret file-store-client-credentials \
  --from-file="$GATEWAY_CLIENT_CN"=<(printf '%s/%s' "$GATEWAY_SWAP_CLIENT_ID" "$GATEWAY_SWAP_CLIENT_SECRET")

# JAAS template: the gateway fills the two %s with the swapped clientId/secret.
apply_secret gateway-oauth-jaas \
  --from-literal=oauth-jaas.conf='org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required clientId="%s" clientSecret="%s";'

info "All secrets are in namespace '$NAMESPACE'."

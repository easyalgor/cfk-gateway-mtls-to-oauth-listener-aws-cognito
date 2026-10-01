#!/usr/bin/env bash
# Removes everything this example deployed, in dependency order.
#
# Usage: ./scripts/teardown.sh          # remove the platform, gateway and secrets
#        ./scripts/teardown.sh --all    # also uninstall the operator and delete
#                                       # the namespace (including data volumes)
source "$(dirname "$0")/lib.sh"
require_tools kubectl

echo "This deletes the Confluent Platform, Gateway and secrets in namespace '$NAMESPACE'."
[[ "${1:-}" == "--all" ]] && echo "It also uninstalls the CFK operator and deletes the namespace and its volumes."
read -r -p "Continue? [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || exit 0

ns() { kubectl -n "$NAMESPACE" "$@"; }

info "Test client"
ns delete pod/kafka-client secret/kafka-client-certs --ignore-not-found

info "Gateway"
ns delete gateway confluent-gateway --ignore-not-found

# Topics and rolebindings are removed through Kafka's REST API, so they must go
# before the brokers do -- otherwise their finalizers block forever.
info "Topics and rolebindings"
ns delete kafkatopic --all
ns delete confluentrolebinding --all

info "Confluent Platform"
ns delete controlcenter,kafka,kraftcontroller,kafkarestclass --all
ns wait pod -l confluent-platform=true --for=delete --timeout=10m || true

info "Secrets"
ns delete secret --ignore-not-found \
  tls-kafka tls-controlcenter gateway-tls mds-token \
  oauth-credentials oidccredential \
  file-store-config file-store-client-credentials gateway-oauth-jaas

if [[ "${1:-}" == "--all" ]]; then
  info "Operator and namespace"
  helm uninstall confluent-operator -n "$NAMESPACE" || true
  kubectl delete namespace "$NAMESPACE"
fi

info "Teardown complete. Local files in generated/ were kept."

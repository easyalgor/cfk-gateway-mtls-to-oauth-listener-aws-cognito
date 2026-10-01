#!/usr/bin/env bash
# End-to-end test of the mTLS -> OAuth swap, run from inside the cluster so it
# needs no DNS, LoadBalancer or local Kafka tools.
#
# Starts a throwaway `kafka-client` pod that holds the demo client certificate
# (CN=$GATEWAY_CLIENT_CN) and resolves $GATEWAY_DOMAIN to the gateway service.
# It then produces 5 messages to demo-topic through the gateway and reads them back.
#
# Usage: ./scripts/test-gateway.sh           # run the test
#        ./scripts/test-gateway.sh --cleanup  # delete the test pod and secret
source "$(dirname "$0")/lib.sh"
require_tools kubectl
load_config

if [[ "${1:-}" == "--cleanup" ]]; then
  kubectl delete pod/kafka-client secret/kafka-client-certs -n "$NAMESPACE" --ignore-not-found
  exit 0
fi

GATEWAY_IP=$(kubectl get svc confluent-gateway -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
[[ -n "$GATEWAY_IP" ]] || die "Service confluent-gateway not found. Is the gateway deployed?"

info "Creating the kafka-client pod ($GATEWAY_DOMAIN -> $GATEWAY_IP)"
apply_secret kafka-client-certs \
  --from-file=client-keystore.jks="$CERT_DIR/client-keystore.jks" \
  --from-file=client-truststore.jks="$CERT_DIR/client-truststore.jks" \
  --from-file=client.properties=<(CLIENT_CERT_DIR=/etc/kafka-client envsubst \
      '${CLIENT_CERT_DIR} ${CLIENT_STORE_PASSWORD} ${GATEWAY_CLIENT_CN}' \
      < "$ROOT_DIR/client/client.properties.template")

kubectl apply -n "$NAMESPACE" -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kafka-client
spec:
  # Port-based routing: the gateway advertises $GATEWAY_DOMAIN:9596-9598 for
  # the brokers, so that name has to resolve to the gateway from inside the pod.
  hostAliases:
    - ip: "$GATEWAY_IP"
      hostnames: ["$GATEWAY_DOMAIN"]
  containers:
    - name: kafka-client
      image: confluentinc/cp-server:8.2.1
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: certs
          mountPath: /etc/kafka-client
          readOnly: true
  volumes:
    - name: certs
      secret:
        secretName: kafka-client-certs
EOF
kubectl wait pod/kafka-client -n "$NAMESPACE" --for=condition=Ready --timeout=5m >/dev/null

BOOTSTRAP="$GATEWAY_DOMAIN:9595"
CONFIG=/etc/kafka-client/client.properties
MESSAGE_PREFIX="hello-from-$GATEWAY_CLIENT_CN-$(date +%s)"

info "Producing 5 messages to demo-topic via $BOOTSTRAP"
kubectl exec -n "$NAMESPACE" kafka-client -- bash -c \
  "seq 1 5 | sed 's/^/$MESSAGE_PREFIX-/' | kafka-console-producer \
     --bootstrap-server $BOOTSTRAP --producer.config $CONFIG --topic demo-topic"

info "Consuming them back"
kubectl exec -n "$NAMESPACE" kafka-client -- kafka-console-consumer \
  --bootstrap-server "$BOOTSTRAP" --consumer.config "$CONFIG" \
  --topic demo-topic --group demo-test-consumer --from-beginning \
  --max-messages 5 --timeout-ms 60000

info "Success: CN=$GATEWAY_CLIENT_CN reached Kafka as User:$GATEWAY_SWAP_CLIENT_ID through the gateway."
info "Remove the test pod with: ./scripts/test-gateway.sh --cleanup"

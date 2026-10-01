#!/usr/bin/env bash
# Generates a self-signed test CA and every certificate/key this example needs:
#
#   ca.pem / ca-key.pem              test certificate authority (trusted by everything)
#   kafka.pem / kafka-key.pem        brokers + KRaft controllers   (CN=kafka)
#   controlcenter.pem / -key.pem     Control Center                (CN=c3)
#   gateway.pem / gateway-key.pem    Confluent Gateway             (CN=$GATEWAY_DOMAIN)
#   client.pem / client-key.pem      demo application              (CN=$GATEWAY_CLIENT_CN)
#   client-keystore.jks / client-truststore.jks   the same, for Java clients
#   mds-tokenkeypair.pem / mds-publickey.pem      MDS token signing keys
#
# Output: generated/certs/. For production, use certificates from your own PKI
# with the same CNs and SANs.
source "$(dirname "$0")/lib.sh"
require_tools openssl keytool
load_config

[[ -e "$CERT_DIR/ca.pem" ]] && die "$CERT_DIR already has a CA. Delete the directory to regenerate."
mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

SUBJ_BASE="/C=US/ST=Pangea/L=Earth"
DAYS=825

info "Certificate authority"
openssl req -x509 -new -nodes -newkey rsa:2048 -sha256 -days "$DAYS" \
  -keyout ca-key.pem -out ca.pem -subj "$SUBJ_BASE/CN=TestCA" 2>/dev/null

# issue <name> <CN> <comma-separated SANs>
# The DN order (C, ST, L, CN) matters: MDS impersonation admins in
# confluent-platform.yaml list the full DN "CN=kafka,L=Earth,ST=Pangea,C=US".
issue() {
  local name=$1 cn=$2 sans=$3
  info "$name (CN=$cn)"
  openssl req -new -nodes -newkey rsa:2048 -keyout "$name-key.pem" -out "$name.csr" \
    -subj "$SUBJ_BASE/CN=$cn" 2>/dev/null
  openssl x509 -req -in "$name.csr" -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
    -out "$name.pem" -days "$DAYS" -sha256 -extfile <(cat <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=$sans
EOF
) 2>/dev/null
  cat "$name.pem" ca.pem > "$name-fullchain.pem"
  rm "$name.csr"
}

issue kafka kafka "DNS:kafka,\
DNS:kafka.confluent.svc.cluster.local,DNS:*.kafka.confluent.svc.cluster.local,\
DNS:kraftcontroller.confluent.svc.cluster.local,DNS:*.kraftcontroller.confluent.svc.cluster.local,\
DNS:*.$EXTERNAL_DOMAIN"

issue controlcenter c3 "DNS:c3,DNS:controlcenter,\
DNS:controlcenter.confluent.svc.cluster.local,DNS:*.controlcenter.confluent.svc.cluster.local,\
DNS:controlcenter.$EXTERNAL_DOMAIN,DNS:localhost,IP:127.0.0.1"

issue gateway "$GATEWAY_DOMAIN" "DNS:$GATEWAY_DOMAIN,DNS:*.$GATEWAY_DOMAIN,\
DNS:confluent-gateway.confluent.svc.cluster.local,DNS:localhost,IP:127.0.0.1"

issue client "$GATEWAY_CLIENT_CN" "DNS:$GATEWAY_CLIENT_CN"

info "Java keystore/truststore for the demo client"
openssl pkcs12 -export -in client.pem -inkey client-key.pem -certfile ca.pem \
  -name client -out client-keystore.p12 -passout "pass:$CLIENT_STORE_PASSWORD"
keytool -importkeystore -noprompt \
  -srckeystore client-keystore.p12 -srcstoretype PKCS12 -srcstorepass "$CLIENT_STORE_PASSWORD" \
  -destkeystore client-keystore.jks -deststoretype JKS -deststorepass "$CLIENT_STORE_PASSWORD" 2>/dev/null
keytool -importcert -noprompt -alias CARoot -file ca.pem \
  -keystore client-truststore.jks -storepass "$CLIENT_STORE_PASSWORD" >/dev/null 2>&1

info "MDS token key pair"
# MDS expects a PKCS#1 ("BEGIN RSA PRIVATE KEY") key. OpenSSL 3 needs
# -traditional for that; LibreSSL (macOS /usr/bin/openssl) does it by default.
openssl genrsa -traditional -out mds-tokenkeypair.pem 2048 2>/dev/null \
  || openssl genrsa -out mds-tokenkeypair.pem 2048 2>/dev/null
openssl rsa -in mds-tokenkeypair.pem -pubout -out mds-publickey.pem 2>/dev/null

rm -f ca.srl
info "Done. Files are in $CERT_DIR"

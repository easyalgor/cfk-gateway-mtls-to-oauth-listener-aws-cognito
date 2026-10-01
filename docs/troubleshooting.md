# Troubleshooting

Each entry below is a problem that came up while building this setup, with the
cause and the fix. Most of the fixes are already in the manifests. This page
explains why they are there.

## Useful commands

```bash
kubectl get pods,kafka,kraftcontroller,controlcenter,gateway -n confluent
kubectl get confluentrolebinding,kafkatopic -n confluent
kubectl describe kafkatopic demo-topic -n confluent          # status/events for a CR
kubectl logs kafka-0 -n confluent | grep -i -E "error|denied|oauth"
kubectl logs -l app=confluent-gateway -n confluent --tail=100
kubectl logs deploy/confluent-operator -n confluent --tail=100
```

## KafkaTopic stuck: `Authorization failed. (40301)`

The CFK operator creates topics through the Kafka REST API hosted by MDS, as
`User:<OAUTH_CLIENT_ID>`. Being in `superUsers` only covers native Kafka
requests; the REST layer checks RBAC. Apply
`generated/manifests/rbac/operator-rolebinding.yaml` (`deploy.sh` does this).

## Rolebindings fail: `kafkarestclass default not found`

The operator needs a `KafkaRestClass` named `default` to manage rolebindings
and topics. It is the last document in `confluent-platform.yaml`.

## Control Center: every SSO user sees every topic

Two settings are needed for Control Center to act *as the logged-in user*:

- `User:c3` in `spec.services.mds.impersonation.admins` on the Kafka CR.
- The `configOverrides` on the ControlCenter CR that point C3's Kafka client
  at the TOKENSASL listener (9075) with `TokenCertificateLoginCallbackHandler`.

Without them C3 talks to Kafka as `User:c3` (SystemAdmin) and RBAC filtering
never happens.

## Control Center: "Topic defaults not available" / create-topic greyed out

C3 asks MDS to impersonate the user, and the resulting token carries groups
only if MDS knows the groups claim. `groupsClaimName: cognito:groups` on the
MDS `oauth` provider handles that. If a group-based binding still doesn't
grant writes, add a per-user binding (like
`manifests/rbac/sso-admin-rolebinding.yaml`) keyed on the user's `sub`.

## SSO login: `redirect_mismatch`

The callback URL is not registered on the Cognito SSO app client. See
[aws-cognito-setup.md](aws-cognito-setup.md#callback-url-for-client-2).

## Rolebinding for a user has no effect

The principal must be the Cognito `sub` (a UUID), not the email or username.
Group principals must match the Cognito group name exactly (case-sensitive).

## Gateway client: `SSL handshake failed`

- The client truststore must contain the CA that signed the gateway certificate
  (`generated/certs/client-truststore.jks`).
- The host name the client connects to must be in the gateway certificate SANs
  (`GATEWAY_DOMAIN`, `*.GATEWAY_DOMAIN`, `localhost`).
- The client certificate must be signed by the CA in the `gateway-tls` secret.

## Gateway client connects, then `TOPIC_AUTHORIZATION_FAILED`

The mTLS and swap steps worked; RBAC is denying the swapped Cognito client.
Kafka sees `User:<GATEWAY_SWAP_CLIENT_ID>`. Check that
`gateway-client-rolebindings.yaml` was applied, that the topic starts with
`demo-`, and that consumers use a group starting with `demo-`.

## Gateway logs: principal not found in secret store

The certificate CN (after `principalMappingRules`) must be a key in the
`file-store-client-credentials` secret. The scripts use `GATEWAY_CLIENT_CN` for
both. If you issue more client certificates, add one key per CN:

```bash
kubectl create secret generic file-store-client-credentials -n confluent \
  --from-literal=alice="<clientId>/<clientSecret>" \
  --from-literal=bob="<otherClientId>/<otherClientSecret>" \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Gateway logs: OAuth URL not allowed

The gateway only calls OAuth endpoints listed in
`-Dorg.apache.kafka.sasl.oauthbearer.allowed.urls` (`GATEWAY_OPTS` in
`gateway.yaml`). It must contain the Cognito token URL exactly.

## LoadBalancer stays `<pending>`

This is a cluster problem, not a manifest problem. On EKS check the AWS Load
Balancer Controller logs and `kubectl describe svc <name> -n confluent`. An
error like `sts:AssumeRoleWithWebIdentity ... AccessDenied` means the
controller's IAM role (IRSA) is misconfigured. Everything in this example can
also be tested without LoadBalancers (`scripts/test-gateway.sh`,
`kubectl port-forward`).

## KRaft controllers crash-loop on authorization

The controllers run with RBAC. The `controller` listener uses mTLS so the quorum
authenticates as `User:kafka` (a super user), and the controller principal
builder is overridden to `OAuthKafkaPrincipalBuilder` in `configOverrides`.
Don't remove either.

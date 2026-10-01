# Confluent Gateway: client mTLS → dedicated Kafka OAuth listener (AWS Cognito)

A ready-to-run Confluent for Kubernetes (CFK) example where applications
authenticate with **client certificates (mTLS)**. The **Confluent Gateway**
swaps each certificate identity for an **AWS Cognito OAuth token** and connects
to a **dedicated OAuth listener** on the Kafka brokers that serves only the
gateway. Kafka then authorizes every request with **RBAC**.

The same deployment also gives you:

- **Control Center (Next Gen)** with **Cognito single sign-on** and per-user RBAC
- **TLS everywhere**, with **mTLS** between Confluent components
- **MDS** (RBAC) for component certificates, Cognito OAuth tokens and Cognito SSO
- A direct **OAuth + mTLS** external listener for clients that don't use the gateway

## Architecture

```
                         ┌──────────────────────── Kubernetes namespace: confluent ────────────────────────┐
                         │                                                                                  │
  Application            │   Confluent Gateway                       Kafka brokers (kafka-0..2)             │
  (cert CN=alice) ──mTLS─┼─▶ 9595-9598  ──── SASL_SSL/OAUTHBEARER ──▶ 9096  "gateway" listener (OAuth)     │
                         │   │  1. verify client cert                9092  external listener (OAuth+mTLS) ◀─┼── direct clients
                         │   │  2. CN "alice" → Cognito client ID    9071  internal listener (mTLS)         │
                         │   │  3. fetch token from Cognito          9075  token listener (C3 per-user)     │
                         │   ▼                                       8090  MDS / REST (RBAC)                │
                         │   AWS Cognito  ◀─── validate tokens (JWKS) ───┘          ▲                       │
                         │        ▲                                                 │ mTLS                  │
                         │        └──── SSO login ──── Control Center ──────────────┘                       │
                         │                                    KRaft controllers (mTLS)                      │
                         └──────────────────────────────────────────────────────────────────────────────────┘
```

**How a gateway request flows**

1. The application connects to the gateway with a certificate signed by the
   example CA, e.g. `CN=alice`. It has no Cognito credentials.
2. The gateway validates the certificate and maps the CN to the principal `alice`.
3. It looks `alice` up in the `file-store-client-credentials` secret and finds
   a Cognito app client (`<clientId>/<clientSecret>`).
4. It gets an access token for that client from Cognito (`client_credentials`).
5. It connects to the brokers' **dedicated `gateway` listener (port 9096)**
   with SASL/OAUTHBEARER.
6. Kafka validates the token against Cognito's JWKS and authorizes the request
   as `User:<Cognito client ID>` using RBAC rolebindings.

**Why a dedicated listener for the gateway?** Port 9096 is OAuth-only (the
gateway already did the client mTLS) and has no external access. The brokers
advertise their in-cluster names on it
(`kafka-N.kafka.confluent.svc.cluster.local`), which the gateway pods can
resolve and verify against the broker certificate. Gateway traffic is also kept
apart from the internal (component) and external (direct client) listeners.

## Repository layout

```
.
├── config.env.example          # the only file you edit (copy to config.env)
├── manifests/                  # templates; ${VARS} are filled from config.env
│   ├── confluent-platform.yaml #   KRaft, Kafka (incl. gateway listener), Control Center, KafkaRestClass
│   ├── gateway.yaml            #   Confluent Gateway: mTLS → OAuth auth swap route
│   ├── topic.yaml              #   demo topic: demo-topic
│   └── rbac/                   #   rolebindings: operator, SSO admin, gateway client, group examples
├── client/
│   └── client.properties.template
├── scripts/
│   ├── deploy.sh               # runs every step below in order
│   ├── generate-certs.sh       # test CA, component/gateway/client certificates, MDS keys
│   ├── create-secrets.sh       # all Kubernetes secrets
│   ├── render.sh               # templates → generated/manifests
│   ├── test-gateway.sh         # in-cluster produce/consume through the gateway
│   └── teardown.sh
├── docs/
│   ├── aws-cognito-setup.md    # user pool, resource server, 3 app clients, users
│   └── troubleshooting.md
└── generated/                  # created by the scripts, git-ignored (certs, keys, rendered YAML)
```

## Prerequisites

| Tool | Used for |
|---|---|
| A Kubernetes cluster (EKS, GKE, AKS, ...) with a default-capable StorageClass | running the platform (~6 vCPU / 24 GB free) |
| `kubectl`, `helm` 3 | deploying |
| `openssl`, `keytool` (any JDK) | generating certificates and keystores |
| `envsubst` (`brew install gettext` / `apt install gettext-base`) | rendering templates |
| An AWS account with Cognito | identity provider |

Versions used: CFK 3.2+, Confluent Platform 8.2.1, Control Center Next Gen
2.5.0, Confluent Gateway 1.0.0.

## Quick start

```bash
# 1. Configure Cognito (one-time): user pool, domain, resource server,
#    3 app clients, a user. Follow docs/aws-cognito-setup.md.

# 2. Fill in your values
cp config.env.example config.env
vi config.env

# 3. Point kubectl at your cluster, then deploy everything (~15 minutes)
./scripts/deploy.sh

# 4. Prove the mTLS → OAuth swap works end to end
./scripts/test-gateway.sh
```

`test-gateway.sh` starts a throwaway client pod holding the `CN=alice`
certificate, produces 5 messages to `demo-topic` through the gateway, and
consumes them back. No DNS, LoadBalancer or local Kafka install is needed.

## Step by step

`deploy.sh` runs these steps. Run them one at a time to see what each does.

### 1. Install the CFK operator

```bash
kubectl create namespace confluent
helm repo add confluentinc https://packages.confluent.io/helm && helm repo update
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes -n confluent
```

### 2. Generate certificates

```bash
./scripts/generate-certs.sh
```

This creates one test CA in `generated/certs/` and signs every certificate with it:

| Certificate | CN | Used by |
|---|---|---|
| `kafka` | `kafka` | brokers and KRaft controllers (`tls-kafka`); also the gateway's truststore for 9096 |
| `controlcenter` | `c3` | Control Center (`tls-controlcenter`) |
| `gateway` | `$GATEWAY_DOMAIN` | gateway server certificate (`gateway-tls`) |
| `client` | `$GATEWAY_CLIENT_CN` | the demo application (`client-keystore.jks`) |

The CN is the principal: `CN=kafka` → `User:kafka` (a super user),
`CN=c3` → `User:c3`, `CN=alice` → the key the gateway looks up for the swap.
For production, issue certificates from your own PKI with the same CNs and SANs
(see `generate-certs.sh` for the SAN list).

### 3. Create secrets

```bash
./scripts/create-secrets.sh
```

| Secret | Contents | Used by |
|---|---|---|
| `tls-kafka`, `tls-controlcenter`, `gateway-tls` | `fullchain.pem`, `privkey.pem`, `cacerts.pem` | component TLS |
| `mds-token` | MDS token signing key pair | MDS, Control Center |
| `oauth-credentials` | `oauth.txt`: Cognito service client (app client 1) | brokers, MDS, operator |
| `oidccredential` | `oidcClientSecret.txt`: Cognito SSO client (app client 2) | Control Center SSO |
| `file-store-client-credentials` | `<CN>` → `<swap clientId>/<secret>` (app client 3) | gateway swap lookup |
| `file-store-config` | `separator=/` | gateway swap lookup |
| `gateway-oauth-jaas` | JAAS template with `%s` placeholders | gateway → Kafka login |

### 4. Render the manifests

```bash
./scripts/render.sh       # writes generated/manifests/ and generated/client/
```

### 5. Deploy Confluent Platform

```bash
kubectl apply -f generated/manifests/confluent-platform.yaml
kubectl get pods -n confluent -w      # wait for kraftcontroller-*, kafka-*, controlcenter-0
```

### 6. Rolebindings and demo topic

```bash
kubectl apply -f generated/manifests/rbac/operator-rolebinding.yaml \
              -f generated/manifests/rbac/sso-admin-rolebinding.yaml \
              -f generated/manifests/rbac/gateway-client-rolebindings.yaml
kubectl apply -f generated/manifests/topic.yaml
kubectl get confluentrolebinding,kafkatopic -n confluent   # all should be CREATED
```

| Rolebinding | Principal | Grants |
|---|---|---|
| `operator-rolebinding` | `User:<OAUTH_CLIENT_ID>` | SystemAdmin, so the operator can create topics |
| `sso-admin-rolebinding` | `User:<SSO_ADMIN_SUB>` | SystemAdmin in Control Center |
| `gateway-client-rolebindings` | `User:<GATEWAY_SWAP_CLIENT_ID>` | produce/consume `demo-*` topics, `demo-*` groups |
| `example-group-rolebindings` (optional) | Cognito groups | examples, edit before applying |

### 7. Deploy the gateway

```bash
kubectl apply -f generated/manifests/gateway.yaml
kubectl get gateway,pods -n confluent
```

## Validate

### Gateway (client mTLS → Cognito OAuth)

**Inside the cluster** (no setup needed):

```bash
./scripts/test-gateway.sh
```

**From your laptop** (needs the Kafka CLI tools and Java), using a port-forward:

```bash
source config.env
echo "127.0.0.1 $GATEWAY_DOMAIN" | sudo tee -a /etc/hosts
kubectl port-forward svc/confluent-gateway 9595 9596 9597 9598 -n confluent &

kafka-console-producer --bootstrap-server $GATEWAY_DOMAIN:9595 \
  --producer.config generated/client/client.properties --topic demo-topic

kafka-console-consumer --bootstrap-server $GATEWAY_DOMAIN:9595 \
  --consumer.config generated/client/client.properties \
  --topic demo-topic --group demo-laptop --from-beginning
```

All four ports must be forwarded: the gateway uses port-based routing and
advertises `$GATEWAY_DOMAIN:9596-9598` for the three brokers.

**Through the LoadBalancer**: point DNS for `$GATEWAY_DOMAIN` at the external
address of `svc/confluent-gateway-bootstrap-lb`, then use the same commands
without the port-forward.

### Control Center (Cognito SSO)

```bash
kubectl port-forward controlcenter-0 9021:9021 -n confluent
```

Open <https://localhost:9021> (accept the self-signed certificate), click
**Log in via SSO**, and sign in as the Cognito user whose `sub` you set as
`SSO_ADMIN_SUB`. You should see the cluster and `demo-topic`. Users without
rolebindings see nothing.

## Customizing

| Want to... | Do this |
|---|---|
| Map more client certificates | issue a cert per CN and add one key per CN to `file-store-client-credentials` (see [troubleshooting](docs/troubleshooting.md#gateway-logs-principal-not-found-in-secret-store)) |
| Give an app more access | add `ConfluentRolebinding`s for its Cognito client ID (`User:<client-id>`) |
| Give SSO users access by group | edit and apply `manifests/rbac/example-group-rolebindings.yaml` |
| Expose Control Center via LoadBalancer | uncomment `externalAccess` in the ControlCenter CR and add its callback URL in Cognito |
| Scale brokers | change `replicas` on the Kafka CR **and** widen `nodeIdRanges` in `gateway.yaml` |
| Change versions | edit the `image:` fields in the manifests |

After editing `config.env` or a template, re-run `./scripts/render.sh` (and
`./scripts/create-secrets.sh` if credentials changed), then re-apply.

## Tear down

```bash
./scripts/teardown.sh          # platform, gateway, secrets
./scripts/teardown.sh --all    # also the operator, namespace and data volumes
```

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md). It covers every issue
hit while building this setup (operator 40301 errors, Control Center showing
all topics, SSO redirect mismatch, gateway handshake and authorization
failures, pending LoadBalancers).

## Notes

- The test CA, certificates and keystore passwords are for evaluation only.
- `config.env` and `generated/` contain secrets and keys and are git-ignored.
  Keep it that way.
- Everything Cognito-specific (endpoint URLs, the `cognito:groups` and
  `client_id` claims) is derived in one place: `load_config` in
  `scripts/lib.sh`. To use another OIDC provider, change it there.

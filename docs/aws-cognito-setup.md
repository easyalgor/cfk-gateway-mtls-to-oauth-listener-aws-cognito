# AWS Cognito setup

This example needs one Cognito **user pool** with a **domain**, one **resource
server**, three **app clients** and at least one **user**. Every value you
collect here goes into `config.env`.

> Console labels change from time to time; the names below match the current
> Cognito console ("User pools" → your pool).

## 1. User pool and domain

1. Create a user pool (or reuse one). Note the **region** and **User pool ID**
   (e.g. `us-east-2_AbCdEf123`).
   → `COGNITO_REGION`, `COGNITO_USER_POOL_ID`
2. **Branding → Domain**: create a Cognito domain (or a custom domain).
   Note the host name, e.g. `my-prefix.auth.us-east-2.amazoncognito.com`.
   → `COGNITO_DOMAIN` (host name only, no `https://`)

From these the scripts derive:

| Endpoint | Value |
|---|---|
| Issuer | `https://cognito-idp.<region>.amazonaws.com/<user-pool-id>` |
| JWKS | `<issuer>/.well-known/jwks.json` |
| Token | `https://<cognito-domain>/oauth2/token` |
| Authorize | `https://<cognito-domain>/oauth2/authorize` |

## 2. Resource server (custom scope)

`client_credentials` app clients in Cognito need at least one custom scope.

1. **Branding → Domain → Resource servers → Create resource server**
   - Identifier: `cp-resource`
   - Custom scope: `cp-resource-access`
2. The full scope is `cp-resource/cp-resource-access`.
   → `COGNITO_SCOPE`

## 3. App clients

Create three **confidential** app clients (**Applications → App clients →
Create app client → Machine-to-machine / Traditional web application**, with a
client secret). Cognito does not allow `client_credentials` and the
authorization-code flow on the same client, so the Control Center SSO client is
separate.

| # | Suggested name | OAuth grant | Scopes | config.env |
|---|---|---|---|---|
| 1 | `confluent-service` | Client credentials | `cp-resource/cp-resource-access` | `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET` |
| 2 | `control-center-sso` | Authorization code | `openid`, `email`, `profile` | `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` |
| 3 | `gateway-swap` | Client credentials | `cp-resource/cp-resource-access` | `GATEWAY_SWAP_CLIENT_ID`, `GATEWAY_SWAP_CLIENT_SECRET` |

- **Client 1** is what the brokers, MDS and the CFK operator use. It is a
  Kafka super user.
- **Client 3** is the identity Kafka sees for applications that connect through
  the gateway with a client certificate. It only gets the permissions in
  `manifests/rbac/gateway-client-rolebindings.yaml`. You can reuse client 1 for
  a quick test.
- With a `client_credentials` token, Kafka's principal is the app client ID
  (taken from the `client_id` claim): `User:<client-id>`.

### Callback URL for client 2

Under client 2 → **Login pages → Managed login pages configuration**, add the
Control Center callback URL:

```
https://localhost:9021/api/metadata/security/1.0/oidc/authorization-code/callback
```

That is the URL when you use `kubectl port-forward` (the default in this
example). If you expose Control Center through a LoadBalancer or another host,
add `https://<that-host>/api/metadata/security/1.0/oidc/authorization-code/callback`
as well. If login fails with `redirect_mismatch`, copy the `redirect_uri`
parameter from the browser's address bar and register exactly that.

## 4. Users and groups

1. **User management → Users → Create user.** Set a permanent password (or
   sign in once to change it).
2. Open the user and copy **User ID (Sub)**, a UUID.
   → `SSO_ADMIN_SUB`. That user becomes SystemAdmin in Control Center.
3. Optional: **Groups → Create group** (e.g. `kafka-admins`,
   `kafka-developers`) and add users. Group names arrive in the
   `cognito:groups` claim and are used by
   `manifests/rbac/example-group-rolebindings.yaml`.

## 5. Check that a client works (optional)

```bash
source config.env
curl -s -X POST "https://$COGNITO_DOMAIN/oauth2/token" \
  -u "$GATEWAY_SWAP_CLIENT_ID:$GATEWAY_SWAP_CLIENT_SECRET" \
  -d grant_type=client_credentials \
  -d scope="$COGNITO_SCOPE" | head -c 120; echo
```

An `access_token` in the response means the client, secret, domain and scope
are right. `invalid_client` means the ID/secret are wrong; `invalid_grant` or
`unauthorized_client` means client credentials is not enabled for that client.

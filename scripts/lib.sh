# Shared helpers. Sourced by the other scripts; not meant to be run directly.
set -Eeuo pipefail
trap 'printf "\033[1;31mERROR:\033[0m command failed (exit %s): %s\n" "$?" "$BASH_COMMAND" >&2' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN_DIR="$ROOT_DIR/generated"
CERT_DIR="$GEN_DIR/certs"
MANIFEST_DIR="$GEN_DIR/manifests"
NAMESPACE=confluent

# Every variable config.env must define.
REQUIRED_VARS=(
  STORAGE_CLASS
  COGNITO_REGION COGNITO_USER_POOL_ID COGNITO_DOMAIN COGNITO_SCOPE
  OAUTH_CLIENT_ID OAUTH_CLIENT_SECRET
  OIDC_CLIENT_ID OIDC_CLIENT_SECRET
  SSO_ADMIN_SUB
  GATEWAY_DOMAIN GATEWAY_CLIENT_CN GATEWAY_SWAP_CLIENT_ID GATEWAY_SWAP_CLIENT_SECRET
  EXTERNAL_DOMAIN
  CLIENT_STORE_PASSWORD
)

# Cognito endpoints and claims, derived from config.env by load_config.
DERIVED_VARS=(
  OAUTH_ISSUER OAUTH_JWKS_URI OAUTH_TOKEN_URI OIDC_AUTHORIZE_URI
  OAUTH_GROUPS_CLAIM OAUTH_SUB_CLAIM
)

# render.sh substitutes exactly these in the templates.
CONFIG_VARS=("${REQUIRED_VARS[@]}" "${DERIVED_VARS[@]}")

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' is not installed. See README.md#prerequisites."
  done
}

# Loads config.env, exports its values and fails on anything missing or still
# holding a <placeholder>.
load_config() {
  local file="$ROOT_DIR/config.env" var missing=()
  [[ -f "$file" ]] || die "config.env not found. Run: cp config.env.example config.env  (then edit it)"
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
  for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" || "${!var}" == *"<"*">"* ]]; then
      missing+=("$var")
    fi
  done
  (( ${#missing[@]} == 0 )) || die "Set these in config.env: ${missing[*]}"

  export OAUTH_ISSUER="https://cognito-idp.$COGNITO_REGION.amazonaws.com/$COGNITO_USER_POOL_ID"
  export OAUTH_JWKS_URI="$OAUTH_ISSUER/.well-known/jwks.json"
  export OAUTH_TOKEN_URI="https://$COGNITO_DOMAIN/oauth2/token"
  export OIDC_AUTHORIZE_URI="https://$COGNITO_DOMAIN/oauth2/authorize"
  # Cognito puts a user's groups in `cognito:groups`, and the app client ID of a
  # client_credentials token in `client_id`.
  export OAUTH_GROUPS_CLAIM="cognito:groups"
  export OAUTH_SUB_CLAIM="client_id"
}

# Creates or updates a secret from `kubectl create secret` arguments.
apply_secret() {
  kubectl create secret generic "$@" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  info "secret/$1"
}

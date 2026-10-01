#!/usr/bin/env bash
# Fills the ${VARS} in manifests/ and client/ from config.env.
# Output: generated/manifests/ and generated/client/ -- apply those, not the templates.
source "$(dirname "$0")/lib.sh"
require_tools envsubst
load_config

# Only substitute our own variables, so `$1` in principal mapping rules survives.
SHELL_FORMAT="$(printf '${%s} ' "${CONFIG_VARS[@]}")"
export CLIENT_CERT_DIR="$CERT_DIR"

rm -rf "$MANIFEST_DIR" "$GEN_DIR/client"
(cd "$ROOT_DIR/manifests" && find . -name '*.yaml') | while read -r file; do
  mkdir -p "$(dirname "$MANIFEST_DIR/$file")"
  envsubst "$SHELL_FORMAT" < "$ROOT_DIR/manifests/$file" > "$MANIFEST_DIR/$file"
done

mkdir -p "$GEN_DIR/client"
envsubst "$SHELL_FORMAT \${CLIENT_CERT_DIR}" < "$ROOT_DIR/client/client.properties.template" \
  > "$GEN_DIR/client/client.properties"

info "Rendered manifests into $MANIFEST_DIR"
info "Rendered client config into $GEN_DIR/client/client.properties"

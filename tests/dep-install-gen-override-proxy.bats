#!/usr/bin/env bats

# gen-override.sh: the proxy and CA passthrough a service container needs when started from a
# proxied agent sandbox. The env entries are names only (compose passes one only when the invoking
# shell sets it), so they are unconditional; the CA bundle is mounted only when the host has one.

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/lib/checks"
SCRIPT="$SCRIPTS_DIR/gen-override.sh"

setup() {
  ROOT="$(mktemp -d)"
  git -C "$ROOT" init -q -b main
  cat > "$ROOT/docker-compose.yml" <<'YML'
services:
  app:
    build: .
    volumes:
      - .:/opt/app
  worker:
    build: .
YML
  ABSENT_CA="$ROOT/no-such-ca.crt"
}

teardown() {
  rm -rf "$ROOT"
}

# _env_of <override> <service> — the service's environment entries, one per line.
_env_of() {
  awk -v svc="  $2:" '
    $0 == svc { in_svc = 1; next }
    in_svc && /^  [^ ]/ { in_svc = 0 }
    in_svc && /^    environment:/ { in_env = 1; next }
    in_env && /^    [^ ]/ { in_env = 0 }
    in_svc && in_env { sub(/^      - /, ""); print }
  ' "$1"
}

# _volumes_of <override> <service> — the service's volume entries, one per line.
_volumes_of() {
  awk -v svc="  $2:" '
    $0 == svc { in_svc = 1; next }
    in_svc && /^  [^ ]/ { in_svc = 0 }
    in_svc && /^    volumes:/ { in_vol = 1; next }
    in_vol && /^    [^ ]/ { in_vol = 0 }
    in_svc && in_vol { sub(/^      - /, ""); print }
  ' "$1"
}

_generate() {
  CREW_CA_FILE="${1:-$ABSENT_CA}" bash "$SCRIPT" --project-root "$ROOT"
}

OVERRIDE() { echo "$ROOT/.git/crew-compose.override.yml"; }

@test "a node override passes the proxy, its CA variable, YARN_HTTPS_PROXY and NPM_TOKEN by name to every service" {
  echo '{"name":"f"}' > "$ROOT/package.json"
  run _generate
  [ "$status" -eq 0 ]
  for svc in app worker; do
    env="$(_env_of "$(OVERRIDE)" "$svc")"
    grep -qx 'HTTPS_PROXY' <<<"$env"
    grep -qx 'NODE_EXTRA_CA_CERTS' <<<"$env"
    grep -qxF 'YARN_HTTPS_PROXY=${HTTPS_PROXY}' <<<"$env"
    grep -qx 'NPM_TOKEN' <<<"$env"
  done
}

@test "a python override passes HTTPS_PROXY and REQUESTS_CA_BUNDLE by name" {
  touch "$ROOT/requirements.txt"
  run _generate
  [ "$status" -eq 0 ]
  for svc in app worker; do
    env="$(_env_of "$(OVERRIDE)" "$svc")"
    grep -qx 'HTTPS_PROXY' <<<"$env"
    grep -qx 'REQUESTS_CA_BUNDLE' <<<"$env"
  done
}

@test "go, rust, ruby and php overrides pass HTTPS_PROXY and SSL_CERT_FILE by name" {
  for manifest in go.mod Cargo.toml Gemfile composer.json; do
    rm -f "$ROOT"/go.mod "$ROOT"/Cargo.toml "$ROOT"/Gemfile "$ROOT"/composer.json
    touch "$ROOT/$manifest"
    run _generate
    [ "$status" -eq 0 ]
    env="$(_env_of "$(OVERRIDE)" app)"
    grep -qx 'HTTPS_PROXY' <<<"$env"
    grep -qx 'SSL_CERT_FILE' <<<"$env"
  done
}

@test "HTTPS_PROXY set in the invoking shell does not write its value into the override" {
  echo '{"name":"f"}' > "$ROOT/package.json"
  HTTPS_PROXY="http://proxy.invalid:3128" NODE_EXTRA_CA_CERTS="/secret/ca.pem" run _generate
  [ "$status" -eq 0 ]
  ! grep -q 'proxy.invalid' "$(OVERRIDE)"
  ! grep -q '/secret/ca.pem' "$(OVERRIDE)"
}

@test "with the CA file present, every service mounts it read-only and the summary says so" {
  echo '{"name":"f"}' > "$ROOT/package.json"
  ca="$ROOT/ca.crt"
  touch "$ca"
  run _generate "$ca"
  [ "$status" -eq 0 ]
  for svc in app worker; do
    _volumes_of "$(OVERRIDE)" "$svc" | grep -qxF "$ca:/etc/ssl/certs/ca-certificates.crt:ro"
  done
  [[ "$output" =~ proxy/CA:[[:space:]]+passed\ through ]]
}

@test "with the CA file absent, no service mentions ca-certificates and the summary has no proxy line" {
  echo '{"name":"f"}' > "$ROOT/package.json"
  run _generate
  [ "$status" -eq 0 ]
  ! grep -q 'ca-certificates' "$(OVERRIDE)"
  [[ "$output" != *"proxy/CA"* ]]
}

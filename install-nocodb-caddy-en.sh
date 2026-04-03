#!/usr/bin/env bash

set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed."
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose plugin is not installed."
  exit 1
fi

DEFAULT_INSTALL_DIR="/opt/nocodb-caddy"

prompt() {
  local message="$1"
  local default_value="${2-}"
  local value=""

  if [[ -n "$default_value" ]]; then
    read -r -p "$message [$default_value]: " value
    value="${value:-$default_value}"
  else
    read -r -p "$message: " value
  fi

  printf '%s' "$value"
}

validate_address() {
  local address="$1"

  if [[ -z "$address" ]]; then
    echo "Address cannot be empty."
    return 1
  fi

  if [[ "$address" == http://* || "$address" == https://* || "$address" == */* ]]; then
    echo "Use only a domain, subdomain, or IPv4 address without protocol or path."
    return 1
  fi

  return 0
}

write_compose_file() {
  local install_dir="$1"

  cat >"$install_dir/docker-compose.yml" <<'EOF'
services:
  nocodb:
    image: nocodb/nocodb:latest
    restart: unless-stopped
    volumes:
      - ./nocodb:/usr/app/data
    expose:
      - "8080"

  caddy:
    image: caddy:2
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - nocodb

volumes:
  caddy_data:
  caddy_config:
EOF
}

write_caddyfile() {
  local install_dir="$1"
  local address="$2"

  cat >"$install_dir/Caddyfile" <<EOF
$address {
  reverse_proxy nocodb:8080
}
EOF
}

main() {
  echo "NocoDB + Caddy installer"
  echo

  local address=""
  while true; do
    address="$(prompt "NocoDB address (domain, subdomain, or IPv4)")"
    if validate_address "$address"; then
      break
    fi
  done

  local install_dir
  install_dir="$(prompt "Installation directory" "$DEFAULT_INSTALL_DIR")"

  mkdir -p "$install_dir/nocodb"

  write_compose_file "$install_dir"
  write_caddyfile "$install_dir" "$address"

  echo
  echo "Starting containers..."
  docker compose -f "$install_dir/docker-compose.yml" up -d

  echo
  echo "Done."
  echo "Install directory: $install_dir"
  echo "Address: $address"
  echo
  echo "Useful commands:"
  echo "  docker compose -f $install_dir/docker-compose.yml ps"
  echo "  docker compose -f $install_dir/docker-compose.yml logs -f"
}

main "$@"

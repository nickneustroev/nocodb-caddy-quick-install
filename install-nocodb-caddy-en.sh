#!/usr/bin/env bash

set -euo pipefail

DEFAULT_INSTALL_DIR="/opt/nocodb-caddy"
DOCKER_CMD=(docker)

has_command() {
  command -v "$1" >/dev/null 2>&1
}

package_manager_install() {
  local package_name="$1"

  if has_command apt-get; then
    run_as_root apt-get update
    run_as_root apt-get install -y "$package_name"
  elif has_command dnf; then
    run_as_root dnf install -y "$package_name"
  elif has_command yum; then
    run_as_root yum install -y "$package_name"
  elif has_command zypper; then
    run_as_root zypper --non-interactive install "$package_name"
  elif has_command apk; then
    run_as_root apk add --no-cache "$package_name"
  else
    echo "No supported package manager found to install $package_name."
    exit 1
  fi
}

require_linux() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "This installer supports Linux only."
    exit 1
  fi
}

run_as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif has_command sudo; then
    sudo "$@"
  else
    echo "This action requires root privileges. Run the script as root or install sudo."
    exit 1
  fi
}

docker_cli() {
  "${DOCKER_CMD[@]}" "$@"
}

set_docker_cmd() {
  if ! has_command docker; then
    return
  fi

  if docker info >/dev/null 2>&1; then
    DOCKER_CMD=(docker)
  elif has_command sudo; then
    DOCKER_CMD=(sudo docker)
  else
    DOCKER_CMD=(docker)
  fi
}

print_docker_start_hint() {
  echo "Docker is installed, but the daemon is not running or not accessible."
  if has_command systemctl; then
    echo "Start it with: sudo systemctl start docker"
    echo "To enable autostart: sudo systemctl enable docker"
  else
    echo "Start the Docker daemon and run the script again."
  fi
}

download_file() {
  local url="$1"
  local output_path="$2"

  if has_command curl; then
    curl -fsSL "$url" -o "$output_path"
  else
    if ! has_command wget; then
      echo "curl or wget is required. Installing curl..."
      package_manager_install curl
    fi
    if has_command curl; then
      curl -fsSL "$url" -o "$output_path"
    elif has_command wget; then
      wget -qO "$output_path" "$url"
    else
      echo "Failed to install a downloader for the Docker installer."
      exit 1
    fi
  fi
}

install_docker_stack() {
  local installer
  installer="$(mktemp)"

  echo "Installing Docker and Docker Compose plugin via get.docker.com..."
  download_file "https://get.docker.com" "$installer"
  run_as_root sh "$installer"
  rm -f "$installer"
}

ensure_docker_stack() {
  local need_install=false

  if ! has_command docker; then
    echo "Docker is not installed."
    need_install=true
  fi

  if has_command docker && ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose plugin is not installed."
    need_install=true
  fi

  if [[ "$need_install" == true ]]; then
    install_docker_stack
  fi

  set_docker_cmd
  if ! has_command docker; then
    echo "Docker installation failed."
    exit 1
  fi

  if ! docker_cli info >/dev/null 2>&1; then
    print_docker_start_hint
    exit 1
  fi

  if ! docker_cli compose version >/dev/null 2>&1; then
    echo "Docker Compose plugin installation failed."
    exit 1
  fi
}

create_install_dir() {
  local install_dir="$1"
  local install_dir_existed=false
  local nocodb_dir_existed=false

  [[ -d "$install_dir" ]] && install_dir_existed=true
  [[ -d "$install_dir/nocodb" ]] && nocodb_dir_existed=true
  run_as_root mkdir -p "$install_dir/nocodb"

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if [[ "$install_dir_existed" == false ]]; then
      run_as_root chown "$(id -u):$(id -g)" "$install_dir"
    fi
    if [[ "$nocodb_dir_existed" == false ]]; then
      run_as_root chown "$(id -u):$(id -g)" "$install_dir/nocodb"
    fi
  fi
}

write_root_owned_file() {
  local destination="$1"
  local content="$2"

  printf '%s' "$content" | run_as_root tee "$destination" >/dev/null
}

confirm_overwrite() {
  local file_path="$1"
  local description="$2"
  local answer=""

  if [[ ! -e "$file_path" ]]; then
    return 0
  fi

  while true; do
    read -r -p "$description already exists at $file_path. Overwrite it? [y/N]: " answer
    case "$answer" in
      [Yy]) return 0 ;;
      ""|[Nn]) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

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
  local domain_regex='^([a-zA-Z0-9]([-a-zA-Z0-9]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9]([-a-zA-Z0-9]{0,61}[a-zA-Z0-9])?\.[a-zA-Z]{2,}$'

  if [[ -z "$address" ]]; then
    echo "Domain cannot be empty."
    return 1
  fi

  if [[ "$address" == *://* || "$address" == */* || "$address" == *:* || "$address" =~ [[:space:]] ]]; then
    echo "Use only a domain or subdomain without protocol, port, path, or spaces."
    return 1
  fi

  if [[ ! "$address" =~ $domain_regex ]]; then
    echo "Enter a valid domain or subdomain."
    return 1
  fi

  return 0
}

write_compose_file() {
  local install_dir="$1"

  if ! confirm_overwrite "$install_dir/docker-compose.yml" "docker-compose.yml"; then
    echo "Keeping existing docker-compose.yml"
    return
  fi

  write_root_owned_file "$install_dir/docker-compose.yml" "$(cat <<'EOF'
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
)"
}

write_caddyfile() {
  local install_dir="$1"
  local address="$2"

  if ! confirm_overwrite "$install_dir/Caddyfile" "Caddyfile"; then
    echo "Keeping existing Caddyfile"
    return
  fi

  write_root_owned_file "$install_dir/Caddyfile" "$(cat <<EOF
$address {
  reverse_proxy nocodb:8080
}
EOF
)"
}

main() {
  require_linux
  ensure_docker_stack

  echo "NocoDB + Caddy installer"
  echo

  local address=""
  while true; do
    address="$(prompt "NocoDB domain (domain or subdomain)")"
    if validate_address "$address"; then
      break
    fi
  done

  local install_dir
  install_dir="$(prompt "Installation directory" "$DEFAULT_INSTALL_DIR")"

  create_install_dir "$install_dir"
  write_compose_file "$install_dir"
  write_caddyfile "$install_dir" "$address"

  echo
  echo "Starting containers..."
  docker_cli compose -f "$install_dir/docker-compose.yml" up -d

  echo
  echo "Done."
  echo "Install directory: $install_dir"
  echo "Address: $address"
  echo
  echo "Useful commands:"
  echo "  ${DOCKER_CMD[*]} compose -f $install_dir/docker-compose.yml ps"
  echo "  ${DOCKER_CMD[*]} compose -f $install_dir/docker-compose.yml logs -f"
}

main "$@"

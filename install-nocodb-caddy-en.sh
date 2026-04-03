#!/usr/bin/env bash

set -euo pipefail

DEFAULT_INSTALL_DIR="/opt/nocodb-caddy"
DOCKER_CMD=(docker)
LOG_FILE=""

has_command() {
  command -v "$1" >/dev/null 2>&1
}

confirm_action() {
  local message="$1"
  local answer=""

  while true; do
    read -r -p "$message [y/N]: " answer
    case "$answer" in
      [Yy]) return 0 ;;
      ""|[Nn]) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

init_log_file() {
  LOG_FILE="$(mktemp -t nocodb-caddy-install.XXXXXX.log)"
}

print_log_hint() {
  if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    echo "Log file: $LOG_FILE"
  fi
}

print_log_tail() {
  if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    echo
    echo "Last log lines:"
    tail -n 20 "$LOG_FILE" || true
  fi
}

handle_error() {
  echo
  echo "Installation failed."
  print_log_hint
  print_log_tail
}

run_quiet() {
  "$@" >>"$LOG_FILE" 2>&1
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

get_public_ipv4() {
  local ip=""
  local service=""

  for service in "https://api.ipify.org" "https://ipv4.icanhazip.com"; do
    if ip="$(curl -4fsSL "$service" 2>/dev/null)"; then
      ip="${ip//$'\r'/}"
      ip="${ip//$'\n'/}"
      if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        printf '%s' "$ip"
        return 0
      fi
    fi
  done

  return 1
}

resolve_domain_ipv4() {
  local domain="$1"

  if has_command dig; then
    dig +short A "$domain" | sed '/^$/d'
  elif has_command getent; then
    getent ahostsv4 "$domain" | awk '{print $1}' | sort -u
  elif has_command host; then
    host -t A "$domain" | awk '/has address/ {print $NF}'
  else
    return 1
  fi
}

confirm_domain_points_to_server() {
  local domain="$1"
  local server_ip=""
  local resolved_ips=""

  if ! server_ip="$(get_public_ipv4)"; then
    echo "Warning: Could not determine the server's public IPv4 address."
    return 0
  fi

  if ! resolved_ips="$(resolve_domain_ipv4 "$domain")"; then
    echo "Warning: Could not resolve the domain's A record."
    return 0
  fi

  if [[ -z "$resolved_ips" ]]; then
    if ! confirm_action "Warning: The domain does not have an A record. Continue anyway?"; then
      exit 1
    fi
    return 0
  fi

  if grep -Fxq "$server_ip" <<<"$resolved_ips"; then
    return 0
  fi

  echo "Warning: The domain does not appear to point to this server."
  echo "Server IPv4: $server_ip"
  echo "Domain A records:"
  printf '%s\n' "$resolved_ips"
  if ! confirm_action "Continue anyway?"; then
    exit 1
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
  run_quiet download_file "https://get.docker.com" "$installer"
  run_quiet run_as_root sh "$installer"
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

sanitize_input() {
  local value="$1"

  value="${value//$'\r'/}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  printf '%s' "$value"
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
  local prompt_text=""

  if [[ -n "$default_value" ]]; then
    prompt_text="$message (leave blank for $default_value): "
    read -r -p "$prompt_text" value
    value="${value:-$default_value}"
  else
    read -r -p "$message: " value
  fi

  value="$(sanitize_input "$value")"

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
    echo "Error: The domain is not correct."
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
    address="$(prompt "Enter domain or subdomain (example: nocodb.mysite.com)")"
    if validate_address "$address"; then
      break
    fi
  done

  confirm_domain_points_to_server "$address"

  local install_dir
  install_dir="$(prompt "Installation directory" "$DEFAULT_INSTALL_DIR")"

  create_install_dir "$install_dir"
  write_compose_file "$install_dir"
  write_caddyfile "$install_dir" "$address"

  echo
  echo "Starting containers..."
  run_quiet docker_cli compose -f "$install_dir/docker-compose.yml" up -d

  echo
  echo "Done."
  echo "Install directory: $install_dir"
  echo "Address: $address"
  echo
  print_log_hint
  echo
  echo "Useful commands:"
  echo "  ${DOCKER_CMD[*]} compose -f $install_dir/docker-compose.yml ps"
  echo "  ${DOCKER_CMD[*]} compose -f $install_dir/docker-compose.yml logs -f"
}

init_log_file
trap handle_error ERR

main "$@"

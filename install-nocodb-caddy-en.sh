#!/usr/bin/env bash

set -euo pipefail

DEFAULT_INSTALL_DIR="/opt/nocodb-caddy"
DOCKER_CMD=(docker)
LOG_FILE=""
READINESS_TIMEOUT=60
READINESS_INTERVAL=2
SPINNER_PID=""
CURRENT_INSTALL_DIR="$DEFAULT_INSTALL_DIR"

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

print_recent_error_context() {
  local error_summary=""
  local daemon_error=""

  if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    daemon_error="$(
      tail -n 50 "$LOG_FILE" \
        | sed 's/\r$//' \
        | grep -F 'Error response from daemon:' \
        | tail -n 1 \
        || true
    )"

    error_summary="$daemon_error"

    if [[ -z "$error_summary" ]]; then
      error_summary="$(
        tail -n 50 "$LOG_FILE" \
          | sed 's/\r$//' \
          | grep -E '([Ee]rror|[Ff]ailed|denied|unauthorized|no space left|cannot allocate|port is already allocated)' \
          | tail -n 3 \
          || true
      )"
    fi

    if [[ -n "$error_summary" ]]; then
      echo "Error details:"
      printf '%s\n' "$error_summary"
    else
      echo "Recent error output:"
      tail -n 12 "$LOG_FILE" || true
    fi
  fi
}

print_readiness_failure_summary() {
  local ps_output="$1"
  local caddy_logs="$2"
  local nocodb_logs="$3"
  local http_probe="$4"
  local https_probe="$5"

  echo
  echo "Likely cause:"

  if grep -qi 'rateLimited\|too many certificates' <<<"$caddy_logs"; then
    echo "Let's Encrypt rate limit prevented Caddy from obtaining a certificate for the configured domain."
    return
  fi

  if grep -Eqi '(^|[[:space:]])(exited|restarting|created|dead)([[:space:]]|$)' <<<"$ps_output"; then
    echo "One or more containers are not healthy or not running. Check the container status and logs below."
    return
  fi

  if grep -qi 'Could not resolve host' <<<"$http_probe$https_probe"; then
    echo "The domain could not be resolved from the server. Check the DNS records for the configured domain."
    return
  fi

  if grep -qi 'Connection refused\|Failed to connect\|timed out' <<<"$http_probe$https_probe"; then
    echo "The server could not reach the domain over HTTP or HTTPS. Check firewall rules, port forwarding, and whether Caddy is listening on ports 80 and 443."
    return
  fi

  if grep -q '308 Permanent Redirect' <<<"$http_probe" && grep -qi 'tlsv1 alert\|SSL routines\|handshake failure\|no alternative certificate subject name\|certificate' <<<"$https_probe$caddy_logs"; then
    echo "HTTP is reachable, but HTTPS/TLS is failing. Check Caddy certificate issuance and TLS configuration."
    return
  fi

  if grep -qi 'Nest application successfully started\|App started successfully' <<<"$nocodb_logs"; then
    echo "NocoDB started, but the public HTTPS endpoint is still unavailable. Check Caddy, TLS issuance, and external access to the domain."
    return
  fi

  echo "The HTTPS endpoint did not become reachable within the timeout. Review the container status, probes, and logs below."
}

print_readiness_debug_info() {
  local address="$1"
  local install_dir="$2"
  local ps_output=""
  local caddy_logs=""
  local nocodb_logs=""
  local http_probe=""
  local https_probe=""

  echo
  echo "Readiness diagnostics:"

  if [[ -f "$install_dir/docker-compose.yml" ]]; then
    ps_output="$(docker_cli compose -f "$install_dir/docker-compose.yml" ps --all 2>&1 || true)"
    caddy_logs="$(docker_cli compose -f "$install_dir/docker-compose.yml" logs --tail 50 caddy 2>&1 || true)"
    nocodb_logs="$(docker_cli compose -f "$install_dir/docker-compose.yml" logs --tail 50 nocodb 2>&1 || true)"
  fi

  if has_command curl; then
    http_probe="$(curl -I -sS --connect-timeout 5 "http://$address" 2>&1 || true)"
    https_probe="$(curl -kI -sS --connect-timeout 5 "https://$address" 2>&1 || true)"
  fi

  print_readiness_failure_summary "$ps_output" "$caddy_logs" "$nocodb_logs" "$http_probe" "$https_probe"
  print_log_hint

  echo
  echo "Troubleshooting commands:"
  echo "  ${DOCKER_CMD[*]} compose -f $install_dir/docker-compose.yml ps"
  echo "  ${DOCKER_CMD[*]} compose -f $install_dir/docker-compose.yml logs --tail 50 caddy"
  echo "  ${DOCKER_CMD[*]} compose -f $install_dir/docker-compose.yml logs --tail 50 nocodb"
  echo "  curl -I http://$address"
  echo "  curl -kI https://$address"
}

handle_error() {
  stop_spinner 1 ""
  echo
  echo "Installation failed."
  print_log_hint
  print_log_tail
  echo
  echo "Troubleshooting commands:"
  echo "  ${DOCKER_CMD[*]} compose -f $CURRENT_INSTALL_DIR/docker-compose.yml ps"
  echo "  ${DOCKER_CMD[*]} compose -f $CURRENT_INSTALL_DIR/docker-compose.yml logs --tail 50"
}

run_quiet() {
  "$@" >>"$LOG_FILE" 2>&1
}

start_spinner() {
  local message="$1"

  if [[ ! -t 1 ]]; then
    echo "$message"
    return
  fi

  (
    local frames='|/-\'
    local i=0
    while true; do
      printf '\r%s %s' "${frames:i++%${#frames}:1}" "$message"
      sleep 0.1
    done
  ) &
  SPINNER_PID=$!
}

stop_spinner() {
  local exit_code="${1:-0}"
  local message="${2-}"

  if [[ -n "$SPINNER_PID" ]]; then
    kill "$SPINNER_PID" >/dev/null 2>&1 || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    if [[ -t 1 ]]; then
      printf '\r\033[K'
    fi
  fi

  if [[ -n "$message" ]]; then
    if [[ "$exit_code" -eq 0 ]]; then
      echo "[OK] $message"
    else
      echo "[FAIL] $message"
      print_log_hint
      print_recent_error_context
    fi
  fi
}

run_with_spinner() {
  local message="$1"
  shift

  start_spinner "$message"
  if "$@" >>"$LOG_FILE" 2>&1; then
    stop_spinner 0 "$message"
    return 0
  fi

  stop_spinner 1 "$message"
  return 1
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

resolve_domain_ipv4_public() {
  local domain="$1"
  local resolved_ips=""
  local response=""
  local resolver=""

  if has_command dig; then
    for resolver in "1.1.1.1" "8.8.8.8"; do
      resolved_ips="$(
        dig @"$resolver" +short A "$domain" 2>/dev/null | sed '/^$/d' || true
      )"
      if [[ -n "$resolved_ips" ]]; then
        printf '%s\n' "$resolved_ips" | sort -u
        return 0
      fi
    done
  fi

  if has_command curl; then
    for resolver in \
      "https://dns.google/resolve?name=$domain&type=A" \
      "https://cloudflare-dns.com/dns-query?name=$domain&type=A"
    do
      if response="$(curl -fsSL -H 'accept: application/dns-json' "$resolver" 2>/dev/null)"; then
        resolved_ips="$(
          printf '%s' "$response" \
            | grep -oE '"data":"([0-9]{1,3}\.){3}[0-9]{1,3}"' \
            | sed -E 's/^"data":"//; s/"$//' \
            | sort -u \
            || true
        )"
        if [[ -n "$resolved_ips" ]]; then
          printf '%s\n' "$resolved_ips"
          return 0
        fi
      fi
    done
  fi

  return 1
}

resolve_domain_ipv4_local() {
  local domain="$1"

  if has_command getent; then
    getent ahostsv4 "$domain" | awk '{print $1}' | sort -u
  elif has_command dig; then
    dig +short A "$domain" | sed '/^$/d'
  elif has_command host; then
    host -t A "$domain" | awk '/has address/ {print $NF}'
  else
    return 1
  fi
}

resolve_domain_ipv4() {
  local domain="$1"

  if resolve_domain_ipv4_public "$domain"; then
    return 0
  fi

  resolve_domain_ipv4_local "$domain"
}

print_wait_step_once() {
  local printed_var="$1"
  local message="$2"

  if [[ "${!printed_var:-false}" == "true" ]]; then
    return
  fi

  printf -v "$printed_var" '%s' "true"
  if [[ -n "$SPINNER_PID" && -t 1 ]]; then
    printf '\r\033[K'
  fi
  echo "  - $message"
}

is_successful_http_response() {
  local response="$1"
  local status_code=""

  status_code="$(
    printf '%s\n' "$response" \
      | sed -nE 's/^HTTP\/[0-9.]+ ([0-9]{3}).*/\1/p' \
      | tail -n 1
  )"

  if [[ -z "$status_code" ]]; then
    return 1
  fi

  [[ "$status_code" =~ ^(200|301|302|303|307|308|401|403)$ ]]
}

wait_for_nocodb() {
  local address="$1"
  local install_dir="$2"
  local elapsed=0
  local ps_output=""
  local caddy_logs=""
  local http_probe=""
  local https_probe=""
  local printed_starting="false"
  local printed_running="false"
  local printed_http_ready="false"
  local printed_tls_pending="false"

  start_spinner "Waiting for NocoDB to become available..."
  print_wait_step_once printed_starting "Starting NocoDB and Caddy containers..."

  while (( elapsed < READINESS_TIMEOUT )); do
    https_probe="$(curl -kI -sS --connect-timeout 5 "https://$address" 2>&1 || true)"
    if is_successful_http_response "$https_probe"; then
      stop_spinner 0 "Waiting for NocoDB to become available..."
      return 0
    fi

    ps_output="$(docker_cli compose -f "$install_dir/docker-compose.yml" ps --all 2>&1 || true)"

    if grep -Eqi '(^|[[:space:]])up([[:space:]]|$)' <<<"$ps_output"; then
      print_wait_step_once printed_running "Containers are running."
    fi

    http_probe="$(curl -I -sS --connect-timeout 5 "http://$address" 2>&1 || true)"
    if is_successful_http_response "$http_probe"; then
      print_wait_step_once printed_http_ready "Domain is responding over HTTP."
    fi

    caddy_logs="$(docker_cli compose -f "$install_dir/docker-compose.yml" logs --tail 20 caddy 2>&1 || true)"
    if grep -qi 'obtaining certificate\|authorization finalized\|waiting on internal rate limiter\|rateLimited\|too many certificates' <<<"$caddy_logs$https_probe"; then
      print_wait_step_once printed_tls_pending "Waiting for Caddy to provision the TLS certificate..."
    fi

    if ! docker_cli compose -f "$install_dir/docker-compose.yml" ps --status running >/dev/null 2>&1; then
      break
    fi

    sleep "$READINESS_INTERVAL"
    elapsed=$((elapsed + READINESS_INTERVAL))
  done

  stop_spinner 0 ""
  return 1
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
      return 1
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
    return 1
  fi

  return 0
}

offer_docker_login() {
  echo
  echo "Docker Hub login is recommended to avoid image pull rate limits."
  if confirm_action "Log in to Docker Hub now?"; then
    docker_cli login
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

  echo "Docker was not found. Installing Docker and Docker Compose plugin..."
  run_with_spinner "Downloading Docker installer..." download_file "https://get.docker.com" "$installer"
  run_with_spinner "Running Docker installer..." run_as_root sh "$installer"
  rm -f "$installer"
  echo "Docker installation completed."
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

  echo "Checking installed Docker availability..."
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

sanitize_domain_input() {
  local value="$1"

  value="$(sanitize_input "$value")"
  value="$(printf '%s' "$value" | tr -cd 'A-Za-z0-9._-')"

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

prompt_existing_install_action() {
  local install_dir="$1"
  local answer=""

  echo "NocoDB is already installed at $install_dir." >&2

  while true; do
    read -r -p "Choose action: [R]econfigure, [S]tart/restart, or [E]xit: " answer
    answer="$(sanitize_input "$answer")"
    case "$answer" in
      [Rr]) printf 'reconfigure'; return 0 ;;
      [Ss]) printf 'restart'; return 0 ;;
      ""|[Ee]) printf 'exit'; return 0 ;;
      *) echo "Please answer R, S, or E." >&2 ;;
    esac
  done
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

is_existing_installation() {
  local install_dir="$1"

  [[ -f "$install_dir/docker-compose.yml" && -f "$install_dir/Caddyfile" ]]
}

get_configured_address() {
  local install_dir="$1"

  if [[ ! -f "$install_dir/Caddyfile" ]]; then
    return 1
  fi

  sed -nE '1s/^[[:space:]]*([^[:space:]{]+)[[:space:]]*\{[[:space:]]*$/\1/p' "$install_dir/Caddyfile" | head -n 1
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

  local install_dir
  install_dir="$(prompt "Installation directory" "$DEFAULT_INSTALL_DIR")"
  CURRENT_INSTALL_DIR="$install_dir"

  local action="install"
  local address=""

  if is_existing_installation "$install_dir"; then
    action="$(prompt_existing_install_action "$install_dir")"
  fi

  if [[ "$action" == "exit" ]]; then
    echo "Nothing to do."
    exit 0
  fi

  if [[ "$action" == "restart" ]]; then
    address="$(get_configured_address "$install_dir" || true)"
    if [[ -z "$address" ]]; then
      echo "Could not determine the configured domain from $install_dir/Caddyfile."
      echo "Use reconfigure mode to set the domain again."
      exit 1
    fi
  else
    while true; do
      address="$(prompt "Enter domain or subdomain (example: nocodb.mysite.com)")"
      address="$(sanitize_domain_input "$address")"
      if validate_address "$address" && confirm_domain_points_to_server "$address"; then
        break
      fi
    done
  fi

  if [[ "$action" != "restart" ]]; then
    offer_docker_login
  fi

  create_install_dir "$install_dir"

  if [[ "$action" == "reconfigure" || "$action" == "install" ]]; then
    write_compose_file "$install_dir"
    write_caddyfile "$install_dir" "$address"
  fi

  echo
  run_with_spinner "Starting containers..." docker_cli compose -f "$install_dir/docker-compose.yml" up -d --force-recreate

  echo
  if wait_for_nocodb "$address" "$install_dir"; then
    echo "NocoDB is now available."
  else
    echo "Error: NocoDB did not become available within $READINESS_TIMEOUT seconds."
    print_readiness_debug_info "$address" "$install_dir"
    exit 1
  fi

  echo
  echo "NocoDB has been successfully installed."
  echo "Open NocoDB: https://$address"
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

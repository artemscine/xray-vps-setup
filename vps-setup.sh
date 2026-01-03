#!/bin/bash

set -e

# Determine script directory (where templates are located)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates_for_script"

# Check for local templates
if [ -d "$TEMPLATES_DIR" ]; then
  USE_LOCAL=true
else
  USE_LOCAL=false
  export GIT_BRANCH="main"
  export GIT_REPO="artemscine/xray-vps-setup"
fi

# Check if script started as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Function to get template (locally or from GitHub)
get_template() {
  local template_name="$1"
  if [ "$USE_LOCAL" = true ]; then
    cat "$TEMPLATES_DIR/$template_name"
  else
    wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/$template_name"
  fi
}

# Generate random API-like path for XHTTP (e.g., /v1/a83j29)
generate_xhttp_path() {
  local random_suffix=$(openssl rand -hex 3)
  echo "/v1/${random_suffix}"
}

# Installation mode selection with retry loop
select_install_mode() {
  while true; do
    echo ""
    echo "=============================================="
    echo "       Marzneshin VPS Setup Script"
    echo "=============================================="
    echo ""
    echo "Select installation mode:"
    echo "  0) Exit"
    echo "  1) Full installation (Marzneshin panel + Marznode)"
    echo "  2) Node only (Marznode for remote panel)"
    echo ""
    read -ep "Enter choice [0/1/2]: " install_mode

    case "$install_mode" in
      0)
        echo "Exiting..."
        exit 0
        ;;
      1|2)
        break
        ;;
      *)
        echo "Invalid choice. Please enter 0, 1, or 2."
        ;;
    esac
  done
}

select_install_mode

# Install required packages
apt update
apt install -y idn sudo dnsutils curl jq openssl wget ufw

export ARCH=$(dpkg --print-architecture)

yq_install() {
  if ! command -v yq &> /dev/null; then
    wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$ARCH -O /usr/bin/yq && chmod +x /usr/bin/yq
  fi
}

yq_install

docker_install() {
  bash <(wget -qO- https://get.docker.com)
}

if ! command -v docker 2>&1 >/dev/null; then
    docker_install
fi

# Check congestion protocol
if sysctl net.ipv4.tcp_congestion_control | grep bbr; then
    echo "BBR is already used"
else
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null
    echo "Enabled BBR"
fi

# UFW configuration function
configure_ufw() {
  local ssh_port="${1:-22}"
  local grpc_port="${2:-0}"
  local hysteria_enabled="${3:-False}"
  local xhttp_enabled="${4:-False}"

  if command -v ufw &> /dev/null; then
    echo "Configuring UFW firewall..."

    # Enable UFW if not active
    if ! ufw status | grep -q "Status: active"; then
      echo "y" | ufw enable
    fi

    # Allow SSH
    ufw allow "$ssh_port/tcp"

    # Allow HTTP/HTTPS for Caddy and VLESS
    ufw allow 80/tcp
    ufw allow 443/tcp

    # Allow gRPC port for node communication (only if specified)
    if [[ "$grpc_port" != "0" ]] && [[ -n "$grpc_port" ]]; then
      ufw allow "$grpc_port/tcp"
    fi

    # Allow XHTTP port if enabled (8443/tcp)
    if [[ "$xhttp_enabled" == "True" ]]; then
      ufw allow 8443/tcp
    fi

    # Allow Hysteria if enabled (8443/udp)
    if [[ "$hysteria_enabled" == "True" ]]; then
      ufw allow 8443/udp
    fi

    ufw reload
    echo "UFW configured"
  else
    echo "UFW not found, skipping firewall auto-configuration"
  fi
}

#####################################
# NODE ONLY INSTALLATION
#####################################
if [[ "$install_mode" == "2" ]]; then
  echo ""
  echo "=== Node Only Installation ==="
  echo ""

  # Node domain for selfsteal Reality
  read -ep "Enter domain for this node (for Reality selfsteal): " input_node_domain
  export NODE_DOMAIN=$(echo $input_node_domain | idn)

  # Verify DNS
  SERVER_IPS=($(hostname -I))
  RESOLVED_IP=$(dig +short $NODE_DOMAIN | tail -n1)

  if [ -z "$RESOLVED_IP" ]; then
    echo "Warning: Domain has no DNS record"
    read -ep "Continue anyway? [y/N] " prompt_response
    if [[ ! "$prompt_response" =~ ^([yY])$ ]]; then
      echo "Come back later"
      exit 1
    fi
  else
    MATCH_FOUND=false
    for server_ip in "${SERVER_IPS[@]}"; do
      if [ "$RESOLVED_IP" == "$server_ip" ]; then
        MATCH_FOUND=true
        break
      fi
    done

    if [ "$MATCH_FOUND" = true ]; then
      echo "DNS record points to this server ($RESOLVED_IP)"
    else
      echo "Warning: DNS record points to different IP ($RESOLVED_IP)"
      echo "This server's IPs: ${SERVER_IPS[*]}"
      read -ep "Continue anyway? [y/N] " prompt_response
      if [[ ! "$prompt_response" =~ ^([yY])$ ]]; then
        exit 1
      fi
    fi
  fi

  # Get node external IP
  export NODE_EXTERNAL_IP=$(curl -4s ifconfig.me || echo "${SERVER_IPS[0]}")
  echo "Detected external IP: $NODE_EXTERNAL_IP"
  read -ep "Enter node external IP (or press Enter to use $NODE_EXTERNAL_IP): " input_node_ip
  export NODE_EXTERNAL_IP=${input_node_ip:-$NODE_EXTERNAL_IP}

  # gRPC settings
  read -ep "Enter gRPC port for marznode [53042]: " input_grpc_port
  export NODE_SERVICE_PORT=${input_grpc_port:-53042}

  # TLS mode is always used for security
  export NODE_INSECURE="False"
  export NODE_SERVICE_ADDRESS="0.0.0.0"
  echo ""
  echo "TLS mode will be used for secure connection."
  echo "You will be prompted to paste the certificate from panel later."
  echo "When registering this node in panel, use connection_backend: grpclib"

  # Generate X25519 keys for Reality
  echo "Generating Reality keys..."
  export XRAY_PIK=$(docker run --rm ghcr.io/xtls/xray-core x25519 | head -n1 | cut -d' ' -f 2)
  export XRAY_PBK=$(docker run --rm ghcr.io/xtls/xray-core x25519 -i $XRAY_PIK | tail -2 | head -1 | cut -d' ' -f 2)
  export XRAY_SID=$(openssl rand -hex 8)

  # Hysteria obfuscation password
  export HYSTERIA_OBFS_PASSWORD=$(openssl rand -base64 32)

  # XHTTP option
  echo ""
  read -ep "Enable XHTTP inbound (VLESS over XHTTP on port 8443)? [Y/n]: " enable_xhttp
  if [[ ${enable_xhttp,,} == "n" ]]; then
    export XHTTP_ENABLED="False"
  else
    export XHTTP_ENABLED="True"
    export XHTTP_PATH=$(generate_xhttp_path)
    echo "XHTTP path generated: $XHTTP_PATH"
  fi

  # Hysteria option
  echo ""
  read -ep "Enable Hysteria2? [Y/n]: " enable_hysteria
  if [[ ${enable_hysteria,,} == "n" ]]; then
    export HYSTERIA_ENABLED="False"
    export HYSTERIA_PORT="8443"
  else
    export HYSTERIA_ENABLED="True"
    export HYSTERIA_PORT="8443"
  fi

  # Check for port conflict
  if [[ "$XHTTP_ENABLED" == "True" ]] && [[ "$HYSTERIA_ENABLED" == "True" ]]; then
    echo ""
    echo "WARNING: Both XHTTP and Hysteria2 use port 8443."
    echo "  - XHTTP uses 8443/TCP"
    echo "  - Hysteria2 uses 8443/UDP"
    echo "This is supported and both can work simultaneously."
  fi

  # Security configuration
  read -ep "Do you want to configure server security (SSH, UFW)? [y/N] " configure_ssh_input
  if [[ ${configure_ssh_input,,} == "y" ]]; then
    read -ep "Enter SSH port [22]: " input_ssh_port
    while [[ "$input_ssh_port" -eq "443" || "$input_ssh_port" -eq "80" || "$input_ssh_port" -eq "8443" ]]; do
      read -ep "Port $input_ssh_port is reserved, enter another: " input_ssh_port
    done
    export SSH_PORT=${input_ssh_port:-22}

    read -ep "Enter SSH public key: " input_ssh_pbk
    echo "$input_ssh_pbk" > ./test_pbk
    ssh-keygen -l -f ./test_pbk
    PBK_STATUS=$(echo $?)
    if [ "$PBK_STATUS" -eq 255 ]; then
      echo "Can't verify the public key."
      exit 1
    fi
    rm ./test_pbk

    export SSH_USER=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8; echo)
    export SSH_USER_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo)
  fi

  # Setup node
  marznode_setup() {
    mkdir -p /opt/marznode
    cd /opt/marznode
    mkdir -p marznode_data caddy/templates

    # Process templates
    get_template "compose_node" | envsubst > ./docker-compose.yml
    get_template "xray_node" | envsubst > ./marznode_data/xray_config.json

    # Add XHTTP inbound if enabled
    if [[ "$XHTTP_ENABLED" == "True" ]]; then
      XHTTP_INBOUND=$(get_template "xray_node_xhttp_inbound" | envsubst)
      jq --argjson inbound "$XHTTP_INBOUND" '.inbounds += [$inbound]' ./marznode_data/xray_config.json > ./marznode_data/xray_config.json.tmp
      mv ./marznode_data/xray_config.json.tmp ./marznode_data/xray_config.json
    fi

    get_template "caddy_node" | envsubst > ./caddy/Caddyfile
    get_template "confluence_page" | envsubst > ./caddy/templates/index.html

    if [[ "$HYSTERIA_ENABLED" == "True" ]]; then
      get_template "hysteria_node" | envsubst > ./marznode_data/hysteria.yaml
    fi

    echo "Marznode setup completed"
  }

  marznode_setup

  # SSH configuration
  sshd_edit() {
    grep -r Port /etc/ssh -l | xargs -n 1 sed -i -e "/Port /c\Port $SSH_PORT"
    grep -r PasswordAuthentication /etc/ssh -l | xargs -n 1 sed -i -e "/PasswordAuthentication /c\PasswordAuthentication no"
    grep -r PermitRootLogin /etc/ssh -l | xargs -n 1 sed -i -e "/PermitRootLogin /c\PermitRootLogin no"
    systemctl daemon-reload
    systemctl restart ssh
  }

  add_user() {
    useradd $SSH_USER -s /bin/bash
    usermod -aG sudo $SSH_USER
    echo $SSH_USER:$SSH_USER_PASS | chpasswd
    mkdir -p /home/$SSH_USER/.ssh
    touch /home/$SSH_USER/.ssh/authorized_keys
    echo $input_ssh_pbk >> /home/$SSH_USER/.ssh/authorized_keys
    chmod 700 /home/$SSH_USER/.ssh/
    chmod 600 /home/$SSH_USER/.ssh/authorized_keys
    chown $SSH_USER:$SSH_USER -R /home/$SSH_USER
    usermod -aG docker $SSH_USER
  }

  if [[ ${configure_ssh_input,,} == "y" ]]; then
    sshd_edit
    add_user
  fi

  # Configure UFW firewall
  read -ep "Configure UFW firewall? [Y/n]: " configure_ufw_input
  if [[ ! "${configure_ufw_input,,}" == "n" ]]; then
    configure_ufw "${SSH_PORT:-22}" "$NODE_SERVICE_PORT" "$HYSTERIA_ENABLED" "$XHTTP_ENABLED"
  fi

  # Format Caddyfile
  docker run -v /opt/marznode/caddy/Caddyfile:/opt/Caddyfile --rm caddy caddy fmt --overwrite /opt/Caddyfile

  # Request TLS certificate from user with retry loop
  while true; do
    echo ""
    echo "=============================================="
    echo "  TLS Certificate Required"
    echo "=============================================="
    echo ""
    echo "Get the certificate from your Marzneshin panel:"
    echo "  1. Go to Settings page"
    echo "  3. Click 'Copy Certificate' button"
    echo ""
    echo "Paste the certificate below (starts with -----BEGIN CERTIFICATE-----):"
    echo "Press Enter after the last line (-----END CERTIFICATE-----):"
    echo ""

    # Read multiline certificate until END CERTIFICATE
    CERT_CONTENT=""
    while IFS= read -r line; do
      CERT_CONTENT+="$line"$'\n'
      if [[ "$line" == "-----END CERTIFICATE-----" ]]; then
        break
      fi
    done

    # Validate certificate
    if [[ "$CERT_CONTENT" == *"-----BEGIN CERTIFICATE-----"* ]] && [[ "$CERT_CONTENT" == *"-----END CERTIFICATE-----"* ]]; then
      # Save certificate
      echo -n "$CERT_CONTENT" > /opt/marznode/marznode_data/client.pem
      echo "Certificate saved to /opt/marznode/marznode_data/client.pem"
      break
    else
      echo ""
      echo "ERROR: Invalid certificate format!"
      echo "Certificate must start with -----BEGIN CERTIFICATE----- and end with -----END CERTIFICATE-----"
      echo "Please try again."
    fi
  done

  # Create certificate directory (will be populated by Caddy)
  mkdir -p "/opt/marznode/caddy/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$NODE_DOMAIN"

  # Start Caddy first to obtain certificates
  echo "Starting Caddy to obtain Let's Encrypt certificates..."
  docker compose -f /opt/marznode/docker-compose.yml up -d caddy

  # Wait for certificates (needed for Hysteria)
  if [[ "$HYSTERIA_ENABLED" == "True" ]]; then
    echo "Waiting for certificates (max 120 seconds)..."
    CERT_PATH="/opt/marznode/caddy/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$NODE_DOMAIN/$NODE_DOMAIN.crt"
    for i in {1..24}; do
      if [ -f "$CERT_PATH" ]; then
        echo "Certificate obtained"
        break
      fi
      echo "  Waiting... ($((i*5))s)"
      sleep 5
    done

    if [ ! -f "$CERT_PATH" ]; then
      echo "Warning: Certificate not found after 120s. Hysteria may not work."
      echo "Check Caddy logs: docker logs caddy"
    fi
  else
    # Give Caddy a moment to start
    sleep 5
  fi

  # Start marznode
  docker compose -f /opt/marznode/docker-compose.yml up -d marznode

  # Cleanup
  docker rmi ghcr.io/xtls/xray-core:latest caddy:latest 2>/dev/null || true

  clear

  echo "=============================================="
  echo "       Marznode Installation Complete"
  echo "=============================================="
  echo ""
  echo "Node Domain: $NODE_DOMAIN"
  echo ""
  echo "=== Register node in Marzneshin panel ==="
  echo "Go to your panel dashboard -> Nodes -> Add Node"
  echo "  Name: (any name you want)"
  echo "  Address: $NODE_EXTERNAL_IP"
  echo "  Port: $NODE_SERVICE_PORT"
  echo "  Connection Backend: grpclib (TLS)"
  echo ""
  echo "TLS certificate installed"
  echo ""

  echo "=== Inbounds ==="
  echo "VLESS Reality (TCP/443):"
  echo "  Tag: VLESS-TCP-Reality"
  echo "  Reality Public Key: $XRAY_PBK"
  echo "  Reality Short ID: $XRAY_SID"
  echo ""

  if [[ "$XHTTP_ENABLED" == "True" ]]; then
    echo "VLESS XHTTP Reality (TCP/8443):"
    echo "  Tag: VLESS-XHTTP-Reality"
    echo "  Path: $XHTTP_PATH"
    echo "  Reality Public Key: $XRAY_PBK"
    echo "  Reality Short ID: $XRAY_SID"
    echo ""
  fi

  if [[ "$HYSTERIA_ENABLED" == "True" ]]; then
    echo "Hysteria2 (UDP/8443):"
    echo "  Tag: hysteria2"
    echo "  Obfs Password: $HYSTERIA_OBFS_PASSWORD"
    echo ""
  fi

  if [[ ${configure_ssh_input,,} == "y" ]]; then
    echo "=== SSH Access ==="
    echo "  User: $SSH_USER"
    echo "  Password: $SSH_USER_PASS"
    echo "  Port: $SSH_PORT"
    echo ""
  fi

  echo "Installation directory: /opt/marznode"
  echo ""
  echo "=== Useful commands ==="
  echo "  View logs: docker compose -f /opt/marznode/docker-compose.yml logs -f"
  echo "  Restart:   docker compose -f /opt/marznode/docker-compose.yml restart"
  echo "  Stop:      docker compose -f /opt/marznode/docker-compose.yml down"
  echo "=============================================="

  exit 0
fi

#####################################
# FULL INSTALLATION (Panel + Node)
#####################################

# Read domain input
read -ep "Enter your domain: " input_domain

export VLESS_DOMAIN=$(echo $input_domain | idn)

SERVER_IPS=($(hostname -I))

RESOLVED_IP=$(dig +short $VLESS_DOMAIN | tail -n1)

if [ -z "$RESOLVED_IP" ]; then
  echo "Warning: Domain has no DNS record"
  read -ep "Are you sure? That domain has no DNS record. If you didn't add that you will have to restart containers by yourself [y/N] " prompt_response
  if [[ "$prompt_response" =~ ^([yY])$ ]]; then
    echo "Ok, proceeding without DNS verification"
  else
    echo "Come back later"
    exit 1
  fi
else
  MATCH_FOUND=false
  for server_ip in "${SERVER_IPS[@]}"; do
    if [ "$RESOLVED_IP" == "$server_ip" ]; then
      MATCH_FOUND=true
      break
    fi
  done

  if [ "$MATCH_FOUND" = true ]; then
    echo "DNS record points to this server ($RESOLVED_IP)"
  else
    echo "Warning: DNS record exists but points to different IP"
    echo "  Domain resolves to: $RESOLVED_IP"
    echo "  This server's IPs: ${SERVER_IPS[*]}"
    read -ep "Continue anyway? [y/N] " prompt_response
    if [[ "$prompt_response" =~ ^([yY])$ ]]; then
      echo "Ok, proceeding"
    else
      echo "Come back later"
      exit 1
    fi
  fi
fi

read -ep "Do you want to configure server security? Do this on first run only. [y/N] " configure_ssh_input
if [[ ${configure_ssh_input,,} == "y" ]]; then
  # Read SSH port
  read -ep "Enter SSH port. Default 22, can't use ports: 80, 443, 4123 and 8443: " input_ssh_port

  while [[ "$input_ssh_port" -eq "80" || "$input_ssh_port" -eq "443" || "$input_ssh_port" -eq "4123" || "$input_ssh_port" -eq "8443" ]]; do
    read -ep "No, ssh can't use $input_ssh_port as port, write again: " input_ssh_port
  done
  # Read SSH Pubkey
  read -ep "Enter SSH public key: " input_ssh_pbk
  echo "$input_ssh_pbk" > ./test_pbk
  ssh-keygen -l -f ./test_pbk
  PBK_STATUS=$(echo $?)
  if [ "$PBK_STATUS" -eq 255 ]; then
    echo "Can't verify the public key. Try again and make sure to include 'ssh-rsa' or 'ssh-ed25519' followed by 'user@pcname' at the end of the file."
    exit 1
  fi
  rm ./test_pbk
fi

# Generate values for XRay and Marzneshin
export SSH_USER=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8; echo)
export SSH_USER_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo)
export SSH_PORT=${input_ssh_port:-22}
export ROOT_LOGIN="yes"
export IP_CADDY=$(hostname -I | cut -d' ' -f1)

# Generate X25519 keys for Reality
export XRAY_PIK=$(docker run --rm ghcr.io/xtls/xray-core x25519 | head -n1 | cut -d' ' -f 2)
export XRAY_PBK=$(docker run --rm ghcr.io/xtls/xray-core x25519 -i $XRAY_PIK | tail -2 | head -1 | cut -d' ' -f 2)
export XRAY_SID=$(openssl rand -hex 8)

# Hysteria obfuscation password
export HYSTERIA_OBFS_PASSWORD=$(openssl rand -base64 32)

# Marzneshin specific
echo ""
read -ep "Enter admin username [admin]: " input_admin_user
export ADMIN_USER=${input_admin_user:-admin}
export MARZNESHIN_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16; echo)
export DASHBOARD_PATH=$(openssl rand -hex 8)

# XHTTP option
echo ""
read -ep "Enable XHTTP inbound (VLESS over XHTTP on port 8443)? [Y/n]: " enable_xhttp
if [[ ${enable_xhttp,,} == "n" ]]; then
  export XHTTP_ENABLED="False"
else
  export XHTTP_ENABLED="True"
  export XHTTP_PATH=$(generate_xhttp_path)
  echo "XHTTP path generated: $XHTTP_PATH"
fi

# Hysteria option
echo ""
read -ep "Enable Hysteria2? [Y/n]: " enable_hysteria
if [[ ${enable_hysteria,,} == "n" ]]; then
  export HYSTERIA_ENABLED="False"
else
  export HYSTERIA_ENABLED="True"
fi

# Check for port conflict info
if [[ "$XHTTP_ENABLED" == "True" ]] && [[ "$HYSTERIA_ENABLED" == "True" ]]; then
  echo ""
  echo "NOTE: Both XHTTP and Hysteria2 use port 8443."
  echo "  - XHTTP uses 8443/TCP"
  echo "  - Hysteria2 uses 8443/UDP"
  echo "This is supported and both can work simultaneously."
fi

# Install Marzneshin
marzneshin_setup() {
  mkdir -p /opt/marzneshin-vps-setup
  cd /opt/marzneshin-vps-setup

  # Create directories
  mkdir -p marzneshin marzneshin_data marznode_data caddy/templates

  # Process templates
  get_template "compose" | envsubst > ./docker-compose.yml
  get_template "marzneshin" | envsubst > ./marzneshin/.env
  get_template "xray" | envsubst > ./marznode_data/xray_config.json

  # Add XHTTP inbound if enabled
  if [[ "$XHTTP_ENABLED" == "True" ]]; then
    XHTTP_INBOUND=$(get_template "xray_xhttp_inbound" | envsubst)
    jq --argjson inbound "$XHTTP_INBOUND" '.inbounds += [$inbound]' ./marznode_data/xray_config.json > ./marznode_data/xray_config.json.tmp
    mv ./marznode_data/xray_config.json.tmp ./marznode_data/xray_config.json
  fi

  if [[ "$HYSTERIA_ENABLED" == "True" ]]; then
    get_template "hysteria" | envsubst > ./marznode_data/hysteria.yaml
  fi

  get_template "caddy" | envsubst > ./caddy/Caddyfile
  get_template "confluence_page" | envsubst > ./caddy/templates/index.html

  # Create templates directory for marzneshin
  mkdir -p marzneshin_data/templates/home
  cp ./caddy/templates/index.html ./marzneshin_data/templates/home/index.html

  echo "Marzneshin setup completed"
}

marzneshin_setup

sshd_edit() {
  grep -r Port /etc/ssh -l | xargs -n 1 sed -i -e "/Port /c\Port $SSH_PORT"
  grep -r PasswordAuthentication /etc/ssh -l | xargs -n 1 sed -i -e "/PasswordAuthentication /c\PasswordAuthentication no"
  grep -r PermitRootLogin /etc/ssh -l | xargs -n 1 sed -i -e "/PermitRootLogin /c\PermitRootLogin no"
  systemctl daemon-reload
  systemctl restart ssh
}

add_user() {
  useradd $SSH_USER -s /bin/bash
  usermod -aG sudo $SSH_USER
  echo $SSH_USER:$SSH_USER_PASS | chpasswd
  mkdir -p /home/$SSH_USER/.ssh
  touch /home/$SSH_USER/.ssh/authorized_keys
  echo $input_ssh_pbk >> /home/$SSH_USER/.ssh/authorized_keys
  chmod 700 /home/$SSH_USER/.ssh/
  chmod 600 /home/$SSH_USER/.ssh/authorized_keys
  chown $SSH_USER:$SSH_USER -R /home/$SSH_USER
  usermod -aG docker $SSH_USER
}

if [[ ${configure_ssh_input,,} == "y" ]]; then
  sshd_edit
  add_user
fi

# Configure UFW firewall (full installation - local node, no gRPC port needed externally)
read -ep "Configure UFW firewall? [Y/n]: " configure_ufw_input
if [[ ! "${configure_ufw_input,,}" == "n" ]]; then
  configure_ufw "${SSH_PORT:-22}" "0" "$HYSTERIA_ENABLED" "$XHTTP_ENABLED"
fi

# Create admin and register node
setup_marzneshin_admin() {
  echo "Waiting for Marzneshin to start..."
  sleep 10

  # Create admin user via environment variable (non-interactive)
  docker exec -e MARZBAN_ADMIN_PASSWORD="$MARZNESHIN_PASS" marzneshin \
    python marzneshin-cli.py admin create \
    --username "$ADMIN_USER" \
    --sudo

  echo "Admin user created"

  # Wait for API to be ready
  sleep 5

  # Get auth token (endpoint is /api/admins/token)
  TOKEN=$(curl -s -X POST "http://127.0.0.1:8000/api/admins/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=$ADMIN_USER&password=$MARZNESHIN_PASS" | jq -r '.access_token')

  if [ "$TOKEN" != "null" ] && [ -n "$TOKEN" ]; then
    # Register local node
    curl -s -X POST "http://127.0.0.1:8000/api/nodes" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"name": "Local", "address": "127.0.0.1", "port": 53042}' > /dev/null

    echo "Local node registered"
  else
    echo "Warning: Could not get auth token. Please register the node manually in the dashboard."
  fi
}

end_script() {
  # Format Caddyfile
  docker run -v /opt/marzneshin-vps-setup/caddy/Caddyfile:/opt/Caddyfile --rm caddy caddy fmt --overwrite /opt/Caddyfile

  # Create certificate directory (will be populated by Caddy)
  mkdir -p "/opt/marzneshin-vps-setup/caddy/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$VLESS_DOMAIN"

  # Start Caddy first to obtain certificates
  echo "Starting Caddy to obtain Let's Encrypt certificates..."
  docker compose -f /opt/marzneshin-vps-setup/docker-compose.yml up -d caddy

  # Wait for certificates
  echo "Waiting for certificates (max 120 seconds)..."
  CERT_PATH="/opt/marzneshin-vps-setup/caddy/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$VLESS_DOMAIN/$VLESS_DOMAIN.crt"
  for i in {1..24}; do
    if [ -f "$CERT_PATH" ]; then
      echo "Certificate obtained"
      break
    fi
    echo "  Waiting... ($((i*5))s)"
    sleep 5
  done

  if [ ! -f "$CERT_PATH" ]; then
    echo "Warning: Certificate not found after 120s."
    echo "Check Caddy logs: docker logs caddy"
  fi

  # Start remaining containers
  docker compose -f /opt/marzneshin-vps-setup/docker-compose.yml up -d

  # Setup admin and register node
  setup_marzneshin_admin

  # Cleanup
  docker rmi ghcr.io/xtls/xray-core:latest caddy:latest 2>/dev/null || true

  clear

  echo "=============================================="
  echo "       Marzneshin Installation Complete"
  echo "=============================================="
  echo ""
  echo "Dashboard URL: https://$VLESS_DOMAIN/$DASHBOARD_PATH/"
  echo "Username: $ADMIN_USER"
  echo "Password: $MARZNESHIN_PASS"
  echo ""
  echo "=== Inbounds ==="
  echo "VLESS TCP Reality (TCP/443):"
  echo "  Tag: VLESS-TCP-Reality"
  echo "  Reality Public Key: $XRAY_PBK"
  echo "  Reality Short ID: $XRAY_SID"
  echo ""
  if [[ "$XHTTP_ENABLED" == "True" ]]; then
    echo "VLESS XHTTP Reality (TCP/8443):"
    echo "  Tag: VLESS-XHTTP-Reality"
    echo "  Path: $XHTTP_PATH"
    echo "  Reality Public Key: $XRAY_PBK"
    echo "  Reality Short ID: $XRAY_SID"
    echo ""
  fi
  if [[ "$HYSTERIA_ENABLED" == "True" ]]; then
    echo "Hysteria2 (UDP/8443):"
    echo "  Tag: hysteria2"
    echo "  Obfs Password: $HYSTERIA_OBFS_PASSWORD"
  fi
  echo ""

  if [[ ${configure_ssh_input,,} == "y" ]]; then
    echo "SSH Access:"
    echo "  User: $SSH_USER"
    echo "  Password: $SSH_USER_PASS"
    echo "  Port: $SSH_PORT"
    echo ""
  fi

  echo "Installation directory: /opt/marzneshin-vps-setup"
  echo "=============================================="
}

end_script
set +e

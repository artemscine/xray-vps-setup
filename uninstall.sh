#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
  echo_error "Please run as root"
  exit 1
fi

echo ""
echo "=============================================="
echo "       Marzneshin VPS Uninstall Script"
echo "=============================================="
echo ""

# Detect installation type
FULL_INSTALL=false
NODE_INSTALL=false

if [ -d "/opt/marzneshin-vps-setup" ]; then
  FULL_INSTALL=true
  echo_info "Detected: Full installation (Panel + Node)"
fi

if [ -d "/opt/marznode" ]; then
  NODE_INSTALL=true
  echo_info "Detected: Node-only installation"
fi

if [ "$FULL_INSTALL" = false ] && [ "$NODE_INSTALL" = false ]; then
  echo_warn "No Marzneshin installation detected."
  echo "Expected directories:"
  echo "  - /opt/marzneshin-vps-setup (full installation)"
  echo "  - /opt/marznode (node-only installation)"
  read -ep "Continue anyway to clean up other components? [y/N]: " continue_anyway
  if [[ ! "${continue_anyway,,}" == "y" ]]; then
    exit 0
  fi
fi

echo ""
echo "This script will remove:"
echo "  - Docker containers (marzneshin, marznode, caddy)"
echo "  - Installation directories and all data"
echo "  - UFW rules added by installer"
echo ""
echo -e "${RED}WARNING: This will delete all VPN user data and configurations!${NC}"
echo ""
read -ep "Are you sure you want to continue? [y/N]: " confirm
if [[ ! "${confirm,,}" == "y" ]]; then
  echo "Aborted."
  exit 0
fi

#####################################
# Stop and remove Docker containers
#####################################
echo ""
echo_info "Stopping Docker containers..."

if [ "$FULL_INSTALL" = true ]; then
  if [ -f "/opt/marzneshin-vps-setup/docker-compose.yml" ]; then
    docker compose -f /opt/marzneshin-vps-setup/docker-compose.yml down --volumes --remove-orphans 2>/dev/null || true
  fi
fi

if [ "$NODE_INSTALL" = true ]; then
  if [ -f "/opt/marznode/docker-compose.yml" ]; then
    docker compose -f /opt/marznode/docker-compose.yml down --volumes --remove-orphans 2>/dev/null || true
  fi
fi

# Remove containers by name if they still exist
for container in marzneshin marznode caddy; do
  if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
    echo_info "Removing container: $container"
    docker rm -f "$container" 2>/dev/null || true
  fi
done

# Remove Docker images
echo_info "Removing Docker images..."
docker rmi ghcr.io/artemscine/marzneshin:latest 2>/dev/null || true
docker rmi ghcr.io/artemscine/marznode:latest 2>/dev/null || true
docker rmi caddy:latest 2>/dev/null || true

#####################################
# Remove installation directories
#####################################
echo ""
echo_info "Removing installation directories..."

if [ "$FULL_INSTALL" = true ] && [ -d "/opt/marzneshin-vps-setup" ]; then
  rm -rf /opt/marzneshin-vps-setup
  echo_info "Removed /opt/marzneshin-vps-setup"
fi

if [ "$NODE_INSTALL" = true ] && [ -d "/opt/marznode" ]; then
  rm -rf /opt/marznode
  echo_info "Removed /opt/marznode"
fi

#####################################
# Reset UFW
#####################################
echo ""
if command -v ufw &> /dev/null; then
  read -ep "Reset UFW firewall rules? [y/N]: " reset_ufw
  if [[ "${reset_ufw,,}" == "y" ]]; then
    echo_info "Resetting UFW..."
    ufw --force reset
    ufw disable
    echo_info "UFW reset and disabled"
  fi
fi

#####################################
# Ask about Docker
#####################################
echo ""
read -ep "Remove Docker completely? [y/N]: " remove_docker
if [[ "${remove_docker,,}" == "y" ]]; then
  echo_info "Removing Docker..."

  # Stop Docker service
  systemctl stop docker 2>/dev/null || true
  systemctl stop docker.socket 2>/dev/null || true

  # Remove Docker packages
  apt remove --purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
  apt autoremove -y 2>/dev/null || true

  # Remove Docker data
  rm -rf /var/lib/docker
  rm -rf /var/lib/containerd
  rm -rf /etc/docker
  rm -f /etc/apt/sources.list.d/docker.list
  rm -f /etc/apt/keyrings/docker.gpg

  echo_info "Docker removed"
else
  echo_info "Docker kept. You can prune unused data with: docker system prune -a"
fi

#####################################
# Cleanup
#####################################
echo ""
echo_info "Running apt cleanup..."
apt autoremove -y 2>/dev/null || true

echo ""
echo "=============================================="
echo "       Uninstallation Complete"
echo "=============================================="
echo ""
echo "Removed components:"
[ "$FULL_INSTALL" = true ] && echo "  - Marzneshin panel installation"
[ "$NODE_INSTALL" = true ] && echo "  - Marznode installation"
echo "  - Docker containers and images"
[[ "${remove_docker,,}" == "y" ]] && echo "  - Docker"
[[ "${reset_ufw,,}" == "y" ]] && echo "  - UFW rules (reset)"
echo ""
echo "=============================================="

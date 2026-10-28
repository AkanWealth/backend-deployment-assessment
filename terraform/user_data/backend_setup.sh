#!/bin/bash
# Backend server bootstrap (Amazon Linux 2): Docker, Docker Compose, Buildx, git.
# Log: /var/log/backend_setup.log
set -euxo pipefail
exec > >(tee -a /var/log/backend_setup.log) 2>&1

COMPOSE_VERSION="v2.32.4"
BUILDX_VERSION="v0.20.1"

# t3.micro has 1 GB RAM; add swap so the Go build does not run out of memory.
if [ ! -f /swapfile ]; then
  dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
fi

yum update -y
yum install -y git

# Docker
amazon-linux-extras install -y docker || yum install -y docker
systemctl enable --now docker
usermod -aG docker ec2-user

# Docker Compose v2 and Buildx as CLI plugins (system-wide)
PLUGIN_DIR=/usr/local/lib/docker/cli-plugins
mkdir -p "$PLUGIN_DIR"
curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
  -o "$PLUGIN_DIR/docker-compose"
curl -fsSL "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-amd64" \
  -o "$PLUGIN_DIR/docker-buildx"
chmod +x "$PLUGIN_DIR/docker-compose" "$PLUGIN_DIR/docker-buildx"

# Also expose the legacy "docker-compose" command.
ln -sf "$PLUGIN_DIR/docker-compose" /usr/local/bin/docker-compose

docker --version
docker compose version
docker buildx version

echo "backend setup complete"

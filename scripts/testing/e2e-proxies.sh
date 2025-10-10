#!/usr/bin/env bash
#
# e2e-proxies.sh
# Host-side caching proxies for Linux packages and container images.
# Works on hosts running Docker and Docker Compose v2+
#
# Usage:
#   ./e2e-proxies.sh start   # starts all proxy containers
#   ./e2e-proxies.sh stop    # stops and removes proxy containers
#   ./e2e-proxies.sh status  # shows running containers

set -euo pipefail

# Directory for proxy data and configuration
BASE_DIR="/srv/e2e-proxies"
mkdir -p "$BASE_DIR"

COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# Create Docker Compose configuration if missing
if [ ! -f "$COMPOSE_FILE" ]; then
  cat > "$COMPOSE_FILE" <<EOF
version: "3.8"

services:
  # APT proxy for Debian/Ubuntu
  apt-cacher-ng:
    image: sameersbn/apt-cacher-ng:latest
    container_name: apt-cacher-ng
    restart: unless-stopped
    ports:
      - "3142:3142"
    volumes:
      - ./apt-cacher-ng/cache:/var/cache/apt-cacher-ng
    networks:
      - proxy_net

  # Squid HTTP cache (general purpose, e.g. Fedora DNF)
  squid:
    image: sameersbn/squid:latest
    container_name: squid-cache
    restart: unless-stopped
    ports:
      - "3128:3128"
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
    volumes:
      - ./squid/cache:/var/spool/squid
      - ./squid/squid.conf:/etc/squid/squid.conf:ro
    networks:
      - proxy_net

  registry-dockerhub:
    image: registry:2
    container_name: registry-dockerhub
    restart: unless-stopped
    ports:
      - "5000:5000"
    volumes:
      - ./registry/dockerhub/config.yml:/etc/docker/registry/config.yml:ro
      - ./registry/dockerhub/cache:/var/lib/registry
    networks:
      - proxy_net

  registry-quay:
    image: registry:2
    container_name: registry-quay
    restart: unless-stopped
    ports:
      - "5001:5000"
    volumes:
      - ./registry/quay/config.yml:/etc/docker/registry/config.yml:ro
      - ./registry/quay/cache:/var/lib/registry
    networks:
      - proxy_net

  registry-k8s:
    image: registry:2
    container_name: registry-k8s
    restart: unless-stopped
    ports:
      - "5002:5000"
    volumes:
      - ./registry/k8s/config.yml:/etc/docker/registry/config.yml:ro
      - ./registry/k8s/cache:/var/lib/registry
    networks:
      - proxy_net

networks:
  proxy_net:
    driver: bridge
EOF

  # Create default Squid config (optimized for .deb/.rpm caching)
  mkdir -p "$BASE_DIR/squid"
  cat > "$BASE_DIR/squid/squid.conf" <<EOF
http_port 3128

cache_dir aufs /var/spool/squid 10000 16 256
cache_swap_low 90
cache_swap_high 95
cache_mem 256 MB

maximum_object_size 1024 MB
minimum_object_size 0 KB

refresh_pattern -i \.deb$  10080 90% 43200
refresh_pattern -i \.udeb$ 10080 90% 43200
refresh_pattern -i \.rpm$  10080 90% 43200
refresh_pattern -i (Release|InRelease|Packages(.gz)?)$ 0 20% 60
refresh_pattern -i (repomd.xml|primary.xml.gz)$ 0 20% 60
refresh_pattern . 0 20% 4320
acl localnet src 172.16.0.0/12
http_access allow localnet
http_access deny all
EOF

  # Create Docker registry proxy config
  mkdir -p "$BASE_DIR/registry/"{dockerhub,quay,k8s}
  cat > "$BASE_DIR/registry/dockerhub/config.yml" <<EOF
version: 0.1
http:
  addr: :5000
proxy:
  remoteurl: https://registry-1.docker.io
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
EOF
  cat > "$BASE_DIR/registry/quay/config.yml" <<EOF
version: 0.1
http:
  addr: :5000
proxy:
  remoteurl: https://quay.io
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
EOF
  cat > "$BASE_DIR/registry/k8s/config.yml" <<EOF
version: 0.1
http:
  addr: :5000
proxy:
  remoteurl: https://registry.k8s.io
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
EOF

  mkdir -p "$BASE_DIR/apt-cacher-ng/cache" "$BASE_DIR/registry/cache" "$BASE_DIR/squid/cache"
fi

compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

case "${1:-}" in
  start)
    echo "[INFO] Starting all proxy containers..."
    compose up -d
    echo "[INFO] All proxies started."
    echo
    echo "Services:"
    echo "  APT proxy:     http://<host-ip>:3142"
    echo "  Fedora proxy:  http://<host-ip>:3128"
    echo "  Registry proxy: http://<host-ip>:5000"
    echo
    echo "For Debian/Ubuntu guests, create /etc/apt/apt.conf.d/01proxy:"
    echo "  Acquire::http::Proxy \"http://<host-ip>:3142\";"
    echo
    echo "For Fedora guests, add to /etc/dnf/dnf.conf:"
    echo "  proxy=http://<host-ip>:3128"
    echo
    echo "For Kubernetes/containerd guests, edit /etc/containerd/config.toml:"
    echo "  [plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"docker.io\"]"
    echo "    endpoint = [\"http://<host-ip>:5000\"]"
    ;;
  stop)
    echo "[INFO] Stopping and removing all proxy containers..."
    compose down
    echo "[INFO] Proxies stopped."
    ;;
  status)
    compose ps
    ;;
  *)
    echo "Usage: $0 {start|stop|status}"
    exit 1
    ;;
esac

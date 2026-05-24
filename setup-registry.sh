#!/bin/bash
# Crea un Docker registry local con auth básica.
# Ejecutar UNA vez en un LXC dedicado (community-scripts/docker.sh, Debian, 5GB disco).
set -euo pipefail

REGISTRY_DIR="/opt/registry"
REGISTRY_PORT="5000"
AUTH_USER="${1:-}"
AUTH_PASS="${2:-}"

if [ -z "$AUTH_USER" ] || [ -z "$AUTH_PASS" ]; then
    echo "Uso: $0 <usuario> <password>"
    echo "Ejemplo: $0 alex mipasswordseguro"
    exit 1
fi

command -v docker >/dev/null || { echo "Docker no instalado."; exit 1; }
apt-get update -qq && apt-get install -y -qq apache2-utils >/dev/null

mkdir -p "$REGISTRY_DIR"/{auth,data}

# Generar htpasswd
htpasswd -Bbn "$AUTH_USER" "$AUTH_PASS" > "$REGISTRY_DIR/auth/htpasswd"
chmod 600 "$REGISTRY_DIR/auth/htpasswd"

# Lanzar registry
docker rm -f registry 2>/dev/null || true
docker run -d \
    --name registry \
    --restart unless-stopped \
    -p "${REGISTRY_PORT}:5000" \
    -v "$REGISTRY_DIR/data:/var/lib/registry" \
    -v "$REGISTRY_DIR/auth:/auth" \
    -e "REGISTRY_AUTH=htpasswd" \
    -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
    -e "REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd" \
    registry:2

LXC_IP=$(hostname -I | awk '{print $1}')

cat <<EOF

============================================================
 Docker Registry desplegado en http://${LXC_IP}:${REGISTRY_PORT}
 Usuario: ${AUTH_USER}
============================================================

PASOS SIGUIENTES:

1. (Recomendado) Asígnale un hostname en tu Unifi, p.ej. 'registry.lan'.
   En todos los hosts cliente, edita /etc/hosts si no usas DNS:
     ${LXC_IP}  registry.lan

2. En CADA LXC que vaya a usar este registry, añade a /etc/docker/daemon.json:
     {
       "insecure-registries": ["${LXC_IP}:${REGISTRY_PORT}", "registry.lan:${REGISTRY_PORT}"]
     }
   Luego: systemctl restart docker

3. Login desde un cliente:
     docker login ${LXC_IP}:${REGISTRY_PORT} -u ${AUTH_USER}

4. Push:
     docker tag mi-imagen:1.0 ${LXC_IP}:${REGISTRY_PORT}/mi-imagen:1.0
     docker push ${LXC_IP}:${REGISTRY_PORT}/mi-imagen:1.0
============================================================
EOF

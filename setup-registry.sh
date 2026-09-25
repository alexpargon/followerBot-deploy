#!/bin/bash
# Crea un Docker registry local con auth básica.
# Ejecutar UNA vez en un LXC dedicado (community-scripts/docker.sh, Debian, 5GB disco).
set -euo pipefail

REGISTRY_DIR="/opt/registry"
REGISTRY_PORT="5000"
AUTH_USER="${1:-}"

# La password NUNCA se pide por argumento de CLI: quedaría visible en el
# historial de bash y en /proc/<pid>/cmdline. Se lee por stdin (oculta).
# Alternativa no-interactiva: SETUP_REGISTRY_PASS='...' ./setup-registry.sh alex
if [ -z "$AUTH_USER" ]; then
    echo "Uso: $0 <usuario>"
    echo "    (la password se pide por stdin, o vía SETUP_REGISTRY_PASS)"
    exit 1
fi

AUTH_PASS="${SETUP_REGISTRY_PASS:-}"
if [ -z "$AUTH_PASS" ]; then
    if [ -t 0 ]; then
        read -rsp "Password para ${AUTH_USER}: " AUTH_PASS; echo
    else
        echo "[!] Sin SETUP_REGISTRY_PASS y sin TTY para pedir la password." >&2
        exit 1
    fi
fi
if [ -z "$AUTH_PASS" ]; then
    echo "[!] Password vacía." >&2
    exit 1
fi

command -v docker >/dev/null || { echo "Docker no instalado."; exit 1; }
apt-get update -qq && apt-get install -y -qq apache2-utils >/dev/null

mkdir -p "$REGISTRY_DIR"/{auth,data}

# Generar htpasswd (-i lee la password por stdin; no pasa el secreto por argv)
printf '%s\n' "$AUTH_PASS" | htpasswd -Bni "$AUTH_USER" > "$REGISTRY_DIR/auth/htpasswd"
chmod 600 "$REGISTRY_DIR/auth/htpasswd"
unset AUTH_PASS

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

   NOTA de confianza: el registry sirve HTTP plano (insecure-registries) y
   auth básica. Aceptable SOLO en LAN de confianza; el secreto de pull de una
   imagen viaja en claro. No exponer este puerto a WAN ni a redes no confiables.

4. Push:
     docker tag mi-imagen:1.0 ${LXC_IP}:${REGISTRY_PORT}/mi-imagen:1.0
     docker push ${LXC_IP}:${REGISTRY_PORT}/mi-imagen:1.0
============================================================
EOF

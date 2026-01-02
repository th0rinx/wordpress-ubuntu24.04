#!/usr/bin/env bash
set -euo pipefail

LOG="/var/log/wordpress-setup.log"
export DEBIAN_FRONTEND=noninteractive

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo "[install] $(date -Is) begin"

MARKER="/var/local/wordpress_docker_installed"
if [[ -f "$MARKER" ]]; then
  echo "[install] SKIP: ya instalado ($MARKER)"
  exit 0
fi

# ===== Base dir: donde vive este install.sh (repo clonado) =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ===== 0) detectar Ubuntu codename =====
. /etc/os-release
CODENAME="${VERSION_CODENAME:-$(lsb_release -sc 2>/dev/null || echo noble)}"
echo "[install] ubuntu codename: $CODENAME"

# ===== 1) update =====
apt-get update -y
apt-get upgrade -y

# ===== 2) Docker Engine + Compose =====
apt-get install -y ca-certificates curl gnupg lsb-release git

install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

docker --version || true

# Fallback: si por algún motivo no existe "docker compose", instala docker-compose legacy
if ! docker compose version >/dev/null 2>&1; then
  echo "[install] docker compose plugin no disponible, instalando docker-compose legacy..."
  apt-get install -y docker-compose
fi

# Helper para usar compose sin importar si es plugin o legacy
compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

# ===== 3) Firewall básico =====
apt-get install -y ufw netcat-openbsd

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 8888/tcp     # WordPress
ufw allow 8081/tcp     # phpMyAdmin
ufw --force enable
ufw status verbose || true

# ===== 4) Validaciones =====
[[ -f docker-compose.yml ]] || { echo "[install] docker-compose.yml no encontrado"; exit 1; }
[[ -f .env ]] || { echo "[install] .env no encontrado"; exit 1; }

# ===== 5) Levantar stack con 1 intento de auto-reparación de DB =====
echo "[install] pull imágenes"
compose pull

start_stack() {
  echo "[install] up -d"
  compose up -d
  compose ps || true
}

mysql_looks_bad() {
  # Señales típicas de inicialización inconsistente (como tu ERROR 1045)
  docker logs --tail 200 wp-db 2>/dev/null | grep -Eq \
    "Access denied for user 'root'@'localhost'|initialize-insecure|empty password"
}

wait_mysql_healthy() {
  echo "[install] esperando wp-db healthy..."
  for i in $(seq 1 90); do
    status="$(docker inspect -f '{{.State.Health.Status}}' wp-db 2>/dev/null || true)"
    if [[ "$status" == "healthy" ]]; then
      echo "[install] wp-db healthy"
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_wordpress() {
  echo "[install] esperando WordPress en http://127.0.0.1:8888/wp-login.php ..."
  for i in $(seq 1 90); do
    if curl -fsS "http://127.0.0.1:8888/wp-login.php" >/dev/null 2>&1; then
      echo "[install] WordPress OK"
      return 0
    fi
    sleep 2
  done
  return 1
}

start_stack

# Espera MySQL; si no queda healthy o los logs muestran inconsistencia → reset 1 vez
if ! wait_mysql_healthy || mysql_looks_bad; then
  echo "[install] detecté MySQL inconsistente o no-healthy. Reseteando volumen de DB (VPS nuevo) y reintentando 1 vez..."
  compose down -v || true
  rm -rf ./data/wp-db || true
  start_stack
  wait_mysql_healthy
fi

# Si WordPress no levanta, falla el script (NO marca instalado)
if ! wait_wordpress; then
  echo "[install] ERROR: WordPress no respondió. Logs:"
  compose ps || true
  docker logs --tail 200 wp-db || true
  docker logs --tail 200 wp || true
  docker logs --tail 200 pma || true
  exit 1
fi

# ===== 6) Marcar instalado solo si está OK =====
mkdir -p /var/local
date -Iseconds > "$MARKER"
echo "[install] done. Marker: $MARKER"
echo "[install] WordPress: http://<IP_PUBLICA>:8888"
echo "[install] phpMyAdmin: http://<IP_PUBLICA>:8081"

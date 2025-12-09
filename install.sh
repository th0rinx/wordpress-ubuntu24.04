#!/usr/bin/env bash
set -euo pipefail

# ===== Configurables =====
NPM_IP="${NPM_IP:-34.118.175.190}"    # IP pública de TU NPM (ajustar)
SSH_PORT="${SSH_PORT:-22}"            # puerto SSH
BIND_IP="${BIND_IP:-0.0.0.0}"         # en compose, puerto 5678 escucha en esta IP del host

LOG="/var/log/n8n-host-setup.log"
export DEBIAN_FRONTEND=noninteractive

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo "[install] $(date -Is) begin"

# ===== 0) detectar Ubuntu codename (jammy/noble, etc.) =====
. /etc/os-release
CODENAME="${VERSION_CODENAME:-$(lsb_release -sc 2>/dev/null || echo jammy)}"
echo "[install] ubuntu codename: $CODENAME"

# ===== 1) actualizar sistema =====
apt-get update -y
apt-get -y upgrade

# ===== 2) Docker Engine + compose plugin =====
apt-get install -y ca-certificates curl gnupg lsb-release
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker --version
docker compose version

# (opcional) permitir docker sin sudo al usuario conectado
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  usermod -aG docker "$SUDO_USER" || true
  echo "[install] agregado $SUDO_USER al grupo docker"
fi

# ===== 3) Firewall UFW (host) =====
apt-get install -y ufw
ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow "${SSH_PORT}"/tcp
# n8n solo desde NPM
ufw allow from "${NPM_IP}"/32 to any port 5678 proto tcp

# habilitar UFW (no corta la conexión si la regla de SSH ya está)
ufw --force enable
ufw status verbose

# Reglas extra en DOCKER-USER para que Docker no “saltee” UFW
# Acepta 5678 sólo desde NPM_IP y cae el resto
iptables -C DOCKER-USER -p tcp --dport 5678 -s "${NPM_IP}" -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -p tcp --dport 5678 -s "${NPM_IP}" -j ACCEPT
iptables -C DOCKER-USER -p tcp --dport 5678 ! -s "${NPM_IP}" -j DROP 2>/dev/null || iptables -I DOCKER-USER -p tcp --dport 5678 ! -s "${NPM_IP}" -j DROP

# ===== 4) Compose: asegurar archivos y levantar =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Verificaciones mínimas
[[ -f docker-compose.yml ]] || { echo "[install] docker-compose.yml no encontrado"; exit 1; }
[[ -f init-data.sh ]] || { echo "[install] init-data.sh no encontrado"; exit 1; }
# Tu .env ya lo tenés; si no existiera, sería recomendable abortar:
# [[ -f .env ]] || { echo "[install] .env no encontrado"; exit 1; }

# (opcional) bind a IP concreta en el compose (si querés evitar 0.0.0.0)
# sed -i "s#^[[:space:]]*- 5678:5678#      - \"${BIND_IP}:5678:5678\"#g" docker-compose.yml

chmod +x init-data.sh
docker compose pull
docker compose up -d

# esperar a que n8n esté escuchando
echo "[install] esperando que n8n escuche en 5678…"
for i in $(seq 1 60); do
  (nc -z 127.0.0.1 5678 && echo "[install] n8n up") && break || sleep 2
done

docker compose ps
echo "[install] done. Acceso local: http://127.0.0.1:5678  (expuesto por NPM/SSL)"

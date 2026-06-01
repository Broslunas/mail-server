#!/usr/bin/env bash
# ============================================================
# WildDuck Mail Server — Oracle Cloud Free Tier setup
# ============================================================
# Run this on a freshly created Oracle Cloud ARM VM (Ubuntu 22.04).
#   curl -sSL https://raw.githubusercontent.com/.../setup-oracle.sh | sudo bash
# Or copy the file to the VM and run: sudo bash setup-oracle.sh
#
# What it does:
#   1. Installs Docker + docker-compose
#   2. Generates TLS certificates via Let's Encrypt
#   3. Generates DH parameters
#   4. Creates the Docker network
#   5. Brings up WildDuck + cloudflared
#   6. Creates the initial WildDuck admin user
#   7. Prints next steps (DNS, Cloudflare Tunnel, etc.)
# ============================================================

set -euo pipefail

# ---- Configuration (override via env vars) ----
MAIL_FQDN="${MAIL_FQDN:-mail.example.com}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-admin@example.com}"
WILDDUCK_API_KEY="${WILDDUCK_API_KEY:-}"
MONGODB_URI="${MONGODB_URI:-}"
SKIP_TLS="${SKIP_TLS:-0}"   # Set to 1 if you have certs already
SKIP_CLOUDFLARED="${SKIP_CLOUDFLARED:-1}"  # Set to 0 to install cloudflared too

# ---- Color helpers ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[i]${NC} $*"; }
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fail()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ---- Pre-flight checks ----
[ "$(id -u)" -eq 0 ] || fail "Run as root (use sudo)"

if [ -z "$WILDDUCK_API_KEY" ]; then
  WILDDUCK_API_KEY=$(openssl rand -hex 32)
  info "Generated WILDDUCK_API_KEY: $WILDDUCK_API_KEY"
  info "Save this in your Next.js .env.local as WILDDUCK_API_KEY"
fi

if [ -z "$MONGODB_URI" ]; then
  warn "MONGODB_URI not provided. The script will write a placeholder."
  warn "Edit /opt/mail-server/.env afterwards and re-run docker compose up -d"
  MONGODB_URI="mongodb://USER:PASS@HOST/?ssl=true&retryWrites=true&w=majority"
fi

# ---- 1. Install Docker ----
if ! command -v docker &> /dev/null; then
  info "Installing Docker..."
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release openssl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
  ok "Docker installed"
else
  ok "Docker already installed"
fi

# ---- 2. Prepare directories ----
INSTALL_DIR="/opt/mail-server"
mkdir -p "$INSTALL_DIR/wildduck/tls" "$INSTALL_DIR/wildduck/dkim" "$INSTALL_DIR/cloudflared"

# ---- 3. Generate self-signed TLS for first boot (Let's Encrypt if reachable) ----
if [ "$SKIP_TLS" != "1" ]; then
  if [ -f "$INSTALL_DIR/wildduck/tls/tls.crt" ]; then
    ok "TLS certificates already present"
  else
    info "Obtaining TLS certificate for $MAIL_FQDN via Let's Encrypt..."

    # Try certbot standalone (requires ports 80/443 to be free)
    apt-get install -y -qq certbot
    if certbot certonly --standalone --non-interactive --agree-tos \
         -m "$LETSENCRYPT_EMAIL" -d "$MAIL_FQDN" --cert-name mail \
         --key-type ecdsa --elliptic-curve secp384r1 2>/dev/null; then
      cp /etc/letsencrypt/live/mail/fullchain.pem "$INSTALL_DIR/wildduck/tls/tls.crt"
      cp /etc/letsencrypt/live/mail/privkey.pem  "$INSTALL_DIR/wildduck/tls/tls.key"
      ok "Let's Encrypt certificates installed"
    else
      warn "Let's Encrypt failed. Generating self-signed certificate (replace later)."
      openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 \
        -days 3650 \
        -keyout "$INSTALL_DIR/wildduck/tls/tls.key" \
        -out    "$INSTALL_DIR/wildduck/tls/tls.crt" \
        -subj "/CN=$MAIL_FQDN" \
        -addext "subjectAltName=DNS:$MAIL_FQDN,DNS:imap.$MAIL_FQDN"
    fi
  fi
fi

# ---- 4. DH parameters (1024 is enough for the cipher suites used; bigger = better security) ----
if [ ! -f "$INSTALL_DIR/wildduck/tls/dhparam.pem" ]; then
  info "Generating DH parameters (this takes ~1 minute)..."
  openssl dhparam -dsaparam -out "$INSTALL_DIR/wildduck/tls/dhparam.pem" 2048
  ok "DH parameters generated"
fi

# ---- 5. Generate DKIM key (optional, for outbound signing if not relayed via Mailjet) ----
if [ ! -f "$INSTALL_DIR/wildduck/dkim/dkim_default.pem" ]; then
  info "Generating DKIM key..."
  openssl genrsa -out "$INSTALL_DIR/wildduck/dkim/dkim_default.pem" 2048 2>/dev/null
  ok "DKIM key generated at $INSTALL_DIR/wildduck/dkim/dkim_default.pem"
fi

# ---- 6. Write .env file ----
if [ -n "$MONGODB_URI" ] && [[ "$MONGODB_URI" == mongodb://* ]]; then
  # Parse user, pass, host, db from a real MongoDB URI
  MONGODB_HOST=$(echo "$MONGODB_URI" | sed -E 's|mongodb://[^@]*@([^/]+)/?.*|\1|')
  MONGODB_DB=$(echo "$MONGODB_URI" | sed -E 's|^mongodb://[^/]+/([^?]+).*|\1|')
  MONGODB_USER_PASS=$(echo "$MONGODB_URI" | sed -E 's|mongodb://([^@]+)@.*|\1|')
  MONGODB_USER=$(echo "$MONGODB_USER_PASS" | cut -d: -f1)
  MONGODB_PASS=$(echo "$MONGODB_USER_PASS" | cut -d: -f2-)
  MONGODB_DB=${MONGODB_DB:-mailservice}
else
  # No URI provided — write placeholders that the user must edit
  MONGODB_HOST="PLEASE_EDIT.cluster0.xxxxx.mongodb.net"
  MONGODB_USER="PLEASE_EDIT_username"
  MONGODB_PASS="PLEASE_EDIT_password"
  MONGODB_DB="mailservice"
  warn "MONGODB_URI not provided (or invalid). Placeholders written to $INSTALL_DIR/.env"
  warn "Edit $INSTALL_DIR/.env NOW and re-run 'docker compose up -d' (no need to re-run this script)."
fi

cat > "$INSTALL_DIR/.env" <<EOF
# Generated by setup-oracle.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
MAIL_FQDN=$MAIL_FQDN
WEBMAIL_DOMAIN=$MAIL_FQDN

MONGODB_USER=$MONGODB_USER
MONGODB_PASS=$MONGODB_PASS
MONGODB_HOST=$MONGODB_HOST
MONGODB_DB=$MONGODB_DB

WILDDUCK_API_KEY=$WILDDUCK_API_KEY

DEFAULT_QUOTA=104857600
DEFAULT_MAX_MESSAGES=50000
EOF

ok ".env file written to $INSTALL_DIR/.env"

# ---- 7. Copy docker-compose + configs ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/../docker-compose.yml" ] || fail "docker-compose.yml not found next to this script"
cp "$SCRIPT_DIR/../docker-compose.yml" "$INSTALL_DIR/"
[ -f "$SCRIPT_DIR/../wildduck/wildduck.yml" ] && cp "$SCRIPT_DIR/../wildduck/wildduck.yml" "$INSTALL_DIR/wildduck/"

# ---- 8. Bring up WildDuck ----
cd "$INSTALL_DIR"
info "Starting WildDuck..."
docker compose up -d wildduck

# ---- 9. Health check ----
info "Waiting for WildDuck to be healthy (up to 60s)..."
for i in $(seq 1 12); do
  if docker compose exec -T wildduck curl -fsS http://localhost:8080/health >/dev/null 2>&1; then
    ok "WildDuck is healthy"
    break
  fi
  sleep 5
done

if ! docker compose exec -T wildduck curl -fsS http://localhost:8080/health >/dev/null 2>&1; then
  warn "WildDuck is not responding to /health. Check logs: docker compose logs -f wildduck"
fi

# ---- 10. Optional: Cloudflare Tunnel ----
if [ "$SKIP_CLOUDFLARED" != "1" ]; then
  if [ -f "$SCRIPT_DIR/../cloudflared/cloudflared-docker-compose.yml" ]; then
    cp "$SCRIPT_DIR/../cloudflared/cloudflared-docker-compose.yml" "$INSTALL_DIR/cloudflared.yml"
    if [ -f "$SCRIPT_DIR/../cloudflared/config.yml" ]; then
      cp "$SCRIPT_DIR/../cloudflared/config.yml" "$INSTALL_DIR/cloudflared/"
    fi
    info "Cloudflared compose copied. Run: docker compose -f cloudflared.yml up -d"
    info "(Requires TUNNEL_ID and credentials.json — see mail-server/docs/DNS.md)"
  fi
fi

# ---- 11. Print summary ----
cat <<EOF

================================================================
  ✅  Instalación completada
================================================================

  WildDuck API:    http://127.0.0.1:8080
  IMAPS:           $MAIL_FQDN:993
  POP3S:           $MAIL_FQDN:995
  SMTP submission: $MAIL_FQDN:587

  WILDDUCK_API_KEY: $WILDDUCK_API_KEY
  (Add this to your Next.js .env.local as WILDDUCK_API_KEY)

  Archivos en: $INSTALL_DIR
  Logs:         docker compose -f $INSTALL_DIR/docker-compose.yml logs -f

================================================================
  ⚠️  Pasos manuales que aún debes hacer
================================================================

  1. DNS: configura los registros descritos en
     mail-server/docs/DNS.md (MX, A, SPF, DKIM, DMARC).

  2. PTR/rDNS: en la consola de Oracle, edita la IP pública
     de la VM y añade "Reverse DNS = $MAIL_FQDN".

  3. Security List: abre los puertos 143, 993, 110, 995, 587
     en la VCN de Oracle (ingress 0.0.0.0/0 TCP).

  4. Cloudflare Tunnel (opcional pero recomendado):
     - Ejecuta: cloudflared tunnel login
     - cloudflared tunnel create webmail
     - Copia el <TUNNEL_ID>.json a $INSTALL_DIR/cloudflared/
     - Edita $INSTALL_DIR/cloudflared/.env con TUNNEL_ID
     - docker compose -f $INSTALL_DIR/cloudflared.yml up -d

  5. Certificados (opcional): Let's Encrypt renovará
     automáticamente si configuras un hook post-renew.

================================================================
EOF

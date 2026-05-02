#!/usr/bin/env bash
#
# install-kitsu.sh
# One-shot installer for self-hosting Kitsu + Zou on Ubuntu 22.04+
# Based on https://dev.kitsu.cloud/self-hosting/setup.html
#
# Usage:
#   sudo bash install-kitsu.sh
#
# Optional flags:
#   --with-meilisearch    Also install the Meilisearch full-text indexer
#   --domain <name|ip>    Set server_name without prompting
#   --admin-email <addr>  Set admin email without prompting
#   --admin-pass <pw>     Set admin password without prompting
#   --db-pass <pw>        Set Postgres password without prompting (default: auto-generated)
#   --no-prompt           Fail instead of prompting (for fully unattended runs)
#

set -euo pipefail

# ---------- helpers ----------
log()  { printf '\033[1;34m[kitsu-install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[kitsu-install]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[kitsu-install]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root. Try: sudo bash $0"
    fi
}

prompt() {
    # prompt <varname> <message> [default] [silent]
    local __varname=$1 __msg=$2 __default=${3:-} __silent=${4:-}
    if [[ "${NO_PROMPT:-0}" == "1" ]]; then
        die "Missing required value for $__varname (run without --no-prompt or pass the matching flag)"
    fi
    local __input=""
    if [[ "$__silent" == "silent" ]]; then
        read -r -s -p "$__msg: " __input; echo
    else
        if [[ -n "$__default" ]]; then
            read -r -p "$__msg [$__default]: " __input
            __input=${__input:-$__default}
        else
            read -r -p "$__msg: " __input
        fi
    fi
    printf -v "$__varname" '%s' "$__input"
}

# ---------- arg parsing ----------
WITH_MEILI=0
NO_PROMPT=0
DOMAIN=""
ADMIN_EMAIL=""
ADMIN_PASS=""
DB_PASS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-meilisearch) WITH_MEILI=1; shift ;;
        --no-prompt)        NO_PROMPT=1; shift ;;
        --domain)           DOMAIN="$2"; shift 2 ;;
        --admin-email)      ADMIN_EMAIL="$2"; shift 2 ;;
        --admin-pass)       ADMIN_PASS="$2"; shift 2 ;;
        --db-pass)          DB_PASS="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,20p' "$0"; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

require_root

# ---------- preflight ----------
log "Checking OS..."
if ! command -v apt-get >/dev/null 2>&1; then
    die "This script requires Ubuntu (apt-get not found)."
fi

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    log "Detected: $PRETTY_NAME"
fi

# ---------- collect inputs ----------
[[ -z "$DOMAIN"      ]] && prompt DOMAIN      "Server domain name or IP (used in nginx server_name)" "$(hostname -I | awk '{print $1}')"
[[ -z "$ADMIN_EMAIL" ]] && prompt ADMIN_EMAIL "Admin email (login for the first Kitsu user)"
[[ -z "$ADMIN_PASS"  ]] && prompt ADMIN_PASS  "Admin password" "" silent
[[ -z "$DB_PASS"     ]] && DB_PASS=$(openssl rand -hex 16)

SECRET_KEY=$(openssl rand -hex 24)

log "Configuration summary:"
log "  Domain/IP:    $DOMAIN"
log "  Admin email:  $ADMIN_EMAIL"
log "  DB password:  (hidden, $([ -n "$DB_PASS" ] && echo set || echo unset))"
log "  Meilisearch:  $([ "$WITH_MEILI" -eq 1 ] && echo yes || echo no)"

# ---------- 1. system dependencies ----------
log "Installing system packages (this can take a while)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    postgresql postgresql-client postgresql-server-dev-all \
    build-essential redis-server nginx xmlsec1 ffmpeg \
    software-properties-common curl ca-certificates gnupg lsb-release \
    docker.io openssl

# Python 3.12 from deadsnakes
if ! command -v python3.12 >/dev/null 2>&1; then
    log "Adding deadsnakes PPA for Python 3.12..."
    add-apt-repository -y ppa:deadsnakes/ppa
    apt-get update -qq
    apt-get install -y -qq python3.12 python3.12-venv python3.12-dev
fi

systemctl enable --now docker
systemctl enable --now redis-server

# ---------- 2. zou user + dirs ----------
log "Creating zou user and directories..."
if ! id -u zou >/dev/null 2>&1; then
    useradd --home /opt/zou --shell /bin/bash zou
fi

mkdir -p /opt/zou /opt/zou/backups /opt/zou/previews /opt/zou/tmp /opt/zou/logs
chown -R zou:zou /opt/zou
chown -R zou:www-data /opt/zou/previews /opt/zou/tmp
chown zou:zou /opt/zou/logs

# ---------- 3. install zou ----------
if [[ ! -x /opt/zou/zouenv/bin/zou ]]; then
    log "Installing Zou into /opt/zou/zouenv (pip install zou)..."
    python3.12 -m venv /opt/zou/zouenv
    /opt/zou/zouenv/bin/python -m pip install --upgrade pip wheel
    /opt/zou/zouenv/bin/python -m pip install zou
    chown -R zou:zou /opt/zou/zouenv
else
    log "Zou virtualenv already exists, skipping install."
fi

# ---------- 4. postgres (docker) ----------
log "Setting up Postgres container..."
if docker ps -a --format '{{.Names}}' | grep -q '^postgres$'; then
    log "Postgres container already exists; ensuring it's running..."
    docker start postgres >/dev/null
else
    docker pull -q postgres
    docker run --name postgres \
        --restart unless-stopped \
        -p 127.0.0.1:5432:5432 \
        -e POSTGRES_PASSWORD="$DB_PASS" \
        -d postgres >/dev/null
fi

# Wait for postgres to accept connections
log "Waiting for Postgres to be ready..."
for i in {1..30}; do
    if docker exec postgres pg_isready -U postgres >/dev/null 2>&1; then break; fi
    sleep 1
    [[ $i -eq 30 ]] && die "Postgres did not become ready in 30s"
done

# Make sure the password matches even if container already existed
docker exec -e PGPASSWORD="$DB_PASS" postgres \
    psql -U postgres -d postgres \
    -c "ALTER USER postgres WITH PASSWORD '$DB_PASS';" >/dev/null

# Create zoudb if missing
if ! docker exec -e PGPASSWORD="$DB_PASS" postgres \
        psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='zoudb'" \
        | grep -q 1; then
    docker exec -e PGPASSWORD="$DB_PASS" postgres \
        psql -U postgres -c "CREATE DATABASE zoudb;" >/dev/null
    log "Created database zoudb."
else
    log "Database zoudb already exists, skipping."
fi

# ---------- 5. redis (docker) ----------
# The apt redis-server is already running; the docs use docker too.
# We'll use the apt one to avoid port conflict, since it's already on 6379.
# If a docker redis exists from a previous run, leave it alone.
log "Using system Redis (already listening on 6379)."

# ---------- 6. (optional) meilisearch ----------
if [[ "$WITH_MEILI" -eq 1 ]]; then
    log "Setting up Meilisearch container..."
    MEILI_KEY=$(openssl rand -hex 24)
    if ! docker ps -a --format '{{.Names}}' | grep -q '^meilisearch$'; then
        docker pull -q getmeili/meilisearch:v1.8.3
        mkdir -p /opt/zou/meili_data
        docker run --name meilisearch \
            --restart unless-stopped \
            -p 127.0.0.1:7700:7700 \
            -e MEILI_ENV='production' \
            -e MEILI_MASTER_KEY="$MEILI_KEY" \
            -v /opt/zou/meili_data:/meili_data \
            -d getmeili/meilisearch:v1.8.3 >/dev/null
    else
        docker start meilisearch >/dev/null
        # Read existing key from container if we can
        MEILI_KEY=$(docker inspect meilisearch \
            --format '{{range .Config.Env}}{{println .}}{{end}}' \
            | awk -F= '/^MEILI_MASTER_KEY=/{print $2}')
    fi
fi

# ---------- 7. /etc/zou/zou.env ----------
log "Writing /etc/zou/zou.env..."
mkdir -p /etc/zou
cat > /etc/zou/zou.env <<EOF
DB_PASSWORD=$DB_PASS
PREVIEW_FOLDER=/opt/zou/previews
TMP_DIR=/opt/zou/tmp
SECRET_KEY=$SECRET_KEY
EOF

if [[ "$WITH_MEILI" -eq 1 ]]; then
    cat >> /etc/zou/zou.env <<EOF
INDEXER_KEY=$MEILI_KEY
INDEXER_HOST=127.0.0.1
INDEXER_PORT=7700
INDEXER_PROTOCOL=http
EOF
fi

cat >> /etc/zou/zou.env <<'EOF'

# Export them so `. /etc/zou/zou.env` puts them in your shell environment
export DB_PASSWORD SECRET_KEY PREVIEW_FOLDER TMP_DIR
EOF

if [[ "$WITH_MEILI" -eq 1 ]]; then
    echo "export INDEXER_KEY INDEXER_HOST INDEXER_PORT INDEXER_PROTOCOL" >> /etc/zou/zou.env
fi

chmod 640 /etc/zou/zou.env
chown root:zou /etc/zou/zou.env

# ---------- 8. init db + seed data ----------
log "Initializing Zou database tables..."
sudo -u zou bash -c "set -a; . /etc/zou/zou.env; set +a; /opt/zou/zouenv/bin/zou init-db"

log "Seeding Zou with default data..."
sudo -u zou bash -c "set -a; . /etc/zou/zou.env; set +a; /opt/zou/zouenv/bin/zou init-data"

# ---------- 9. gunicorn configs ----------
log "Writing gunicorn configs..."
cat > /etc/zou/gunicorn.py <<'EOF'
accesslog = "/opt/zou/logs/gunicorn_access.log"
errorlog = "/opt/zou/logs/gunicorn_error.log"
workers = 3
worker_class = "gevent"
EOF

cat > /etc/zou/gunicorn-events.py <<'EOF'
accesslog = "/opt/zou/logs/gunicorn_events_access.log"
errorlog = "/opt/zou/logs/gunicorn_events_error.log"
workers = 1
worker_class = "geventwebsocket.gunicorn.workers.GeventWebSocketWorker"
EOF

# ---------- 10. systemd units ----------
log "Writing systemd units..."
cat > /etc/systemd/system/zou.service <<'EOF'
[Unit]
Description=Gunicorn instance to serve the Zou API
After=network.target

[Service]
User=zou
Group=www-data
WorkingDirectory=/opt/zou
Environment="PATH=/opt/zou/zouenv/bin:/usr/bin"
EnvironmentFile=/etc/zou/zou.env
ExecStart=/opt/zou/zouenv/bin/gunicorn -c /etc/zou/gunicorn.py -b 127.0.0.1:5000 zou.app:app
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/zou-events.service <<'EOF'
[Unit]
Description=Gunicorn instance to serve the Zou Events API
After=network.target

[Service]
User=zou
Group=www-data
WorkingDirectory=/opt/zou
Environment="PATH=/opt/zou/zouenv/bin"
EnvironmentFile=/etc/zou/zou.env
ExecStart=/opt/zou/zouenv/bin/gunicorn -c /etc/zou/gunicorn-events.py -b 127.0.0.1:5001 zou.event_stream:app
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# ---------- 11. install Kitsu front-end ----------
if [[ ! -f /opt/kitsu/dist/index.html ]]; then
    log "Downloading Kitsu front-end (latest release)..."
    mkdir -p /opt/kitsu/dist
    KITSU_URL=$(curl -sL https://api.github.com/repos/cgwire/kitsu/releases/latest \
        | grep 'browser_download_url.*kitsu-.*\.tgz' \
        | cut -d : -f 2,3 | tr -d '"' | xargs)
    [[ -z "$KITSU_URL" ]] && die "Could not resolve Kitsu release URL from GitHub."
    curl -fL -o /tmp/kitsu.tgz "$KITSU_URL"
    tar xzf /tmp/kitsu.tgz -C /opt/kitsu/dist/
    rm -f /tmp/kitsu.tgz
else
    log "Kitsu front-end already present, skipping download."
fi

# ---------- 12. nginx ----------
log "Writing nginx site config..."
cat > /etc/nginx/sites-available/zou <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /api {
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Host \$host;
        proxy_pass http://localhost:5000/;
        client_max_body_size 500M;
        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
        send_timeout 600s;
    }

    location /socket.io {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_pass http://localhost:5001;
    }

    location / {
        autoindex on;
        root  /opt/kitsu/dist;
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/zou /etc/nginx/sites-enabled/zou

nginx -t

# ---------- 13. start everything ----------
log "Reloading systemd and starting services..."
systemctl daemon-reload
systemctl enable zou zou-events >/dev/null
systemctl restart zou zou-events
systemctl restart nginx

# ---------- 14. create admin ----------
log "Creating admin user $ADMIN_EMAIL..."
sudo -u zou bash -c "set -a; . /etc/zou/zou.env; set +a; \
    /opt/zou/zouenv/bin/zou create-admin --password '$ADMIN_PASS' '$ADMIN_EMAIL'" \
    || warn "Admin creation reported an error (this is normal if the admin already exists)."

# ---------- 15. (optional) build search index ----------
if [[ "$WITH_MEILI" -eq 1 ]]; then
    log "Building Meilisearch index..."
    sudo -u zou bash -c "set -a; . /etc/zou/zou.env; set +a; \
        /opt/zou/zouenv/bin/zou reset-search-index" || warn "Index build failed; you can re-run later."
fi

# ---------- done ----------
cat <<EOF

============================================================
  Kitsu installation complete!
============================================================

  Open in your browser:  http://$DOMAIN/
  Login email:           $ADMIN_EMAIL
  Login password:        (the one you entered)

  Useful files:
    /etc/zou/zou.env              Environment variables (DB pw, secret key)
    /etc/zou/gunicorn.py          API gunicorn config
    /etc/zou/gunicorn-events.py   Events gunicorn config
    /etc/nginx/sites-available/zou  Nginx site config
    /opt/zou/logs/                Application logs

  Service control:
    sudo systemctl status zou zou-events
    sudo journalctl -u zou -f

  HTTPS reminder:
    This script configures plain HTTP on port 80 to match the
    official docs. For any real deployment, run certbot:
      sudo apt-get install certbot python3-certbot-nginx
      sudo certbot --nginx -d $DOMAIN

============================================================
EOF

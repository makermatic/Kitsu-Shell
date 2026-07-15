#!/usr/bin/env bash
#
# update-kitsu.sh
# Updates an existing Kitsu/Zou installation set up per the old documentation
# (https://zou.cg-wire.com/) — native Postgres via apt, Zou in /opt/zou/zouenv.
#
# Usage:
#   sudo bash update-kitsu.sh                # update both backend and frontend
#   sudo bash update-kitsu.sh --backend-only # just upgrade Zou + migrate DB
#   sudo bash update-kitsu.sh --frontend-only # just refresh Kitsu UI files
#

set -euo pipefail

log()  { printf '\033[1;34m[kitsu-update]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[kitsu-update]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[kitsu-update]\033[0m %s\n' "$*" >&2; exit 1; }

BACKEND=1
FRONTEND=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend-only)  FRONTEND=0; shift ;;
        --frontend-only) BACKEND=0; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
[[ -f /etc/zou/zou.env ]] || die "/etc/zou/zou.env not found — is Kitsu installed?"
[[ -x /opt/zou/zouenv/bin/pip ]] || die "/opt/zou/zouenv not found — is Zou installed?"

# ---------- backend ----------
if [[ "$BACKEND" -eq 1 ]]; then
    log "Upgrading Zou Python package..."
    /opt/zou/zouenv/bin/python -m pip install --upgrade zou

    log "Running database schema migrations..."
    bash -c "set -a; . /etc/zou/zou.env; set +a; /opt/zou/zouenv/bin/zou upgrade-db"

    log "Restarting zou and zou-events services..."
    systemctl restart zou zou-events
fi

# ---------- frontend ----------
if [[ "$FRONTEND" -eq 1 ]]; then
    log "Looking up latest Kitsu front-end release..."
    KITSU_URL=$(curl -sL https://api.github.com/repos/cgwire/kitsu/releases/latest \
        | grep 'browser_download_url.*kitsu-.*\.tgz' \
        | cut -d : -f 2,3 | tr -d '"' | xargs)
    [[ -z "$KITSU_URL" ]] && die "Could not resolve Kitsu release URL from GitHub."

    log "Downloading $KITSU_URL"
    curl -fL -o /tmp/kitsu.tgz "$KITSU_URL"

    log "Replacing /opt/kitsu/dist contents..."
    rm -rf /opt/kitsu/dist
    mkdir -p /opt/kitsu/dist
    tar xzf /tmp/kitsu.tgz -C /opt/kitsu/dist/
    rm -f /tmp/kitsu.tgz

    log "Reloading nginx..."
    nginx -t && systemctl reload nginx
fi

cat <<EOF

============================================================
  Update complete!
============================================================

  Verify services are healthy:
    sudo systemctl status zou zou-events nginx

  Check the API version:
    curl http://localhost:5000/

============================================================
EOF
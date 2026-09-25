# Kitsu-Shell

One-command installer and updater for self-hosting [Kitsu](https://www.cg-wire.com/kitsu) on Ubuntu. Automates the [official documentation](https://dev.kitsu.cloud/self-hosting/setup.html) so you don't have to walk through every step by hand.

Two scripts:

- **`install-kitsu.sh`** — sets up a fresh Ubuntu server end-to-end: Python, Postgres, Redis, Zou (the API), the Kitsu front-end, nginx, systemd services, and an admin user. Total time: ~10-15 minutes.
- **`update-kitsu.sh`** — updates an existing Kitsu install to the latest Zou + Kitsu releases. Safe to re-run whenever a new version drops.

---

## Before you start

You'll need:

1. **A fresh server running Ubuntu 22.04 or newer.** Any cheap VPS works — Vultr, DigitalOcean, Hetzner, Linode all have $5-6/month options that are plenty for testing. Don't run this on a server that's already doing something else; the script assumes a clean box.
2. **SSH access to that server** (root or a user with sudo).
3. **Inbound TCP port 80 open** in the VPS provider's firewall, if your provider has one. The script opens port 80 in the server's own firewall (UFW) for you, but a cloud firewall lives in the provider's dashboard, not on the server, so the script can't touch it. Check the "Firewall" or "Networking" section of your VPS control panel and make sure port 80 is allowed from anywhere. If you skip this step, the install will succeed but your browser won't be able to reach Kitsu.
4. **A terminal.** PowerShell on Windows works fine (`ssh` and `scp` are built in). Terminal on Mac/Linux. WSL also fine.

---

## Install (fresh server)

### 1. SSH into your server

```bash
ssh root@your-server-ip
```

Replace `your-server-ip` with the IP address from your VPS dashboard. First connection will ask you to confirm the host fingerprint — type `yes`.

> **Tip:** run the install inside `tmux` so a flaky connection doesn't kill it halfway through:
> ```bash
> tmux new -s kitsu
> ```
> If you get disconnected, reconnect and `tmux attach -t kitsu` picks up where you left off.

### 2. Download the installer

```bash
curl -fLO https://raw.githubusercontent.com/makermatic/Kitsu-Shell/refs/heads/main/install-kitsu.sh
```

The flags matter. Copy them exactly:
- `-f` fails loudly on HTTP errors instead of saving error pages as your script
- `-L` follows redirects
- `-O` (capital letter O, not zero) saves the file to disk

If you forget the `-O`, curl dumps the script contents into your terminal instead of saving it, and the next step fails with "No such file or directory." Confirm the file landed:

```bash
ls -la install-kitsu.sh
```

Should be ~15KB.

### 3. Run the installer

```bash
sudo bash install-kitsu.sh
```

It'll ask three questions:

1. **Server domain name or IP** — if you have a domain pointed at this server, use it. Otherwise just hit enter to use the server's IP.
2. **Admin email** — the login for the first Kitsu user. Doesn't have to be a real email; Kitsu won't send anything to it. Hit enter to use the default, `adminemail@yourstudio.com`.
3. **Admin password** — you'll type it silently (no echo). This is what you'll use to log into Kitsu. Hit enter to use the default, `1SecretPass`.

> **If you use the defaults, change them right after your first login.** They're published in this README, so anyone who finds your server could try them.

Then walk away for ~10 minutes. Watch the colored `[kitsu-install]` log lines scroll past. When it's done you'll see a big success banner with your login URL.

### 4. Log in

Open a browser on your local machine (not the server) and go to `http://your-server-ip/`. Log in with the email and password you set (or the defaults above, if you hit enter).

---

## Update (existing install)

Once installed, use `update-kitsu.sh` whenever a new Zou or Kitsu release comes out. It follows the [old docs' update procedure](https://zou.cg-wire.com/) — pip upgrade, database migration, service restart, and frontend refresh.

### 1. SSH in and grab the updater

```bash
ssh root@your-server-ip
curl -fLO https://raw.githubusercontent.com/makermatic/Kitsu-Shell/refs/heads/main/update-kitsu.sh
```

### 2. Run it

```bash
sudo bash update-kitsu.sh                  # update both backend and frontend
sudo bash update-kitsu.sh --backend-only   # just Zou + database migrations
sudo bash update-kitsu.sh --frontend-only  # just the Kitsu web UI
```

Takes 1-3 minutes depending on how much has changed. Services restart automatically at the end.

### Manual update (equivalent, from the old docs)

If you'd rather do it by hand or the script doesn't work for you, the equivalent manual steps are:

```bash
# Backend
sudo /opt/zou/zouenv/bin/python -m pip install --upgrade zou
sudo bash -c ". /etc/zou/zou.env && /opt/zou/zouenv/bin/zou upgrade-db"
sudo systemctl restart zou zou-events

# Frontend
sudo rm -rf /opt/kitsu/dist && sudo mkdir -p /opt/kitsu/dist
KITSU_URL=$(curl -sL https://api.github.com/repos/cgwire/kitsu/releases/latest \
  | grep 'browser_download_url.*kitsu-.*\.tgz' | cut -d : -f 2,3 | tr -d '"' | xargs)
sudo curl -fL -o /tmp/kitsu.tgz "$KITSU_URL"
sudo tar xzf /tmp/kitsu.tgz -C /opt/kitsu/dist/
sudo rm /tmp/kitsu.tgz
sudo nginx -t && sudo systemctl reload nginx
```

---

## Troubleshooting

**"No such file or directory" when running the script.**
`curl` didn't actually save the file. Re-check you used `-O` (capital letter O). Run `ls install-kitsu.sh` to confirm before `sudo bash`.

**Install finishes but browser says "can't reach this site" / connection timed out.**
Port 80 is blocked somewhere. A timeout (rather than "connection refused") means a firewall is silently dropping the traffic. Check both layers:

1. **The server's firewall (UFW).** Run `sudo ufw status`. If it says `active` and there's no `80/tcp ALLOW` line, run `sudo ufw allow 80/tcp`. The script does this automatically, but installs made with older versions of the script didn't.
2. **Your VPS provider's firewall.** Check the provider's firewall panel and allow inbound TCP port 80. The script can't touch this layer.

To tell which layer is the problem, run `curl -sI http://localhost/ | head -1` on the server. If that prints `200 OK`, Kitsu itself is fine and it's one of the firewalls.

**Install fails partway through.**
Just re-run `sudo bash install-kitsu.sh`. The script is idempotent — it skips steps that already completed and picks up from where it stopped. That said, if the same step keeps failing on retry, the fastest fix is often destroying the VPS instance and starting fresh on a clean box (costs pennies in prorated billing).

**Checking service status.**

```bash
sudo systemctl status zou zou-events nginx    # green = good, red = broken
sudo journalctl -u zou -n 50                   # last 50 log lines
sudo journalctl -u zou -f                      # live tail (Ctrl+C to exit)
```

**Adding HTTPS.**
The script only sets up plain HTTP on port 80 (matching the official docs). For any real deployment with a domain name:

```bash
sudo apt-get install certbot python3-certbot-nginx
sudo certbot --nginx -d your-domain.com
```

Only works with a real domain pointed at the server, not a raw IP.

---

## What the install script does

1. Installs system packages: Postgres client/dev tools, Redis, nginx, ffmpeg, build tools, Docker, and Python 3.12 (from the deadsnakes PPA on 22.04, or system default on 24.04+).
2. Creates a dedicated `zou` system user and the `/opt/zou/` directory tree.
3. Installs Zou into a Python virtualenv at `/opt/zou/zouenv`.
4. Runs Postgres in a Docker container with an auto-generated random password.
5. Writes `/etc/zou/zou.env` with the DB password and a random `SECRET_KEY` (mode 640, root:zou — not world-readable).
6. Initializes the Zou database schema and seeds default data.
7. Writes gunicorn configs, systemd unit files, and the nginx site config.
8. Downloads the latest Kitsu front-end release from GitHub.
9. Opens ports 22 and 80 in UFW (only adds rules — doesn't enable UFW if it's inactive).
10. Starts everything and creates the admin user.

The full script source is [right here in the repo](install-kitsu.sh) — read through it before running if you want to know exactly what's happening as root on your server.

---

## Files created

| Path | What's in it |
|---|---|
| `/etc/zou/zou.env` | DB password, SECRET_KEY, preview/tmp paths |
| `/etc/zou/gunicorn.py` | API gunicorn worker config |
| `/etc/zou/gunicorn-events.py` | Events gunicorn worker config |
| `/etc/systemd/system/zou.service` | Systemd unit for the API |
| `/etc/systemd/system/zou-events.service` | Systemd unit for the event stream |
| `/etc/nginx/sites-available/zou` | Nginx site config |
| `/opt/zou/zouenv/` | Python virtualenv containing Zou |
| `/opt/zou/previews/` | User-uploaded preview media |
| `/opt/zou/logs/` | Application logs |
| `/opt/kitsu/dist/` | Kitsu front-end static files |

All of these are plain text and editable with `nano`. After editing, restart the affected service:
- `zou.env`, `gunicorn.py`, or `gunicorn-events.py` → `sudo systemctl restart zou zou-events`
- Systemd unit files → `sudo systemctl daemon-reload && sudo systemctl restart zou zou-events`
- Nginx config → `sudo nginx -t && sudo systemctl reload nginx`

---

## Credits

Kitsu is developed by [CGWire](https://www.cg-wire.com/). This installer is just an automation wrapper around their [official self-hosting docs](https://dev.kitsu.cloud/self-hosting/setup.html); all credit for Kitsu itself goes to them.
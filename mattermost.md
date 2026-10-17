# Mattermost on Docker — Ubuntu 24.04 EC2 Deployment

A single-host guide to deploy **Mattermost** using plain **Docker** on one
**Ubuntu 24.04** EC2 instance. Three containers: MySQL + Mattermost + Nginx.

```
[ Browser ] --> [ Nginx :80 ] --> [ Mattermost app :8065 ] --> [ MySQL :3306 ]
```

> **Version note:** Mattermost 10+ dropped MySQL support. This guide pins the app image to
> `mattermost/mattermost-team-edition:9.11` (the last MySQL-capable release). Do **not** use
> `:latest` with MySQL — it fails with *"Must be 'postgres'"*.

---

## 0. What you'll build (folder structure)

On the EC2 host you'll create this small structure under your home directory:

```
~/mattermost/
├── nginx/
│   └── mattermost.conf      # Nginx reverse-proxy config
└── run.sh                   # script that starts all 3 containers
```

That's it — plain Docker needs no more than a config file and a run script.

---

## 1. Create the EC2 instance

AWS Console → **EC2** → **Instances** → **Launch instances**.

| Field | Value |
|-------|-------|
| Name | `mattermost-host` |
| AMI | **Ubuntu Server 24.04 LTS** (x86_64) |
| Instance type | `t3a.medium` (demo) or larger |
| Key pair | Create/select one, e.g. `mattermost-key` → download the `.pem` |
| Root volume | **20 GB gp3** (the 8 GB default fills up fast) |

### Security group (inbound rules)

Create a security group with exactly these rules:

| Type | Protocol | Port | Source | Why |
|------|----------|------|--------|-----|
| SSH | TCP | 22 | **My IP** | So only you can SSH in |
| HTTP | TCP | 80 | `0.0.0.0/0` | Users reach Mattermost via Nginx |
| HTTPS | TCP | 443 | `0.0.0.0/0` | For TLS later (optional now) |

> **Do not** open port 22 to `0.0.0.0/0`. Pick **My IP** in the console.
> On Ubuntu AMIs the SSH user is **`ubuntu`** (not `ec2-user`).

Click **Launch instance**, then copy the instance's **Public IPv4 address**.

---

## 2. Connect to the instance

Run on **your laptop**. Replace `<KEY>.pem` with your key file and `<PUBLIC_IP>` with the instance IP.

```bash
chmod 400 <KEY>.pem
ssh -i <KEY>.pem ubuntu@<PUBLIC_IP>
```

Type `yes` at the host-authenticity prompt the first time.

---

## 3. Install Docker on Ubuntu 24.04

Run everything below **on the EC2 instance** (after SSH). These are the official Docker apt-repo
steps for Ubuntu 24.04.

### Step 1 — Update and install prerequisites

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
```

### Step 2 — Add Docker's official GPG key

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
```

### Step 3 — Add the Docker apt repository

```bash
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

### Step 4 — Install Docker Engine

```bash
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io
```

### Step 5 — Enable Docker and allow your user to run it without sudo

```bash
sudo systemctl enable --now docker
sudo usermod -aG docker ubuntu
```

Now **log out and back in** so the group change applies:

```bash
exit
ssh -i <KEY>.pem ubuntu@<PUBLIC_IP>
```

### Step 6 — Verify Docker

```bash
docker --version
docker run --rm hello-world     # should print "Hello from Docker!"
```

If `hello-world` prints its greeting without `sudo`, Docker is ready.

---

## 4. Create the project folder and config

Run on the EC2 instance.

### Step 1 — Make the folders

```bash
mkdir -p ~/mattermost/nginx
cd ~/mattermost
```

### Step 2 — Create the Nginx config

Open a new file:

```bash
nano ~/mattermost/nginx/mattermost.conf
```

**Copy-paste this content into the file**, then save (in nano: `Ctrl+O`, `Enter`, `Ctrl+X`):

```nginx
upstream mattermost_backend {
    server mattermost-app:8065;
}

server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://mattermost_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

> **Why `mattermost-app`?** Nginx must point at the app **container name**. We name the app
> container `mattermost-app` in the next step, so the upstream must match exactly. A wrong name
> makes Nginx crash with *"host not found in upstream"*.

### Step 3 — Create the run script

Open a new file:

```bash
nano ~/mattermost/run.sh
```

**Copy-paste this content into the file**, then save:

```bash
#!/usr/bin/env bash
# Start Mattermost (MySQL + app + Nginx) as plain Docker containers.
set -euo pipefail

# ---- edit these ----
MYSQL_ROOT_PASSWORD='StrongRoot#2024'
MYSQL_DATABASE='mattermostdb'
MYSQL_USER='mmuser'
MYSQL_PASSWORD='StrongUser#2024'
SITE_URL='http://<PUBLIC_IP>'          # e.g. http://3.110.1.2
MATTERMOST_IMAGE='mattermost/mattermost-team-edition:9.11'
# --------------------

NGINX_CONF="$HOME/mattermost/nginx/mattermost.conf"

echo "==> network + volumes"
docker network inspect mattermost-net >/dev/null 2>&1 || docker network create mattermost-net
for v in mysql-data mm-config mm-data mm-logs mm-plugins; do
  docker volume inspect "$v" >/dev/null 2>&1 || docker volume create "$v"
done

echo "==> MySQL"
docker rm -f mattermost-mysql >/dev/null 2>&1 || true
docker run -d --name mattermost-mysql --network mattermost-net --restart unless-stopped \
  -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  -e MYSQL_DATABASE="$MYSQL_DATABASE" \
  -e MYSQL_USER="$MYSQL_USER" \
  -e MYSQL_PASSWORD="$MYSQL_PASSWORD" \
  -v mysql-data:/var/lib/mysql \
  mysql:8 --character-set-server=utf8mb4 --collation-server=utf8mb4_general_ci

echo "==> waiting for MySQL"
for i in $(seq 1 30); do
  docker exec mattermost-mysql mysqladmin ping -h localhost \
    -p"$MYSQL_ROOT_PASSWORD" --silent >/dev/null 2>&1 && { echo "MySQL ready"; break; }
  echo "waiting... ($i)"; sleep 5
done

echo "==> Mattermost app"
docker rm -f mattermost-app >/dev/null 2>&1 || true
docker run -d --name mattermost-app --network mattermost-net --restart unless-stopped \
  -e MM_SQLSETTINGS_DRIVERNAME=mysql \
  -e MM_SQLSETTINGS_DATASOURCE="${MYSQL_USER}:${MYSQL_PASSWORD}@tcp(mattermost-mysql:3306)/${MYSQL_DATABASE}?charset=utf8mb4,utf8&writeTimeout=30s" \
  -e MM_SERVICESETTINGS_SITEURL="$SITE_URL" \
  -v mm-config:/mattermost/config \
  -v mm-data:/mattermost/data \
  -v mm-logs:/mattermost/logs \
  -v mm-plugins:/mattermost/plugins \
  "$MATTERMOST_IMAGE"

echo "==> Nginx"
docker rm -f mattermost-nginx >/dev/null 2>&1 || true
docker run -d --name mattermost-nginx --network mattermost-net --restart unless-stopped \
  -p 80:80 \
  -v "$NGINX_CONF":/etc/nginx/conf.d/default.conf:ro \
  nginx:stable

echo "==> done"
docker ps --filter "name=mattermost-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

### Step 4 — Edit your values

Open `run.sh` again and set real values for the passwords and, importantly, `SITE_URL`
(use your instance's public IP, e.g. `http://3.110.1.2`):

```bash
nano ~/mattermost/run.sh
```

---

## 5. Run the deployment

```bash
cd ~/mattermost
chmod +x run.sh
./run.sh
```

The script creates the network and volumes, starts MySQL and waits for it, starts the
Mattermost app, then starts Nginx. Expected final output:

```
NAMES              STATUS                   PORTS
mattermost-nginx   Up                       0.0.0.0:80->80/tcp
mattermost-app     Up (health: starting)    8065/tcp
mattermost-mysql   Up                       3306/tcp
```

Give the app ~30–60 seconds; `mattermost-app` moves from `health: starting` to `healthy`.

---

## 6. Access the UI and verify

### On the EC2 host

```bash
docker ps --filter name=mattermost-
curl -I http://localhost        # expect: HTTP/1.1 200 OK
```

### From your browser

```
http://<PUBLIC_IP>
```

You should see the Mattermost setup page. Create the first **admin account** (email +
password), name your team, and you're in.

---

## 7. Checks (EC2 / security group)

If the browser can't load but `curl http://localhost` works on the host, the **security group**
is the problem — port 80 isn't open.

**In the console:** EC2 → Instances → select instance → **Security** tab → click the security
group → **Inbound rules** → confirm HTTP 80 from `0.0.0.0/0` exists. If not, **Edit inbound
rules** → **Add rule** → Type `HTTP`, Source `0.0.0.0/0` → **Save**.

**From the CLI (optional):**

```bash
# which SG is attached to the instance
aws ec2 describe-instances --instance-ids <i-xxxx> \
  --query 'Reservations[0].Instances[0].SecurityGroups' --output table

# list that SG's inbound rules
aws ec2 describe-security-groups --group-ids <sg-xxxx> \
  --query 'SecurityGroups[0].IpPermissions' --output table
```

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| App container `Restarting`, log says *"Must be 'postgres'"* | Image is v10+ (dropped MySQL) | Use `mattermost/mattermost-team-edition:9.11` |
| `nginx Restarting`, `curl localhost` refused | upstream name doesn't match app container | Upstream must be `mattermost-app:8065` |
| App log: *"Failed to ping DB ... connection refused"* | MySQL still booting (first ~10s) | Harmless — the app retries and connects |
| Browser can't reach, host `curl` works | SG blocks port 80 | Add inbound HTTP 80 from `0.0.0.0/0` |
| `permission denied` on docker | group change not applied | Log out and SSH back in after `usermod -aG docker ubuntu` |
| Out of disk space | 8 GB root volume | Resize EBS to 20 GB+ and reboot |

**Inspect logs:**

```bash
docker logs mattermost-app   | tail -n 40    # app startup + DB connect
docker logs mattermost-nginx                 # nginx errors
docker logs mattermost-mysql | tail -n 20    # database
```

---

## 9. Manage / remove

```bash
# restart everything
cd ~/mattermost && ./run.sh

# stop (keep data)
docker stop mattermost-nginx mattermost-app mattermost-mysql

# start again
docker start mattermost-mysql mattermost-app mattermost-nginx

# remove containers (keep data volumes)
docker rm -f mattermost-nginx mattermost-app mattermost-mysql

# DANGER: delete all data too
docker volume rm mysql-data mm-config mm-data mm-logs mm-plugins
```

> Back up the `mysql-data` volume before deleting volumes on a real deployment.

---

## Summary

1. Launch an Ubuntu 24.04 EC2 host; open ports 22 (your IP), 80, 443.
2. Install Docker from the official apt repo.
3. Create `~/mattermost/nginx/mattermost.conf` and `~/mattermost/run.sh` (copy-paste the content above).
4. Set passwords + `SITE_URL`, then `./run.sh`.
5. Open `http://<PUBLIC_IP>` and create the admin account.

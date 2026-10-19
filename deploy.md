# Deployment Guide

This repository is served as a static site from a Docker container on a cloud VM. Two environments run it, each from its own repository and its own VM:

| | Production | Staging |
|---|---|---|
| Homepage and dashboard | `https://insights.cppalliance.org/` and `/boost/` | `https://staging.insights.cppalliance.org/` and `/boost/` |
| Repository | `cppalliance/boost-usage-dashboard` | `wpak-ai/boost-usage-dashboard` |
| Data written by | the production collector | the staging collector |
| Search engines | allowed | blocked (`X-Robots-Tag` header, and `robots.txt` disallows everything) |
| `LIVE_URL` variable | `https://insights.cppalliance.org/boost` | `https://staging.insights.cppalliance.org/boost` |

A merge in one repository never touches the other environment. Both repositories carry the same code and documentation; only the generated data (`develop/`) differs.

## Overview

```
Push to main
  └── deploy.yml  →  SSH into the VM  →  git pull in /opt/boost  →  nginx container serves the updated files
```

The site content lives in a git clone at `/opt/boost` on the VM. An nginx Docker container bind-mounts that directory read-only, so a `git pull` is all that is needed to deploy content changes: no image rebuild and no container restart. Only `Dockerfile`, `nginx.conf` and `docker-compose.yml` need a rebuild, and `deploy.yml` does that automatically (Part 4).

Two more workflows keep the data current:

- `boost-release.yml` runs daily at 05:00 UTC. When Boost publishes a new release it copies `develop/` to `vX.YY/`, rewrites `versions.json`, commits and pushes. A push made with the workflow's own token does not start `deploy.yml`, so the new folder goes live with the next data push or after a manual deploy (Actions → Deploy to GCP → Run workflow).
- `check-freshness.yml` runs daily at 06:30 UTC and fails when the newest commit touching `develop/`, or the live `develop/index.html`, is more than 72 hours old.

---

## Repository Files

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the `nginx:alpine` image with the custom nginx config |
| `nginx.conf` | Container-internal nginx config: two virtual hosts, the dashboard (repository root) and the homepage (`home/`) |
| `docker-compose.yml` | Defines the `boost-site` container, its port mapping and the read-only bind mount of `/opt/boost` |
| `.github/workflows/deploy.yml` | CD workflow: SSHs into the VM and runs `git pull` on every push to `main` |
| `.github/workflows/boost-release.yml` | Snapshots `develop/` into a version folder when Boost releases |
| `.github/workflows/check-freshness.yml` | Daily alarm when the dashboard stops updating |
| `.github/scripts/verify-host.sh` | Checks a live host against the rollout matrix (Part 5) |
| `index.html` | Version selector at `/boost/`; reads `versions.json` |
| `versions.json` | The version folders the selector shows, newest first |
| `home/` | The Insights homepage, served at the host root through a second nginx virtual host (see Part 3b) |
| `develop/`, `vX.YY/` | Generated dashboards. `develop/` is rewritten by the collector's nightly publish |

---

## Part 1 — GitHub Repository Configuration

### 1.1 Repository secrets

Go to **Settings → Secrets and variables → Actions → New repository secret** and add:

| Secret name | Value |
|---|---|
| `SERVER_HOST` | Address of this environment's VM (the production VM in the production repository, the staging VM in the staging repository) |
| `SERVER_USER` | SSH user on that VM |
| `SERVER_SSH_KEY` | Full contents of the private SSH key (the matching public key must be in `~/.ssh/authorized_keys` of that user on that VM) |

Each repository must point at its own environment's VM. A deploy that reaches the wrong VM still ends green, so Part 4 explains how to check it.

### 1.2 Repository variable

Go to **Settings → Secrets and variables → Actions → Variables → New repository variable** and add `LIVE_URL`: the public base of this environment's dashboard without a trailing slash (see the table at the top). `check-freshness.yml` uses it to check the live host; without it that half of the check only warns.

### 1.3 Merge settings

Go to **Settings → General → Pull Requests**, allow only **Rebase and merge**, and turn off merge commits and squash merging. History must stay linear.

---

## Part 2 — VM Setup (one-time)

SSH into the VM and run the following commands once to prepare the environment.

### 2.1 Install Docker and Docker Compose

If not already installed:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

Verify:

```bash
docker --version
docker compose version
```

### 2.2 Clone the repository

Clone this environment's repository into `/opt/boost` over SSH, as the account that `deploy.yml` logs in as. That account's SSH key must be accepted by GitHub; the repositories are public, so any registered key can read them.

```bash
sudo mkdir /opt/boost
sudo chown $USER:$USER /opt/boost

# production
git clone git@github.com:cppalliance/boost-usage-dashboard.git /opt/boost
# staging
git clone git@github.com:wpak-ai/boost-usage-dashboard.git /opt/boost
```

### 2.3 Set permissions

The `git pull` that `deploy.yml` runs is done by your SSH user, who owns the clone, so no `sudo` is needed. The nginx worker in the container runs as UID 101 and reads the bind mount as "other", so the files must be world-readable:

```bash
find /opt/boost -type d -exec chmod 755 {} \;
find /opt/boost -type f -exec chmod 644 {} \;
```

### 2.4 Build and start the container

```bash
cd /opt/boost
docker compose up -d --build
```

### 2.5 Verify the container is serving

```bash
curl http://localhost:9102/
```

You should receive the HTML content of `index.html`. If you see an nginx error page, check `docker logs boost-site`.

---

## Part 3 — Host nginx Configuration (one-time)

The VM runs a host-level nginx that routes subdirectory requests to individual services. Inside the `server` block for this environment's host name (the one that listens on 443), add a `location` block for `/boost/`:

```nginx
location /boost/ {
    proxy_pass http://127.0.0.1:9102/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

The trailing slash on `proxy_pass` causes nginx to strip the `/boost/` prefix before forwarding requests to the container. All internal HTML links in this repository use relative paths, so no URL rewriting is needed.

Test and reload:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

Verify end-to-end from your local machine (use the production host name for production):

```bash
curl -I https://staging.insights.cppalliance.org/boost/
```

---

## Part 3b — Homepage at the host root (one-time per host)

The repository also holds a small homepage in `home/`. It is served at the root of each host (`https://insights.cppalliance.org/` and `https://staging.insights.cppalliance.org/`) and never under `/boost/`.

```
host nginx
  = /    ^~ /assets/    = /robots.txt  →  127.0.0.1:9102, Host: insights-home.internal  →  container virtual host "home"     →  /usr/share/nginx/html/home
  /boost/                               →  127.0.0.1:9102, Host: $host (as in Part 3)    →  container default virtual host  →  /usr/share/nginx/html
```

- `nginx.conf` defines two virtual hosts. The default one serves the repository root as before and answers 404 for `/home/`. The second one, `insights-home.internal`, serves `home/` and answers only for `/`, `/assets/` and `/robots.txt`.
- The homepage's response headers (cache, `nosniff`, referrer policy, `frame-ancestors`) are set in `nginx.conf`, so the host nginx needs no `add_header` lines of its own for them.
- Do not change `proxy_set_header Host $host` in the `/boost/` block. A client that forges `Host: insights-home.internal` can make the host nginx show it the homepage at `/boost/`. That client sees only public content.

Add these blocks inside the same `server` block as the `/boost/` block (the one that listens on 443):

```nginx
location = / {
    proxy_pass http://127.0.0.1:9102;
    proxy_set_header Host insights-home.internal;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}

location ^~ /assets/ {
    proxy_pass http://127.0.0.1:9102;
    proxy_set_header Host insights-home.internal;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}

location = /robots.txt {
    proxy_pass http://127.0.0.1:9102;
    proxy_set_header Host insights-home.internal;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

- `proxy_pass` has no URI part, so nginx forwards the original path unchanged. This differs from `/boost/`, which strips its prefix.
- `=` and `^~` locations win over regex locations, so a rule such as `location ~* \.(css|js)$` cannot intercept `/assets/`.
- Nothing else may use `/assets/` or `/robots.txt` at the host root.
- `add_header` is only inherited into a location that has none of its own. If the `server` block sets headers such as `Strict-Transport-Security`, repeat them in the first two blocks.

Staging only, to keep it out of search results: add `add_header X-Robots-Tag "noindex, nofollow" always;` to the first two blocks, and replace the `/robots.txt` block with:

```nginx
location = /robots.txt {
    default_type text/plain;
    return 200 "User-agent: *\nDisallow: /\n";
}
```

Order of steps for a host:

1. Merge the change to `main`. `deploy.yml` pulls it and, because `nginx.conf` changed, rebuilds the container.
2. On the VM, check the container before touching the host nginx:
   ```bash
   curl -s -H 'Host: insights-home.internal' http://127.0.0.1:9102/ | grep -o '<title>[^<]*</title>'   # C++ Alliance Insights
   curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9102/home/                               # 404
   docker exec boost-site nginx -t                                                                   # syntax is ok
   ```
3. Back up the nginx file, add the blocks above, then `sudo nginx -t && sudo systemctl reload nginx`.
4. From outside, run the checker (Part 5) for that environment.

Rollback: remove the three blocks and reload nginx; the default page returns. To remove the container side as well, revert the commit and let `deploy.yml` rebuild.

---

## Part 4 — Continuous Deployment

After the one-time setup above, all future deployments are automatic.

### How deploy.yml works

On every push to `main` (or manual dispatch), the workflow SSHs into the VM and runs:

```bash
cd /opt/boost
git fetch origin main
CHANGED=$(git diff HEAD origin/main --name-only)
git pull origin main
if echo "$CHANGED" | grep -qE "^(Dockerfile|nginx\.conf|docker-compose\.yml)$"; then
  docker compose up -d --build
fi
```

- **Content changes** (HTML files, JSON data): `git pull` updates files on disk; the container's bind mount reflects changes immediately. No restart needed.
- **Infrastructure changes** (`Dockerfile`, `nginx.conf`, `docker-compose.yml`): the container is rebuilt and recreated automatically. `/boost/` and `/` answer 502 for a few seconds while that happens.

### Check that a deploy reached the right VM

A deploy that SSHes into the wrong VM still ends green. In the "Pull and optionally restart" step of the run log, the `git fetch` and `git pull` lines must say `From github.com:<owner>/<repo>` with this repository's name. If they name the other repository, `SERVER_HOST`, `SERVER_USER` or `SERVER_SSH_KEY` in this repository points at the wrong VM.

### When the rebuild fails

The rebuild only happens when the difference between `HEAD` and `origin/main` lists `Dockerfile`, `nginx.conf` or `docker-compose.yml`. If the pull succeeds but `docker compose up -d --build` fails, re-running the workflow finds nothing left to rebuild. Fix the cause, then run this on the VM:

```bash
cd /opt/boost && docker compose up -d --build
```

### Timing

`deploy.yml` has no concurrency guard. Do not start a deploy while another one is running, and avoid 02:30 to 03:30 UTC, when the nightly publish pushes and deploys.

---

## Part 5 — Validation Checklist

After a change, check the environment:

1. Run the checker. It must end with `0 failed`:
   ```bash
   .github/scripts/verify-host.sh https://insights.cppalliance.org production --neighbours
   .github/scripts/verify-host.sh https://staging.insights.cppalliance.org staging --neighbours
   ```
   It needs only bash and curl (jq is optional) and covers the homepage and its headers, every version folder in `versions.json`, the paths that must stay private, the search engine settings and the other services behind the same nginx.
2. A content-only push (for example a data commit in `develop/`) starts `deploy.yml` and finishes in about 10 to 30 seconds, with no container recreate in the log.
3. Open the host root and `/boost/` in a browser. The homepage links to `/boost/` and `/weblate/`; the selector lists Development and every version in `versions.json`; `/boost/home/` returns 404.
4. Run **Actions → Deploy to GCP → Run workflow** once. With no new commits it is a no-op.
5. Run **Actions → Check dashboard freshness → Run workflow**. It must end green.

---

## Part 6 — Making a change

Code and documentation live in both repositories and must stay identical.

1. Cut a branch from the repository's own `main`. Never open a pull request from the staging repository's `main` into production: it holds staging data and would carry it along.
2. Commit once, then mirror the commits into the other repository with `git format-patch origin/main..` and `git am` onto a branch cut from that repository's `main`. Compare the touched files before opening the second pull request.
3. Open one pull request per repository, staging first, and merge each with **Rebase and merge**. Do not use "Sync fork" or "Update branch": they create merge commits and pull one environment's data into the other.
4. After each merge wait for the deploy to finish, read its log (Part 4) and run the checker (Part 5) against that environment. Merge into production only after staging passes.
5. Anything that rebuilds the container waits until outside 02:30 to 03:30 UTC, and two deploys never overlap.

---

## Troubleshooting

**Container is not serving files**

```bash
docker logs boost-site
docker compose ps
```

Check that `/opt/boost` is world-readable:
```bash
ls -la /opt/boost
```

**deploy.yml fails with "Permission denied" on git pull**

Ensure ownership was transferred in step 2.2:
```bash
ls -la /opt/
sudo chown -R $USER:$USER /opt/boost
```

**The deploy is green but the site did not change**

Read the "Pull and optionally restart" log (Part 4). If it names the other repository, fix this repository's `SERVER_*` secrets. If it says "Already up to date", the commit was already on the VM.

**nginx returns 502 Bad Gateway for /boost/**

A few seconds of 502 during a rebuild is expected. If it persists, the Docker container is not running or is not bound to port 9102:
```bash
docker compose ps
curl http://localhost:9102/
```

**The container was not rebuilt after an nginx.conf change**

```bash
cd /opt/boost && docker compose up -d --build
```

**Host nginx config change not taking effect**

```bash
sudo nginx -t        # check for syntax errors
sudo systemctl reload nginx
```

**The checker reports failures**

Run it again and look at the `FAIL` lines; each names the path and what it returned. Re-run the failing request by hand with `curl -sI`, and compare it with the other environment.

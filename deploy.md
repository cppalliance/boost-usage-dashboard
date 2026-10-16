# Deployment Guide

This repository is served as a static site from a Docker container on a cloud server (e.g., GCP), accessible at `dev.cppdigest.org/boost/`. GitHub Pages remains active solely to redirect legacy visitors to the new URL.

> **Hostnames.** `dev.cppdigest.org` now redirects to `staging.insights.cppalliance.org`. The production host is `insights.cppalliance.org`. Where this guide names `dev.cppdigest.org`, read the staging host.

## Overview

```
Push to main
  ├── deploy.yml  →  SSH into server  →  git pull /opt/boost  →  nginx container serves updated files
  └── pages.yml   →  (only if index.html or 404.html changed)  →  GitHub Pages serves redirect-only artifact
```

The site content lives in a git clone at `/opt/boost` on the server. An nginx Docker container bind-mounts that directory read-only, so a `git pull` is all that is needed to deploy content changes — no Docker image rebuild, no container restart.

---

## Repository Files

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the nginx:alpine container image with a custom nginx config |
| `nginx.conf` | Container-internal nginx config — serves files from the bind-mounted directory |
| `docker-compose.yml` | Defines the `boost-site` container, port mapping, and bind mount |
| `.github/workflows/deploy.yml` | CD workflow — SSHs into the server and runs `git pull` on every push to `main` |
| `.github/workflows/pages.yml` | GitHub Pages workflow — deploys redirect-only artifact when `index.html` or `404.html` change |
| `index.html` | Root page — contains a hostname-conditional redirect for GitHub Pages visitors |
| `404.html` | GitHub Pages 404 handler — redirects deep-linked legacy URLs to their GCP equivalents |
| `home/` | The Insights homepage, served at the host root through a second nginx virtual host (see Part 3b) |

---

## Part 1 — GitHub Repository Configuration

### 1.1 Add Repository Secrets

Go to **Settings → Secrets and variables → Actions → New repository secret** and add:

| Secret name | Value |
|---|---|
| `SERVER_HOST` | IP address or hostname of your cloud server |
| `SERVER_USER` | SSH username on the server (e.g. `ubuntu`) |
| `SERVER_SSH_KEY` | Full contents of the private SSH key (the matching public key must be in `~/.ssh/authorized_keys` on the server) |

### 1.2 Switch GitHub Pages Source to GitHub Actions

Go to **Settings → Pages → Build and deployment → Source** and change from **"Deploy from a branch"** to **"GitHub Actions"**.

This is required for `pages.yml` to deploy. Without it the workflow will fail with a permissions error.

> After this change, GitHub Pages will only update when the `pages.yml` workflow runs — which only happens when `index.html` or `404.html` are modified. Routine content pushes (e.g. updating the `develop/` directory) will not trigger a Pages redeploy.

---

## Part 2 — Server Setup (one-time)

SSH into your server and run the following commands once to prepare the environment.

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

### 2.2 Clone the Repository

```bash
sudo git clone https://github.com/CppDigest/cppdigest.github.io.git /opt/boost
```

### 2.3 Set Ownership and Permissions

Transfer ownership to your SSH user so that `git pull` works without `sudo`, and set world-readable permissions so the nginx container user (UID 101 inside `nginx:alpine`) can read the files via the bind mount:

```bash
sudo chown -R $USER:$USER /opt/boost
find /opt/boost -type d -exec chmod 755 {} \;
find /opt/boost -type f -exec chmod 644 {} \;
```

**Why this works:** The `nginx:alpine` worker process runs as the `nginx` user (UID 101). The bind mount is owned by your SSH user, so nginx reads the files as "other". Standard `755` (directories) and `644` (files) permissions grant world-read access. The deploy workflow's `git pull` runs as your SSH user (the owner), so no `sudo` is needed there either.

### 2.4 Build and Start the Container

```bash
cd /opt/boost
docker compose up -d --build
```

### 2.5 Verify the Container is Serving

```bash
curl http://localhost:9102/
```

You should receive the HTML content of `index.html`. If you see an nginx error page, check `docker logs boost-site`.

---

## Part 3 — Host nginx Configuration (one-time)

The server runs a host-level nginx instance that routes subdirectory requests to individual Docker containers. Add a `location` block for `/boost/` inside the existing `server` block for `dev.cppdigest.org`.

```nginx
location /boost/ {
    proxy_pass http://127.0.0.1:9102/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

The trailing slash on `proxy_pass` causes nginx to strip the `/boost/` prefix before forwarding requests to the container. All internal HTML links in this repo use relative paths, so no URL rewriting is needed.

Test and reload:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

Verify end-to-end from your local machine:

```bash
curl https://dev.cppdigest.org/boost/
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
- The homepage's response headers (cache, `nosniff`, referrer policy, `frame-ancestors`) are set in `nginx.conf`, so the host nginx needs no `add_header` lines.
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

Staging only, to keep it out of search results: add `add_header X-Robots-Tag "noindex, nofollow" always;` to the first two blocks, and replace the `/robots.txt` block with:

```nginx
location = /robots.txt {
    default_type text/plain;
    return 200 "User-agent: *\nDisallow: /\n";
}
```

Order of steps for a host:

1. Merge the change to `main`. `deploy.yml` pulls it and, because `nginx.conf` changed, rebuilds the container.
2. On the server, check the container before touching the host nginx:
   ```bash
   curl -s -H 'Host: insights-home.internal' http://127.0.0.1:9102/ | grep -o '<title>[^<]*</title>'   # C++ Alliance Insights
   curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9102/home/                               # 404
   ```
3. Add the blocks above, then `sudo nginx -t && sudo systemctl reload nginx`.
4. From outside (use the staging host name for staging):
   ```bash
   H=https://insights.cppalliance.org
   for p in / /assets/home.css /assets/home.js /assets/logo.svg /robots.txt /boost/ /weblate/; do printf '%-18s ' $p; curl -s -o /dev/null -w '%{http_code}\n' $H$p; done   # all 200
   for p in /boost/home/ /boost/home/index.html /boost/assets/home.css; do printf '%-26s ' $p; curl -s -o /dev/null -w '%{http_code}\n' $H$p; done                 # all 404
   ```

Rollback: remove the three blocks and reload nginx; the default page returns. To remove the container side as well, revert the commit and let `deploy.yml` rebuild.

---

## Part 4 — Continuous Deployment

After the one-time setup above, all future deployments are automatic.

### How deploy.yml works

On every push to `main` (or manual dispatch), the workflow SSHs into the server and runs:

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
- **Infrastructure changes** (`Dockerfile`, `nginx.conf`, `docker-compose.yml`): the container is rebuilt and restarted automatically.

### How pages.yml works

Triggers only when `index.html` or `404.html` are modified. It copies those two files into a temporary `_pages/` directory and uploads that as the GitHub Pages artifact. The full site content (hundreds of HTML files and large JSON data) is never pushed to GitHub Pages.

---

## Part 5 — GitHub Pages Redirect Behaviour

### index.html redirect

A small script near the top of `<head>` in `index.html` fires only when the page is served from `cppdigest.github.io`:

```html
<script>
  if (window.location.hostname === 'cppdigest.github.io') {
    window.location.replace('https://dev.cppdigest.org/boost/');
  }
</script>
```

When served from `dev.cppdigest.org`, the hostname check fails silently and the full page content displays normally. The same file is used for both deployments.

### 404.html deep-link forwarding

GitHub Pages serves `404.html` for any path not present in the Pages artifact (which only contains `index.html` and `404.html`). This handles bookmarked deep links such as `cppdigest.github.io/v1.90/asio.html` by reconstructing the equivalent GCP URL:

```javascript
window.location.replace(
  'https://dev.cppdigest.org/boost' + window.location.pathname
);
```

For example:
- `cppdigest.github.io/v1.90/` → `dev.cppdigest.org/boost/v1.90/`
- `cppdigest.github.io/v1.90/libraries/asio.html` → `dev.cppdigest.org/boost/v1.90/libraries/asio.html`

---

## Part 6 — Validation Checklist

After completing all steps above, run through this checklist:

1. Push a content-only change to `main` (e.g. edit a file in `develop/`)
   - `deploy.yml` should trigger and complete in ~10s
   - `pages.yml` should **not** trigger (confirm in the Actions tab)
2. Browse to `https://dev.cppdigest.org/boost/` and confirm the change is live
3. Push a change to `index.html`
   - Both `deploy.yml` and `pages.yml` should trigger
4. Visit `https://cppdigest.github.io/` and confirm it redirects to `https://dev.cppdigest.org/boost/`
5. Visit `https://cppdigest.github.io/v1.90/` and confirm it redirects to `https://dev.cppdigest.org/boost/v1.90/`
6. Test manual dispatch: go to **Actions → Deploy to GCP → Run workflow**
7. Browse to the host root (`https://insights.cppalliance.org/`) and confirm the Insights homepage shows, with links to `/boost/` and `/weblate/`
8. Browse to `/boost/` and confirm it still shows the version selector, and that `/boost/home/` returns 404

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

Ensure ownership was transferred in step 2.3:
```bash
ls -la /opt/
sudo chown -R $USER:$USER /opt/boost
```

**pages.yml fails with "Resource not accessible by integration"**

The GitHub Pages source has not been switched to GitHub Actions. See step 1.2.

**nginx returns 502 Bad Gateway for /boost/**

The Docker container is not running or is not bound to port 9102:
```bash
docker compose ps
curl http://localhost:9102/
```

**Host nginx config change not taking effect**

```bash
sudo nginx -t        # check for syntax errors
sudo systemctl reload nginx
```

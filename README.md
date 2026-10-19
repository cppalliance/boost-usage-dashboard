# Boost Library Usage Analysis

This repository hosts analysis and statistics of Boost C++ Library usage across GitHub repositories, organized by Boost version. It is served at `/boost/` on each host; `deploy.md` describes the environments and how they are deployed.

## Repository Structure

```
.
├── index.html              # Version selector (root landing page of /boost/); reads versions.json
├── versions.json           # Version folders the selector shows, newest first
├── home/                   # Insights homepage, served at the host root (not under /boost/)
├── develop/                # Development dashboard, rewritten by the collector's nightly publish
├── v1.90/                  # Boost 1.90 analysis
│   ├── index.html          # Main dashboard
│   ├── bsl_analysis.html   # BSL-1.0 license analysis
│   ├── data_to_release_note.html  # Release notes data
│   ├── dashboard_data.json # Dashboard data
│   └── libraries/          # Individual library detail pages
│       ├── algorithm.html
│       ├── asio.html
│       └── ...
├── v1.91/, v1.92/          # Later releases, same layout
├── Dockerfile              # Container that serves the site
├── nginx.conf              # Its nginx configuration
├── docker-compose.yml      # Container definition
└── .github/                # Deploy, release-sync and freshness workflows, and verify-host.sh
```

## Homepage

`home/` holds the Insights homepage that links to `/boost/` and `/weblate/`. It is served at the root of the host by a second nginx virtual host and is not reachable under `/boost/`. See `home/README.md` and Part 3b of `deploy.md`.

## Adding a New Version

New release versions appear automatically. `boost-release.yml` runs daily at 05:00 UTC, detects the latest production Boost tag (for example `boost-1.93.0`), copies `develop/` to `v1.93/`, rewrites `versions.json` and pushes. The selector reads `versions.json`, so no HTML edit is needed.

A push made with the workflow's own token does not start `deploy.yml`. The new folder therefore goes live with the next data push, or immediately if you run **Actions → Deploy to GCP → Run workflow**.

To add a version by hand:

1. Copy `develop/` (or the previous version's folder) to `vX.YY/`.
2. Update the files in `vX.YY/` with the new data and version numbers.
3. Add `"vX.YY"` at the top of `versions` in `versions.json` and set `latest` to it.
4. Commit and let the deploy publish it.

## File Organization

- **Root `index.html`**: landing page with the version selector.
- **Version directories (`v1.90/`, `v1.91/`, etc.)**: each contains a complete set of analysis pages for that version.
- **Library detail pages**: located in `vX.YY/libraries/`.

## Navigation

- Users land on the root `index.html` and select a version.
- Within each version, navigation links are relative (no version prefix needed).
- Library pages link back to their version's dashboard using `../index.html`.
- All version pages include a "Back to Version Selector" link.

## Notes

- All internal links within a version directory use relative paths.
- The selector builds its links from `versions.json` (for example `v1.90/index.html`).

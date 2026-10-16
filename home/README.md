# Insights homepage

The page served at the root of `insights.cppalliance.org` and `staging.insights.cppalliance.org`.
It is plain HTML, CSS and one small script. There is no build step.

This folder is not served under `/boost/`. The container's `nginx.conf` answers 404 for `/home/`,
and serves these files only through a second virtual host that the host nginx reaches for `/`,
`/assets/` and `/robots.txt`. See "Part 3b" in `deploy.md`.

## Files

| File | Purpose |
|---|---|
| `index.html` | The page. One `h1`, landmarks, a skip link, and no content that needs JavaScript. |
| `assets/home.css` | Design tokens, layout, light and dark themes. |
| `assets/home.js` | The theme toggle. Without it the page follows the visitor's OS setting. |
| `assets/logo.svg` | The C++ Alliance logo, from `https://cppalliance.org/images/logo.svg`. Also the page icon. |
| `robots.txt` | Allows crawling. Staging overrides it at the host nginx. |

## Add a project card

Copy one `<li class="card">` block in `index.html`, then change the path chip, the title link, the
description and the secondary links. Keep the title link: it covers the whole card. Use a
root-absolute path such as `/boost/`. Do not write a `style` attribute: the page's
Content-Security-Policy blocks inline styles. Keep both repos' copies of this folder identical.

## Preview

```bash
python -m http.server 8765 --directory home
```

Open `http://localhost:8765/`. This does not send the nginx headers; the full two-tier check is in
`deploy.md`.

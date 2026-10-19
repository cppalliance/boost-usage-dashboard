#!/usr/bin/env bash
#
# Check a live host against the rollout matrix for this repository: the Insights
# homepage at the root, the dashboard under /boost/, the hardening that keeps
# repository files private, and the staging-only search engine settings.
#
# Usage: .github/scripts/verify-host.sh <base-url> <production|staging> [--neighbours]
#
#   base-url      https://insights.cppalliance.org or https://staging.insights.cppalliance.org
#   --neighbours  also check the other services behind the same nginx (Weblate,
#                 paperscout and the collector's health endpoint)
#
# Needs bash and curl. jq is optional: without it the structure of versions.json
# is not checked. The exit status is the number of failed checks (255 at most),
# so 0 means everything passed. A request that fails or is cut short is a failed
# check, never a pass.

set -u

usage() {
  echo "Usage: $0 <base-url> <production|staging> [--neighbours]" >&2
  exit 2
}

{ [ $# -ge 2 ] && [ $# -le 3 ]; } || usage
BASE="${1%/}"
ENVIRONMENT="$2"
NEIGHBOURS=0
case "$ENVIRONMENT" in
  production | staging) ;;
  *) usage ;;
esac
if [ $# -eq 3 ]; then
  [ "$3" = "--neighbours" ] || usage
  NEIGHBOURS=1
fi
command -v curl >/dev/null 2>&1 || {
  echo "curl is required" >&2
  exit 2
}

# A name that must not appear in published pages.
LEGACY='cpp[-_ ]?digest'

PASSED=0
FAILED=0

pass() {
  PASSED=$((PASSED + 1))
  printf 'ok    %s\n' "$1"
}

fail() {
  FAILED=$((FAILED + 1))
  printf 'FAIL  %s\n' "$1"
}

# A request that fails must never pass a check. After a response that is cut short
# curl can still print the status code it received, so every helper below looks
# at curl's exit status first.

# Prints the HTTP status, or "request-failed" when the transfer did not complete.
fetch_status() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$BASE$1") || {
    printf 'request-failed'
    return
  }
  printf '%s' "$code"
}

# Prints the body of a page that answered with a success status. Fails, and prints
# nothing, when the transfer fails or the status is an error, so a page that could
# not be read never satisfies a check that wants some text to be absent.
fetch_body() { curl -sf --max-time 30 "$BASE$1"; }

# Prints the first value of a response header, without the carriage return. Fails
# when the request fails; prints nothing when the header is absent.
fetch_header() {
  local headers
  headers=$(curl -s -I --max-time 30 "$BASE$1") || return 1
  printf '%s\n' "$headers" | tr -d '\r' | grep -i "^$2:" | head -n 1 | sed 's/^[^:]*:[[:space:]]*//'
}

# expect_status <path> <status>
expect_status() {
  local got
  got=$(fetch_status "$1")
  if [ "$got" = "$2" ]; then pass "$1 returns $got"; else fail "$1 returns $got, want $2"; fi
}

# expect_status_in <path> <status> <status>
expect_status_in() {
  local got
  got=$(fetch_status "$1")
  if [ "$got" = "$2" ] || [ "$got" = "$3" ]; then pass "$1 returns $got"; else fail "$1 returns $got, want $2 or $3"; fi
}

# expect_header <path> <name> <value>
expect_header() {
  local got
  got=$(fetch_header "$1" "$2") || {
    fail "$1 could not be fetched"
    return
  }
  if [ "$got" = "$3" ]; then pass "$1 sends $2: $got"; else fail "$1 sends $2: '$got', want '$3'"; fi
}

# expect_no_header <path> <name>
expect_no_header() {
  local got
  got=$(fetch_header "$1" "$2") || {
    fail "$1 could not be fetched"
    return
  }
  if [ -z "$got" ]; then pass "$1 sends no $2"; else fail "$1 sends $2: '$got', want none"; fi
}

# expect_body_has <path> <fixed string> <what>
expect_body_has() {
  local body
  body=$(fetch_body "$1") || {
    fail "$1 could not be fetched"
    return
  }
  if grep -qF -- "$2" <<<"$body"; then pass "$1 $3"; else fail "$1 does not $3"; fi
}

# expect_body_lacks <path> <extended regex> <what>
expect_body_lacks() {
  local body
  body=$(fetch_body "$1") || {
    fail "$1 could not be fetched"
    return
  }
  if grep -qiE -- "$2" <<<"$body"; then fail "$1 has $3"; else pass "$1 has no $3"; fi
}

echo "Checking $BASE as $ENVIRONMENT"

# Pages that must exist.
for path in / /assets/home.css /assets/home.js /assets/logo.svg /robots.txt \
  /boost/ /boost/versions.json /boost/develop/index.html; do
  expect_status "$path" 200
done

# Every version listed in versions.json must have a dashboard. Only the entries of
# the "versions" array count: "latest" is not a source of folders, and an empty
# array means there are no versions.
versions=""
versions_ok=0
if versions_json=$(fetch_body /boost/versions.json); then
  versions_ok=1
  versions=$(printf '%s' "$versions_json" | tr -d '\r\n' |
    sed -n 's/.*"versions"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' |
    grep -oE '"v[0-9]+\.[0-9]+"' | tr -d '"' | sort -u)
  [ -n "$versions" ] || fail "/boost/versions.json lists no versions"
else
  fail "/boost/versions.json could not be fetched"
fi
for version in $versions; do
  expect_status "/boost/$version/index.html" 200
done

if [ "$versions_ok" -eq 1 ]; then
  if command -v jq >/dev/null 2>&1; then
    if jq -e '(.versions | type == "array" and length > 0) and .latest == .versions[0] and .develop == true' <<<"$versions_json" >/dev/null 2>&1; then
      pass "/boost/versions.json is well formed: latest is the first version and develop is true"
    else
      fail "/boost/versions.json is malformed, latest is not the first version or develop is not true"
    fi
  else
    echo "skip  /boost/versions.json structure (jq is not installed)"
  fi
fi

# Pages that must not exist: the homepage is never served under /boost/, and
# repository files and plumbing stay private.
for path in /boost/home /boost/home/ /boost/home/index.html /boost/assets/home.css \
  /boost/robots.txt /boost/404.html /boost/.git/config /boost/deploy.md /boost/nginx.conf \
  /boost/Dockerfile /boost/.github/workflows/deploy.yml /nope; do
  expect_status "$path" 404
done

# Homepage and its assets.
expect_header / Cache-Control "no-cache"
expect_header / X-Content-Type-Options "nosniff"
expect_header / Referrer-Policy "strict-origin-when-cross-origin"
expect_header / Content-Security-Policy "frame-ancestors 'none'"
expect_header /assets/home.css Cache-Control "public, max-age=3600"
expect_body_has / "<title>C++ Alliance Insights</title>" "show the Insights homepage"

# Search engines: allowed on production, blocked on staging.
if [ "$ENVIRONMENT" = staging ]; then
  expect_header / X-Robots-Tag "noindex, nofollow"
  expect_header /assets/home.css X-Robots-Tag "noindex, nofollow"
  expect_body_has /robots.txt "Disallow: /" "disallow crawling"
else
  expect_no_header / X-Robots-Tag
  expect_no_header /assets/home.css X-Robots-Tag
  expect_body_has /robots.txt "Allow: /" "allow crawling"
fi

# The version selector reads versions.json and no longer calls the GitHub API.
expect_body_has /boost/ "versions.json" "read versions.json"
expect_body_lacks /boost/ 'api\.github\.com' "call to the GitHub API"

# Published pages must not name the retired site.
for path in / /boost/ /boost/versions.json /robots.txt; do
  expect_body_lacks "$path" "$LEGACY" "mention of the retired name"
done

if [ "$NEIGHBOURS" -eq 1 ]; then
  for path in /weblate/ /weblate/healthz/ /paperscout/health; do
    expect_status "$path" 200
  done
  # 401 is fine: the collector may require a bearer token on its health endpoint.
  expect_status_in /boost-data-collector/health/ 200 401
fi

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -gt 255 ] && FAILED=255
exit "$FAILED"

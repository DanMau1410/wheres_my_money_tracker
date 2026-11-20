#!/bin/sh
# Smoke test for the `web` image (AC-OPS-7): / and a deep link both return 200 with index.html
# and the three security headers. Usage: sh tool/smoke_web.sh URL   (e.g. http://localhost:8080)
set -eu
base="${1:?usage: smoke_web.sh URL}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail=0
check() { # check LABEL COMMAND...: prints ok/FAIL and records failures
  label=$1; shift
  if "$@"; then echo "ok   $label"; else echo "FAIL $label"; fail=1; fi
}

for path in / /journal/42; do
  name=$(echo "$path" | tr -c 'a-z0-9\n' '_')
  # Retries cover a container that is still starting: Docker's port proxy may accept and then
  # reset the connection (curl error 56), which --retry-connrefused alone doesn't retry.
  code=$(curl -sS --retry 10 --retry-all-errors --retry-delay 1 \
    -o "$tmp/$name.body" -D "$tmp/$name.headers" -w '%{http_code}' "$base$path") || code=000
  check "$path returns 200 (got $code)" [ "$code" = 200 ]
  check "$path Content-Security-Policy with frame-ancestors 'none'" \
    grep -qi "^content-security-policy:.*frame-ancestors 'none'" "$tmp/$name.headers"
  check "$path X-Content-Type-Options: nosniff" grep -qi '^x-content-type-options: *nosniff' "$tmp/$name.headers"
  check "$path Referrer-Policy: strict-origin-when-cross-origin" \
    grep -qi '^referrer-policy: *strict-origin-when-cross-origin' "$tmp/$name.headers"
done

check "/ serves the Flutter index.html" grep -q 'flutter_bootstrap.js' "$tmp/_.body"
check "/journal/42 serves the same index.html" cmp -s "$tmp/_.body" "$tmp/_journal_42.body"

exit "$fail"

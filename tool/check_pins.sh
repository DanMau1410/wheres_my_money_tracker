#!/bin/sh
# Supply-chain pins (SPEC-devops): fails, naming the file and line, when
#   - a workflow `uses:` isn't pinned to a 40-character commit SHA (local ./ actions excepted)
#   - a Dockerfile FROM isn't pinned by digest (`scratch` and earlier stages excepted)
#   - the Dockerfile's FLUTTER_VERSION differs from pubspec.yaml's `environment: flutter`
# Usage: sh tool/check_pins.sh (from the repo root)
set -eu

bad=0

for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -f "$wf" ] || continue
  out=$(awk '
    /^[[:space:]]*(-[[:space:]]+)?uses:/ {
      v = $0
      sub(/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*/, "", v)
      sub(/[[:space:]]+#.*$/, "", v)
      gsub(/["'\'']/, "", v)
      sha = v; sub(/^[^@]*@/, "", sha)
      # length() instead of {40}: older mawk builds have no interval expressions.
      if (v !~ /^\.\// && !(v ~ /@[0-9a-f]+$/ && length(sha) == 40)) print FILENAME ":" FNR ": not pinned to a commit SHA: " v
    }' "$wf")
  if [ -n "$out" ]; then echo "$out" >&2; bad=1; fi
done

out=$(awk '
  toupper($1) == "FROM" {
    i = 2
    while ($i ~ /^--/) i++
    img = tolower($i)
    digest = img; sub(/^[^@]*@sha256:/, "", digest)
    if (img != "scratch" && !(img in stages) && !(img ~ /@sha256:[0-9a-f]+$/ && length(digest) == 64))
      print FILENAME ":" FNR ": FROM not pinned by digest: " $i
    if (toupper($(i + 1)) == "AS") stages[tolower($(i + 2))] = 1
  }' Dockerfile)
if [ -n "$out" ]; then echo "$out" >&2; bad=1; fi

docker_pin=$(sed -n 's/^ARG FLUTTER_VERSION=//p' Dockerfile)
# The `flutter:` key inside the top-level `environment:` block, quotes stripped.
pubspec_pin=$(awk '
  /^[^[:space:]#]/ { in_env = ($0 ~ /^environment:/) }
  in_env && /^[[:space:]]+flutter:/ { v = $2; gsub(/["'\'']/, "", v); print v; exit }' pubspec.yaml)
if [ -z "$docker_pin" ] || [ -z "$pubspec_pin" ] || [ "$docker_pin" != "$pubspec_pin" ]; then
  echo "Dockerfile:$(grep -n '^ARG FLUTTER_VERSION=' Dockerfile | cut -d: -f1): FLUTTER_VERSION '${docker_pin}'" \
    "differs from pubspec.yaml:$(grep -n '^[[:space:]]*flutter:[[:space:]]*[^[:space:]]' pubspec.yaml | head -1 | cut -d: -f1): environment flutter '${pubspec_pin}'" >&2
  bad=1
fi

[ "$bad" -eq 0 ] && echo "check_pins: all pinned, Flutter $docker_pin"
exit "$bad"

#!/bin/sh
# Fails when line coverage in an lcov file is below MIN percent.
# Usage: sh tool/check_coverage.sh MIN [coverage/lcov.info]
# Generated localization files (lib/l10n/) don't count.
set -eu

min="${1:?usage: check_coverage.sh MIN [LCOV_FILE]}"
file="${2:-coverage/lcov.info}"

if [ ! -f "$file" ]; then
  echo "check_coverage: $file not found" >&2
  exit 1
fi

awk -v min="$min" '
  /^SF:/ { skip = ($0 ~ /^SF:lib\/l10n\//) }
  /^LF:/ && !skip { total += substr($0, 4) }
  /^LH:/ && !skip { hit += substr($0, 4) }
  END {
    if (total == 0) { print "check_coverage: no instrumented lines" > "/dev/stderr"; exit 1 }
    pct = 100 * hit / total
    printf "Line coverage: %.1f%% (%d of %d lines), minimum %s%%\n", pct, hit, total, min
    exit (pct < min + 0) ? 1 : 0
  }
' "$file"

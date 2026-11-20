#!/bin/sh
# The two secret scans from dev_rules §9. Prints file names only, never the matched text.
# Exits 1 when either scan finds something. Usage: sh tool/secret_scan.sh
set -eu

# Same pattern as dev_rules §9; the plain words are split with '' so this file doesn't match itself.
content='BEGIN [A-Z ]*PRIVATE KEY|"private''_key"|client''_secret|refresh''_token|sk-[a-z0-9_-]{20,}|gh[pousr]_[a-z0-9]{30,}|github''_pat_|sb_secret_[a-z0-9_-]{10,}|sbp_[a-z0-9]{20,}|GOCSPX-[a-z0-9_-]{20,}'
names='\.(jks|keystore|p12|pem|mobileprovision)$|key\.properties$|service-?account|(^|/)\.env'

found=0

# git grep exits 1 when nothing matches; anything above 1 is an error, not a pass.
rc=0
hits=$(git grep --untracked -lIiE "$content" -- ':!.claude/dev_rules.md') || rc=$?
if [ "$rc" -gt 1 ]; then
  echo "secret_scan: git grep failed (exit $rc)" >&2
  exit 2
fi
if [ -n "$hits" ]; then
  echo "secret_scan: secret-like content in:" >&2
  printf '%s\n' "$hits" | sed 's/^/  /' >&2
  found=1
fi

files=$(git ls-files --cached --others --exclude-standard)
hits=$(printf '%s\n' "$files" | grep -iE "$names" || true)
if [ -n "$hits" ]; then
  echo "secret_scan: secret-like file names:" >&2
  printf '%s\n' "$hits" | sed 's/^/  /' >&2
  found=1
fi

[ "$found" -eq 0 ] && echo "secret_scan: clean"
exit "$found"

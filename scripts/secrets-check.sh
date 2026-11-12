#!/usr/bin/env bash
# Publication check (D57): secrets in the whole git history + personal data in tracked files. Exit 1 on findings.
set -euo pipefail
cd "$(dirname "$0")/.."
GITLEAKS=${GITLEAKS:-$(command -v gitleaks || echo "$HOME/go/bin/gitleaks")}
[[ -x "$GITLEAKS" ]] || { echo "install gitleaks: go install github.com/zricethezav/gitleaks/v8@v8.24.0" >&2; exit 2; }
fail=0
echo "==> gitleaks: full history"
"$GITLEAKS" git --no-banner --redact --config .gitleaks.toml . || fail=1
echo "==> tracked files: private addresses, home paths, e-mail addresses"
# private IPv4 ranges (RFC 1918) except documentation placeholders like 192.168.x.y
if git grep -nIE '\b(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})\b' \
     -- ':!*.lock' ':!**/testdata/**' ':!**/vectors/**' | grep -vE '10\.0\.2\.2|10\.0\.2\.15'; then
  echo "private IP address in a tracked file (use 192.168.x.y / 203.0.113.x placeholders)"; fail=1
fi
if git grep -nIE '/home/[A-Za-z0-9_]' -- ':!scripts/secrets-check.sh'; then echo "home path in a tracked file"; fail=1; fi
if git grep -nIE '[A-Za-z0-9._%+-]+@(gmail|yandex|mail|outlook|hotmail|icloud)\.[a-z]+' -- ':!scripts/secrets-check.sh'; then
  echo "personal e-mail address in a tracked file"; fail=1
fi
(( fail == 0 )) || { echo "secrets check: FAILED" >&2; exit 1; }
echo "secrets check: ok"

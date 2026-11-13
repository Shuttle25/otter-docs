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
     -- ':!*.lock' | grep -vE '10\.0\.2\.2|10\.0\.2\.15'; then
  echo "private IP address in a tracked file (use 192.168.x.y / 203.0.113.x placeholders)"; fail=1
fi
if git grep -nIE '/home/[A-Za-z0-9_.-]+/' -- ':!scripts/secrets-check.sh'; then echo "home path in a tracked file"; fail=1; fi
if git grep -nIE '[A-Za-z0-9._%+-]+@(gmail|yandex|mail|outlook|hotmail|icloud)\.[a-z]+' -- ':!scripts/secrets-check.sh'; then
  echo "personal e-mail address in a tracked file"; fail=1
fi
echo "==> full history: real server IPs from ${OTTER_REAL_IPS:-$HOME/.otter-real-ips}"
IPS=${OTTER_REAL_IPS:-$HOME/.otter-real-ips}
if [[ -f "$IPS" ]]; then
  pats=$(grep -vE '^\s*(#|$)' "$IPS" | sed 's/\./\\./g' | paste -sd'|')
  if [[ -n "$pats" ]] && grep -qE "\b($pats)\b" <(git log --all -p --no-color); then
    echo "a real server IP is in the git history (rewrite it out before pushing)"; fail=1
  fi
else
  echo "warning: $IPS missing, real-IP check skipped (one IP per line)"
fi
echo "==> full history: commit metadata (UTC, no time of day, no session trailers)"
if git log --all --format='%ad%n%cd' --date=raw | awk '{print $2}' | grep -v '^+0000$' >/dev/null; then
  echo "a commit has a non-UTC timezone (commit with UTC 12:00 + n s dates, D57)"; fail=1
fi
if TZ=UTC git log --all --format='%ad%n%cd' --date=format-local:%H | grep -v '^12$' >/dev/null; then
  echo "a commit shows a real time of day (commit with UTC 12:00 + n s dates, D57)"; fail=1
fi
if git log --all --format=%B | grep '^Claude-Session:' >/dev/null; then echo "a commit message has a Claude-Session trailer"; fail=1; fi
echo "==> full history: image metadata (C2PA, EXIF, XMP, text chunks)"
python3 -I - <<'PY' || fail=1
import subprocess, sys
keep = {b'IHDR', b'PLTE', b'IDAT', b'IEND', b'tRNS', b'gAMA', b'cHRM', b'sRGB', b'iCCP', b'sBIT', b'bKGD', b'pHYs'}
objs = [l.split(' ', 1) for l in subprocess.run(['git', 'rev-list', '--all', '--objects'], capture_output=True,
        text=True, check=True).stdout.splitlines() if ' ' in l]
cat = subprocess.Popen(['git', 'cat-file', '--batch'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
bad = set()
for sha, path in objs:
    if not path.lower().endswith(('.png', '.jpg', '.jpeg', '.webp')):
        continue
    cat.stdin.write(sha.encode() + b'\n'); cat.stdin.flush()
    h = cat.stdout.readline().split(); d = cat.stdout.read(int(h[2])); cat.stdout.read(1)
    if d.startswith(b'\x89PNG'):
        i = 8
        while i + 8 <= len(d):
            n = int.from_bytes(d[i:i + 4], 'big')
            if d[i + 4:i + 8] not in keep: bad.add(path)
            i += 12 + n
    elif d[:2] == b'\xff\xd8' and (b'Exif\x00' in d[:65536] or b'http://ns.adobe.com/xap' in d[:65536] or b'jumb' in d[:65536]):
        bad.add(path)
    elif d[:4] == b'RIFF' and (b'EXIF' in d[12:4096] or b'XMP ' in d[12:4096]):
        bad.add(path)
for p in sorted(bad): print('metadata in image:', p)
sys.exit(1 if bad else 0)
PY
echo "==> full history: private words from ${OTTER_PRIVATE_WORDS:-$HOME/.otter-private-words}"
WORDS=${OTTER_PRIVATE_WORDS:-$HOME/.otter-private-words}
if [[ -f "$WORDS" ]]; then
  wpats=$(grep -vE '^\s*(#|$)' "$WORDS" | paste -sd'|')
  if [[ -n "$wpats" ]] && git log --all -p --no-color | grep -E "$wpats" >/dev/null; then
    echo "a private word (provider, device, account, place) is in the git history or a commit message"; fail=1
  fi
else
  echo "warning: $WORDS missing, private-word check skipped (one extended regex per line)"
fi
(( fail == 0 )) || { echo "secrets check: FAILED" >&2; exit 1; }
echo "secrets check: ok"

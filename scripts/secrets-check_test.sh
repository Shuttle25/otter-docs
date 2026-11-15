#!/usr/bin/env bash
# Tests for secrets-check.sh (C28). Builds throw-away repos in a temp dir; never touches the real lists.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export GITLEAKS=/bin/true  # gitleaks is not under test here
mk() {  # mk <name> <file content> → repo with scripts/secrets-check.sh and one tracked file
  local r=$tmp/$1; mkdir -p "$r/scripts"; cp "$here/secrets-check.sh" "$r/scripts/"; touch "$r/.gitleaks.toml"
  printf '%s\n' "$2" > "$r/f.txt"
  git -C "$r" init -q; git -C "$r" add -A
  TZ=UTC GIT_AUTHOR_DATE=2026-01-01T12:00:00+0000 GIT_COMMITTER_DATE=2026-01-01T12:00:00+0000 \
    git -C "$r" -c user.name=t -c user.email=t@users.noreply.invalid commit -qm init
  echo "$r"
}
printf '203.0.113.250\n' > "$tmp/ips"; printf 'nosuchword\n' > "$tmp/words"
run() { OTTER_REAL_IPS=${IPS:-$tmp/ips} OTTER_PRIVATE_WORDS=${WORDS:-$tmp/words} bash "$1/scripts/secrets-check.sh" >"$tmp/out" 2>&1; }
ok=$(mk ok 'emulator 10.0.2.2 and 10.0.2.15 only')
run "$ok" || { cat "$tmp/out"; echo "FAIL: clean repo"; exit 1; }
mixed=$(mk mixed 'emulator 10.0.2.2 but also 10.1.2.3')
if run "$mixed"; then echo "FAIL: real private IP hidden by the emulator filter"; exit 1; fi
grep -q 'f.txt:1' "$tmp/out" || { echo "FAIL: no file:line"; exit 1; }
if grep -q '10\.1\.2\.3' "$tmp/out"; then echo "FAIL: match printed"; exit 1; fi
mail=$(mk mail 'write to someone@'"gmail"'.com')  # split so this test file never matches itself
if run "$mail"; then echo "FAIL: e-mail passed"; exit 1; fi
if grep -q 'someone@' "$tmp/out"; then echo "FAIL: e-mail printed"; exit 1; fi
home=$(mk home 'see /hom''e/someone/x')  # split so this test file never matches itself
if run "$home"; then echo "FAIL: home path passed"; exit 1; fi
grep -q 'f.txt:1' "$tmp/out" || { echo "FAIL: home path without file:line"; exit 1; }
if grep -q 'someone' "$tmp/out"; then echo "FAIL: home path printed"; exit 1; fi
rip=$(mk rip 'node at 203.0.113.250')
if run "$rip"; then echo "FAIL: real IP in history passed"; exit 1; fi
if grep -q '203\.0\.113\.250' "$tmp/out"; then echo "FAIL: real IP printed"; exit 1; fi
word=$(mk word 'hosted at nosuchword')
if run "$word"; then echo "FAIL: private word passed"; exit 1; fi
if grep -q 'hosted at' "$tmp/out"; then echo "FAIL: private word printed"; exit 1; fi
set +e; IPS=$tmp/none run "$ok"; rc=$?; set -e
[[ $rc == 2 ]] || { echo "FAIL: missing IP list gave $rc"; exit 1; }
set +e; WORDS=$tmp/none run "$ok"; rc=$?; set -e
[[ $rc == 2 ]] || { echo "FAIL: missing word list gave $rc"; exit 1; }
echo "secrets-check tests: ok"

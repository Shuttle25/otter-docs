# M1.6 Server Scripts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From the admin PC, add a node to a running network with one command, upgrade every node with one
command, and see all nodes in one status table.

**Architecture:** Thin bash wrappers in `otter-server/deploy/` around the existing tools (`otter-admin`,
`push.sh`, `upgrade.sh`, `check.sh`). A new per-admin file `~/.otter-admin/hosts` maps node labels to SSH
targets, so no script needs an address after a node is added. One small Go addition, `otter-node stats`,
gives status and tests a cheap read-only view of a node's database. Verified offline with stubbed `ssh`
and end-to-end with two QEMU VMs that replicate to each other.

**Tech Stack:** bash (set -euo pipefail, existing `deploy/lib.sh` helpers), Go 1.26 (`otter-node`), QEMU/KVM
Debian 12 cloud image (`deploy/test/vm.sh`), nftables inside the VMs.

**Spec:** `docs/superpowers/specs/2026-11-12-ops-scripts-and-backup-design.md` (Part 1).

---

## Context for the engineer

* Repo: `~/Documents/Projects/OttterMSG/otter-server` (git, no remote, branch from `main`:
  `git checkout -b m1-6-ops`). `docs/` at the project root is not in git. Only `otter-server` changes.
* Build tools first: `make build` (→ `bin/otter-admin`, `bin/otter-node`); `deploy/lib.sh` refuses to run
  without them.
* `deploy/lib.sh` provides `ROOT`, `ADMIN_DIR` (`$OTTER_ADMIN_DIR` or `~/.otter-admin`), `say`, `die`,
  `admin …` (runs otter-admin on the admin dir), `remote TARGET cmd…`, `upload TARGET SRC DST`,
  `node_env LABEL` (evals `OTTER_HOST OTTER_PORT OTTER_PATH OTTER_PIN OTTER_NODE_ID …`). SSH port comes from
  `SSH_PORT` (`$OTTER_SSH_PORT`, default 22), extra options from `$OTTER_SSH_OPTS`.
* `otter-admin node list` prints one line per endpoint: `label node_id kind host:port/path cdn=… pin=…`, in
  manifest order. `otter-admin manifest publish` (no `--via`) sends `manifest.bin` to every node and
  succeeds if at least one accepted it; nodes that already have it print `already current`.
* A running node picks up a newly published manifest at runtime: `replication.Replicator.dialMissing`
  dials every manifest peer it has no session with (logs `peer session up`). No restart needed.
* `upgrade.sh TARGET BINARY` exits 0 upgraded, 2 rolled back, 3 rollback failed.
* `push.sh` builds a missing bundle with `make-bundle.sh LABEL` (no version → the highest release in `dist/`,
  `sort -V`). The owner's `dist/` holds real releases (`0.2.0`) and `bundle-eeee.invites`: tests must pass an
  explicit version and must never delete files in `dist/` they did not create.
* Never touch the real network (`~/.otter-admin`, node `eeee` at `root@eeee`) without asking the owner;
  every test uses a throwaway `OTTER_ADMIN_DIR` and `OTTER_ADMIN_PASSPHRASE`.
* Commits end with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01S4HpRBxLVKgjFPHw4U4CNo
  ```

## File map

| File | Responsibility |
|------|----------------|
| `internal/store/stats.go` (new) | `Store.Stats` — counts for status/tests |
| `cmd/otter-node/main.go` | `stats --config FILE` subcommand |
| `deploy/lib.sh` | `HOSTS_FILE`, `host_lookup`, `node_labels` helpers |
| `deploy/hosts.sh` (new) | `set/get/list/rm` on `~/.otter-admin/hosts` |
| `deploy/add-node.sh` (new) | one-command add of a node to a running network (resumable) |
| `deploy/status.sh` (new) | table of all nodes |
| `deploy/upgrade-all.sh` (new) | release + rolling upgrade of every node |
| `deploy/test/scripts_test.sh` (new) | offline tests with stubbed ssh |
| `deploy/test/vm.sh` | named VMs with their own ports |
| `deploy/test/e2e-mesh.sh` (new) | two-VM add-node / replication / upgrade-all / status test |
| `deploy/README.md`, `deploy/FIRST-DEPLOY.md`, `Makefile` | docs, `make deploy-test` |

---

### Task 1: `otter-node stats`

**Goal:** A read-only `otter-node stats --config FILE` that prints one line of database counts.

**Files:**
- Create: `internal/store/stats.go`, `internal/store/stats_test.go`
- Modify: `cmd/otter-node/main.go` (usage, command switch), `cmd/otter-node/main_test.go`

**Acceptance Criteria:**
- [ ] `Store.Stats` returns users, records, oplog head, blobs, blob bytes, known peers.
- [ ] `otter-node stats --config F` prints `users=N records=N oplog_seq=N blobs=N blob_bytes=N peers=N`.
- [ ] Safe while the node runs (reader connection only, WAL).

**Verify:** `go test ./internal/store/ ./cmd/otter-node/ -run 'Stats' -v` → PASS; `make check` → PASS

**Steps:**

- [ ] **Step 1: Failing store test** — `internal/store/stats_test.go`:

```go
package store

import (
	"context"
	"testing"
)

func TestStats(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	st, err := s.Stats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st != (Stats{}) {
		t.Fatalf("empty store: %+v", st)
	}
	r, b := rec(t)
	if _, _, err := s.Apply(ctx, r, b); err != nil {
		t.Fatal(err)
	}
	st, err = s.Stats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.Records != 1 || st.OplogSeq < 1 {
		t.Fatalf("after one record: %+v", st)
	}
}
```

Run `go test ./internal/store/ -run TestStats` → FAIL (`s.Stats undefined`).

- [ ] **Step 2: Implement** — `internal/store/stats.go`:

```go
package store

import "context"

// Stats is a cheap read-only summary of the node database (otter-node stats, deploy/status.sh).
type Stats struct {
	Users, Records, OplogSeq, Blobs, BlobBytes, Peers int64
}

func (s *Store) Stats(ctx context.Context) (Stats, error) {
	var st Stats
	for _, q := range []struct {
		sql string
		dst *int64
	}{
		{"SELECT COUNT(*) FROM users", &st.Users},
		{"SELECT COUNT(*) FROM records", &st.Records},
		{"SELECT COALESCE(MAX(seq), 0) FROM oplog", &st.OplogSeq},
		{"SELECT COUNT(*) FROM blobs", &st.Blobs},
		{"SELECT COALESCE(SUM(size), 0) FROM blobs", &st.BlobBytes},
		{"SELECT COUNT(*) FROM peers", &st.Peers},
	} {
		if err := s.r.QueryRowContext(ctx, q.sql).Scan(q.dst); err != nil {
			return st, err
		}
	}
	return st, nil
}
```

Run the test → PASS. (If `blobs` has no `size` column after migration 0004, read
`internal/store/migrations/0004_blobs.sql` and use its size column name.)

- [ ] **Step 3: Failing CLI test** — in `cmd/otter-node/main_test.go`, extract the network/config setup at the
top of `TestImportAndRun` into a helper and add `TestStats`:

```go
// testNode creates a throwaway network with node n1 and returns its config path and manifest path.
func testNode(t *testing.T) (cfg, manifest string, n *pb.NodeInfo, addr, path string) {
	t.Helper()
	dir := t.TempDir()
	adm := filepath.Join(dir, "admin")
	if err := admin.InitNetwork(adm, pass); err != nil {
		t.Fatal(err)
	}
	n, err := admin.AddNode(adm, admin.NodeSpec{Label: "n1", WSSHost: "127.0.0.1"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := admin.SignManifest(adm, pass, time.Now()); err != nil {
		t.Fatal(err)
	}
	st, _ := admin.LoadState(adm)
	addr = freePort(t)
	path = n.Endpoints[0].Path
	cfg = filepath.Join(dir, "node.toml")
	os.WriteFile(cfg, []byte(fmt.Sprintf(`data_dir = %q
node_key = %q
network_pub = %q
[wss]
listen = %q
path = %q
`, filepath.Join(dir, "data"), filepath.Join(adm, "nodes", "n1", "node.key"), hex.EncodeToString(st.NetworkPub), addr, path)), 0o600)
	return cfg, filepath.Join(adm, "manifest.bin"), n, addr, path
}

func TestStats(t *testing.T) {
	cfg, manifest, _, _, _ := testNode(t)
	var out bytes.Buffer
	if err := run(context.Background(), []string{"import", "--config", cfg, manifest}, &out); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err := run(context.Background(), []string{"stats", "--config", cfg}, &out); err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(out.String()); !strings.HasPrefix(got, "users=0 records=1 oplog_seq=1 blobs=0 blob_bytes=0 peers=") {
		t.Fatalf("stats: %q", got)
	}
}
```

Change `TestImportAndRun` to start with `cfg, manifest, n, addr, path := testNode(t)` and delete the
duplicated setup lines. Run `go test ./cmd/otter-node/ -run 'TestStats|TestImportAndRun'` → TestStats FAIL
(usage error).

- [ ] **Step 4: Implement the subcommand** in `cmd/otter-node/main.go`:
  - usage: add the line `  stats --config FILE          database counts (safe while running)` after the
    `backup` line.
  - `if cmd != "run" && cmd != "import" && cmd != "backup" && cmd != "stats" {`
  - new case in the switch:

```go
	case "stats":
		st, err := a.st.Stats(ctx)
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "users=%d records=%d oplog_seq=%d blobs=%d blob_bytes=%d peers=%d\n",
			st.Users, st.Records, st.OplogSeq, st.Blobs, st.BlobBytes, st.Peers)
		return nil
```

If `open()` prints anything to `out` before the command runs, make the CLI test compare only the last line.
Run both tests → PASS, then `make check` → PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/store/stats.go internal/store/stats_test.go cmd/otter-node/main.go cmd/otter-node/main_test.go
git commit -m "feat(node): otter-node stats prints database counts"
```

---

### Task 2: Hosts registry (`deploy/hosts.sh`) and lib helpers

**Goal:** `~/.otter-admin/hosts` maps labels to SSH targets; scripts look targets up instead of taking them.

**Files:**
- Create: `deploy/hosts.sh`, `deploy/test/scripts_test.sh`
- Modify: `deploy/lib.sh`

**Acceptance Criteria:**
- [ ] `hosts.sh set LABEL TARGET [SSH_PORT]` adds or replaces the line; file mode 0600.
- [ ] `hosts.sh get LABEL` prints `TARGET PORT` (port defaults to `$OTTER_SSH_PORT` or 22); unknown → exit 1.
- [ ] `hosts.sh list` prints every node of `otter-admin node list` with its target or `-`; `rm LABEL` removes.
- [ ] Invalid label/port is refused.

**Verify:** `deploy/test/scripts_test.sh` → `scripts test: ok`

**Steps:**

- [ ] **Step 1: Failing test** — `deploy/test/scripts_test.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# Offline tests for the admin-side deploy scripts (no VM; ssh/scp are stubs).
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d); trap 'rm -rf "$work"; rm -f dist/otter-node_0.0.0-st_linux_* dist/bundle-n3.*' EXIT
fail() { echo "scripts test: FAIL: $*" >&2; exit 1; }
export OTTER_ADMIN_DIR="$work/admin" OTTER_ADMIN_PASSPHRASE=scripts-test-passphrase
make -s build; mkdir -p dist
bin/otter-admin --dir "$OTTER_ADMIN_DIR" network init >/dev/null
bin/otter-admin --dir "$OTTER_ADMIN_DIR" node add --label n1 --wss-host 192.0.2.1 --ip 192.0.2.1 >/dev/null
bin/otter-admin --dir "$OTTER_ADMIN_DIR" node add --label n2 --wss-host 192.0.2.2 --ip 192.0.2.2 >/dev/null
bin/otter-admin --dir "$OTTER_ADMIN_DIR" manifest sign >/dev/null

# --- hosts.sh
deploy/hosts.sh set n1 root@n1.example
[[ "$(deploy/hosts.sh get n1)" == "root@n1.example 22" ]] || fail "get n1"
deploy/hosts.sh set n1 root@other 2222
[[ "$(deploy/hosts.sh get n1)" == "root@other 2222" ]] || fail "replace n1"
[[ "$(grep -c '^n1 ' "$OTTER_ADMIN_DIR/hosts")" == 1 ]] || fail "duplicate line"
[[ "$(stat -c %a "$OTTER_ADMIN_DIR/hosts")" == 600 ]] || fail "hosts mode"
if deploy/hosts.sh get n2 >/dev/null 2>&1; then fail "unknown label found"; fi
list=$(deploy/hosts.sh list)
grep -q '^n1 *root@other *2222$' <<< "$list" || fail "list n1: $list"
grep -q '^n2 *-$' <<< "$list" || fail "list n2: $list"
if deploy/hosts.sh set 'Bad Label' root@x 2>/dev/null; then fail "bad label accepted"; fi
if deploy/hosts.sh set n2 root@x port 2>/dev/null; then fail "bad port accepted"; fi
deploy/hosts.sh rm n1
if deploy/hosts.sh get n1 >/dev/null 2>&1; then fail "rm"; fi

echo "scripts test: ok"
```

Run it → FAIL (`deploy/hosts.sh: No such file`).

- [ ] **Step 2: lib helpers** — append to `deploy/lib.sh` (before the final `[[ -x … ]]` line):

```bash
HOSTS_FILE="$ADMIN_DIR/hosts"
# host_lookup LABEL → sets TARGET and TARGET_PORT from $HOSTS_FILE; returns 1 if the label has no host.
host_lookup() {
  local line
  line=$(awk -v l="$1" '$1 == l { print $2, $3 }' "$HOSTS_FILE" 2>/dev/null | tail -n1)
  [[ -n "$line" ]] || return 1
  read -r TARGET TARGET_PORT <<< "$line"
  TARGET_PORT=${TARGET_PORT:-$SSH_PORT}
}
# node_labels → every node label in manifest order (node list prints one line per endpoint).
node_labels() { admin node list | awk '{ print $1 }' | uniq; }
```

- [ ] **Step 3: `deploy/hosts.sh`** (chmod +x):

```bash
#!/usr/bin/env bash
# SSH targets of the nodes, kept in ~/.otter-admin/hosts as "label target [port]".
# Usage: hosts.sh set LABEL TARGET [SSH_PORT] | get LABEL | list | rm LABEL
source "$(dirname "$0")/lib.sh"
usage="usage: hosts.sh set LABEL TARGET [SSH_PORT] | get LABEL | list | rm LABEL"
cmd=${1:-}; shift || true
without() { if [[ -f "$HOSTS_FILE" ]]; then awk -v l="$1" '$1 != l' "$HOSTS_FILE"; fi; }
case "$cmd" in
set)
  label=${1:?$usage}; target=${2:?$usage}; port=${3:-}
  [[ "$label" =~ ^[a-z0-9-]+$ ]] || die "label must be lowercase letters, digits, -"
  [[ -z "$port" || "$port" =~ ^[0-9]+$ ]] || die "ssh port must be a number"
  umask 077
  { without "$label"; echo "$label $target${port:+ $port}"; } > "$HOSTS_FILE.tmp"
  mv "$HOSTS_FILE.tmp" "$HOSTS_FILE"; chmod 0600 "$HOSTS_FILE"
  say "$label → $target${port:+ (port $port)}" ;;
get)
  label=${1:?$usage}
  host_lookup "$label" || exit 1
  echo "$TARGET $TARGET_PORT" ;;
list)
  for l in $(node_labels); do
    if host_lookup "$l"; then printf '%-12s %s %s\n' "$l" "$TARGET" "$TARGET_PORT"; else printf '%-12s -\n' "$l"; fi
  done ;;
rm)
  label=${1:?$usage}
  umask 077; without "$label" > "$HOSTS_FILE.tmp"; mv "$HOSTS_FILE.tmp" "$HOSTS_FILE" ;;
*) die "$usage" ;;
esac
```

Run `deploy/test/scripts_test.sh` → `scripts test: ok`. Also `bash -n deploy/*.sh`.

- [ ] **Step 4: Commit**

```bash
git add deploy/lib.sh deploy/hosts.sh deploy/test/scripts_test.sh
git commit -m "feat(deploy): hosts registry for node SSH targets"
```

---

### Task 3: `deploy/add-node.sh` and `deploy/status.sh`

**Goal:** One command adds a node to a running network (resumable); one command shows all nodes.

**Files:**
- Create: `deploy/add-node.sh`, `deploy/status.sh`
- Modify: `deploy/test/scripts_test.sh`

**Acceptance Criteria:**
- [ ] `add-node.sh LABEL TARGET --ip IP [--ip IP2] [--domain D] [--wss-port P] [--ssh-port N] [--version V]`:
  node add (wss host = domain or first IP) → manifest sign → hosts set → (domain: print records, wait for
  `dns check` ok, up to 30 min) → bundle (`--version` → `make-bundle.sh LABEL V`) → `push.sh` →
  `manifest publish` when other nodes exist → done message.
- [ ] Re-running the same command after a failure skips steps already done: node exists → no add; manifest
  already lists the node's pin → no sign (a node added but never signed gets signed on the re-run).
- [ ] Any failure ends with one line saying to fix the cause and re-run the same command.
- [ ] Missing `--ip` or a label already registered to a *different* target is refused before any change.
- [ ] `status.sh` prints one row per node: label, target, version, pinned hello, service, stats, disk;
  exits 1 if any node is not OK; nodes without a host still get the pinned-hello column.

**Verify:** `deploy/test/scripts_test.sh` → ok (argument checks); full flow in Task 5.

**Steps:**

- [ ] **Step 1: Failing tests** — append to `deploy/test/scripts_test.sh` before the final echo:

```bash
# --- add-node.sh argument checks (no network access needed: they fail before any ssh)
if out=$(deploy/add-node.sh n3 root@n3 2>&1); then fail "add-node without --ip"; fi
grep -q -- '--ip' <<< "$out" || fail "add-node usage: $out"
deploy/hosts.sh set n2 root@n2.example
if out=$(deploy/add-node.sh n2 root@elsewhere --ip 192.0.2.2 2>&1); then fail "add-node to another target"; fi
grep -q 'already registered' <<< "$out" || fail "add-node conflict message: $out"
# resume: a node added but never signed gets signed on the re-run; it stops at the missing release (before ssh)
bin/otter-admin --dir "$OTTER_ADMIN_DIR" node add --label n3 --wss-host 192.0.2.3 --ip 192.0.2.3 >/dev/null
if out=$(deploy/add-node.sh n3 root@n3.example --ip 192.0.2.3 --version 0.0.0-missing 2>&1); then fail "add-node without release"; fi
grep -q 'skipping node add' <<< "$out" || fail "add-node resume: $out"
grep -q 're-run the same command' <<< "$out" || fail "add-node resume hint: $out"
bin/otter-admin --dir "$OTTER_ADMIN_DIR" manifest show | grep -q '"n3"' || fail "n3 not signed into the manifest"
bin/otter-admin --dir "$OTTER_ADMIN_DIR" node remove --label n3 >/dev/null
bin/otter-admin --dir "$OTTER_ADMIN_DIR" manifest sign >/dev/null
deploy/hosts.sh rm n3

# --- status.sh with stubbed ssh: unreachable nodes are reported, exit 1
mkdir -p "$work/stub"
printf '#!/bin/sh\necho "ssh: connect to host: Connection refused" >&2\nexit 255\n' > "$work/stub/ssh"
chmod +x "$work/stub/ssh"
if out=$(PATH="$work/stub:$PATH" deploy/status.sh 2>&1); then fail "status should fail"; fi
grep -q '^n1 ' <<< "$out" && grep -q '^n2 ' <<< "$out" || fail "status rows: $out"
```

Run → FAIL (scripts missing).

- [ ] **Step 2: `deploy/add-node.sh`** (chmod +x):

```bash
#!/usr/bin/env bash
# Adds a node to the network and installs it; safe to re-run after a failure (docs/11 §8).
# Usage: add-node.sh LABEL ROOT@HOST --ip IP [--ip IP]... [--domain NAME] [--wss-port PORT] [--ssh-port N] [--version V]
source "$(dirname "$0")/lib.sh"
usage="usage: add-node.sh LABEL ROOT@HOST --ip IP [--ip IP]... [--domain NAME] [--wss-port PORT] [--ssh-port N] [--version V]"
label=${1:-}; target=${2:-}
[[ -n "$label" && -n "$target" && "$target" != --* ]] || die "$usage"
shift 2
ips=(); domain=""; wss_port=""; ssh_port=""; version=""
while (( $# )); do
  case "$1" in
    --ip) ips+=("${2:?$usage}"); shift 2 ;;
    --domain) domain=${2:?$usage}; shift 2 ;;
    --wss-port) wss_port=${2:?$usage}; shift 2 ;;
    --ssh-port) ssh_port=${2:?$usage}; shift 2 ;;
    --version) version=${2:?$usage}; shift 2 ;;
    *) die "$usage" ;;
  esac
done
(( ${#ips[@]} )) || die "at least one --ip (the server's public address) is required; $usage"
if host_lookup "$label" && [[ "$TARGET" != "$target" ]]; then
  die "node $label is already registered to $TARGET (deploy/hosts.sh rm $label to change it)"
fi
trap 'rc=$?; if (( rc != 0 )); then echo "add-node stopped (exit $rc): fix the cause and re-run the same command; finished steps are skipped" >&2; fi' EXIT
existing=$(node_labels)
others=$(grep -vx "$label" <<< "$existing" || true)

if grep -qx "$label" <<< "$existing"; then
  say "node $label already exists: skipping node add"
else
  args=(--label "$label" --wss-host "${domain:-${ips[0]}}")
  for ip in "${ips[@]}"; do args+=(--ip "$ip"); done
  [[ -z "$wss_port" ]] || args+=(--wss-port "$wss_port")
  say "registering node $label"
  admin node add "${args[@]}"
fi
node_env "$label"
# the pin is unique per node, so a manifest containing it already lists the node (same test as make-bundle.sh)
if [[ -f "$ADMIN_DIR/manifest.bin" ]] && admin manifest show 2>/dev/null | grep -qF "\"$OTTER_PIN\""; then
  say "the signed manifest already lists $label"
else
  say "signing the manifest (asks for the admin passphrase)"
  admin manifest sign
fi
"$ROOT/deploy/hosts.sh" set "$label" "$target" ${ssh_port:+"$ssh_port"}

if [[ -n "$domain" ]]; then
  say "create these DNS records now (TTL 300):"
  admin dns records | grep -F "$domain" || true
  say "waiting for DNS (up to 30 min; Ctrl-C and re-run this command to resume)"
  for _ in $(seq 60); do
    if admin dns check --label "$label" >/dev/null 2>&1; then break; fi
    sleep 30
  done
  admin dns check --label "$label" || die "DNS for $domain is not correct yet"
fi

[[ -z "$version" ]] || "$ROOT/deploy/make-bundle.sh" "$label" "$version"
host_lookup "$label"
say "installing $label on $TARGET"
OTTER_SSH_PORT=$TARGET_PORT "$ROOT/deploy/push.sh" "$label" "$TARGET"
if [[ -n "$others" ]]; then
  say "publishing the new manifest to the running nodes"
  admin manifest publish
fi
say "done: $label is part of the network; phones learn about it on their next connection"
```

Notes: `push.sh` → `check.sh` already verifies DNS, pinned hello, service, health. Check that
`otter-admin manifest show` prints node labels and pins as JSON strings (`"n3"`, `"<pin>"`) — `make-bundle.sh`
already relies on the pin form; adjust the test's `'"n3"'` grep if labels print differently. Without
`--version`, `push.sh` bundles the newest release in `dist/` (fine for real use).

- [ ] **Step 3: `deploy/status.sh`** (chmod +x):

```bash
#!/usr/bin/env bash
# One row per node: reachability, version, health, database counts, disk. Usage: status.sh
source "$(dirname "$0")/lib.sh"
bad=0
printf '%-12s %-22s %-10s %-6s %-8s %-48s %s\n' LABEL TARGET VERSION HELLO SERVICE STATS DISK
for label in $(node_labels); do
  node_env "$label"
  host=$OTTER_HOST; if [[ "$host" == *:* ]]; then host="[$host]"; fi
  if "$NODE_BIN" probe --url "wss://$host:$OTTER_PORT$OTTER_PATH" --pin "$OTTER_PIN" \
       --expect-node "$OTTER_NODE_ID" --timeout 5s >/dev/null 2>&1; then hello=ok; else hello=FAIL; bad=1; fi
  target=- version=- service=- stats=- disk=-
  if host_lookup "$label"; then
    target=$TARGET
    if out=$(OTTER_SSH_PORT=$TARGET_PORT SSH_PORT=$TARGET_PORT remote "$TARGET" \
        '/usr/local/bin/otter-node version; systemctl is-active otter-node || true;
         runuser -u otter -- /usr/local/bin/otter-node stats --config /etc/otter/node.toml 2>/dev/null || echo -;
         du -sh /var/lib/otter 2>/dev/null | cut -f1' 2>/dev/null); then
      { read -r version; read -r service; read -r stats; read -r disk; } <<< "$out"
      [[ "$service" == active ]] || bad=1
    else
      service=unreachable; bad=1
    fi
  fi
  printf '%-12s %-22s %-10s %-6s %-8s %-48s %s\n' "$label" "$target" "$version" "$hello" "$service" "$stats" "$disk"
done
exit $bad
```

`SSH_PORT` is set in the subshell of the command substitution so `remote` uses the node's own port.
Run `deploy/test/scripts_test.sh` → ok.

- [ ] **Step 4: Commit**

```bash
git add deploy/add-node.sh deploy/status.sh deploy/test/scripts_test.sh
git commit -m "feat(deploy): add-node.sh and status.sh"
```

---

### Task 4: `deploy/upgrade-all.sh`

**Goal:** Build a release and upgrade every node one by one, stopping at the first rollback.

**Files:**
- Create: `deploy/upgrade-all.sh`
- Modify: `deploy/test/scripts_test.sh`

**Acceptance Criteria:**
- [ ] `upgrade-all.sh VERSION [--only LABEL]...` runs `make release VERSION=…` unless both
  `dist/otter-node_VERSION_linux_{amd64,arm64}` exist.
- [ ] Every selected node must have a host (else: error naming `deploy/hosts.sh set`) — checked before any
  upgrade starts.
- [ ] Per node: `uname -m` → amd64/arm64 (else error); skips a node already on VERSION; runs `upgrade.sh`.
- [ ] Stops at the first node whose upgrade exits non-zero, prints a summary (`upgraded / skipped / rolled
  back / not attempted`) and exits with that code (2 or 3).

**Verify:** `deploy/test/scripts_test.sh` → ok; full flow in Task 5.

**Steps:**

- [ ] **Step 1: Failing tests** — append before the final echo of `scripts_test.sh`:

```bash
# --- upgrade-all.sh: refuses when a node has no host, before touching anything
deploy/hosts.sh rm n2
touch dist/otter-node_0.0.0-st_linux_amd64 dist/otter-node_0.0.0-st_linux_arm64
if out=$(deploy/upgrade-all.sh 0.0.0-st 2>&1); then fail "upgrade-all without hosts"; fi
grep -q 'hosts.sh set n1' <<< "$out" || fail "upgrade-all message: $out"
# --only limits the set; an unknown CPU type is refused
deploy/hosts.sh set n1 root@n1.example
printf '#!/bin/sh\ncase "$*" in *uname*) echo sparc64;; *) exit 0;; esac\n' > "$work/stub/ssh"
if out=$(PATH="$work/stub:$PATH" deploy/upgrade-all.sh 0.0.0-st --only n1 2>&1); then fail "sparc accepted"; fi
grep -q 'sparc64' <<< "$out" || fail "arch message: $out"
rm -f dist/otter-node_0.0.0-st_linux_*
```

Run → FAIL.

- [ ] **Step 2: `deploy/upgrade-all.sh`** (chmod +x):

```bash
#!/usr/bin/env bash
# Rolling upgrade of every node (or --only LABEL...) to VERSION; stops at the first failure.
# Usage: upgrade-all.sh VERSION [--only LABEL]...   Exit: 0 all done, 2 rolled back, 3 manual action needed.
source "$(dirname "$0")/lib.sh"
usage="usage: upgrade-all.sh VERSION [--only LABEL]..."
version=${1:?$usage}; shift
only=()
while (( $# )); do case "$1" in --only) only+=("${2:?$usage}"); shift 2 ;; *) die "$usage" ;; esac; done
labels=()
for l in $(node_labels); do
  if (( ${#only[@]} == 0 )) || printf '%s\n' "${only[@]}" | grep -qx "$l"; then labels+=("$l"); fi
done
(( ${#labels[@]} )) || die "no matching nodes"
for l in "${labels[@]}"; do host_lookup "$l" || die "node $l has no SSH target: deploy/hosts.sh set $l root@HOST"; done

if [[ ! -f "$ROOT/dist/otter-node_${version}_linux_amd64" || ! -f "$ROOT/dist/otter-node_${version}_linux_arm64" ]]; then
  say "building release $version"
  make -C "$ROOT" -s release VERSION="$version"
fi

declare -A result
for l in "${labels[@]}"; do result[$l]="not attempted"; done
summary() { for l in "${labels[@]}"; do printf '%-12s %s\n' "$l" "${result[$l]}"; done; }
for l in "${labels[@]}"; do
  host_lookup "$l"
  export OTTER_SSH_PORT=$TARGET_PORT SSH_PORT=$TARGET_PORT
  m=$(remote "$TARGET" uname -m) || { result[$l]="unreachable"; summary; exit 3; }
  case "$m" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) die "node $l: unsupported CPU type $m" ;; esac
  cur=$(remote "$TARGET" /usr/local/bin/otter-node version 2>/dev/null || echo unknown)
  if [[ "$cur" == "$version" ]]; then result[$l]="already $version"; continue; fi
  say "upgrading $l ($TARGET, $arch) from $cur to $version"
  set +e; "$ROOT/deploy/upgrade.sh" "$TARGET" "$ROOT/dist/otter-node_${version}_linux_$arch"; rc=$?; set -e
  case $rc in
    0) result[$l]="upgraded $cur → $version" ;;
    2) result[$l]="ROLLED BACK (still $cur)"; summary; exit 2 ;;
    *) result[$l]="FAILED — check the server now"; summary; exit 3 ;;
  esac
done
summary
say "all selected nodes are on $version"
```

Run `deploy/test/scripts_test.sh` → ok.

- [ ] **Step 3: Commit**

```bash
git add deploy/upgrade-all.sh deploy/test/scripts_test.sh
git commit -m "feat(deploy): upgrade-all.sh rolling upgrade"
```

---

### Task 5: Two-VM end-to-end test

**Goal:** Prove add-node, replication between two real installs, upgrade-all and status on two QEMU VMs.

**Files:**
- Modify: `deploy/test/vm.sh` (named instances), `Makefile` (`deploy-test` target)
- Create: `deploy/test/e2e-mesh.sh`

**Acceptance Criteria:**
- [ ] `vm.sh` supports `OTTER_VM=name OTTER_VM_SSH=port OTTER_VM_WSS=port vm.sh start|stop|ssh`; defaults
  (`vm`, 2222, 27443) keep `e2e.sh` working unchanged.
- [ ] `e2e-mesh.sh`: VM a (ssh 2222, wss 27443) installed with `add-node.sh` as the first node; VM b
  (ssh 2223, wss 27444) added with `add-node.sh`; both journals show `peer session up`; b's `stats`
  records count reaches a's within 60 s; `upgrade-all.sh` moves both to a second version; `status.sh`
  exits 0; VMs stopped at the end (unless `--keep`).
- [ ] `deploy/test/e2e.sh` still passes.

**Verify:** `deploy/test/e2e-mesh.sh` → `e2e-mesh: all steps passed`; `deploy/test/e2e.sh` → `e2e: all steps passed`

**Steps:**

- [ ] **Step 1: Named VMs** — in `deploy/test/vm.sh` replace the fixed names/ports:

```bash
NAME=${OTTER_VM:-vm}; SSH_PORT=${OTTER_VM_SSH:-2222}; WSS_PORT=${OTTER_VM_WSS:-27443}
VM=.vm; RUN=".vm/run-$NAME"; CACHE="$HOME/.cache/otter-vm"
SSH=(ssh -p "$SSH_PORT" -i "$VM/id" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 root@127.0.0.1)
```

and in `start`/`stop` use `$RUN` for per-instance files (`disk.qcow2`, `seed/`, `seed.img`, `qemu.pid`,
`console.log`) while the key stays `$VM/id`; `mkdir -p "$RUN/seed"`; hostfwd becomes
`hostfwd=tcp:127.0.0.1:$SSH_PORT-:22,hostfwd=tcp:127.0.0.1:$WSS_PORT-:$WSS_PORT`; `local-hostname:
otter-$NAME`. Run `deploy/test/e2e.sh` → still passes (default instance).

- [ ] **Step 2: `deploy/test/e2e-mesh.sh`** (chmod +x):

```bash
#!/usr/bin/env bash
# Two-node deploy test on two VMs: add-node, replication, upgrade-all, status. Usage: e2e-mesh.sh [--keep]
set -euo pipefail
cd "$(dirname "$0")/../.."
keep=0; if [[ "${1:-}" == --keep ]]; then keep=1; fi
work=$(mktemp -d)
vm() { local n=$1; shift; case $n in a) OTTER_VM=a OTTER_VM_SSH=2222 OTTER_VM_WSS=27443 deploy/test/vm.sh "$@" ;;
                                      b) OTTER_VM=b OTTER_VM_SSH=2223 OTTER_VM_WSS=27444 deploy/test/vm.sh "$@" ;; esac; }
cleanup() { if (( ! keep )); then vm a stop; vm b stop; fi; rm -rf "$work"; }
trap cleanup EXIT
step() { printf '\n######## %s\n' "$*"; }
fail() { printf '\ne2e-mesh: FAIL: %s\n' "$*" >&2; exit 1; }
export OTTER_ADMIN_DIR="$work/admin" OTTER_ADMIN_PASSPHRASE=e2e-only-passphrase OTTER_SKIP_DNS=1
export OTTER_SSH_OPTS="-i $PWD/.vm/id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
stat_of() { vm "$1" ssh runuser -u otter -- /usr/local/bin/otter-node stats --config /etc/otter/node.toml; }
records() { sed -E 's/.*records=([0-9]+).*/\1/' <<< "$1"; }
# Inside each VM the other node's manifest address 127.0.0.1:<its port> is forwarded to the host
# (10.0.2.2), whose hostfwd reaches the other VM.
bridge() {
  vm "$1" ssh "command -v nft >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables >/dev/null
    sysctl -qw net.ipv4.conf.all.route_localnet=1
    nft add table ip otterlab
    nft add chain ip otterlab out '{ type nat hook output priority -100; }'
    nft add rule ip otterlab out ip daddr 127.0.0.1 tcp dport $2 dnat to 10.0.2.2:$2
    nft add chain ip otterlab post '{ type nat hook postrouting priority 100; }'
    nft add rule ip otterlab post ip daddr 10.0.2.2 masquerade"
}

step "build"
make -s build
make -s release VERSION=0.0.1-e2e >/dev/null
step "VMs"
vm a start; vm b start
bridge a 27444; bridge b 27443
step "network + first node (add-node.sh)"
bin/otter-admin --dir "$OTTER_ADMIN_DIR" network init >/dev/null
# first node: add-node.sh registers and signs; the bootstrap invite must exist before the bundle is built
bin/otter-admin --dir "$OTTER_ADMIN_DIR" node add --label a --wss-host 127.0.0.1 --ip 127.0.0.1 >/dev/null
bin/otter-admin --dir "$OTTER_ADMIN_DIR" manifest sign >/dev/null
bin/otter-admin --dir "$OTTER_ADMIN_DIR" invite bootstrap >/dev/null
deploy/add-node.sh a root@127.0.0.1 --ip 127.0.0.1 --ssh-port 2222 --version 0.0.1-e2e
step "second node (add-node.sh)"
deploy/add-node.sh b root@127.0.0.1 --ip 127.0.0.1 --wss-port 27444 --ssh-port 2223 --version 0.0.1-e2e
[[ "$(deploy/hosts.sh get b)" == "root@127.0.0.1 2223" ]] || fail "host of b"
step "replication"
for _ in $(seq 60); do
  sa=$(stat_of a); sb=$(stat_of b)
  if (( $(records "$sb") >= $(records "$sa") )) && vm a ssh "journalctl -u otter-node --no-pager | grep -q 'peer session up'"; then break; fi
  sleep 1
done
echo "a: $sa"; echo "b: $sb"
(( $(records "$sb") >= $(records "$sa") )) || fail "b did not catch up with a"
vm b ssh "journalctl -u otter-node --no-pager | grep -q 'peer session up'" || fail "no peer session on b"
step "status"
deploy/status.sh || fail "status reported a problem"
step "upgrade-all to 0.0.2-e2e"
deploy/upgrade-all.sh 0.0.2-e2e
[[ "$(vm a ssh /usr/local/bin/otter-node version)" == 0.0.2-e2e ]] || fail "a version"
[[ "$(vm b ssh /usr/local/bin/otter-node version)" == 0.0.2-e2e ]] || fail "b version"
deploy/upgrade-all.sh 0.0.2-e2e | grep -q 'already 0.0.2-e2e' || fail "second run should skip"
deploy/status.sh || fail "status after upgrade"
rm -f dist/*-e2e* dist/bundle-a.* dist/bundle-b.*   # never other bundle files: the owner's are in dist/ too
(cd dist && if ls otter-*_* >/dev/null 2>&1; then sha256sum otter-*_* > SHA256SUMS; else rm -f SHA256SUMS; fi)
printf '\ne2e-mesh: all steps passed\n'
```

Notes for the engineer:
* Both VMs forward their own WSS port only; `check.sh` (run by `push.sh`) probes `127.0.0.1:<port>` from
  the host, which is the node's real manifest address — no `OTTER_PROBE_ADDR` needed.
* Node a is registered and signed by hand first because the bootstrap invite needs a signed manifest and
  must exist before a's bundle is built; `add-node.sh a …` then sees the node exists and is signed, skips
  add/sign, builds the bundle (with the invite) and installs it; there are no other nodes, so no publish.
  Node b goes through the full path (add, sign, install, publish to a).
* `--version 0.0.1-e2e` matters: without it `push.sh` would bundle the newest release in `dist/` (the
  owner's real `0.2.0`).
* If `apt-get install nftables` is slow/unavailable in the image, check `nft --version` first; Debian 12
  genericcloud ships it in most builds.
* If peers do not connect, look at `journalctl -u otter-node` on both VMs for `peer dial failed`
  (`log_level = "debug"` in `/etc/otter/node.toml` + restart shows dial errors).

- [ ] **Step 3: Makefile target** — add to `Makefile` (`.PHONY` too):

```make
deploy-test:
	deploy/test/scripts_test.sh
	deploy/test/bundle_test.sh
	deploy/test/e2e.sh
	deploy/test/e2e-mesh.sh
```

- [ ] **Step 4: Run** `deploy/test/e2e-mesh.sh` → passes; `deploy/test/e2e.sh` → passes.

- [ ] **Step 5: Commit**

```bash
git add deploy/test/vm.sh deploy/test/e2e-mesh.sh Makefile
git commit -m "test(deploy): two-VM add-node, replication and rolling upgrade"
```

---

### Task 6: Docs, register `eeee`, merge

**Goal:** Document the new commands, record the decision, register the owner's existing node, merge.

**Files:**
- Modify: `deploy/README.md`, `deploy/FIRST-DEPLOY.md`
- Modify (not in git): `docs/11-deployment.md`, `docs/09-roadmap.md`, `docs/00-decisions.md`
- Memory: `~/.claude/projects/-home-al-Documents-Projects-OttterMSG/memory/otter-milestone-status.md`

**Acceptance Criteria:**
- [ ] `deploy/README.md`: "New node" shows `add-node.sh`; "Day 2" table has `status.sh`, `upgrade-all.sh`,
  `hosts.sh`; Tests lists `scripts_test.sh`, `e2e-mesh.sh`, `make deploy-test`.
- [ ] `FIRST-DEPLOY.md`: after step 5 "Register the server: `deploy/hosts.sh set LABEL root@IP`"; new
  section "Second node" (`add-node.sh … --ip …`, note that an IP-only network should add a second node
  soon); §7 uses `upgrade-all.sh`.
- [ ] `docs/00-decisions.md`: D49 — admin hosts registry + one-command add/upgrade/status (wrappers only;
  no agent on servers; rolling upgrade stops at first rollback).
- [ ] `docs/09-roadmap.md`: M1.6 row (done date) + "M1.6 notes" (deviations).
- [ ] With the owner's OK only: `deploy/hosts.sh set eeee root@eeee` on the real admin dir, then
  `deploy/status.sh` shows eeee OK (read-only; prints the result to the owner).
- [ ] `make check` and `deploy/test/scripts_test.sh` pass on the merge result; `m1-6-ops` fast-forwarded
  into `main`; memory updated (M1.6 merged; next: M6 plan `docs/superpowers/plans/2026-11-12-m6-backup-restore.md`).

**Verify:** `make check && deploy/test/scripts_test.sh` → PASS / ok

**Steps:**

- [ ] **Step 1:** Edit `deploy/README.md` — replace the "New node" block with:

```markdown
## New node

First node of a new network: `deploy/FIRST-DEPLOY.md`. Every further node, one command:

```bash
deploy/add-node.sh fi-2 root@198.51.100.20 --ip 198.51.100.20 [--domain chat2.example.org]
```

It registers the node, signs the manifest (passphrase), remembers the SSH target in `~/.otter-admin/hosts`,
waits for DNS (with `--domain`), installs and checks the node, then publishes the new manifest to the running
nodes so they connect to it. Re-run the same command to resume after an error.
```

and add rows to "Day 2": `| All nodes at a glance | deploy/status.sh |`,
`| Upgrade every node | deploy/upgrade-all.sh 1.2.1 (stops at the first rollback) |`,
`| SSH target of a node | deploy/hosts.sh set fi-1 root@203.0.113.10 [port] / list |`.
Tests: add `deploy/test/scripts_test.sh` (offline), `deploy/test/e2e-mesh.sh [--keep]` (two VMs), and
`make deploy-test` (all four).

- [ ] **Step 2:** Edit `FIRST-DEPLOY.md` as in the acceptance criteria; in §7 replace the `upgrade.sh` lines
with `deploy/upgrade-all.sh <next>` (keep the broken-binary rollback test using `upgrade.sh`, it needs a
custom binary).

- [ ] **Step 3:** Decisions/roadmap/deployment docs (outside git) as in the acceptance criteria. In
`docs/11-deployment.md` add a section "§8 Adding nodes and rolling upgrades" describing the four scripts and
the hosts file format `label target [port]`.

- [ ] **Step 4: Commit and merge**

```bash
git add deploy/README.md deploy/FIRST-DEPLOY.md
git commit -m "docs(deploy): add-node, status, upgrade-all, hosts registry"
make check && deploy/test/scripts_test.sh
git checkout main && git merge --ff-only m1-6-ops && git branch -d m1-6-ops
```

- [ ] **Step 5:** Ask the owner before touching `~/.otter-admin`; then `deploy/hosts.sh set eeee root@eeee`
and `deploy/status.sh`; report the table. Update the memory file.

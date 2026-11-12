# M1.5 — Deployment + Profile Editing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A node goes from source to a running, health-checked systemd service on a fresh Debian/Ubuntu server with
one bundle and one command, can be upgraded with automatic rollback, and is verified by a scripted VM test. Members
can edit their display name in the app, and the change reaches every other member through the directory.

**Read first (in this order):**
1. `docs/09-roadmap.md` → "M1 notes", "M2 notes", **"M3 notes"** (build facts: Gradle on **Temurin 21**
   `JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2`; the `staging` build type; dev-mesh hints; open issues).
2. `docs/11-deployment.md` (the whole procedure this milestone implements; §10 is the work list; M2 already did the
   pinning rows marked "Done in M2").
3. `docs/00-decisions.md` D14 (display names visible to nodes), D25–D28 (deployment), D31 (username clash rule).
4. `docs/10-otter-design-guidelines.md` §4–§5 (type, geometry), §10 (Settings: "Профиль — аватар, имя, редактирование;
   username отдельно от отображаемого имени"), §12 (tone, TalkBack).
5. `docs/superpowers/plans/2026-11-11-m3-groups.md` for the plan format and what exists.

**Architecture:**
- *Server side:* new CLI pieces in Go (`otter-node probe|check|backup`, `otter-admin dns …|node set-ip|rotate-tls|drop-old-pins|env|version`,
  `make release`), bash scripts in `otter-server/deploy/` that only glue those commands together, and a QEMU/KVM VM
  test that runs the real scripts against a Debian 12 cloud image.
- *Profile:* a member publishes a new version of their own signed `DIRECTORY_ENTRY` through a new node method
  `directory.update`. Nodes already replicate directory entries and push a `directory` event; the other apps already
  update contact names and direct-chat titles from it. The app stores the new name locally at once and publishes it
  whenever it is online (pending flag), so editing works offline.

**Decisions (made by the planner; Task 12 records them as D39–D43 in `docs/00-decisions.md`):**
- **D39 Profile scope in V1:** the profile is the **display name** only (1–64 characters, plaintext in the directory per
  D14). The username can't be changed (a rename comes with the username-conflict screen in M8). Profile photos need blobs
  (M4) and encrypted profiles (V2), so they are not in this milestone; the avatar stays coloured initials.
  A name edit is saved on the phone immediately and published to the directory when online; until then Settings says so.
- **D40 `DirectoryEntry.registered_ms`:** new field = the time of the first registration, copied into every later
  version. Nodes rank username clashes (D31) by `registered_ms` (or, when 0 — entries from M1–M3 — by the record's
  `created_ms`), so a profile update never changes who keeps a username. `directory.update` refuses a changed username
  (`INVALID`) and a version that isn't newer (`CONFLICT`).
- **D41 `otter-node backup` and `otter-node check` move from M8 to M1.5:** the upgrade rollback needs a consistent DB
  copy without the `sqlite3` CLI on the server, and install needs a config check before starting the service.
- **D42 TLS rotation files:** `node rotate-tls` stages `tls.new.crt/key` and adds the new pin next to the old one;
  bundles use the staged pair when present; `node drop-old-pins` promotes it (old pair kept as `tls.old.*`) and leaves
  only the new pin. `node set-ip` re-issues the certificate **with the same key**, so the pin doesn't change.
- **D43 Scripts and admin directory:** every script honours `OTTER_ADMIN_DIR` (default `~/.otter-admin`),
  `OTTER_SSH_PORT` and `OTTER_SSH_OPTS`; server-side helpers live in `/usr/local/lib/otter/`; `/etc/otter/probe.env`
  holds the URL, pin and node id the health check uses (`--addr 127.0.0.1:<port>`, so it works before DNS is updated).

**Tech Stack:** Go 1.26 (server, CLI), bash (`set -euo pipefail`), QEMU/KVM + Debian 12 `genericcloud` image (VM test;
`qemu-system-x86_64` and `/dev/kvm` are present on the dev machine, the user is in group `kvm`), Kotlin/Compose (app).

**Out of scope:** profile photos, username rename (M8), REALITY/port 443 (M7), `otter-node status` and `/metrics` (M8),
sudo/non-root SSH targets (scripts expect `root@host`), `sqlite3` on servers.

**Branches:** `m1-5-deploy` in `otter-server` and in `otter-android` (create from `main`). The top-level `docs/` is not
in git; edit it in place.

---

## File structure

```
otter-server/
  Makefile                                   + release target (version-stamped, cross-compiled, SHA256SUMS)
  .gitignore                                 + dist/
  proto/otter/v1/records.proto               DirectoryEntry.registered_ms = 9
  internal/client/client.go (+test)          DialWith(DialOptions{AllowPlain, Addr, Insecure})
  internal/probe/probe.go (+test)            pinned WSS hello probe
  internal/nodecheck/check.go (+test)        config/key/manifest/TLS consistency check
  internal/store/backup.go (+test)           VACUUM INTO
  internal/store/typed.go                    entry_created_ms from registered_ms
  internal/records/validate.go (+test)       registered_ms ≤ created_ms + 5 min
  internal/service/directory.go (+test)      UpdateDirectoryEntry
  internal/gateway/methods.go, profile_test.go   directory.update
  internal/pinning/pinning.go (+test)        IssueCert(existing key)
  internal/admin/nodeops.go (+test)          SetIPs, RotateTLS, DropOldPins, NodeEnv
  internal/admin/dns.go (+test)              DNSRecords, CheckDNS
  cmd/otter-node/main.go (+test)             probe, check, backup
  cmd/otter-admin/main.go (+test)            dns records|check, node set-ip|rotate-tls|drop-old-pins|env, version
  deploy/
    README.md                                quick reference (points to docs/11)
    lib.sh                                   shared helpers for admin-side scripts
    make-bundle.sh, push.sh, upgrade.sh, check.sh
    bundle/install.sh, bundle/uninstall.sh, bundle/backup.sh, bundle/health.sh   (copied into each bundle)
    templates/node.toml, templates/otter-node.service, templates/otter-backup.service,
    templates/otter-backup.timer, templates/site/index.html
    test/bundle_test.sh                      offline bundle test (no VM)
    test/vm.sh, test/e2e.sh                  VM test

otter-android/
  core/proto (synced)                        registered_ms
  core/data/account/DirectoryEntries.kt      one builder for registration and updates
  core/data/account/AccountRepository.kt     reload(), createdMs
  core/data/profile/ProfileRepository.kt (+test)   local save, pending flag, publisher loop
  core/data/settings/Settings.kt             entryVersion, profilePending
  core/data/directory/DirectorySync.kt       own entry → version, adopt name when not pending
  core/data/sync/SyncEngine.kt               session.launch { profile.run(api) }
  core/data/registration/Registration.kt     uses DirectoryEntries, registered_ms
  core/network/NodeApi.kt                    updateDirectory()
  core/database/dao/AccountDao.kt            setDisplayName()
  core/data/src/test/.../FakeNode.kt         directory.update
  core/data/src/test/.../LiveProfileTest.kt  against dev-node / VM
  feature/settings/ (new module)             SettingsScreen (moved), ProfileScreen, EditNameScreen
  core/ui/theme                              primaryContainer tokens (M3 open issue: lavender FAB)
  app/AppNavHost.kt                          routes
  docs/m1.5-manual-test.md
```

---

### Task 1: `make release` and version stamping

**Goal:** `make release VERSION=x.y.z` produces static, version-stamped `otter-node` for linux/amd64 and linux/arm64,
`otter-admin` for the admin machine, and `dist/SHA256SUMS`.

**Files:**
- Modify: `otter-server/Makefile`, `otter-server/.gitignore`, `otter-server/cmd/otter-admin/main.go`
- Test: `otter-server/cmd/otter-admin/main_test.go`

**Acceptance Criteria:**
- [ ] `make release` without `VERSION` fails with "set VERSION=x.y.z".
- [ ] `make release VERSION=0.0.1-test` creates `dist/otter-node_0.0.1-test_linux_{amd64,arm64}`,
      `dist/otter-admin_0.0.1-test_<goos>_<goarch>`, `dist/SHA256SUMS`; `file` reports "statically linked".
- [ ] `dist/otter-node_0.0.1-test_linux_amd64 version` prints `0.0.1-test`; `otter-admin version` prints the version.
- [ ] Older versions in `dist/` are kept; `SHA256SUMS` covers every `otter-*_*` file.

**Verify:** `cd otter-server && make release VERSION=0.0.1-test && dist/otter-node_0.0.1-test_linux_amd64 version && (cd dist && sha256sum -c SHA256SUMS)`

**Steps:**

- [ ] **Step 1: test for `otter-admin version`** in `cmd/otter-admin/main_test.go`:

```go
func TestVersion(t *testing.T) {
	var out bytes.Buffer
	if err := run([]string{"version"}, &out, strings.NewReader("")); err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(out.String()) != version {
		t.Fatalf("got %q", out.String())
	}
}
```
Run `go test ./cmd/otter-admin -run TestVersion` → FAIL (`version` undefined).

- [ ] **Step 2: implement.** In `cmd/otter-admin/main.go` add `var version = "dev"`, add `  version` to `usage`, and at
the top of `run` after `root.Parse`:

```go
	a := root.Args()
	if len(a) == 1 && a[0] == "version" {
		fmt.Fprintln(out, version)
		return nil
	}
```
(keep the existing `if len(a) < 2` check after it).

- [ ] **Step 3: Makefile.**

```make
VERSION ?=
GOOS_HOST := $(shell go env GOOS)
GOARCH_HOST := $(shell go env GOARCH)
LDFLAGS = -s -w -X main.version=$(VERSION)

.PHONY: release
release:
	@test -n "$(VERSION)" || { echo "set VERSION=x.y.z"; exit 1; }
	mkdir -p dist
	for arch in amd64 arm64; do \
	  CGO_ENABLED=0 GOOS=linux GOARCH=$$arch go build -trimpath -ldflags "$(LDFLAGS)" \
	    -o dist/otter-node_$(VERSION)_linux_$$arch ./cmd/otter-node || exit 1; \
	done
	CGO_ENABLED=0 go build -trimpath -ldflags "$(LDFLAGS)" \
	  -o dist/otter-admin_$(VERSION)_$(GOOS_HOST)_$(GOARCH_HOST) ./cmd/otter-admin
	cd dist && sha256sum otter-*_* > SHA256SUMS
```
Also stamp `make build`: `CGO_ENABLED=0 go build -trimpath -ldflags "-X main.version=dev-$$(git rev-parse --short HEAD)" -o bin/ ./cmd/...`.
Add `dist/` to `.gitignore`.

- [ ] **Step 4: run the Verify command**, then `file dist/otter-node_0.0.1-test_linux_arm64` → "ARM aarch64, statically linked". `rm -rf dist`.

- [ ] **Step 5: commit** `git commit -m "build: make release with version stamping and checksums"`.

---

### Task 2: `otter-node probe`, `check`, `backup`

**Goal:** three operator subcommands the scripts rely on: a pinned-TLS hello probe, a pre-start config check, and a
consistent DB copy.

**Files:**
- Modify: `otter-server/internal/client/client.go`, `otter-server/cmd/otter-node/main.go`
- Create: `otter-server/internal/probe/probe.go`, `probe_test.go`; `otter-server/internal/nodecheck/check.go`,
  `check_test.go`; `otter-server/internal/store/backup.go`, `backup_test.go`

**Acceptance Criteria:**
- [ ] `otter-node probe --url wss://H:P/path --pin B64 [--pin …] [--addr IP:PORT] [--insecure] [--expect-node HEX] [--timeout 10s]`
      prints `ok node_id=<hex> protocol=1 rtt=<n>ms` and exits 0; exits 1 on wrong pin, wrong node id, timeout, or a
      `wss` URL without `--pin`/`--insecure`. It needs no config file.
- [ ] `--addr` dials that address but keeps the URL host for SNI and certificate checks.
- [ ] `otter-node check --config F` verifies: config loads; node key reads; `manifest_file` verifies against
      `network_pub`; this node is in the manifest; the manifest endpoint path equals `wss.path`; `tls_cert`/`tls_key` load as a
      pair and the certificate's pin is in the endpoint's pins. Prints one `ok …` line per check, or the first failure, and
      never opens the database.
- [ ] `otter-node backup --config F --out FILE` writes a consistent copy (`VACUUM INTO`) while the node may be running;
      refuses an existing `FILE`.

**Verify:** `cd otter-server && go test -race ./internal/probe ./internal/nodecheck ./internal/store ./internal/client ./cmd/otter-node`

**Steps:**

- [ ] **Step 1: `client.DialWith`.** Replace `Dial`'s body in `internal/client/client.go`:

```go
// DialOptions tune Dial for operator tools.
type DialOptions struct {
	AllowPlain bool
	Addr       string // dial this host:port instead of the endpoint's; SNI and checks still use ep.Host
	Insecure   bool   // without pins: skip certificate verification (decoy checks only)
}

func Dial(ctx context.Context, ep *pb.Endpoint, allowPlain bool) (*Conn, error) {
	return DialWith(ctx, ep, DialOptions{AllowPlain: allowPlain})
}

// DialWith connects to ep (pinned TLS for WSS) and waits for the node's hello.
func DialWith(ctx context.Context, ep *pb.Endpoint, o DialOptions) (*Conn, error) {
	url, err := URL(ep, o.AllowPlain)
	if err != nil {
		return nil, err
	}
	tr := &http.Transport{}
	if ep.Kind == pb.Endpoint_WSS {
		cfg := pinning.ClientConfig(ep.Host, ep.TlsSpkiPins)
		if o.Insecure && len(ep.TlsSpkiPins) == 0 {
			cfg.InsecureSkipVerify = true
		}
		tr.TLSClientConfig = cfg
	}
	if o.Addr != "" {
		d := &net.Dialer{}
		tr.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
			return d.DialContext(ctx, network, o.Addr)
		}
	}
	c, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPClient: &http.Client{Transport: tr}})
	if err != nil {
		return nil, err
	}
	// … unchanged from here (SetReadLimit, readLoop, wait for hello)
```

- [ ] **Step 2: failing probe tests** `internal/probe/probe_test.go`. A TLS `httptest` server serving the real gateway
  with a certificate for `chat.test` from `pinning.GenerateCert`:

```go
func tlsNode(t *testing.T) (addr string, pin []byte, nodeID []byte) {
	st, err := store.Open(filepath.Join(t.TempDir(), "n.db"))
	if err != nil {
		t.Fatal(err)
	}
	pub, _, _ := ed25519.GenerateKey(nil)
	_, nodeKey, _ := ed25519.GenerateKey(nil)
	svc := service.New(st, nodeKey, pub)
	certPEM, keyPEM, pin, err := pinning.GenerateCert([]string{"chat.test"}, nil, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	pair, _ := tls.X509KeyPair(certPEM, keyPEM)
	srv := httptest.NewUnstartedServer(gateway.New(svc, slog.New(slog.DiscardHandler)))
	srv.TLS = &tls.Config{Certificates: []tls.Certificate{pair}}
	srv.StartTLS()
	t.Cleanup(func() { srv.Close(); st.Close() })
	return srv.Listener.Addr().String(), pin, svc.NodeID
}

func TestProbe(t *testing.T) {
	addr, pin, id := tlsNode(t)
	_, port, _ := net.SplitHostPort(addr)
	url := "wss://chat.test:" + port + "/"
	ctx := context.Background()
	ok := Options{URL: url, Pins: [][]byte{pin}, Addr: addr, ExpectNode: id, Timeout: 5 * time.Second}
	r, err := Run(ctx, ok)
	if err != nil || !bytes.Equal(r.NodeID, id) || r.Protocol != 1 {
		t.Fatalf("probe: %v %+v", err, r)
	}
	bad := ok
	bad.Pins = [][]byte{make([]byte, 32)}
	if _, err := Run(ctx, bad); err == nil {
		t.Fatal("wrong pin accepted")
	}
	other := ok
	other.ExpectNode = make([]byte, 16)
	if _, err := Run(ctx, other); err == nil {
		t.Fatal("wrong node id accepted")
	}
	none := ok
	none.Pins = nil
	if _, err := Run(ctx, none); err == nil {
		t.Fatal("wss without pins or --insecure accepted")
	}
}
```
(`gateway.New` serves the WebSocket on any path in tests, as `testclient_test.go` does with `httptest.NewServer(gw)`.)
Run → FAIL (package missing).

- [ ] **Step 3: `internal/probe/probe.go`.**

```go
// Package probe checks that a node answers with its hello over (pinned) WSS. Used by health checks.
package probe

type Options struct {
	URL        string
	Pins       [][]byte
	Addr       string
	Insecure   bool
	ExpectNode []byte
	Timeout    time.Duration
}

type Result struct {
	NodeID   []byte
	Protocol uint32
	RTT      time.Duration
}

func Run(ctx context.Context, o Options) (*Result, error) {
	u, err := url.Parse(o.URL)
	if err != nil || (u.Scheme != "wss" && u.Scheme != "ws") {
		return nil, errors.New("url must look like wss://host:port/path")
	}
	port, _ := strconv.Atoi(u.Port())
	if port <= 0 || port > 65535 {
		return nil, errors.New("url needs an explicit port")
	}
	kind := pb.Endpoint_WSS
	if u.Scheme == "ws" {
		kind = pb.Endpoint_WS_PLAIN
	}
	if kind == pb.Endpoint_WSS && len(o.Pins) == 0 && !o.Insecure {
		return nil, errors.New("--pin or --insecure is required for wss")
	}
	path := u.Path
	if path == "" {
		path = "/"
	}
	ep := &pb.Endpoint{Kind: kind, Host: u.Hostname(), Port: uint32(port), Path: path, TlsSpkiPins: o.Pins}
	if o.Timeout <= 0 {
		o.Timeout = 10 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, o.Timeout)
	defer cancel()
	t0 := time.Now()
	c, err := client.DialWith(ctx, ep, client.DialOptions{AllowPlain: kind == pb.Endpoint_WS_PLAIN, Addr: o.Addr, Insecure: o.Insecure})
	if err != nil {
		return nil, err
	}
	defer c.Close()
	h := c.Hello()
	if len(o.ExpectNode) > 0 && !bytes.Equal(h.NodeId, o.ExpectNode) {
		return nil, fmt.Errorf("node_id %x, expected %x", h.NodeId, o.ExpectNode)
	}
	return &Result{NodeID: h.NodeId, Protocol: h.ProtocolVersion, RTT: time.Since(t0)}, nil
}
```
Run the probe test → PASS.

- [ ] **Step 4: backup.** Test `internal/store/backup_test.go`: open a store, apply one record the way `store_test.go`
  does (reuse its helper), `Backup(ctx, out)`, open `out` with `store.Open`, and assert the record is there; a second
  `Backup` to the same path returns an error. Implementation `internal/store/backup.go`:

```go
// Backup writes a consistent copy of the database to path, which must not exist yet. Safe while the node runs.
func (s *Store) Backup(ctx context.Context, path string) error {
	if _, err := os.Stat(path); err == nil {
		return fmt.Errorf("%s already exists", path)
	}
	_, err := s.r.ExecContext(ctx, `VACUUM INTO ?`, path)
	return err
}
```
(If the read-only reader pool refuses `VACUUM INTO`, run it on `s.w` instead; note which in the commit message.)

- [ ] **Step 5: `internal/nodecheck/check.go`.**

```go
// Package nodecheck verifies a node's config, keys, manifest and TLS pair before it starts (install, upgrade).
package nodecheck

// Run returns one "ok …" line per passed check, or the first failure.
func Run(cfgPath string) ([]string, error) {
	var out []string
	cfg, err := config.Load(cfgPath)
	if err != nil {
		return out, err
	}
	out = append(out, "ok config "+cfgPath)
	key, err := keys.ReadPlainKey(cfg.NodeKey)
	if err != nil {
		return out, fmt.Errorf("node_key: %w", err)
	}
	nodeID := keys.ID16(key.Public().(ed25519.PublicKey))
	out = append(out, fmt.Sprintf("ok node key, node_id %x", nodeID))
	netPub, _ := cfg.NetworkPubKey()
	raw, err := os.ReadFile(cfg.ManifestFile)
	if err != nil {
		return out, fmt.Errorf("manifest_file: %w", err)
	}
	var rec pb.Record
	if err := proto.Unmarshal(raw, &rec); err != nil {
		return out, fmt.Errorf("manifest_file: %w", err)
	}
	v := &records.Validator{NetworkPub: netPub, Users: noUsers{}, Now: time.Now}
	body, err := v.Validate(&rec)
	if err != nil || body.Type != pb.RecordType_MANIFEST {
		return out, fmt.Errorf("manifest_file does not verify against network_pub: %v", err)
	}
	var m pb.Manifest
	_ = proto.Unmarshal(body.Payload, &m)
	var me *pb.NodeInfo
	for _, n := range m.Nodes {
		if bytes.Equal(n.NodeId, nodeID) {
			me = n
		}
	}
	if me == nil {
		return out, fmt.Errorf("node %x is not in manifest version %d", nodeID, m.Version)
	}
	out = append(out, fmt.Sprintf("ok manifest version %d lists node %s", m.Version, me.Label))
	var ep *pb.Endpoint
	for _, e := range me.Endpoints {
		if e.Path == cfg.WSS.Path {
			ep = e
		}
	}
	if ep == nil {
		return out, errors.New("no manifest endpoint uses wss.path from the config")
	}
	if cfg.WSS.TLSCert == "" {
		return append(out, "ok plain endpoint (development)"), nil
	}
	pair, err := tls.LoadX509KeyPair(cfg.WSS.TLSCert, cfg.WSS.TLSKey)
	if err != nil {
		return out, fmt.Errorf("tls pair: %w", err)
	}
	leaf, _ := x509.ParseCertificate(pair.Certificate[0])
	pin := pinning.SPKIPin(leaf)
	for _, p := range ep.TlsSpkiPins {
		if bytes.Equal(p, pin) {
			return append(out, "ok tls certificate matches pin "+base64.StdEncoding.EncodeToString(pin)), nil
		}
	}
	return out, fmt.Errorf("tls certificate pin %s is not in the manifest", base64.StdEncoding.EncodeToString(pin))
}

type noUsers struct{}

func (noUsers) UserKey([]byte) (records.UserKey, bool) { return records.UserKey{}, false }
```
Test `check_test.go`: build a temp admin dir with `admin.InitNetwork`, `admin.AddNode(--wss-host chat.test)`,
`admin.SignManifest`; write a `node.toml` pointing at `nodes/<label>/{node.key,tls.crt,tls.key}` and `manifest.bin`
(path from `nodes.json` via `admin.LoadState`). Assert `Run` succeeds with 5 lines; then swap in a fresh
`pinning.GenerateCert` pair → error mentions "pin"; then a wrong `wss.path` → error "wss.path".

- [ ] **Step 6: wire the CLI** in `cmd/otter-node/main.go`. Update `usage`:

```
usage: otter-node <command>
  run --config FILE            serve clients
  import --config FILE FILE... apply signed record files (manifest, bootstrap invite)
  check --config FILE          verify config, keys, manifest and TLS before starting
  backup --config FILE --out F consistent database copy (safe while running)
  probe --url URL --pin B64 [--pin B64]... [--addr HOST:PORT] [--insecure] [--expect-node HEX] [--timeout 10s]
  version
```
Handle `probe` and `check` before `open()` (they must not touch the database):

```go
	if cmd == "probe" {
		return runProbe(ctx, args[1:], out)
	}
	if cmd == "check" {
		fs := flag.NewFlagSet("check", flag.ContinueOnError)
		cfgPath := fs.String("config", "/etc/otter/node.toml", "config file")
		if err := fs.Parse(args[1:]); err != nil {
			return err
		}
		lines, err := nodecheck.Run(*cfgPath)
		for _, l := range lines {
			fmt.Fprintln(out, l)
		}
		return err
	}
```
```go
func runProbe(ctx context.Context, args []string, out io.Writer) error {
	fs := flag.NewFlagSet("probe", flag.ContinueOnError)
	var o probe.Options
	var pins pinList
	var expect string
	fs.StringVar(&o.URL, "url", "", "wss://host:port/path")
	fs.Var(&pins, "pin", "base64 SHA-256 SPKI pin (repeatable)")
	fs.StringVar(&o.Addr, "addr", "", "connect to HOST:PORT instead of the URL host")
	fs.BoolVar(&o.Insecure, "insecure", false, "no pin: skip certificate verification")
	fs.StringVar(&expect, "expect-node", "", "expected node id (hex)")
	fs.DurationVar(&o.Timeout, "timeout", 10*time.Second, "overall timeout")
	if err := fs.Parse(args); err != nil {
		return err
	}
	o.Pins = pins
	if expect != "" {
		id, err := hex.DecodeString(expect)
		if err != nil {
			return fmt.Errorf("--expect-node: %w", err)
		}
		o.ExpectNode = id
	}
	r, err := probe.Run(ctx, o)
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "ok node_id=%x protocol=%d rtt=%dms\n", r.NodeID, r.Protocol, r.RTT.Milliseconds())
	return nil
}

type pinList [][]byte

func (p *pinList) String() string { return fmt.Sprint(len(*p)) }
func (p *pinList) Set(v string) error {
	b, err := base64.StdEncoding.DecodeString(v)
	if err != nil || len(b) != 32 {
		return fmt.Errorf("pin must be base64 of 32 bytes")
	}
	*p = append(*p, b)
	return nil
}
```
and in the post-`open()` switch:

```go
	case "backup":
		// flag parsed above together with --config: add `outPath := fs.String("out", "", "backup file")` before fs.Parse
		if *outPath == "" {
			return errors.New("backup: --out is required")
		}
		if err := a.st.Backup(ctx, *outPath); err != nil {
			return err
		}
		fmt.Fprintf(out, "backup written to %s\n", *outPath)
		return nil
```
Add a `cmd/otter-node/main_test.go` case: `run(ctx, []string{"probe", "--url", "wss://x:1/p"}, &out)` → error
containing "--pin". `probe`/`check` exit codes come from `main` (error → exit 1).

- [ ] **Step 7:** run Verify → PASS; `make check` → green.

- [ ] **Step 8: commit** `git commit -m "feat(node): probe, check and backup subcommands"`.

---

### Task 3: `otter-admin` DNS and node operations

**Goal:** the admin commands from docs/11 §5–§6: `dns records`, `dns check`, `node set-ip`, `node rotate-tls`,
`node drop-old-pins`, plus `node env` (machine-readable node facts for the scripts).

**Files:**
- Modify: `otter-server/internal/pinning/pinning.go` (+test), `otter-server/internal/admin/tls.go`,
  `otter-server/cmd/otter-admin/main.go` (+test)
- Create: `otter-server/internal/admin/nodeops.go`, `nodeops_test.go`, `dns.go`, `dns_test.go`

**Acceptance Criteria:**
- [ ] `dns records` prints, per node with a hostname (not an IP literal), one `A`/`AAAA` line per IP from
      `nodes/<label>/meta.json`, TTL 300, under a comment header; nodes without IPs get `; <label>: no IPs recorded (node set-ip)`.
- [ ] `dns check [--label L]` resolves each hostname and prints `ok`, `MISSING <ip>`, `UNEXPECTED <ip>` per node; exit 1 on
      any mismatch or resolution error; IP-literal hosts print `skip (IP endpoint)`.
- [ ] `node set-ip --label L --ip A [--ip B]` rewrites `meta.json`, re-issues `tls.crt` (and `tls.new.crt` if staged) with
      the **same key** and new SANs; the pin is unchanged; prints the DNS records to update. The manifest is not changed.
- [ ] `node rotate-tls --label L` writes `tls.new.{crt,key}` and appends the new pin (refuses if already staged);
      `node drop-old-pins --label L` moves `tls.*` → `tls.old.*`, `tls.new.*` → `tls.*`, keeps only the new pin
      (refuses if nothing is staged). Both say "Run 'manifest sign' and 'manifest publish'".
- [ ] `node env --label L` prints shell-quoted `OTTER_LABEL OTTER_HOST OTTER_PORT OTTER_PATH OTTER_NETWORK_PUB OTTER_NODE_ID
      OTTER_NODE_DIR OTTER_TLS_CERT OTTER_TLS_KEY OTTER_PIN OTTER_KIND` (TLS = the staged pair when present; `OTTER_PIN` = pin of
      that certificate, base64; `OTTER_KIND` = `wss`|`plain`).

**Verify:** `cd otter-server && go test -race ./internal/admin ./internal/pinning ./cmd/otter-admin`

**Steps:**

- [ ] **Step 1: `pinning.IssueCert`.** Test in `pinning_test.go`: generate a key, issue twice with different IPs →
  both certificates parse, have the requested SANs, and `SPKIPin` is equal. Then refactor:

```go
// IssueCert creates a self-signed certificate for an existing key (re-issuing keeps the pin).
func IssueCert(key *ecdsa.PrivateKey, hosts []string, ips []net.IP, validity time.Duration) (certPEM, pin []byte, err error) {
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	cn := ""
	if len(hosts) > 0 {
		cn = hosts[0]
	}
	tmpl := &x509.Certificate{
		SerialNumber: serial, Subject: pkix.Name{CommonName: cn},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(validity),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames: hosts, IPAddresses: ips, BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}
	cert, _ := x509.ParseCertificate(der)
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), SPKIPin(cert), nil
}

func GenerateCert(hosts []string, ips []net.IP, validity time.Duration) (certPEM, keyPEM, pin []byte, err error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, nil, err
	}
	certPEM, pin, err = IssueCert(key, hosts, ips, validity)
	if err != nil {
		return nil, nil, nil, err
	}
	kb, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return nil, nil, nil, err
	}
	return certPEM, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kb}), pin, nil
}

// ReadKeyPEM parses an "EC PRIVATE KEY" PEM file written by GenerateCert.
func ReadKeyPEM(b []byte) (*ecdsa.PrivateKey, error) {
	blk, _ := pem.Decode(b)
	if blk == nil {
		return nil, errors.New("no PEM block")
	}
	return x509.ParseECPrivateKey(blk.Bytes)
}

// CertPin returns the SPKI pin of a PEM certificate.
func CertPin(certPEM []byte) ([]byte, error) {
	blk, _ := pem.Decode(certPEM)
	if blk == nil {
		return nil, errors.New("no PEM block")
	}
	c, err := x509.ParseCertificate(blk.Bytes)
	if err != nil {
		return nil, err
	}
	return SPKIPin(c), nil
}
```

- [ ] **Step 2: failing admin tests** `internal/admin/nodeops_test.go` (helper `newNet(t)` = `InitNetwork` in a temp dir
  with passphrase `"test-passphrase-123"` + `AddNode(Label "fi-1", WSSHost "chat.example.org", IPs ["203.0.113.10"])`):

```go
func TestSetIPKeepsPin(t *testing.T) {
	dir := newNet(t)
	before := pinOf(t, dir, "fi-1", "tls.crt")
	if err := SetIPs(dir, "fi-1", []string{"198.51.100.7", "2001:db8::7"}); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, pinOf(t, dir, "fi-1", "tls.crt")) {
		t.Fatal("pin changed")
	}
	ips, _ := NodeIPs(dir, "fi-1")
	if len(ips) != 2 || ips[0] != "198.51.100.7" {
		t.Fatalf("ips %v", ips)
	}
	c := certOf(t, dir, "fi-1", "tls.crt")
	if len(c.IPAddresses) != 2 || c.DNSNames[0] != "chat.example.org" {
		t.Fatalf("SANs %v %v", c.DNSNames, c.IPAddresses)
	}
	if err := SetIPs(dir, "fi-1", []string{"nope"}); err == nil {
		t.Fatal("bad ip accepted")
	}
}

func TestRotateAndDropPins(t *testing.T) {
	dir := newNet(t)
	old := pinOf(t, dir, "fi-1", "tls.crt")
	newPin, err := RotateTLS(dir, "fi-1")
	if err != nil {
		t.Fatal(err)
	}
	if pins := endpointPins(t, dir, "fi-1"); len(pins) != 2 || !bytes.Equal(pins[0], old) || !bytes.Equal(pins[1], newPin) {
		t.Fatalf("pins after rotate: %d", len(pins))
	}
	if _, err := RotateTLS(dir, "fi-1"); err == nil {
		t.Fatal("second rotate must fail while staged")
	}
	env, _ := NodeEnv(dir, "fi-1")
	if env["OTTER_PIN"] != base64.StdEncoding.EncodeToString(newPin) || !strings.HasSuffix(env["OTTER_TLS_CERT"], "tls.new.crt") {
		t.Fatalf("env uses staged pair: %v", env)
	}
	if err := DropOldPins(dir, "fi-1"); err != nil {
		t.Fatal(err)
	}
	if pins := endpointPins(t, dir, "fi-1"); len(pins) != 1 || !bytes.Equal(pins[0], newPin) {
		t.Fatal("old pin kept")
	}
	if !bytes.Equal(pinOf(t, dir, "fi-1", "tls.crt"), newPin) || !bytes.Equal(pinOf(t, dir, "fi-1", "tls.old.crt"), old) {
		t.Fatal("files not promoted")
	}
	if err := DropOldPins(dir, "fi-1"); err == nil {
		t.Fatal("drop without staged pair must fail")
	}
}

func TestNodeEnv(t *testing.T) {
	dir := newNet(t)
	env, err := NodeEnv(dir, "fi-1")
	if err != nil {
		t.Fatal(err)
	}
	if env["OTTER_HOST"] != "chat.example.org" || env["OTTER_PORT"] != "27443" || !strings.HasPrefix(env["OTTER_PATH"], "/") ||
		env["OTTER_KIND"] != "wss" || len(env["OTTER_NETWORK_PUB"]) != 64 || len(env["OTTER_NODE_ID"]) != 32 {
		t.Fatalf("%v", env)
	}
	if got := ShellQuote("it's"); got != `'it'\''s'` {
		t.Fatal(got)
	}
}
```
(`pinOf` reads the file and calls `pinning.CertPin`; `certOf` parses it; `endpointPins` loads `LoadState` and returns
the node's first endpoint pins.)

- [ ] **Step 3: implement `internal/admin/nodeops.go`.**

```go
func findNode(st *State, label string) (*pb.NodeInfo, error) {
	for _, n := range st.Nodes {
		if n.Label == label {
			return n, nil
		}
	}
	return nil, fmt.Errorf("node %s: %w", label, ErrNotFound)
}

func nodeDir(dir, label string) string { return filepath.Join(dir, "nodes", label) }

// NodeIPs returns the IPs recorded for label (meta.json).
func NodeIPs(dir, label string) ([]string, error) {
	b, err := os.ReadFile(filepath.Join(nodeDir(dir, label), "meta.json"))
	if err != nil {
		return nil, err
	}
	var m nodeMeta
	return m.IPs, json.Unmarshal(b, &m)
}

func parseIPs(ips []string) ([]net.IP, error) {
	var out []net.IP
	for _, a := range ips {
		ip := net.ParseIP(a)
		if ip == nil {
			return nil, fmt.Errorf("invalid ip %q", a)
		}
		out = append(out, ip)
	}
	return out, nil
}

// reissue rewrites <name>.crt for the node's host and ips with the key in <name>.key (pin unchanged).
func reissue(nd, name, host string, ips []net.IP) error {
	kb, err := os.ReadFile(filepath.Join(nd, name+".key"))
	if err != nil {
		return err
	}
	key, err := pinning.ReadKeyPEM(kb)
	if err != nil {
		return err
	}
	hosts, all := certNames(host, ips)
	certPEM, _, err := pinning.IssueCert(key, hosts, all, CertValidity)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(nd, name+".crt"), certPEM, 0o644)
}

// certNames splits an endpoint host into DNS names / IPs for a certificate (shared with writeNodeTLS).
func certNames(host string, ips []net.IP) ([]string, []net.IP) {
	if ip := net.ParseIP(host); ip != nil {
		return nil, append(append([]net.IP{}, ips...), ip)
	}
	return []string{host}, ips
}

func SetIPs(dir, label string, ips []string) error {
	st, err := LoadState(dir)
	if err != nil {
		return err
	}
	n, err := findNode(st, label)
	if err != nil {
		return err
	}
	parsed, err := parseIPs(ips)
	if err != nil {
		return err
	}
	nd := nodeDir(dir, label)
	if err := writeNodeMeta(nd, ips); err != nil {
		return err
	}
	ep := n.Endpoints[0]
	if ep.Kind != pb.Endpoint_WSS {
		return nil
	}
	if err := reissue(nd, "tls", ep.Host, parsed); err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(nd, "tls.new.key")); err == nil {
		return reissue(nd, "tls.new", ep.Host, parsed)
	}
	return nil
}

func RotateTLS(dir, label string) ([]byte, error) {
	st, err := LoadState(dir)
	if err != nil {
		return nil, err
	}
	n, err := findNode(st, label)
	if err != nil {
		return nil, err
	}
	nd := nodeDir(dir, label)
	if _, err := os.Stat(filepath.Join(nd, "tls.new.key")); err == nil {
		return nil, fmt.Errorf("node %s already has a staged certificate (run 'node drop-old-pins' after deploying it)", label)
	}
	ep := n.Endpoints[0]
	if ep.Kind != pb.Endpoint_WSS {
		return nil, errors.New("plain endpoints have no TLS")
	}
	ipStr, err := NodeIPs(dir, label)
	if err != nil {
		return nil, err
	}
	ips, _ := parseIPs(ipStr)
	hosts, all := certNames(ep.Host, ips)
	certPEM, keyPEM, pin, err := pinning.GenerateCert(hosts, all, CertValidity)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(filepath.Join(nd, "tls.new.key"), keyPEM, 0o600); err != nil {
		return nil, err
	}
	if err := os.WriteFile(filepath.Join(nd, "tls.new.crt"), certPEM, 0o644); err != nil {
		return nil, err
	}
	ep.TlsSpkiPins = append(ep.TlsSpkiPins, pin)
	return pin, saveNodes(dir, st.Nodes)
}

func DropOldPins(dir, label string) error {
	st, err := LoadState(dir)
	if err != nil {
		return err
	}
	n, err := findNode(st, label)
	if err != nil {
		return err
	}
	nd := nodeDir(dir, label)
	newCrt, err := os.ReadFile(filepath.Join(nd, "tls.new.crt"))
	if err != nil {
		return fmt.Errorf("node %s has no staged certificate (run 'node rotate-tls' first)", label)
	}
	pin, err := pinning.CertPin(newCrt)
	if err != nil {
		return err
	}
	for _, ext := range []string{"crt", "key"} {
		if err := os.Rename(filepath.Join(nd, "tls."+ext), filepath.Join(nd, "tls.old."+ext)); err != nil {
			return err
		}
		if err := os.Rename(filepath.Join(nd, "tls.new."+ext), filepath.Join(nd, "tls."+ext)); err != nil {
			return err
		}
	}
	n.Endpoints[0].TlsSpkiPins = [][]byte{pin}
	return saveNodes(dir, st.Nodes)
}

// NodeEnv returns the facts deploy scripts need about one node.
func NodeEnv(dir, label string) (map[string]string, error) {
	st, err := LoadState(dir)
	if err != nil {
		return nil, err
	}
	n, err := findNode(st, label)
	if err != nil {
		return nil, err
	}
	ep := n.Endpoints[0]
	nd := nodeDir(dir, label)
	env := map[string]string{
		"OTTER_LABEL": label, "OTTER_HOST": ep.Host, "OTTER_PORT": strconv.Itoa(int(ep.Port)), "OTTER_PATH": ep.Path,
		"OTTER_NETWORK_PUB": hex.EncodeToString(st.NetworkPub), "OTTER_NODE_ID": hex.EncodeToString(n.NodeId),
		"OTTER_NODE_DIR": nd, "OTTER_KIND": "wss", "OTTER_TLS_CERT": "", "OTTER_TLS_KEY": "", "OTTER_PIN": "",
	}
	if ep.Kind != pb.Endpoint_WSS {
		env["OTTER_KIND"] = "plain"
		return env, nil
	}
	name := "tls"
	if _, err := os.Stat(filepath.Join(nd, "tls.new.crt")); err == nil {
		name = "tls.new"
	}
	crt, err := os.ReadFile(filepath.Join(nd, name+".crt"))
	if err != nil {
		return nil, err
	}
	pin, err := pinning.CertPin(crt)
	if err != nil {
		return nil, err
	}
	env["OTTER_TLS_CERT"] = filepath.Join(nd, name+".crt")
	env["OTTER_TLS_KEY"] = filepath.Join(nd, name+".key")
	env["OTTER_PIN"] = base64.StdEncoding.EncodeToString(pin)
	return env, nil
}

func ShellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }
```
Change `writeNodeTLS` in `tls.go` to use `certNames(host, ips)`.

- [ ] **Step 4: DNS.** Tests `dns_test.go`:

```go
type fakeResolver map[string][]net.IP

func (f fakeResolver) LookupIP(_ context.Context, _ string, host string) ([]net.IP, error) {
	if ips, ok := f[host]; ok {
		return ips, nil
	}
	return nil, &net.DNSError{Err: "no such host", Name: host, IsNotFound: true}
}

func TestDNSRecords(t *testing.T) {
	dir := newNet(t) // fi-1 chat.example.org 203.0.113.10
	if err := SetIPs(dir, "fi-1", []string{"203.0.113.10", "2001:db8::10"}); err != nil {
		t.Fatal(err)
	}
	got, err := DNSRecords(dir)
	if err != nil {
		t.Fatal(err)
	}
	want := "; Add these records at the DNS provider of each domain (TTL 300 recommended)\n" +
		"chat.example.org.    300  IN  A     203.0.113.10\n" +
		"chat.example.org.    300  IN  AAAA  2001:db8::10\n"
	if got != want {
		t.Fatalf("got\n%s", got)
	}
}

func TestCheckDNS(t *testing.T) {
	dir := newNet(t)
	ok := fakeResolver{"chat.example.org": {net.ParseIP("203.0.113.10")}}
	res, err := CheckDNS(context.Background(), dir, "", ok)
	if err != nil || len(res) != 1 || !res[0].OK {
		t.Fatalf("%v %+v", err, res)
	}
	wrong := fakeResolver{"chat.example.org": {net.ParseIP("192.0.2.1")}}
	res, _ = CheckDNS(context.Background(), dir, "", wrong)
	if res[0].OK || res[0].Missing[0] != "203.0.113.10" || res[0].Unexpected[0] != "192.0.2.1" {
		t.Fatalf("%+v", res[0])
	}
	res, _ = CheckDNS(context.Background(), dir, "", fakeResolver{})
	if res[0].OK || res[0].Err == "" {
		t.Fatalf("%+v", res[0])
	}
}
```
Implementation `dns.go`:

```go
type Resolver interface {
	LookupIP(ctx context.Context, network, host string) ([]net.IP, error)
}

type DNSResult struct {
	Label, Host         string
	Skipped, OK         bool
	Missing, Unexpected []string
	Err                 string
}

func DNSRecords(dir string) (string, error) {
	st, err := LoadState(dir)
	if err != nil {
		return "", err
	}
	var b strings.Builder
	b.WriteString("; Add these records at the DNS provider of each domain (TTL 300 recommended)\n")
	for _, n := range st.Nodes {
		host := n.Endpoints[0].Host
		if net.ParseIP(host) != nil {
			continue
		}
		ips, err := NodeIPs(dir, n.Label)
		if err != nil {
			return "", err
		}
		if len(ips) == 0 {
			fmt.Fprintf(&b, "; %s: no IPs recorded (node set-ip --label %s --ip ...)\n", n.Label, n.Label)
		}
		for _, a := range ips {
			typ := "A   "
			if net.ParseIP(a).To4() == nil {
				typ = "AAAA"
			}
			fmt.Fprintf(&b, "%s.    300  IN  %s  %s\n", host, typ, a)
		}
	}
	return b.String(), nil
}

func CheckDNS(ctx context.Context, dir, label string, r Resolver) ([]DNSResult, error) {
	st, err := LoadState(dir)
	if err != nil {
		return nil, err
	}
	var out []DNSResult
	for _, n := range st.Nodes {
		if label != "" && n.Label != label {
			continue
		}
		res := DNSResult{Label: n.Label, Host: n.Endpoints[0].Host}
		if net.ParseIP(res.Host) != nil {
			res.Skipped, res.OK = true, true
			out = append(out, res)
			continue
		}
		want, err := NodeIPs(dir, n.Label)
		if err != nil {
			return nil, err
		}
		got, err := r.LookupIP(ctx, "ip", res.Host)
		if err != nil {
			res.Err = err.Error()
			out = append(out, res)
			continue
		}
		gotSet := map[string]bool{}
		for _, ip := range got {
			gotSet[ip.String()] = true
		}
		wantSet := map[string]bool{}
		for _, a := range want {
			ip := net.ParseIP(a).String()
			wantSet[ip] = true
			if !gotSet[ip] {
				res.Missing = append(res.Missing, ip)
			}
		}
		for ip := range gotSet {
			if !wantSet[ip] {
				res.Unexpected = append(res.Unexpected, ip)
			}
		}
		sort.Strings(res.Unexpected)
		res.OK = len(res.Missing) == 0 && len(res.Unexpected) == 0 && len(want) > 0
		out = append(out, res)
	}
	return out, nil
}
```

- [ ] **Step 5: CLI cases** in `cmd/otter-admin/main.go` (add the lines to `usage`):

```
  node set-ip --label L --ip A [--ip B]...
  node rotate-tls --label L
  node drop-old-pins --label L
  node env --label L
  dns records
  dns check [--label L]
  version
```
```go
	case "node set-ip":
		fs := flag.NewFlagSet("node set-ip", flag.ContinueOnError)
		label := fs.String("label", "", "node label")
		var ips multi
		fs.Var(&ips, "ip", "IP address (repeatable)")
		if err := fs.Parse(a[2:]); err != nil {
			return err
		}
		if len(ips) == 0 {
			return errors.New("node set-ip: at least one --ip")
		}
		if err := admin.SetIPs(*dir, *label, ips); err != nil {
			return err
		}
		recs, _ := admin.DNSRecords(*dir)
		fmt.Fprintf(out, "node %s: IPs %v recorded, certificate re-issued (pin unchanged).\nUpdate DNS:\n%s", *label, []string(ips), recs)
	case "node rotate-tls", "node drop-old-pins":
		fs := flag.NewFlagSet(a[0]+" "+a[1], flag.ContinueOnError)
		label := fs.String("label", "", "node label")
		if err := fs.Parse(a[2:]); err != nil {
			return err
		}
		if a[1] == "rotate-tls" {
			pin, err := admin.RotateTLS(*dir, *label)
			if err != nil {
				return err
			}
			fmt.Fprintf(out, "node %s: new certificate staged, pin %s added.\nRun 'manifest sign' and 'manifest publish', wait for apps to update, deploy (push.sh), then 'node drop-old-pins'.\n",
				*label, base64.StdEncoding.EncodeToString(pin))
		} else {
			if err := admin.DropOldPins(*dir, *label); err != nil {
				return err
			}
			fmt.Fprintf(out, "node %s: only the new pin remains. Run 'manifest sign' and 'manifest publish'.\n", *label)
		}
	case "node env":
		fs := flag.NewFlagSet("node env", flag.ContinueOnError)
		label := fs.String("label", "", "node label")
		if err := fs.Parse(a[2:]); err != nil {
			return err
		}
		env, err := admin.NodeEnv(*dir, *label)
		if err != nil {
			return err
		}
		keys := make([]string, 0, len(env))
		for k := range env {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			fmt.Fprintf(out, "%s=%s\n", k, admin.ShellQuote(env[k]))
		}
	case "dns records":
		s, err := admin.DNSRecords(*dir)
		if err != nil {
			return err
		}
		fmt.Fprint(out, s)
	case "dns check":
		fs := flag.NewFlagSet("dns check", flag.ContinueOnError)
		label := fs.String("label", "", "only this node")
		if err := fs.Parse(a[2:]); err != nil {
			return err
		}
		res, err := admin.CheckDNS(context.Background(), *dir, *label, net.DefaultResolver)
		if err != nil {
			return err
		}
		bad := false
		for _, r := range res {
			switch {
			case r.Skipped:
				fmt.Fprintf(out, "%-12s %s skip (IP endpoint)\n", r.Label, r.Host)
			case r.Err != "":
				bad = true
				fmt.Fprintf(out, "%-12s %s ERROR %s\n", r.Label, r.Host, r.Err)
			case r.OK:
				fmt.Fprintf(out, "%-12s %s ok\n", r.Label, r.Host)
			default:
				bad = true
				fmt.Fprintf(out, "%-12s %s MISSING %v UNEXPECTED %v\n", r.Label, r.Host, r.Missing, r.Unexpected)
			}
		}
		if bad {
			return errors.New("DNS does not match (records may still be propagating; TTL 300)")
		}
```
CLI test in `main_test.go`: `network init` (env passphrase) → `node add` → `node env --label fi-1` output contains
`OTTER_PORT='27443'`; `dns records` contains `IN  A`.

- [ ] **Step 6:** Verify → PASS; `make check` green. **Commit** `git commit -m "feat(admin): dns records/check, node set-ip, rotate-tls, drop-old-pins, env"`.

---

### Task 4: Server — profile updates (`directory.update`, `registered_ms`)

**Goal:** a logged-in member can publish a newer version of their own directory entry; username clash ranking stays
stable (D40).

**Files:**
- Modify: `otter-server/proto/otter/v1/records.proto` (then `make gen`), `internal/records/validate.go` (+test),
  `internal/store/typed.go` (+`typed_test.go`), `internal/gateway/methods.go`
- Create: `internal/service/directory.go`, `internal/service/directory_test.go`, `internal/gateway/profile_test.go`

**Acceptance Criteria:**
- [ ] `DirectoryEntry.registered_ms` (field 9, `int64`); a record with `registered_ms > created_ms + 5 min` is `INVALID`.
- [ ] `users.entry_created_ms` = `registered_ms` when > 0, else the record's `created_ms`; a replicated clash between a
      v2 entry (registered earlier) and another user's v1 entry keeps the name with the earlier registration.
- [ ] `directory.update{record}`: OK for a newer version of the caller's own entry with the same username and account key;
      `UNAUTHORIZED` for someone else's entry; `INVALID` for a changed username or non-directory record;
      `CONFLICT` for a version ≤ the current; `RETRY_LATER` when the node doesn't know the user yet. Every other connected
      client gets a `directory` event; `directory.sync` returns the new display name.
- [ ] Peers replicate the update like any directory entry (existing replication; covered by the meshsim run in `make check`).

**Verify:** `cd otter-server && make gen && go test -race ./internal/records ./internal/store ./internal/service ./internal/gateway`

**Steps:**

- [ ] **Step 1: proto.** In `records.proto`:

```proto
message DirectoryEntry {
  …existing fields 1–8…
  int64 registered_ms = 9; // first registration (copied into later versions); username clash rank (D40). 0 = record created_ms
}
```
`make gen`.

- [ ] **Step 2: failing tests.**
  `validate_test.go`: a directory entry with `RegisteredMs = created + 10 min` → `ErrBadPayload`; `= created` → ok.
  `typed_test.go` (follow the existing clash test that applies two entries `fromPeer`): user X entry v2 with
  `RegisteredMs = 1000`, record `created_ms = 9000`, username "anna"; user Y v1 username "anna", created 5000, applied
  from a peer → X keeps "anna", Y becomes `anna#<hex>`.
  `internal/gateway/profile_test.go`:

```go
func TestDirectoryUpdate(t *testing.T) {
	n := startNode(t)
	ctx := context.Background()
	secret := make([]byte, 32)
	rand.Read(secret)
	sum := sha256.Sum256(secret)
	inv := sign(t, pb.RecordType_INVITE, keys.ID16(n.svc.NetworkPub), &pb.Invite{InviteId: sum[:], ExpiresMs: time.Now().Add(time.Hour).UnixMilli()}, n.netPriv)
	if _, err := n.svc.ImportRecord(ctx, inv); err != nil {
		t.Fatal(err)
	}
	ca := dial(t, n)
	anna, req := registerReq(t, n, secret, "anna")
	if st, msg := ca.call("register", req, nil); st != pb.Status_STATUS_OK {
		t.Fatalf("register: %v %s", st, msg)
	}
	login(t, ca, anna)
	watcher := dial(t, n) // a second session of anna stands in for "another member's app"
	login(t, watcher, anna)

	entry := func(username, display string, version uint64) *pb.Record {
		var cur pb.DirectoryEntry
		var body pb.RecordBody
		proto.Unmarshal(req.DirectoryEntry.Body, &body)
		proto.Unmarshal(body.Payload, &cur)
		cur.Username, cur.DisplayName, cur.Version, cur.RegisteredMs = username, display, version, body.CreatedMs
		return sign(t, pb.RecordType_DIRECTORY_ENTRY, anna.id, &cur, anna.priv)
	}
	if st, msg := ca.call("directory.update", &pb.RecordRequest{Record: entry("anna", "Анна Петровна", 2)}, nil); st != pb.Status_STATUS_OK {
		t.Fatalf("update: %v %s", st, msg)
	}
	watcher.nextEvent("directory")
	var dir pb.RecordBatch
	ca.call("directory.sync", &pb.Empty{}, &dir)
	if got := displayNameOf(t, dir.Records, anna.id); got != "Анна Петровна" {
		t.Fatalf("directory shows %q", got)
	}
	if st, _ := ca.call("directory.update", &pb.RecordRequest{Record: entry("anna", "Старое", 2)}, nil); st != pb.Status_STATUS_CONFLICT {
		t.Fatalf("same version: %v", st)
	}
	if st, _ := ca.call("directory.update", &pb.RecordRequest{Record: entry("anya", "Аня", 3)}, nil); st != pb.Status_STATUS_INVALID {
		t.Fatalf("username change: %v", st)
	}
	ack := sign(t, pb.RecordType_ACK, anna.id, &pb.Ack{EnvelopeIds: [][]byte{make([]byte, 32)}}, anna.priv)
	if st, _ := ca.call("directory.update", &pb.RecordRequest{Record: ack}, nil); st != pb.Status_STATUS_INVALID {
		t.Fatalf("non-directory record: %v", st)
	}
}

func displayNameOf(t *testing.T, recs []*pb.Record, id []byte) string {
	for _, r := range recs {
		var b pb.RecordBody
		var e pb.DirectoryEntry
		proto.Unmarshal(r.Body, &b)
		proto.Unmarshal(b.Payload, &e)
		if bytes.Equal(e.UserId, id) {
			return e.DisplayName
		}
	}
	t.Fatal("user not in directory")
	return ""
}
```
Also add a case for someone else's entry: register boris through an invite from anna (as `TestEndToEnd` does) and
have anna's session submit boris's re-signed v2 entry (signed by boris's key) → `UNAUTHORIZED`.

Run → FAIL (`unknown method "directory.update"`).

- [ ] **Step 3: validator.** In `checkPayload`, `DIRECTORY_ENTRY` case, after the existing checks:

```go
		if e.RegisteredMs > b.CreatedMs+int64(5*time.Minute/time.Millisecond) {
			return ErrBadPayload
		}
```

- [ ] **Step 4: store.** In `applyDirectoryEntry` (`typed.go`) compute the rank time once at the top and use it
  everywhere `created` is used for the username (the `wins(...)` call and both `entry_created_ms` writes):

```go
	rank := created
	if e.RegisteredMs > 0 {
		rank = e.RegisteredMs
	}
```

- [ ] **Step 5: service** `internal/service/directory.go`:

```go
// UpdateDirectoryEntry applies a newer version of the caller's own directory entry (profile edit, D39/D40).
func (s *Service) UpdateDirectoryEntry(ctx context.Context, user []byte, rec *pb.Record) error {
	body, err := s.validator(nil).Validate(rec)
	if err != nil {
		return invalid(err)
	}
	if body.Type != pb.RecordType_DIRECTORY_ENTRY {
		return fmt.Errorf("%w: not a directory entry", ErrInvalid)
	}
	if !bytes.Equal(body.Author, user) {
		return fmt.Errorf("%w: entry of another user", ErrUnauthorized)
	}
	var e pb.DirectoryEntry
	_ = proto.Unmarshal(body.Payload, &e)
	cur, err := s.Store.UserByID(ctx, user)
	if err != nil {
		return err
	}
	if cur == nil {
		return fmt.Errorf("%w: user", ErrRetryLater)
	}
	if e.Username != cur.Username {
		return fmt.Errorf("%w: username changes are not supported", ErrInvalid)
	}
	if e.Version <= cur.Version {
		return fmt.Errorf("%w: version %d is not newer than %d", ErrConflict, e.Version, cur.Version)
	}
	_, applied, err := s.Store.ApplyFrom(ctx, rec, body, s.NodeID)
	if err != nil {
		return err
	}
	if applied {
		s.afterApply(ctx, body)
	}
	return nil
}
```
Note: a user whose name was suffixed by a clash (`username_conflict`, `name#xxxx`) has `cur.Username` = the suffixed
name, while their entry carries the original — compare against the original instead when `cur` is in conflict. Look at
how `store.User` exposes this; if it doesn't, add `UsernameConflict bool` to `store.User` and accept
`e.Username == strings.SplitN(cur.Username, "#", 2)[0]` in that case. Add a service test for it.
`ErrConflict` already maps to `STATUS_CONFLICT` (used by `PublishManifest`).

- [ ] **Step 6: gateway** `methods.go`, before `default:`:

```go
	case "directory.update":
		var r pb.RecordRequest
		if err := decode(req.Body, &r); err != nil {
			return nil, err
		}
		if r.Record == nil {
			return nil, fmt.Errorf("%w: record missing", service.ErrInvalid)
		}
		return &pb.Empty{}, svc.UpdateDirectoryEntry(ctx, s.user, r.Record)
```
(It sits with the methods that require login — the same place as `msg.send`.)

- [ ] **Step 7:** Verify → PASS, `make check` green. **Commit**
  `git commit -m "feat(directory): directory.update for profile edits; registered_ms keeps clash rank"`.

---

### Task 5: Bundle — templates, `make-bundle.sh`, server-side scripts

**Goal:** `deploy/make-bundle.sh <label>` builds `dist/bundle-<label>.tar.gz` (0600) with everything a server needs;
the bundle's `install.sh`, `uninstall.sh`, `backup.sh`, `health.sh` implement docs/11 §5.3, §6, §7.

**Files:**
- Create: `otter-server/deploy/lib.sh`, `deploy/make-bundle.sh`, `deploy/bundle/{install.sh,uninstall.sh,backup.sh,health.sh}`,
  `deploy/templates/{node.toml,otter-node.service,otter-backup.service,otter-backup.timer,site/index.html}`,
  `deploy/test/bundle_test.sh`, `deploy/README.md`

**Acceptance Criteria:**
- [ ] `make-bundle.sh fi-1 [VERSION]` (default: newest version in `dist/` by `sort -V`) creates `dist/bundle-fi-1.tar.gz`
      (mode 0600) containing `bundle-fi-1/` with: `otter-node-amd64`, `otter-node-arm64`, `node.key`, `tls.crt`, `tls.key`
      (the staged pair if present), `manifest.bin`, `node.toml`, `probe.env`, `otter-node.service`,
      `otter-backup.{service,timer}`, `site/index.html`, `invites/*.bin` (every pending bootstrap invite), the four scripts,
      `SHA256SUMS`; and writes `dist/bundle-fi-1.invites` listing the included invite files.
- [ ] It refuses to run when `manifest.bin` doesn't list the node or its pins don't include the bundle certificate's pin
      (message: run `manifest sign`).
- [ ] `deploy/test/bundle_test.sh` (no root, no VM) builds a bundle from a throwaway admin dir, verifies `SHA256SUMS`,
      rewrites `/etc/otter` and `/var/lib/otter` paths to temp dirs and passes `otter-node check`, and greps the unit for
      `ExecStart=/usr/local/bin/otter-node run --config /etc/otter/node.toml`.
- [ ] Scripts start with `set -euo pipefail`, print every action (`==> …`), and `bash -n` passes for all of them.
- [ ] The decoy page has no Otter/OtterMSG wording.

**Verify:** `cd otter-server && for f in deploy/*.sh deploy/bundle/*.sh deploy/test/*.sh; do bash -n "$f" || exit 1; done && deploy/test/bundle_test.sh`
→ last line `bundle test: ok`

**Steps:**

- [ ] **Step 1: `deploy/lib.sh`** (sourced by admin-side scripts):

```bash
# Shared helpers for admin-side deploy scripts. Source it; do not run it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADMIN_DIR="${OTTER_ADMIN_DIR:-$HOME/.otter-admin}"
ADMIN_BIN="${OTTER_ADMIN_BIN:-$ROOT/bin/otter-admin}"
NODE_BIN="${OTTER_NODE_BIN:-$ROOT/bin/otter-node}"   # host-arch otter-node for probes (make build)
SSH_PORT="${OTTER_SSH_PORT:-22}"
read -r -a SSH_EXTRA <<< "${OTTER_SSH_OPTS:-}"
say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
admin() { "$ADMIN_BIN" --dir "$ADMIN_DIR" "$@"; }
remote() { local target=$1; shift; ssh -p "$SSH_PORT" "${SSH_EXTRA[@]}" "$target" "$@"; }
upload() { local target=$1 src=$2 dst=$3; scp -P "$SSH_PORT" "${SSH_EXTRA[@]}" "$src" "$target:$dst"; }
node_env() { eval "$(admin node env --label "$1")"; }
[[ -x "$ADMIN_BIN" && -x "$NODE_BIN" ]] || die "build the tools first: make build"
```

- [ ] **Step 2: templates.** `templates/node.toml`:

```toml
# Generated by make-bundle.sh for node ${OTTER_LABEL}. See docs/11-deployment.md §5.4.
data_dir      = "/var/lib/otter"
node_key      = "/etc/otter/node.key"
network_pub   = "${OTTER_NETWORK_PUB}"
manifest_file = "/etc/otter/manifest.bin"
log_level     = "info"

[wss]
listen   = ":${OTTER_PORT}"
path     = "${OTTER_PATH}"
tls_cert = "/etc/otter/tls.crt"
tls_key  = "/etc/otter/tls.key"
site_dir = "/var/lib/otter/site"
```
`templates/otter-node.service`: exactly the unit in docs/11 §5.5. `templates/otter-backup.service`:

```ini
[Unit]
Description=OtterMSG node database backup

[Service]
Type=oneshot
User=otter
Group=otter
ExecStart=/usr/local/lib/otter/backup.sh --run
```
`templates/otter-backup.timer`:

```ini
[Unit]
Description=Daily OtterMSG node database backup

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
```
`templates/site/index.html`: a plain, neutral page (no product names):

```html
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Under maintenance</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:36rem;margin:20vh auto;padding:0 1rem;color:#333}</style>
</head><body><h1>Under maintenance</h1><p>This site is being updated. Please check back later.</p></body></html>
```

- [ ] **Step 3: `deploy/make-bundle.sh`.**

```bash
#!/usr/bin/env bash
# Builds dist/bundle-<label>.tar.gz for one node. Usage: make-bundle.sh <label> [version]
source "$(dirname "$0")/lib.sh"
label=${1:?usage: make-bundle.sh <label> [version]}
version=${2:-$(ls "$ROOT"/dist/otter-node_*_linux_amd64 2>/dev/null | sed -E 's/.*otter-node_(.*)_linux_amd64/\1/' | sort -V | tail -n1)}
[[ -n "$version" ]] || die "no release in dist/ (make release VERSION=x.y.z)"
for arch in amd64 arm64; do [[ -f "$ROOT/dist/otter-node_${version}_linux_$arch" ]] || die "missing dist/otter-node_${version}_linux_$arch"; done
node_env "$label"
[[ "$OTTER_KIND" == wss ]] || die "node $label has a plain endpoint (development only); bundles need TLS"
[[ -f "$ADMIN_DIR/manifest.bin" ]] || die "no signed manifest: run 'otter-admin manifest sign'"
admin manifest show | grep -q "\"$OTTER_PIN\"" || die "the signed manifest lacks pin $OTTER_PIN of node $label: run 'otter-admin manifest sign'"

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
b="$work/bundle-$label"
mkdir -p "$b/site" "$b/invites"
say "bundle $label, otter-node $version"
cp "$ROOT/dist/otter-node_${version}_linux_amd64" "$b/otter-node-amd64"
cp "$ROOT/dist/otter-node_${version}_linux_arm64" "$b/otter-node-arm64"
cp "$OTTER_NODE_DIR/node.key" "$b/node.key"
cp "$OTTER_TLS_CERT" "$b/tls.crt"
cp "$OTTER_TLS_KEY" "$b/tls.key"
cp "$ADMIN_DIR/manifest.bin" "$b/manifest.bin"
export OTTER_LABEL OTTER_NETWORK_PUB OTTER_PORT OTTER_PATH
envsubst '${OTTER_LABEL} ${OTTER_NETWORK_PUB} ${OTTER_PORT} ${OTTER_PATH}' < "$ROOT/deploy/templates/node.toml" > "$b/node.toml"
cp "$ROOT"/deploy/templates/otter-node.service "$ROOT"/deploy/templates/otter-backup.service "$ROOT"/deploy/templates/otter-backup.timer "$b/"
cp -r "$ROOT/deploy/templates/site/." "$b/site/"
cp "$ROOT"/deploy/bundle/*.sh "$b/"
chmod 0755 "$b"/*.sh "$b"/otter-node-*
host=$OTTER_HOST; [[ "$host" == *:* ]] && host="[$host]"
cat > "$b/probe.env" <<EOF
OTTER_PROBE_URL=wss://$host:$OTTER_PORT$OTTER_PATH
OTTER_PROBE_PIN=$OTTER_PIN
OTTER_NODE_ID=$OTTER_NODE_ID
OTTER_PORT=$OTTER_PORT
EOF
: > "$ROOT/dist/bundle-$label.invites"
shopt -s nullglob
for f in "$ADMIN_DIR"/invites/*.bin; do
  cp "$f" "$b/invites/"; echo "$f" >> "$ROOT/dist/bundle-$label.invites"; say "including bootstrap invite $(basename "$f")"
done
(cd "$b" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
umask 077
tar -C "$work" -czf "$ROOT/dist/bundle-$label.tar.gz" "bundle-$label"
chmod 0600 "$ROOT/dist/bundle-$label.tar.gz"
say "wrote dist/bundle-$label.tar.gz (contains private keys; push.sh deletes it after a successful install)"
```
(`manifest show` prints protojson with base64 pins, so the grep finds the pin string.)

- [ ] **Step 4: `deploy/bundle/health.sh`** (installed to `/usr/local/lib/otter/health.sh`; root):

```bash
#!/usr/bin/env bash
# Health check on the server: service active and the node answers its pinned hello on 127.0.0.1.
set -euo pipefail
source /etc/otter/probe.env
for i in $(seq 1 20); do
  if systemctl is-active --quiet otter-node &&
     /usr/local/bin/otter-node probe --url "$OTTER_PROBE_URL" --pin "$OTTER_PROBE_PIN" \
       --addr "127.0.0.1:$OTTER_PORT" --expect-node "$OTTER_NODE_ID" --timeout 3s; then
    exit 0
  fi
  sleep 1
done
echo "health check failed; last log lines:" >&2
journalctl -u otter-node -n 30 --no-pager >&2 || true
exit 1
```

- [ ] **Step 5: `deploy/bundle/install.sh`.**

```bash
#!/usr/bin/env bash
# Installs or updates this OtterMSG node from the bundle directory. Safe to run again. Run as root.
set -euo pipefail
cd "$(dirname "$0")"
say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
command -v systemctl >/dev/null || die "systemd is required"
source /etc/os-release
[[ "$ID" == debian || "$ID" == ubuntu || "${ID_LIKE:-}" == *debian* ]] || die "Debian or Ubuntu required (found $ID)"
case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) die "unsupported architecture $(uname -m)" ;; esac
say "verifying SHA256SUMS"
sha256sum --quiet -c SHA256SUMS
source ./probe.env
if ss -ltnH "sport = :$OTTER_PORT" | grep -q . && ! systemctl is-active --quiet otter-node; then
  die "port $OTTER_PORT is in use: $(ss -ltnpH "sport = :$OTTER_PORT")"
fi

say "time synchronisation"
if ! systemctl is-active --quiet chrony 2>/dev/null; then
  if ! systemctl enable --now systemd-timesyncd 2>/dev/null; then
    apt-get update -q && apt-get install -y -q systemd-timesyncd && systemctl enable --now systemd-timesyncd
  fi
fi
for _ in $(seq 30); do [[ "$(timedatectl show -p NTPSynchronized --value)" == yes ]] && break; sleep 2; done
[[ "$(timedatectl show -p NTPSynchronized --value)" == yes ]] || say "WARNING: clock not synchronised yet (logins need ±5 min)"

if ! id otter >/dev/null 2>&1; then
  say "creating system user otter"
  useradd --system --home-dir /var/lib/otter --no-create-home --shell /usr/sbin/nologin otter
fi
if systemctl is-active --quiet otter-node; then say "stopping otter-node"; systemctl stop otter-node; fi

say "installing files"
install -d -o root -g otter -m 0750 /etc/otter
install -d -o otter -g otter -m 0700 /var/lib/otter
install -d -o otter -g otter -m 0755 /var/lib/otter/site
install -d -o otter -g otter -m 0700 /var/backups/otter
install -d -o root -g root -m 0755 /usr/local/lib/otter
install -o root -g otter -m 0640 node.key tls.key node.toml manifest.bin tls.crt probe.env /etc/otter/
cp -r site/. /var/lib/otter/site/
chown -R otter:otter /var/lib/otter/site
if [[ -x /usr/local/bin/otter-node ]] && ! cmp -s "otter-node-$arch" /usr/local/bin/otter-node; then
  cp -p /usr/local/bin/otter-node /usr/local/bin/otter-node.prev
fi
install -o root -g root -m 0755 "otter-node-$arch" /usr/local/bin/otter-node
install -o root -g root -m 0755 install.sh uninstall.sh backup.sh health.sh /usr/local/lib/otter/
install -o root -g root -m 0644 otter-node.service otter-backup.service otter-backup.timer /etc/systemd/system/

say "checking configuration"
runuser -u otter -- /usr/local/bin/otter-node check --config /etc/otter/node.toml
shopt -s nullglob
for f in invites/*.bin; do
  say "importing $(basename "$f")"
  runuser -u otter -- /usr/local/bin/otter-node import --config /etc/otter/node.toml "$f"
done

if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  say "ufw: allowing SSH and $OTTER_PORT/tcp"
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp
  ufw allow "$OTTER_PORT/tcp"
else
  say "WARNING: no active host firewall. Allow only SSH and $OTTER_PORT/tcp in the provider's cloud firewall (docs/11 §8)."
fi

say "starting otter-node"
systemctl daemon-reload
systemctl enable --quiet otter-node
systemctl restart otter-node
/usr/local/lib/otter/health.sh
say "node is up: $(/usr/local/bin/otter-node version), $OTTER_PROBE_URL"
say "single node? enable daily backups: /usr/local/lib/otter/backup.sh --install"
```

- [ ] **Step 6: `deploy/bundle/uninstall.sh`.**

```bash
#!/usr/bin/env bash
# Removes the OtterMSG node. Keeps /var/lib/otter and /var/backups/otter unless --purge. Run as root.
set -euo pipefail
say() { printf '==> %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
purge=0; [[ "${1:-}" == --purge ]] && purge=1
say "stopping services"
systemctl disable --now otter-node otter-backup.timer 2>/dev/null || true
rm -f /etc/systemd/system/otter-node.service /etc/systemd/system/otter-backup.service /etc/systemd/system/otter-backup.timer
systemctl daemon-reload
say "removing binary and configuration (keys are shredded)"
rm -f /usr/local/bin/otter-node /usr/local/bin/otter-node.prev /usr/local/bin/otter-node.failed
for k in /etc/otter/node.key /etc/otter/tls.key; do [[ -f $k ]] && shred -u "$k"; done
rm -rf /etc/otter /usr/local/lib/otter
if (( purge )); then
  say "purging data and backups"
  rm -rf /var/lib/otter /var/backups/otter
  userdel otter 2>/dev/null || true
else
  say "kept /var/lib/otter and /var/backups/otter (use --purge to delete)"
fi
```

- [ ] **Step 7: `deploy/bundle/backup.sh`.**

```bash
#!/usr/bin/env bash
# Daily node database backups (docs/11 §6). --install (root): enable the timer. --run (user otter, from the timer): one copy, keep 7.
set -euo pipefail
case "${1:-}" in
  --install)
    [[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
    systemctl daemon-reload
    systemctl enable --now otter-backup.timer
    echo "==> daily backups enabled into /var/backups/otter (7 kept): $(systemctl list-timers otter-backup.timer --no-pager | sed -n 2p)"
    ;;
  --run)
    out=/var/backups/otter/node-$(date +%F).db
    [[ -e "$out" ]] && { echo "$out exists"; exit 0; }
    /usr/local/bin/otter-node backup --config /etc/otter/node.toml --out "$out"
    ls -1t /var/backups/otter/node-*.db | tail -n +8 | xargs -r rm -f
    ;;
  *) echo "usage: backup.sh --install | --run" >&2; exit 2 ;;
esac
```
Note: the backup service runs as `otter`, which can read `/etc/otter/node.toml` (group `otter`, 0640) and the data dir.

- [ ] **Step 8: `deploy/test/bundle_test.sh`.**

```bash
#!/usr/bin/env bash
# Offline bundle test: builds a bundle from a throwaway admin dir and checks its contents and config.
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
export OTTER_ADMIN_DIR="$work/admin" OTTER_ADMIN_PASSPHRASE=bundle-test-passphrase
make -s build
make -s release VERSION=0.0.0-bundletest >/dev/null
bin/otter-admin --dir "$OTTER_ADMIN_DIR" network init >/dev/null
bin/otter-admin --dir "$OTTER_ADMIN_DIR" node add --label t1 --wss-host chat.example.org --ip 203.0.113.10 >/dev/null
bin/otter-admin --dir "$OTTER_ADMIN_DIR" manifest sign >/dev/null
bin/otter-admin --dir "$OTTER_ADMIN_DIR" invite bootstrap >/dev/null
deploy/make-bundle.sh t1 0.0.0-bundletest
[[ "$(stat -c %a dist/bundle-t1.tar.gz)" == 600 ]] || { echo "bundle mode"; exit 1; }
tar -C "$work" -xzf dist/bundle-t1.tar.gz
b="$work/bundle-t1"
(cd "$b" && sha256sum --quiet -c SHA256SUMS)
for f in otter-node-amd64 otter-node-arm64 node.key tls.crt tls.key manifest.bin node.toml probe.env otter-node.service \
         otter-backup.service otter-backup.timer site/index.html install.sh uninstall.sh backup.sh health.sh; do
  [[ -e "$b/$f" ]] || { echo "missing $f"; exit 1; }
done
ls "$b"/invites/*.bin >/dev/null
grep -q '^ExecStart=/usr/local/bin/otter-node run --config /etc/otter/node.toml$' "$b/otter-node.service"
! grep -qi otter "$b/site/index.html"
sed -e "s#/etc/otter#$b#g" -e "s#/var/lib/otter#$work/data#g" "$b/node.toml" > "$work/node.toml"
"$b/otter-node-amd64" check --config "$work/node.toml"
rm -f dist/bundle-t1.tar.gz dist/bundle-t1.invites dist/*0.0.0-bundletest*
(cd dist && ls otter-*_* >/dev/null 2>&1 && sha256sum otter-*_* > SHA256SUMS || rm -f SHA256SUMS)
echo "bundle test: ok"
```
(On an arm64 admin machine use `otter-node-arm64` for the `check` line; the dev machine is amd64.)

- [ ] **Step 9: `deploy/README.md`** — a one-screen quick reference: build (`make build`, `make release VERSION=`),
  the deploy sequence from docs/11 §5, the env variables (`OTTER_ADMIN_DIR`, `OTTER_SSH_PORT`, `OTTER_SSH_OPTS`,
  `OTTER_PROBE_ADDR`, `OTTER_SKIP_DNS`), and a link to `docs/11-deployment.md` (outside this repo: "see the project docs").

- [ ] **Step 10:** Verify → `bundle test: ok`. **Commit** `git commit -m "feat(deploy): bundle builder, install/uninstall/backup/health scripts"`.

---

### Task 6: `push.sh`, `upgrade.sh`, `check.sh`

**Goal:** the admin-side scripts that install a bundle remotely, upgrade with automatic rollback, and run the docs/11 §7
health checks.

**Files:**
- Create: `otter-server/deploy/push.sh`, `deploy/upgrade.sh`, `deploy/check.sh`

**Acceptance Criteria:**
- [ ] `push.sh <label> <root@host>`: builds the bundle if missing, uploads it to a `mktemp -d` dir, runs `install.sh`,
      removes the remote copy, runs `check.sh <label> <target>`, then deletes the local bundle and moves the included
      invites to `$OTTER_ADMIN_DIR/invites/delivered/`. A failure keeps the local bundle and exits non-zero.
- [ ] `upgrade.sh <root@host> <binary>`: verifies the checksum on the server, backs up the DB with the **installed**
      binary, swaps binaries (keeps `.prev`), restarts, runs `health.sh`. On failure: restores `.prev` and the DB copy,
      restarts, keeps the bad binary as `otter-node.failed`; exit 0 = upgraded, 2 = rolled back, 3 = rollback failed.
- [ ] `check.sh <label> [root@host]`: `dns check` (skipped when `OTTER_SKIP_DNS=1` or the host is an IP), probe with the pin
      (must pass), probe with a random pin (must fail), decoy `GET /` = 200 via `curl -k`; with a target also
      `systemctl is-active`, `NTPSynchronized=yes`, `health.sh`, and no "not listed in the manifest" log line since boot.
      `OTTER_PROBE_ADDR=host:port` overrides where the admin-side probes connect. Prints a PASS/FAIL table; exit 1 on any FAIL.

**Verify:** `bash -n deploy/push.sh deploy/upgrade.sh deploy/check.sh` (behaviour is verified by the VM test, Task 7)

**Steps:**

- [ ] **Step 1: `deploy/check.sh`.**

```bash
#!/usr/bin/env bash
# Health checks for one node (docs/11 §7). Usage: check.sh <label> [ssh-target]
source "$(dirname "$0")/lib.sh"
label=${1:?usage: check.sh <label> [ssh-target]}; target=${2:-}
node_env "$label"
host=$OTTER_HOST; [[ "$host" == *:* ]] && host="[$host]"
url="wss://$host:$OTTER_PORT$OTTER_PATH"
addr_args=(); curl_args=()
if [[ -n "${OTTER_PROBE_ADDR:-}" ]]; then
  addr_args=(--addr "$OTTER_PROBE_ADDR")
  curl_args=(--connect-to "$OTTER_HOST:$OTTER_PORT:${OTTER_PROBE_ADDR%:*}:${OTTER_PROBE_ADDR##*:}")
fi
fails=0
row() { printf '%-28s %s\n' "$1" "$2"; [[ "$2" == PASS* || "$2" == SKIP* ]] || fails=$((fails + 1)); }

if [[ "${OTTER_SKIP_DNS:-0}" == 1 ]]; then row "DNS" "SKIP (OTTER_SKIP_DNS)"
elif admin dns check --label "$label" >/dev/null 2>&1; then row "DNS" "PASS"
else row "DNS" "FAIL ($(admin dns check --label "$label" 2>&1 | tail -n1))"; fi

if out=$("$NODE_BIN" probe --url "$url" --pin "$OTTER_PIN" --expect-node "$OTTER_NODE_ID" "${addr_args[@]}" 2>&1); then
  row "pinned hello" "PASS ($out)"; else row "pinned hello" "FAIL ($out)"; fi
random_pin=$(head -c 32 /dev/urandom | base64)
if "$NODE_BIN" probe --url "$url" --pin "$random_pin" "${addr_args[@]}" >/dev/null 2>&1; then
  row "wrong pin rejected" "FAIL (accepted)"; else row "wrong pin rejected" "PASS"; fi
code=$(curl -sk -o /dev/null -w '%{http_code}' "${curl_args[@]}" "https://$host:$OTTER_PORT/" || true)
[[ "$code" == 200 ]] && row "decoy site" "PASS" || row "decoy site" "FAIL (HTTP $code)"

if [[ -n "$target" ]]; then
  st=$(remote "$target" systemctl is-active otter-node || true)
  [[ "$st" == active ]] && row "service" "PASS" || row "service" "FAIL ($st)"
  ntp=$(remote "$target" timedatectl show -p NTPSynchronized --value || true)
  [[ "$ntp" == yes ]] && row "clock synchronised" "PASS" || row "clock synchronised" "FAIL ($ntp)"
  remote "$target" /usr/local/lib/otter/health.sh >/dev/null 2>&1 && row "server-side health" "PASS" || row "server-side health" "FAIL"
  n=$(remote "$target" "journalctl -u otter-node -b --no-pager | grep -c 'not listed in the manifest' || true")
  [[ "$n" == 0 ]] && row "listed in manifest" "PASS" || row "listed in manifest" "FAIL ($n warnings)"
fi
(( fails == 0 )) || die "$fails check(s) failed"
say "all checks passed for $label"
```

- [ ] **Step 2: `deploy/push.sh`.**

```bash
#!/usr/bin/env bash
# Installs a node from its bundle. Usage: push.sh <label> <root@host>
source "$(dirname "$0")/lib.sh"
label=${1:?usage: push.sh <label> <root@host>}; target=${2:?usage: push.sh <label> <root@host>}
bundle="$ROOT/dist/bundle-$label.tar.gz"
[[ -f "$bundle" ]] || "$ROOT/deploy/make-bundle.sh" "$label"
say "uploading bundle to $target"
rdir=$(remote "$target" mktemp -d /root/otter-bundle.XXXXXX)
upload "$target" "$bundle" "$rdir/"
say "running install.sh on $target"
if ! remote "$target" "cd '$rdir' && tar xzf bundle-$label.tar.gz && ./bundle-$label/install.sh; rc=\$?; rm -rf '$rdir'; exit \$rc"; then
  die "install failed on $target; the local bundle is kept in dist/"
fi
"$ROOT/deploy/check.sh" "$label" "$target"
if [[ -s "$ROOT/dist/bundle-$label.invites" ]]; then
  mkdir -p "$ADMIN_DIR/invites/delivered"
  while read -r f; do [[ -f "$f" ]] && mv "$f" "$ADMIN_DIR/invites/delivered/"; done < "$ROOT/dist/bundle-$label.invites"
  say "bootstrap invite delivered; send its link to the first member"
fi
rm -f "$bundle" "$ROOT/dist/bundle-$label.invites"
say "done: $label on $target (local bundle deleted; make-bundle.sh can recreate it)"
```

- [ ] **Step 3: `deploy/upgrade.sh`.**

```bash
#!/usr/bin/env bash
# Upgrades otter-node on one server with automatic rollback (docs/11 §6).
# Usage: upgrade.sh <root@host> <otter-node binary for that server's arch>
# Exit: 0 upgraded, 2 rolled back, 3 rollback failed (manual action needed).
source "$(dirname "$0")/lib.sh"
target=${1:?usage: upgrade.sh <root@host> <binary>}; bin=${2:?usage: upgrade.sh <root@host> <binary>}
[[ -f "$bin" ]] || die "no such file: $bin"
sum=$(sha256sum "$bin" | cut -d' ' -f1)
say "uploading $(basename "$bin") to $target"
upload "$target" "$bin" /usr/local/bin/otter-node.new
set +e
remote "$target" bash -s -- "$sum" <<'EOF'
set -euo pipefail
sum=$1
say() { printf '==> %s\n' "$*"; }
echo "$sum  /usr/local/bin/otter-node.new" | sha256sum --quiet -c
chmod 0755 /usr/local/bin/otter-node.new
ts=$(date +%Y%m%d-%H%M%S)
backup=/var/backups/otter/pre-upgrade-$ts.db
say "backing up the database to $backup (installed binary: $(/usr/local/bin/otter-node version))"
runuser -u otter -- /usr/local/bin/otter-node backup --config /etc/otter/node.toml --out "$backup"
say "swapping binaries"
systemctl stop otter-node
cp -p /usr/local/bin/otter-node /usr/local/bin/otter-node.prev
mv /usr/local/bin/otter-node.new /usr/local/bin/otter-node
systemctl start otter-node || true
if /usr/local/lib/otter/health.sh; then
  say "upgraded to $(/usr/local/bin/otter-node version)"
  exit 0
fi
say "health check failed: rolling back"
systemctl stop otter-node || true
mv /usr/local/bin/otter-node /usr/local/bin/otter-node.failed
cp -p /usr/local/bin/otter-node.prev /usr/local/bin/otter-node
rm -f /var/lib/otter/node.db-wal /var/lib/otter/node.db-shm
install -o otter -g otter -m 0600 "$backup" /var/lib/otter/node.db
systemctl start otter-node || true
if /usr/local/lib/otter/health.sh; then
  say "rolled back to $(/usr/local/bin/otter-node version); the failed binary is /usr/local/bin/otter-node.failed"
  exit 2
fi
echo "ROLLBACK FAILED: see journalctl -u otter-node" >&2
exit 3
EOF
rc=$?
set -e
case $rc in
  0) say "upgrade of $target done" ;;
  2) printf 'error: upgrade failed and was rolled back on %s\n' "$target" >&2; exit 2 ;;
  *) printf 'error: upgrade of %s failed (exit %s) — check the server now\n' "$target" "$rc" >&2; exit 3 ;;
esac
```

- [ ] **Step 4:** `bash -n` all three. **Commit** `git commit -m "feat(deploy): push, upgrade with rollback, health checks"`.

---

### Task 7: VM end-to-end test (install, check, upgrade, rollback, backup, uninstall)

**Goal:** a scripted run of the real scripts against a disposable Debian 12 VM under QEMU/KVM, plus the Android live
test over pinned TLS against that VM.

**Files:**
- Create: `otter-server/deploy/test/vm.sh`, `otter-server/deploy/test/e2e.sh`
- Modify: `otter-server/.gitignore` (`/.vm/`)

**Acceptance Criteria:**
- [ ] `deploy/test/vm.sh start|stop|ssh` boots a Debian 12 `genericcloud` amd64 image (downloaded once to
      `~/.cache/otter-vm/`, verified against Debian's `SHA512SUMS`) as a throwaway overlay, root SSH key login via
      cloud-init NoCloud (seed served over HTTP on 127.0.0.1:8099), forwards `127.0.0.1:2222→22` and `127.0.0.1:27443→27443`.
- [ ] `deploy/test/e2e.sh` (exit 0 only if every step passed): network with node `vm` (`--wss-host 127.0.0.1`), bootstrap
      invite, `push.sh` → install + checks pass; `push.sh` again (idempotent) passes; `upgrade.sh` to `0.0.2-e2e` → exit 0 and
      the node reports `0.0.2-e2e`; `upgrade.sh` with a broken binary → exit 2, node still answers and reports `0.0.2-e2e`;
      `backup.sh --install` + `systemctl start otter-backup.service` → one `node-*.db` in `/var/backups/otter`;
      `uninstall.sh` keeps `/var/lib/otter`; `uninstall.sh --purge` removes it.
- [ ] With `--keep`, e2e stops before uninstall and prints the bootstrap link; then `LiveNodeTest` passes against the VM over
      pinned TLS (`OTTER_DEV_INVITE=<link>`). Record the run in the M1.5 notes (Task 12).

**Verify:** `cd otter-server && deploy/test/e2e.sh` → ends with `e2e: all steps passed`

**Steps:**

- [ ] **Step 1: `deploy/test/vm.sh`.**

```bash
#!/usr/bin/env bash
# Disposable Debian 12 VM for deploy tests. Usage: vm.sh start | stop | ssh [cmd...]
set -euo pipefail
cd "$(dirname "$0")/../.."
VM=.vm; CACHE="$HOME/.cache/otter-vm"
BASE_URL=https://cloud.debian.org/images/cloud/bookworm/latest
IMG=debian-12-genericcloud-amd64.qcow2
SSH=(ssh -p 2222 -i "$VM/id" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1)
case "${1:-}" in
start)
  mkdir -p "$CACHE" "$VM/seed"
  if [[ ! -f "$CACHE/$IMG" ]]; then
    echo "==> downloading $IMG (~400 MB, once)"
    curl -fL -o "$CACHE/$IMG.part" "$BASE_URL/$IMG"
    curl -fsL -o "$CACHE/SHA512SUMS" "$BASE_URL/SHA512SUMS"
    (cd "$CACHE" && grep " $IMG\$" SHA512SUMS | sed "s/$IMG/$IMG.part/" | sha512sum -c --quiet)
    mv "$CACHE/$IMG.part" "$CACHE/$IMG"
  fi
  rm -f "$VM/disk.qcow2"
  qemu-img create -q -f qcow2 -b "$CACHE/$IMG" -F qcow2 "$VM/disk.qcow2" 8G
  [[ -f "$VM/id" ]] || ssh-keygen -q -t ed25519 -N '' -f "$VM/id"
  cat > "$VM/seed/user-data" <<EOF
#cloud-config
disable_root: false
ssh_pwauth: false
users:
  - name: root
    ssh_authorized_keys: ["$(cat "$VM/id.pub")"]
EOF
  printf 'instance-id: otter-e2e-%s\nlocal-hostname: otter-e2e\n' "$(date +%s)" > "$VM/seed/meta-data"
  python3 -m http.server 8099 --bind 127.0.0.1 --directory "$VM/seed" >/dev/null 2>&1 & echo $! > "$VM/http.pid"
  qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 2 -display none -daemonize -pidfile "$VM/qemu.pid" \
    -drive file="$VM/disk.qcow2",if=virtio \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:27443-:27443 \
    -device virtio-net-pci,netdev=n0 \
    -smbios type=1,serial=ds='nocloud;s=http://10.0.2.2:8099/'
  echo "==> waiting for SSH"
  for _ in $(seq 120); do "${SSH[@]}" true 2>/dev/null && { echo "==> VM ready"; exit 0; }; sleep 2; done
  echo "VM did not come up" >&2; exit 1 ;;
stop)
  for p in qemu http; do [[ -f "$VM/$p.pid" ]] && kill "$(cat "$VM/$p.pid")" 2>/dev/null || true; rm -f "$VM/$p.pid"; done
  rm -f "$VM/disk.qcow2" ;;
ssh) shift; exec "${SSH[@]}" "$@" ;;
*) echo "usage: vm.sh start|stop|ssh [cmd]" >&2; exit 2 ;;
esac
```
If Debian's image ignores the SMBIOS seed, fall back to `ds=nocloud-net;s=…` (the older name) and note it.

- [ ] **Step 2: `deploy/test/e2e.sh`.**

```bash
#!/usr/bin/env bash
# Deploy end-to-end test against a disposable VM. Usage: e2e.sh [--keep]
set -euo pipefail
cd "$(dirname "$0")/../.."
keep=0; [[ "${1:-}" == --keep ]] && keep=1
work=$(mktemp -d)
cleanup() { (( keep )) || deploy/test/vm.sh stop; rm -rf "$work"; }
trap cleanup EXIT
step() { printf '\n######## %s\n' "$*"; }
export OTTER_ADMIN_DIR="$work/admin" OTTER_ADMIN_PASSPHRASE=e2e-only-passphrase
export OTTER_SSH_PORT=2222 OTTER_SSH_OPTS="-i $PWD/.vm/id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
T=root@127.0.0.1
vmsh() { deploy/test/vm.sh ssh "$@"; }

step "build"
make -s build
make -s release VERSION=0.0.1-e2e >/dev/null
make -s release VERSION=0.0.2-e2e >/dev/null
step "VM"
deploy/test/vm.sh start
step "network"
bin/otter-admin --dir "$OTTER_ADMIN_DIR" network init >/dev/null
bin/otter-admin --dir "$OTTER_ADMIN_DIR" node add --label vm --wss-host 127.0.0.1 --ip 127.0.0.1
bin/otter-admin --dir "$OTTER_ADMIN_DIR" manifest sign >/dev/null
link=$(bin/otter-admin --dir "$OTTER_ADMIN_DIR" invite bootstrap | grep -m1 '^otter://')
step "install (push.sh)"
deploy/make-bundle.sh vm 0.0.1-e2e
deploy/push.sh vm "$T"
[[ "$(vmsh /usr/local/bin/otter-node version)" == 0.0.1-e2e ]]
step "install again (idempotent)"
deploy/make-bundle.sh vm 0.0.1-e2e
deploy/push.sh vm "$T"
step "upgrade to 0.0.2-e2e"
deploy/upgrade.sh "$T" dist/otter-node_0.0.2-e2e_linux_amd64
[[ "$(vmsh /usr/local/bin/otter-node version)" == 0.0.2-e2e ]]
step "upgrade with a broken binary → rollback"
printf '#!/bin/sh\nexit 1\n' > "$work/broken"
set +e; deploy/upgrade.sh "$T" "$work/broken"; rc=$?; set -e
[[ $rc == 2 ]] || { echo "expected exit 2 (rolled back), got $rc"; exit 1; }
[[ "$(vmsh /usr/local/bin/otter-node version)" == 0.0.2-e2e ]]
OTTER_SKIP_DNS=1 deploy/check.sh vm "$T"
step "backups"
vmsh /usr/local/lib/otter/backup.sh --install
vmsh systemctl start otter-backup.service
vmsh 'ls /var/backups/otter/node-*.db'
if (( keep )); then
  rm -rf .vm/admin && cp -r "$OTTER_ADMIN_DIR" .vm/admin
  printf '\nVM kept running (admin dir copied to .vm/admin). Invite for LiveNodeTest:\n%s\nStop with deploy/test/vm.sh stop\n' "$link"
  exit 0
fi
step "uninstall"
vmsh /usr/local/lib/otter/uninstall.sh
vmsh test -d /var/lib/otter
vmsh test ! -e /etc/otter
deploy/make-bundle.sh vm 0.0.2-e2e && deploy/push.sh vm "$T"   # reinstall over kept data works
vmsh /usr/local/lib/otter/uninstall.sh --purge
vmsh test ! -e /var/lib/otter
rm -f dist/*-e2e* && (cd dist && sha256sum otter-*_* > SHA256SUMS 2>/dev/null || rm -f SHA256SUMS)
printf '\ne2e: all steps passed\n'
```
With `--keep` the admin dir is copied to `.vm/admin`, so `OTTER_ADMIN_DIR=.vm/admin deploy/check.sh vm root@127.0.0.1` works later.

- [ ] **Step 3: run** `deploy/test/e2e.sh`. Fix script bugs it finds (they belong to Tasks 5–6; commit the fixes with this
  task and list them in the commit body). Expected: `e2e: all steps passed`.

- [ ] **Step 4: Android over pinned TLS.** `deploy/test/e2e.sh --keep`, then in `otter-android`:

```bash
OTTER_DEV_INVITE='<printed otter://join/… link>' JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2 \
  ./gradlew :core:data:testDebugUnitTest --tests '*LiveNodeTest*'
```
Expected: PASS (the manifest endpoint is `wss://127.0.0.1:27443/…` with a pin; the certificate has IP SAN 127.0.0.1).
If `PinnedTrustManager` rejects IP-literal hosts, that's a bug to fix in `core:network` (with a unit test in
`PinnedConnectionTest`), not a reason to change the test. Then `deploy/test/vm.sh stop`.

- [ ] **Step 5: commit** `git commit -m "test(deploy): VM end-to-end test of install, upgrade, rollback, backup, uninstall"`.

---

### Task 8: Android — profile data layer

**Goal:** the app can change its display name offline-first and publishes a new signed directory entry when online;
its own entry version follows the directory.

**Files:**
- Modify: `otter-android/core/proto` (via `scripts/sync-proto.sh`), `core/network/.../NodeApi.kt`,
  `core/database/.../dao/AccountDao.kt`, `core/data/.../account/AccountRepository.kt`, `account/LocalAccount.kt`,
  `core/data/.../settings/Settings.kt`, `core/data/.../directory/DirectorySync.kt`, `core/data/.../sync/SyncEngine.kt`,
  `core/data/.../registration/Registration.kt`, `core/data/src/test/.../FakeNode.kt`, `TestGraph.kt`, `LiveClient.kt`
- Create: `core/data/.../account/DirectoryEntries.kt`, `core/data/.../profile/ProfileRepository.kt`,
  `core/data/src/test/.../ProfileTest.kt`, `core/data/src/test/.../LiveProfileTest.kt`

**Acceptance Criteria:**
- [ ] `ProfileRepository.setDisplayName(raw)`: trims; 1–64 code points else `ProfileError.Empty/TooLong`; stores the name
      in `account` and sets `profile_pending` in one transaction; `AccountRepository.account` emits the new name at once.
- [ ] While a session is up, a pending name is published as entry `version = entryVersion + 1` with the same username, keys,
      `identity_sig`, `can_invite = true` and `registered_ms = account.createdMs`; on OK the pending flag clears and
      `entryVersion` is stored. `CONFLICT` → reads its own entry from `directory()`, continues from that version (max 3 tries).
      Network errors leave it pending and retry on the next session or after 30 s.
- [ ] `DirectorySync` sees its own entry: raises `entryVersion` to the entry's version; when nothing is pending and the
      name differs, adopts it (restore/second install cases).
- [ ] Registration builds the entry through `DirectoryEntries` and sets `registered_ms`.
- [ ] Tests (`FakeNode`): offline edit → online publishes once; a second client sees the new contact name and the direct
      chat title; conflict path; validation; pending survives an app restart (new graph on the same DB).

**Verify:** `cd otter-android && JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2 ./gradlew :core:data:testDebugUnitTest --tests '*Profile*' --tests '*DirectorySync*' --tests '*Registration*'`

**Steps:**

- [ ] **Step 1:** `scripts/sync-proto.sh` (copies `registered_ms`). Build `:core:proto`.

- [ ] **Step 2: failing tests** `ProfileTest.kt` (Robolectric, same setup as `MessagingFlowTest`: one `FakeNode`, two `TestGraph`s
  registered through an invite):

```kotlin
@RunWith(RobolectricTestRunner::class)
class ProfileTest {
    @Test fun offlineEditIsPublishedWhenOnlineAndOthersSeeIt() = runBlocking {
        val (node, a, b) = twoMembers() // helper: registers "Мама"/mama and "Боря"/borya, both online, contacts synced
        a.offline()
        a.profile.setDisplayName("  Мама Оля ").getOrThrow()
        assertEquals("Мама Оля", a.accounts.account.value!!.displayName)
        assertTrue(a.settings.profilePending())
        a.online()
        eventually(what = "published") { !a.settings.profilePending() }
        assertEquals(2, a.settings.entryVersion())
        eventually(what = "B sees the name") { b.db.contactDao().get(a.me.userId)!!.displayName == "Мама Оля" }
        val conv = b.messages.conversationWith(a.me.userId)
        eventually(what = "B's chat title") { b.db.conversationDao().get(conv)!!.title == "Мама Оля" }
        assertEquals(1, node.directoryUpdates(a.me.userId))
    }

    @Test fun validation() = runBlocking {
        val (_, a, _) = twoMembers()
        assertEquals(ProfileError.Empty, a.profile.setDisplayName("   ").exceptionOrNull())
        assertEquals(ProfileError.TooLong, a.profile.setDisplayName("я".repeat(65)).exceptionOrNull())
        assertTrue(a.profile.setDisplayName("😀".repeat(64)).isSuccess) // 64 code points, 128 UTF-16 units
    }

    @Test fun conflictContinuesFromServerVersion() = runBlocking {
        val (node, a, _) = twoMembers()
        node.bumpDirectoryVersion(a.me.userId, to = 5) // simulates an entry published by an earlier install
        a.profile.setDisplayName("Оля").getOrThrow()
        eventually(what = "published") { !a.settings.profilePending() }
        assertEquals(6, a.settings.entryVersion())
    }

    @Test fun pendingSurvivesRestart() = runBlocking {
        val (_, a, _) = twoMembers()
        a.offline()
        a.profile.setDisplayName("Оля").getOrThrow()
        val a2 = a.restart() // new graph on the same database file
        assertTrue(a2.settings.profilePending())
        assertEquals("Оля", a2.accounts.load()!!.displayName)
        a2.online()
        eventually(what = "published after restart") { !a2.settings.profilePending() }
    }
}
```
`TestGraph` gains `profile`, `settings`, `accounts` accessors and `restart()` if missing (look at how `ForegroundSyncTest`
or `OutboxTest` reopen a graph; add `restart()` that closes the scope and builds a new `TestGraph` on the same
`db` file). `FakeNode` gains `directoryUpdates(userId)`, `bumpDirectoryVersion(userId, to)` and the `updateDirectory`
handler (Step 5). Run → FAIL (compile errors).

- [ ] **Step 3: storage.**
  `AccountDao`: `@Query("UPDATE account SET display_name = :name") suspend fun setDisplayName(name: String)`.
  `Settings`:

```kotlin
    /** Version of our own DIRECTORY_ENTRY as last published or seen (M1–M3 registrations are version 1). */
    suspend fun entryVersion(): Int = int(ENTRY_VERSION) ?: 1
    suspend fun setEntryVersion(v: Int) = putInt(ENTRY_VERSION, v)
    /** A display-name change is saved locally but not yet accepted by a node. */
    suspend fun profilePending(): Boolean = (int(PROFILE_PENDING) ?: 0) != 0
    suspend fun setProfilePending(v: Boolean) = putInt(PROFILE_PENDING, if (v) 1 else 0)
    // companion: const val ENTRY_VERSION = "profile_entry_version"; const val PROFILE_PENDING = "profile_pending"
```
  (No Room migration: settings are key/value rows; `account.display_name` exists.)
  `LocalAccount` gains `val createdMs: Long` (from `AccountEntity.createdMs`). `AccountRepository`:

```kotlin
    /** Re-reads the account row (after a profile change). */
    suspend fun reload(): LocalAccount? = loadMutex.withLock {
        accountDao.get()?.let { e ->
            val cur = _account.value
            val acc = if (cur != null && cur.userId.contentEquals(e.userId)) cur.copyWith(displayName = e.displayName) else build(e)
            acc.also { _account.value = it }
        }
    }
```
  Implement `build(e)` (the body `load()` already has) and `LocalAccount.copyWith(displayName)`; `load()` uses `build`.

- [ ] **Step 4: `DirectoryEntries.kt`** (`core/data/.../account/`):

```kotlin
/** Builds our own DIRECTORY_ENTRY record (registration and profile updates use the same fields). */
object DirectoryEntries {
    fun build(userId: ByteArray, username: String, displayName: String, seed: ByteArray, version: Int, registeredMs: Long): DirectoryEntry {
        val account = SeedKeys.accountKeyPair(seed)
        val identity = IdentityKeys.fromSeed(seed)
        return DirectoryEntry.newBuilder().setUserId(bs(userId)).setUsername(username).setDisplayName(displayName)
            .setAccountPub(bs(account.publicKey)).setIdentityPub(bs(identity.publicKey.serialize()))
            .setIdentitySig(bs(IdentityKeys.bindAccount(identity, account.publicKey)))
            .setVersion(version.toLong()).setCanInvite(true).setRegisteredMs(registeredMs).build()
    }

    fun record(me: LocalAccount, displayName: String, version: Int, nowMs: Long): Record =
        RecordCodec.sign(RecordCodec.body(RecordType.DIRECTORY_ENTRY, me.userId,
            build(me.userId, me.username, displayName, me.seed, version, me.createdMs).toByteArray(), createdMs = nowMs), me.accountKey)

    /** Display names: trimmed, 1–64 Unicode code points (the node counts runes). */
    fun validate(name: String): ProfileError? = when {
        name.isEmpty() -> ProfileError.Empty
        name.codePointCount(0, name.length) > 64 -> ProfileError.TooLong
        else -> null
    }
}

sealed class ProfileError : Exception() {
    data object Empty : ProfileError() { private fun readResolve(): Any = Empty }
    data object TooLong : ProfileError() { private fun readResolve(): Any = TooLong }
}
```
(`version` is `uint64` in the proto → `setVersion(Long)`; keep `bs` from `Bytes.kt`.) In `Registration.doRegister`, replace
the inline builder with `DirectoryEntries.build(userId, user, name, seed, 1, now)`, and use `DirectoryEntries.validate(name)`
for the name check (map `ProfileError` → `RegistrationError.BadDisplayName`), so registration also counts code points.

- [ ] **Step 5: network.** `NodeApi`: `suspend fun updateDirectory(entry: Record)`; implementation
  `override suspend fun updateDirectory(entry: Record) { rpc.call("directory.update", req(entry)) }`.
  `FakeNode.updateDirectory`: verify the record like `register` does; author must be the session user
  (`STATUS_UNAUTHORIZED`), username unchanged (`STATUS_INVALID`), version > current (`throw RpcException(Status.STATUS_CONFLICT, "not newer")`);
  store it, count it in `directoryUpdates`, and `emit("directory", Empty)` to every logged-in session.

- [ ] **Step 6: `ProfileRepository.kt`** (`core/data/.../profile/`):

```kotlin
@Singleton
class ProfileRepository @Inject constructor(
    private val accounts: AccountRepository, private val db: OtterDatabase, private val settings: Settings, private val clock: Clock,
) {
    private val kicks = Channel<Unit>(Channel.CONFLATED)
    private val _pending = MutableStateFlow(false)
    /** True while a name change waits for a node (Settings shows a note). */
    val pending: StateFlow<Boolean> = _pending

    suspend fun refresh() { _pending.value = settings.profilePending() }

    /** Saves the display name on the phone at once; it reaches the directory when online (D39). */
    suspend fun setDisplayName(raw: String): Result<Unit> {
        val name = raw.trim()
        DirectoryEntries.validate(name)?.let { return Result.failure(it) }
        val me = accounts.require()
        if (name == me.displayName) return Result.success(Unit)
        db.withTransaction {
            db.accountDao().setDisplayName(name)
            settings.setProfilePending(true)
        }
        accounts.reload()
        _pending.value = true
        kicks.trySend(Unit)
        return Result.success(Unit)
    }

    /** Runs for one connected session: publishes a pending change now and after every later edit. */
    suspend fun run(api: NodeApi): Nothing {
        while (true) {
            try {
                publishIfPending(api)
                kicks.receive()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log.log(Level.INFO, "profile publish failed; retrying", e)
                withTimeoutOrNull(RETRY_MS) { kicks.receive() }
            }
        }
    }

    suspend fun publishIfPending(api: NodeApi) {
        repeat(MAX_TRIES) {
            if (!settings.profilePending()) { _pending.value = false; return }
            val me = accounts.require()
            val version = settings.entryVersion() + 1
            try {
                api.updateDirectory(DirectoryEntries.record(me, me.displayName, version, clock.now()))
                db.withTransaction {
                    settings.setEntryVersion(version)
                    // an edit made during the call keeps the flag: compare with what we sent
                    if (accounts.reload()?.displayName == me.displayName) settings.setProfilePending(false)
                }
                _pending.value = settings.profilePending()
                if (!_pending.value) return
            } catch (e: RpcException) {
                if (e.status != Status.STATUS_CONFLICT) throw e
                val mine = api.directory().mapNotNull { ownVersion(it, me.userId) }.maxOrNull() ?: throw e
                settings.setEntryVersion(maxOf(mine, settings.entryVersion()))
            }
        }
    }

    private fun ownVersion(rec: Record, me: ByteArray): Int? = runCatching {
        val body = RecordBody.parseFrom(rec.body)
        if (body.type != RecordType.DIRECTORY_ENTRY || !body.author.toByteArray().contentEquals(me)) return null
        DirectoryEntry.parseFrom(body.payload).version.toInt()
    }.getOrNull()

    companion object {
        const val RETRY_MS = 30_000L
        const val MAX_TRIES = 3
        private val log: Logger = Logger.getLogger("ProfileRepository")
    }
}
```
(`Clock` is `app.ottermsg.core.data.Clock`; `Status` is the proto enum used by `RpcException`.)

- [ ] **Step 7: own entry in `DirectorySync.apply`.** Replace `if (userId.contentEquals(me.userId)) continue` with:

```kotlin
            if (userId.contentEquals(me.userId)) { applyOwn(e); continue }
```
```kotlin
    private suspend fun applyOwn(e: DirectoryEntry) {
        if (e.version.toInt() > settings.entryVersion()) settings.setEntryVersion(e.version.toInt())
        if (!settings.profilePending() && e.displayName != accounts.require().displayName) {
            accountDao.setDisplayName(e.displayName)
            accounts.reload()
        }
    }
```
(Inject `Settings` and `AccountDao` into `DirectorySync`; update `DirectorySyncTest`'s construction.) Add a
`DirectorySyncTest` case: own entry v3 named "Оля" → `entryVersion == 3`, account name "Оля"; with pending set → name kept.

- [ ] **Step 8: `SyncEngine.runSession`:** inject `ProfileRepository`; after `prekeys.refillIfPending(api)` add
  `session.launch { profile.run(api) }`. Update `TestGraph`/`LiveClient` construction.

- [ ] **Step 9:** run Verify → PASS; then the whole `./gradlew test` → green (other tests construct `DirectorySync`/`SyncEngine`).

- [ ] **Step 10: `LiveProfileTest.kt`** (skipped without `OTTER_DEV_INVITE`, same shape as `LiveNodeTest`): A and B register,
  A renames to "Мама $suffix", B eventually shows it as the contact name. Run it against `scripts/dev-node.sh --host 127.0.0.1`
  (fresh invite) → PASS.

- [ ] **Step 11: commit** `git commit -m "feat(profile): offline-first display name edits published as directory entries"`.

---

### Task 9: Android — `feature:settings`, Profile and Edit-name screens

**Goal:** Settings becomes its own module; the profile row opens a Profile screen with an Edit-name screen, following
the design guide; the FAB colour bug from M3 is fixed.

**Files:**
- Create: `otter-android/feature/settings/build.gradle.kts`, `feature/settings/src/main/AndroidManifest.xml` (if the other
  feature modules have one), `feature/settings/src/main/kotlin/app/ottermsg/feature/settings/{SettingsScreen.kt,ProfileScreen.kt,EditNameScreen.kt,ProfileViewModel.kt}`,
  `feature/settings/src/main/res/values/strings.xml`, `values-en/strings.xml` (follow the RU-primary layout of `feature:chats`),
  `feature/settings/src/test/kotlin/app/ottermsg/feature/settings/{ProfileViewModelTest.kt,EditNameScreenTest.kt}`
- Modify: `settings.gradle.kts`, `app/build.gradle.kts`, `app/src/main/java/app/ottermsg/AppNavHost.kt`,
  delete `feature/chats/.../SettingsScreen.kt` and its `settings_*` strings from `feature:chats`,
  `core/ui/.../theme` colour scheme (`primaryContainer`, `onPrimaryContainer`)

**Acceptance Criteria:**
- [ ] Settings → "Профиль" section shows one row: avatar 48 dp (`OtterAvatar(name, seed = userId)`), display name, `@username`,
      chevron; tapping opens Profile.
- [ ] Profile: `OtterTopBar("Профиль", onBack)`; centred avatar 64 dp; name 24/32 sp weight 600; `@username`; rows
      "Имя" (current name, chevron → Edit name) and "Имя пользователя" (`@username`, caption "Нельзя изменить");
      while pending, a calm note "Имя обновится у близких, когда появится подключение" (`onSurfaceVariant`, no spinner).
- [ ] Edit name: single-line `OutlinedTextField` labelled "Имя", pre-filled, focus + keyboard on open, counter "n / 64"
      (code points) in supporting text; errors "Введите имя" / "Не длиннее 64 символов" shown under the field; "Сохранить"
      button (48 dp min, full width) disabled when unchanged or invalid; IME action Done saves; after save → back to Profile.
      Back without saving discards.
- [ ] English strings for every new string; content descriptions: "Назад" from `OtterTopBar`; avatars decorative.
- [ ] Layout works at 320 dp width and 200 % font (Profile scrolls; the field and button stay visible above the keyboard).
- [ ] "Написать" FAB uses the Otter primary container: light `#DCF1E3`/`#17382D`, dark `#25463A`/`#E0F4E7`
      (the outgoing-bubble tokens; contrast ≥ 4.5:1 for the label).
- [ ] The chat list's top-bar avatar and new invites (inviter name) use the new name immediately.

**Verify:** `cd otter-android && JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2 ./gradlew :feature:settings:testDebugUnitTest :app:assembleDebug`

**Steps:**

- [ ] **Step 1: module.** Copy `feature/chats/build.gradle.kts` to `feature/settings/` with `namespace = "app.ottermsg.feature.settings"`;
  add `include(":feature:settings")` to `settings.gradle.kts` and `implementation(project(":feature:settings"))` to
  `app/build.gradle.kts`. Move `SettingsScreen.kt` (package `app.ottermsg.feature.settings`) and its strings
  (`settings_*`, both languages). `AppNavHost` imports `app.ottermsg.feature.settings.SettingsRoute`. Build → green.

- [ ] **Step 2: failing ViewModel test** `ProfileViewModelTest.kt` with a fake `ProfileStore` interface (so the VM tests
  don't need Room):

```kotlin
interface ProfileStore {
    val account: StateFlow<LocalAccount?>
    val pending: StateFlow<Boolean>
    suspend fun setDisplayName(name: String): Result<Unit>
}
```
(`ProfileRepository` + `AccountRepository` are adapted by a small `@Singleton class RealProfileStore @Inject constructor(…) : ProfileStore`
bound in a Hilt module in `feature:settings`.)

```kotlin
class ProfileViewModelTest {
    @get:Rule val main = MainDispatcherRule() // reuse the rule from feature:groups tests (copy if it isn't shared)

    @Test fun editStateValidatesAndSaves() = runTest {
        val store = FakeProfileStore(name = "Мама")
        val vm = EditNameViewModel(store)
        assertEquals("Мама", vm.state.value.text)
        assertFalse(vm.state.value.canSave)               // unchanged
        vm.onText("   ")
        assertEquals(EditNameError.Empty, vm.state.value.error)
        vm.onText("я".repeat(65))
        assertEquals(EditNameError.TooLong, vm.state.value.error)
        vm.onText("Мама Оля")
        assertTrue(vm.state.value.canSave)
        assertEquals("8 / 64", vm.state.value.counter)
        var done = false
        vm.save { done = true }
        advanceUntilIdle()
        assertTrue(done)
        assertEquals("Мама Оля", store.saved)
    }
}
```
Run → FAIL.

- [ ] **Step 3: ViewModels** `ProfileViewModel.kt`:

```kotlin
enum class EditNameError { Empty, TooLong }

data class EditNameState(val text: String, val original: String, val error: EditNameError?, val saving: Boolean = false) {
    private val trimmed get() = text.trim()
    val counter: String get() = "${trimmed.codePointCount(0, trimmed.length)} / 64"
    val canSave: Boolean get() = error == null && !saving && trimmed != original
}

@HiltViewModel
class ProfileViewModel @Inject constructor(store: ProfileStore) : ViewModel() {
    val account = store.account
    val pending = store.pending
}

@HiltViewModel
class EditNameViewModel @Inject constructor(private val store: ProfileStore) : ViewModel() {
    private val original = store.account.value?.displayName.orEmpty()
    private val _state = MutableStateFlow(EditNameState(original, original, null))
    val state: StateFlow<EditNameState> = _state

    fun onText(t: String) { _state.value = _state.value.copy(text = t, error = validate(t)) }

    fun save(onDone: () -> Unit) {
        val s = _state.value
        if (!s.canSave) return
        _state.value = s.copy(saving = true)
        viewModelScope.launch {
            store.setDisplayName(s.text).fold(
                onSuccess = { onDone() },
                onFailure = { e ->
                    _state.value = _state.value.copy(saving = false,
                        error = if (e == ProfileError.TooLong) EditNameError.TooLong else EditNameError.Empty)
                })
        }
    }

    private fun validate(t: String): EditNameError? {
        val n = t.trim()
        return when {
            n.isEmpty() -> EditNameError.Empty
            n.codePointCount(0, n.length) > 64 -> EditNameError.TooLong
            else -> null
        }
    }
}
```
`ProfileRepository` must call `refresh()` once at startup so `pending` is right after a restart: call it from
`RealProfileStore`'s `init { scope.launch { repo.refresh() } }` using an application `CoroutineScope` the app already
provides in DI (look in `app/.../di`; M2 added one for `SyncEngine`).

- [ ] **Step 4: screens.** `ProfileScreen.kt`:

```kotlin
@Composable
fun ProfileRoute(onBack: () -> Unit, onEditName: () -> Unit, vm: ProfileViewModel = hiltViewModel()) {
    val account by vm.account.collectAsStateWithLifecycle()
    val pending by vm.pending.collectAsStateWithLifecycle()
    val me = account ?: return
    Scaffold(containerColor = MaterialTheme.colorScheme.background,
        topBar = { OtterTopBar(stringResource(R.string.profile_title), onBack = onBack) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally) {
            Spacer(Modifier.height(Dimens.s24))
            OtterAvatar(me.displayName, seed = me.userId, size = Dimens.avatarProfile)
            Spacer(Modifier.height(Dimens.s12))
            Text(me.displayName, style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = Dimens.screenGutter))
            Text("@${me.username}", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (pending) {
                Text(stringResource(R.string.profile_pending), style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
                    modifier = Modifier.padding(horizontal = Dimens.screenGutter, vertical = Dimens.s8))
            }
            Spacer(Modifier.height(Dimens.s24))
            OtterSettingsRow(stringResource(R.string.profile_name), subtitle = me.displayName, icon = Icons.Outlined.Badge,
                onClick = onEditName)
            OtterSettingsRow(stringResource(R.string.profile_username), subtitle = "@${me.username} · " +
                stringResource(R.string.profile_username_fixed), icon = Icons.Outlined.AlternateEmail)
        }
    }
}
```
Use the actual names in `core:ui` (`Dimens`, `OtterAvatar` signature, typography role for "Имя в карточке профиля
24/32 600" — if the theme has no such style, add `profileName` to the Otter typography extension rather than inlining
sizes). Icons must exist in the icon set the project uses (it depends on material-icons-extended; check `Badge`,
`AlternateEmail`; otherwise `Person`/`Info`).

`EditNameScreen.kt`:

```kotlin
@Composable
fun EditNameRoute(onBack: () -> Unit, vm: EditNameViewModel = hiltViewModel()) {
    val s by vm.state.collectAsStateWithLifecycle()
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    Scaffold(containerColor = MaterialTheme.colorScheme.background,
        topBar = { OtterTopBar(stringResource(R.string.edit_name_title), onBack = onBack) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState())
            .padding(horizontal = Dimens.screenGutter, vertical = Dimens.s16)) {
            OutlinedTextField(
                value = s.text, onValueChange = vm::onText, singleLine = true,
                label = { Text(stringResource(R.string.edit_name_label)) },
                isError = s.error != null,
                supportingText = {
                    Row(Modifier.fillMaxWidth()) {
                        Text(when (s.error) {
                            EditNameError.Empty -> stringResource(R.string.edit_name_empty)
                            EditNameError.TooLong -> stringResource(R.string.edit_name_too_long)
                            null -> stringResource(R.string.edit_name_hint)
                        }, Modifier.weight(1f))
                        Text(s.counter)
                    }
                },
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { vm.save(onBack) }),
                modifier = Modifier.fillMaxWidth().focusRequester(focus),
            )
            Spacer(Modifier.height(Dimens.s16))
            Button(onClick = { vm.save(onBack) }, enabled = s.canSave,
                modifier = Modifier.fillMaxWidth().heightIn(min = Dimens.touchTarget)) {
                Text(stringResource(R.string.edit_name_save))
            }
        }
    }
}
```

- [ ] **Step 5: strings.** RU (default resources of the module, matching the other modules' convention):

| key | RU | EN |
|---|---|---|
| `profile_title` | Профиль | Profile |
| `profile_name` | Имя | Name |
| `profile_username` | Имя пользователя | Username |
| `profile_username_fixed` | нельзя изменить | can't be changed |
| `profile_pending` | Имя обновится у близких, когда появится подключение | Your name will update for others once you're online |
| `edit_name_title` | Изменить имя | Edit name |
| `edit_name_label` | Имя | Name |
| `edit_name_hint` | Так вас видят близкие | This is how others see you |
| `edit_name_empty` | Введите имя | Enter a name |
| `edit_name_too_long` | Не длиннее 64 символов | 64 characters at most |
| `edit_name_save` | Сохранить | Save |

- [ ] **Step 6: settings row + navigation.** In `SettingsRoute` replace the profile row with a clickable row showing
  `OtterAvatar(name, seed = userId, size = Dimens.avatarList)`, the name and `@username` (add `onProfile: () -> Unit`).
  `AppNavHost`: routes `settings/profile` and `settings/profile/name`;
  `SettingsRoute(onBack, onInvite, onProfile = { nav.navigate(Routes.PROFILE) })`,
  `ProfileRoute(onBack = { nav.popBackStack() }, onEditName = { nav.navigate(Routes.EDIT_NAME) })`,
  `EditNameRoute(onBack = { nav.popBackStack() })`.

- [ ] **Step 7: FAB colour.** In the Otter colour scheme (`core/ui/.../theme`, light and dark) set
  `primaryContainer = outgoingContainer` and `onPrimaryContainer = onOutgoingContainer` token values from the table above.
  Check the existing `ColorContrastTest` (or `AvatarPalette` contrast test) pattern and add both pairs to it.

- [ ] **Step 8: Compose test** `EditNameScreenTest.kt` (Robolectric + `createComposeRule`, as feature:groups tests do):
  set text "" → "Введите имя" shown and "Сохранить" disabled; set "Оля" → enabled; click → fake store saved "Оля".

- [ ] **Step 9:** Verify → green; `./gradlew test assembleDebug` green. Run on the emulator: Settings → Профиль → Изменить имя
  → save offline (airplane mode) → note shows → online → note disappears. Light/dark, 200 % font, 320 dp
  (`adb shell wm size 720x1600` + density 360 → 320 dp; reset with `wm size reset`/`wm density reset`).

- [ ] **Step 10: commit** `git commit -m "feat(settings): settings module, profile and edit-name screens; primary container colours"`.

---

### Task 10: Release build and on-device checks

**Goal:** the R8 build works with the new module and API; the manual checklist covers profile editing and the VPS.

**Files:**
- Create: `otter-android/docs/m1.5-manual-test.md`
- Modify (only if R8 needs it): `otter-android/app/proguard-rules.pro`

**Acceptance Criteria:**
- [ ] `./gradlew assembleRelease assembleStaging` green; the `staging` APK on the emulator against `dev-node.sh`
      (`adb reverse tcp:<port> tcp:<port>`, see M3 notes) can rename the profile and the second scripted client sees it.
- [ ] `SmokeTest` still green: `./gradlew :app:connectedDebugAndroidTest` (after `adb uninstall app.ottermsg`).
- [ ] `docs/m1.5-manual-test.md` lists numbered steps with a result column for: rename on phone A → shown on phone B in
      contacts, direct chat title, group member list and group author names; rename offline → note → online → propagates;
      validation messages; 200 % font; TalkBack reads the profile rows; the VPS steps of Task 11.

**Verify:** `cd otter-android && JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2 ./gradlew assembleRelease assembleStaging test`

**Steps:**
- [ ] **Step 1:** build; fix R8 issues if any (keep rules only for what actually breaks; note them).
- [ ] **Step 2:** staging run on the emulator as described; record the result in the checklist file.
- [ ] **Step 3:** SmokeTest.
- [ ] **Step 4:** write the checklist (two phones: phone A over adb, phone B via `python3 -m http.server 8000`).
- [ ] **Step 5: commit** `git commit -m "test: M1.5 manual checklist; release build checks"`.

---

### Task 11: First real deployment (with the owner)

**Goal:** the milestone's "done when": a node installed on a real VPS from a bundle, the app connected over pinned TLS,
an upgrade with rollback exercised on that server.

**Files:**
- Modify: `otter-android/docs/m1.5-manual-test.md` (results), `docs/09-roadmap.md` (notes, Task 12)

**Acceptance Criteria:**
- [ ] The owner provides: the server (Hetzner, Linode or bare metal; Debian 12/13 or Ubuntu 22.04/24.04, root SSH key
      login), the domain, and whether it's a **new** network (then `network init` + bootstrap invite) or an extra node for an
      existing dev network. **Ask before touching any real server or DNS**; never put the admin key on a server.
- [ ] Following docs/11 §5 literally: `make release`, `node add`, `manifest sign`, `dns records` → owner creates the records →
      `dns check` ok → `make-bundle.sh`/`push.sh` → `check.sh <label> root@<ip>` all PASS.
- [ ] Both phones join (bootstrap link → second member by in-app invite), exchange messages, rename works.
- [ ] `upgrade.sh` to a new version succeeds; a deliberately broken binary rolls back (exit 2) without losing the chat.
- [ ] Every place where docs/11 didn't match reality is fixed in docs/11 (Task 12) and listed in the M1.5 notes.

**Verify:** `deploy/check.sh <label> root@<server-ip>` → `all checks passed`

**Steps:**
- [ ] **Step 1:** ask the owner for the server, domain and network choice (one message, all three questions).
- [ ] **Step 2:** run the procedure; paste each command's output summary into the checklist.
- [ ] **Step 3:** phones; then the upgrade/rollback pair.
- [ ] **Step 4:** if the owner can't provide a server now, mark the task blocked with the exact remaining steps; the VM run
      (Task 7) stands in, and the roadmap row says "VPS run open".

---

### Task 12: Documentation

**Goal:** the docs describe what was built.

**Files:**
- Modify: `docs/00-decisions.md`, `docs/02-protocol.md`, `docs/03-mesh-replication.md`, `docs/07-android-architecture.md`,
  `docs/08-operations.md`, `docs/09-roadmap.md`, `docs/11-deployment.md`, `docs/10-otter-design-guidelines.md` (only §10
  Профиль row note), `otter-server/README.md`

**Acceptance Criteria:**
- [ ] 00: D39–D43 as worded in this plan's header (adjusted to what was built).
- [ ] 02: `DirectoryEntry.registered_ms`; method table row `directory.update{record}` with its statuses; the `Content`
      comment drops "later: ProfileUpdate" (profiles travel in the directory, not in E2E content, per D14/D39).
- [ ] 03: username clash rule mentions `registered_ms`.
- [ ] 07: module list gains `feature/settings` (settings, profile, edit name); `ProfileRepository` paragraph (pending flag,
      publisher per session, own-entry handling in `DirectorySync`).
- [ ] 11: §10 work list marked done; `otter-node check/backup` (no sqlite3 CLI needed — replace the `sqlite3 … .backup` line);
      rotation files (`tls.new.*`, `tls.old.*`); the env variables; `/etc/otter/probe.env`; `/usr/local/lib/otter/`;
      the VM test; anything Task 11 found.
- [ ] 08: points to `deploy/README.md` and 11 for day-2 commands.
- [ ] 09: M1.5 row "done YYYY-MM-DD" (or "VPS run open"); Android column "profile editing"; **"M1.5 notes"** section in
      the same style as M3 notes (verified, deviations, open issues for M4+); the M3 open issue about the lavender FAB
      struck through.

**Verify:** `grep -n "M1.5 notes" docs/09-roadmap.md && grep -n "D43" docs/00-decisions.md && grep -n "directory.update" docs/02-protocol.md`

**Steps:**
- [ ] **Step 1:** edit each file; keep the existing style (tables, short sentences).
- [ ] **Step 2:** `otter-server/README.md`: add the release and deploy commands; commit in otter-server
      `git commit -m "docs: release and deploy commands"`.
- [ ] **Step 3:** merge: in both repos `git checkout main && git merge --ff-only m1-5-deploy` after `make check` and
      `./gradlew test assembleDebug assembleRelease` are green.

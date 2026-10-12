# ADR-011: TLS Ingress in Two Phases, Self-Signed then Let's Encrypt

**Status:** Accepted — implemented by the `ingress` service, `configs/ingress/`, `scripts/ops/tls-*.sh`; tested in `tests/ops/tls.bats` and `tests/integration/run.sh` (certbot against Pebble).

## Context
DEC-002 left the platform without TLS, so services were bound to loopback and unreachable. The public DNS name and the CA choice (Let's Encrypt, institutional CA) are not settled, but testing must not wait for them.

## Decision
1. **nginx ingress** (`nginx:1.30-alpine`, the stable branch) is the only service published beyond loopback:
   - `443` serves Open WebUI;
   - `8443` serves the OpenAI-compatible API, **`/v1/*` only**. LiteLLM's admin UI and key/user management stay on `127.0.0.1:4000`;
   - `80` serves ACME HTTP-01 challenges from a webroot and redirects everything else to HTTPS.
2. **One certificate location:** nginx reads `TLS_DIR/live/{fullchain,privkey}.pem`. Both phases write exactly there, and `install_live` swaps the files atomically only after checking hostname coverage, key match and expiry. nginx is reloaded only after `nginx -t` passes.
3. **Phase 1, `tls-selfsigned.sh`:** a private lab CA (created once, 10 years) signs a 397-day server certificate. Clients import `live/ca.pem` once; re-running renews only the leaf.
4. **Phase 2, `tls-letsencrypt.sh`:** certbot (pinned image, Compose `tools` profile, never started by a deploy) issues via webroot. Renewal is a systemd timer (`install-timers.sh --with-cert-renew`). It refuses to be silently overwritten by phase 1.
5. **TLS policy:** Mozilla "intermediate" (TLS 1.2 + 1.3), no session tickets, HSTS, `server_tokens off`.
6. **Smoke test** connects with the public hostname pinned to loopback and verifies the chain against the active trust root. It also asserts the HTTP→HTTPS redirect, 401 on the public API and 404 for admin endpoints.

## Alternatives considered
- **Caddy or Traefik with built-in ACME:** less glue, but the certificate lifecycle would live inside a proxy-specific store, and the self-signed and institutional-CA phases would need a different path. nginx plus files keeps all three phases identical from nginx's point of view.
- **Path-based API under 443:** Open WebUI already owns `/api/*`, so a prefix rewrite would be needed and is fragile. A separate port is simpler and lets firewalls treat the API separately.

## Consequences
- HTTP-01 requires PUBLIC_HOSTNAME to resolve publicly and port 80 to be open from the internet. For an internal-only service use the institutional CA (install its files into `live/` the same way) or a certbot DNS-01 plugin.
- Ports 80/443/8443 must be free on the VM, and the firewall must allow them.

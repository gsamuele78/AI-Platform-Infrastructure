# ADR-010: Release, Deployment and Rollback Strategy for the Single-Node Stack

**Status:** Accepted — implemented by `scripts/deploy/*`, `scripts/ops/*`; tested in `tests/deploy`, `tests/ops`, `tests/integration`.

## Context
- One VM, one pair of L40S. A 72B model needs both GPUs, so a second copy for blue/green or canary cannot be loaded. Any vLLM change costs downtime equal to the model load time.
- LiteLLM (Prisma) and Open WebUI (Alembic/SQLite) migrate their schemas **forward** when they start. An older image on a migrated schema can fail or corrupt data, so rolling back images without the matching data is not a real rollback.
- The previous design had no deploy or rollback tooling for the stack, and the ADRs claimed backups that did not exist.

## Decision
1. **Immutable releases.** `deploy.sh` copies `compose.yaml`, the GPU profile (as `release.env`; ADR-012) and `configs/` into `/var/lib/lifewatch/releases/<UTC-timestamp>-<git-sha>`. Secrets stay in `.env` (mode 600) and are never copied. `releases/current` is an atomically swapped symlink.
2. **Reviewed state only.** Deploy refuses uncommitted changes. Images are pinned by digest and the model by commit revision, so a release is reproducible.
3. **Preflight before change:** secrets present, strong, URL-safe and not placeholders; Compose renders; weights staged; 2 GPUs visible.
4. **Back up before change:** a verified `pg_dump` plus an archive of the Open WebUI volume (UI stopped), with checksums, before the image pull.
5. **Health-gated cut-over:** `docker compose up -d --wait` blocks on every healthcheck, then `smoke-test.sh` checks liveness, **401 for unauthenticated and invalid keys**, the model listing, real inference and UI health.
6. **Automatic rollback** to the previous release on any failure. Data is restored from the pre-deploy backup **only if a stateful image changed**, because that is the only case where a migration may have run. Otherwise current data is kept.
7. **Manual rollback** (`rollback.sh --previous`) refuses to guess about data. When stateful images differ, the operator must choose `--restore-backup DIR` (loses writes since that backup) or `--no-restore`.

## Alternatives considered
- **Blue/green or canary:** impossible within 96 GB of VRAM for a 72B model. Revisit if a second GPU node is added.
- **Kubernetes / Helm rollbacks:** a control plane for one node adds failure modes without adding capacity. Helm rollback does not solve data migrations either.
- **Rollback by `git checkout` + redeploy:** depends on git hygiene on the host and on registry availability at rollback time. Release snapshots keep exactly what ran.

## Consequences
- Vulnerable windows are explicit: writes between the pre-deploy backup and an automatic rollback are lost **only** when stateful images changed.
- Postgres major-version upgrades are out of scope for automatic rollback (the data directory format changes) and must be planned migrations.
- Backups live on the VM until DEC-006 adds an off-host copy.

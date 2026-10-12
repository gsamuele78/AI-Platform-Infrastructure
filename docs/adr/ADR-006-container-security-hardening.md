# ADR-006: Container Hardening & Immutable Image Tagging

**Status:** Accepted — implemented: digest pins, loopback-only ports, policy-tested (`tests/compose/policy.bats`).

## Context
Deployment configurations using floating tags (`latest`) and exposed backend ports introduce security and reproducibility risks.

## Decision
1. Pin all container images to exact immutable release tags.
2. Bind inference engine backends exclusively to internal Docker networks.
3. Keep host secret keys out of source control using `.env` templates.

## Rationale
Protects internal inference backends from unauthenticated external access and ensures reproducible builds.

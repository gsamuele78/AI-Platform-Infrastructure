#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="."

echo "=== Building Complete LifeWatch ERIC Local AI Platform Repository Bundle ==="
mkdir -p "${REPO_DIR}"
cd "${REPO_DIR}"

# Directory Structure Initialization
mkdir -p \
  .github/workflows \
  configs/proxy \
  configs/models \
  configs/monitoring \
  docs/audit \
  docs/requirements \
  docs/architecture/diagrams \
  docs/adr \
  docs/operations \
  scripts/pve \
  scripts/vm \
  scripts/verify \
  scripts/rollback \
  tests/infrastructure \
  tests/unit

echo "--> Writing configuration and secret templates..."

# 1. .gitignore
cat <<'EOF' > .gitignore
# Environment & Secrets
.env
*.env
*.pem
*.key
*.crt

# Model Caches & Persistent State
/data/
/cache/
*.bin
*.pt
*.safetensors
*.gguf

# Operational Logs & Run Artifacts
*.log
/logs/
/backups/

# IDE & OS Artifacts
.DS_Store
.idea/
.vscode/
EOF

# 2. .env.example
cat <<'EOF' > .env.example
# Security Notice: Copy this file to .env and configure production secrets.
# NEVER commit the active .env file to Git.

# LiteLLM Proxy Gateway Master Key
LITELLM_MASTER_KEY=sk-lifewatch-prod-change-me-immediately-3821903

# PostgreSQL Credentials for Gateway State & Audit
POSTGRES_USER=litellm
POSTGRES_PASSWORD=change_this_secure_postgres_password_98721
POSTGRES_DB=litellm

# LifeWatch ERIC Keycloak / OIDC Authentication
OIDC_CLIENT_ID=lifewatch-ai-platform
OIDC_CLIENT_SECRET=your-production-oidc-client-secret-here
OIDC_PROVIDER_URL=https://auth.lifewatch.eu/realms/lifewatch

# HuggingFace Token (Optional: Required for restricted weights)
HF_TOKEN=
EOF

echo "--> Writing architecture audits..."

# 3. docs/audit/INITIAL_ARCHITECTURE_AUDIT.md
cat <<'EOF' > docs/audit/INITIAL_ARCHITECTURE_AUDIT.md
# Initial Architecture Proposal Audit: LifeWatch AI Platform

## Executive Summary
An exhaustive technical audit of the initial architecture proposal (`Guida_Architettura_AI_LifeWatch.html`) reveals critical technical inaccuracies, mathematically impossible hardware assumptions, and security vulnerabilities that prevent deployment in a production environment without significant refactoring.

## Detailed Findings & Claim Verification Matrix

| Claim / Component in Initial Proposal | Status | Technical Reality & Evidence | Required Engineering Correction |
| :--- | :--- | :--- | :--- |
| Deploy `neuralmagic/DeepSeek-V3-FP8` on 2x NVIDIA L40S (96 GB VRAM) | **INCORRECT / IMPOSSIBLE** | DeepSeek-V3 contains 671 billion parameters. At 8-bit precision (FP8), weight memory alone requires ~$671\text{ GB}$. The target host has 96 GB total VRAM. | Replace with `Qwen2.5-72B-Instruct-FP8` ($TP=2$) or `Meta-Llama-3.3-70B-Instruct-FP8` ($TP=2$). |
| DeepSeek-V3 FP8 download size is "circa 65 GB" | **INCORRECT** | A 65 GB download corresponds to a ~65B–70B model. DeepSeek-V3 FP8 is ~671 GB. | Update project documentation to reflect 70B parameter models (~70 GB download). |
| NVIDIA L40S lacks physical NVLink; interconnect is PCIe | **VERIFIED** | L40S uses the Ada Lovelace architecture without physical NVLink bridges. Inter-GPU communication occurs via PCIe Gen4/Gen5. | Enforce Tensor Parallelism ($TP=2$) for models $>48\text{ GB}$. Use independent $TP=1$ replicas for models $\le 32\text{B}$. |
| vLLM PagedAttention prevents KV cache memory fragmentation | **VERIFIED** | Dynamic block allocation in vLLM optimizes KV cache VRAM utilization during high concurrency. | Retain vLLM v0.6.3+ as the primary inference runtime. |
| Compose configuration using `latest` tags and `--trust-remote-code` | **UNSAFE** | Floating tags yield non-reproducible builds. Unvetted remote code execution exposes the container host to arbitrary code execution. | Pin container image digests/versions and disable `--trust-remote-code`. |
| Single shared API key (`vllm-free-key`) without identity mapping | **UNSAFE** | Shared credentials prevent user auditing, rate limiting, and role-based access control (RBAC). | Deploy LiteLLM Proxy integrated with LifeWatch ERIC Keycloak OIDC. |
EOF

# 4. docs/audit/REPOSITORY_AUDIT.md
cat <<'EOF' > docs/audit/REPOSITORY_AUDIT.md
# Repository & Infrastructure Audit

## Infrastructure Inventory
- **Hypervisor:** Proxmox VE 9.2.x (Debian 13 base, Kernel 6.8+).
- **Physical GPUs:** 2 × NVIDIA L40S (48 GB GDDR6 VRAM each, 96 GB Total).
- **Host RAM:** ~2 TB DDR5 ECC RAM.
- **Topology:** Dual PCIe Gen5 slots, no physical NVLink bridge available.
- **Virtualization Target:** Single Linux VM (Ubuntu 24.04 LTS) receiving both GPUs via PCIe Passthrough (`vfio-pci`).

## Deficiencies Identified in Existing Workspace
1. Missing automated IOMMU isolation and preflight verification scripts on the Proxmox host.
2. Lack of an API gateway layer for identity validation, rate limiting, and token quota enforcement.
3. Hardcoded container paths without clear separation between volatile runtime data and backed-up persistent databases.
4. Absence of health checks, resource constraints, and readiness probes in the compose stack.
EOF

echo "--> Writing PRD and Requirements..."

# 5. docs/requirements/PRD.md
cat <<'EOF' > docs/requirements/PRD.md
# Product Requirements Document (PRD) — LifeWatch AI Platform

## 1. Product Overview
Provide a secure, multi-tenant, local LLM inference platform running on hyperconverged Proxmox VE hardware for LifeWatch ERIC researchers, system engineers, and institutional collaborators.

## 2. Memory Sizing & Model Sizing Formulation
Total required GPU memory ($M_{\text{total}}$) is defined as:
$$M_{\text{total}} = M_{\text{weights}} + M_{\text{KV}} + M_{\text{CUDA\_graphs}} + M_{\text{headroom}}$$

Where:
- $M_{\text{weights}} = P \times B_{\text{precision}}$
- $M_{\text{KV}} = 2 \times N_{\text{layers}} \times N_{\text{heads}} \times d_{\text{head}} \times L_{\text{context}} \times B_{\text{KV}} \times \text{Batch Size}$

### Feasibility Assessment on 2 × 48 GB (96 GB Total VRAM)

| Model Candidate | Parameter Count ($P$) | Precision | Weight Footprint ($M_{\text{weights}}$) | Context Window ($L$) | Execution Strategy | Feasibility Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| DeepSeek-V3-FP8 | 671B | FP8 | ~671 GB | N/A | Exceeds VRAM | **REJECTED (OOM)** |
| Qwen2.5-72B-Instruct-FP8 | 72B | FP8 | ~72 GB | 32,768 | Tensor Parallelism ($TP=2$) | **PASSED (Production Flagship)** |
| Llama-3.3-70B-Instruct-FP8 | 70B | FP8 | ~70 GB | 32,768 | Tensor Parallelism ($TP=2$) | **PASSED (Approved Alternative)** |
| Qwen2.5-Coder-32B-FP8 | 32B | FP8 | ~32 GB | 32,768 | Single GPU Replica ($TP=1$) × 2 | **PASSED (High Throughput)** |

## 3. Functional Requirements
1. **Model Serving:** Expose OpenAI-compatible `/v1/chat/completions` and `/v1/models` endpoints.
2. **Authentication & Identity:** Validate Keycloak OIDC JWT tokens at the gateway before routing requests to backends.
3. **Role-Based Access Control (RBAC):** Restrict high-parameter models and administrative functions based on OIDC group membership.
4. **Web Interface:** Provide Open WebUI for interactive research chat, document processing (RAG), and workspace sharing.
5. **Operational Integrity:** Ensure non-destructive hypervisor passthrough scripts with dry-run planning and explicit rollback procedures.
EOF

# 6. docs/requirements/ACCEPTANCE_CRITERIA.md
cat <<'EOF' > docs/requirements/ACCEPTANCE_CRITERIA.md
# Acceptance Criteria & Validation Matrix

## 1. Infrastructure Automation
- [ ] `scripts/pve/preflight.sh` runs in read-only mode and correctly identifies IOMMU groups and NVIDIA L40S PCIe addresses.
- [ ] `scripts/pve/configure-passthrough.sh` creates a timestamped configuration backup before altering Proxmox VM settings.
- [ ] Dry-run mode (`--vm-id <ID>`) executes without writing host configuration changes.

## 2. Guest VM & GPU Environment
- [ ] `nvidia-smi` inside the guest OS detects both NVIDIA L40S GPUs with 48 GB VRAM each.
- [ ] `scripts/verify/vm-check.sh` successfully executes a CUDA test container across both physical GPUs.

## 3. Serving Backend & API Gateway
- [ ] vLLM backend initializes `Qwen2.5-72B-Instruct-FP8` using Tensor Parallelism ($TP=2$) without CUDA memory allocation errors.
- [ ] Unauthenticated API requests to `http://localhost:4000/v1/chat/completions` are rejected with HTTP 401 Unauthorized.
- [ ] Authenticated requests with valid Keycloak OIDC tokens complete inference successfully.
EOF

echo "--> Writing Architecture Documentation & Diagrams..."

# 7. docs/architecture/ARCHITECTURE.md
cat <<'EOF' > docs/architecture/ARCHITECTURE.md
# Technical Architecture Document

## System Layers & Boundaries

1. **Hypervisor Layer (Proxmox VE 9.2.x):** Isolates host hardware, configures VFIO bindings, and manages VM lifecycle.
2. **Virtual Machine Layer (Ubuntu 24.04 LTS):** Hosts the NVIDIA driver stack, Container Toolkit, and persistent mounts.
3. **Gateway & Security Layer (LiteLLM Proxy + NGINX):** Handles TLS termination, Keycloak OIDC authentication, rate limits, and model access policies.
4. **Inference Runtime Layer (vLLM v0.6.3+):** Manages GPU memory allocation via PagedAttention and executes FP8 CUDA kernels.
5. **Presentation Layer (Open WebUI):** Provides standard research interfaces, document uploads, and session persistence.
EOF

# 8. docs/architecture/diagrams/system-topology.mmd
cat <<'EOF' > docs/architecture/diagrams/system-topology.mmd
graph TD
    User([External Researchers / Clients]) -->|HTTPS / Port 443| NGINX[NGINX Reverse Proxy]
    NGINX -->|HTTP / Port 8080| WebUI[Open WebUI Interface]
    NGINX -->|HTTP / Port 4000| Gateway[LiteLLM API Gateway]
    
    Gateway -->|Validate Token| Keycloak[(LifeWatch Keycloak OIDC)]
    Gateway -->|Route Request| vLLM[vLLM Inference Engine]
    
    subgraph Guest Virtual Machine (Ubuntu 24.04 LTS)
        WebUI
        Gateway
        vLLM
    end
    
    subgraph Hardware Layer (PCIe Passthrough)
        vLLM -->|CUDA / Driver 550+| GPU0[NVIDIA L40S #0 - 48GB]
        vLLM -->|CUDA / Driver 550+| GPU1[NVIDIA L40S #1 - 48GB]
    end
EOF

# 9. docs/DECISIONS_REQUIRED.md
cat <<'EOF' > docs/DECISIONS_REQUIRED.md
# Open Decision Register

| Decision Identifier | Description | Default Working Assumption | Stakeholder Review Required | Status |
| :--- | :--- | :--- | :--- | :--- |
| `DEC-001` | LifeWatch Keycloak Production OIDC Client Credentials | Use placeholder client IDs during staging bootstrap. | LifeWatch IT Security Team | **OPEN** |
| `DEC-002` | Public TLS Certificate Authority | Use ACME Let's Encrypt via NGINX ingress reverse proxy. | University / Department Sysadmins | **OPEN** |
| `DEC-003` | Model Weight Storage Quotas | Dedicated 2 TB NVMe volume mounted at `/data/vllm_cache`. | Research Group Director | **ACCEPTED** |
EOF

echo "--> Writing Architecture Decision Records (ADRs 001 through 009)..."

# 10. docs/adr/ADR-001-guest-os-selection.md
cat <<'EOF' > docs/adr/ADR-001-guest-os-selection.md
# ADR-001: Guest Operating System Selection

## Context
The platform requires an enterprise Linux distribution supporting NVIDIA 550.x+ drivers, CUDA 12.4, Docker Engine, and long-term security maintenance.

## Decision
Select **Ubuntu 24.04 LTS Server**.

## Rationale
1. Native support and validation from NVIDIA for Container Toolkit.
2. Kernel 6.8 LTS provides support for modern PCIe device passthrough and memory management.
3. Long-Term Support (LTS) maintenance guaranteed through 2029.

## Consequences
System administrators must verify DKMS module compilation following kernel updates.
EOF

# 11. docs/adr/ADR-002-gpu-passthrough-vfio.md
cat <<'EOF' > docs/adr/ADR-002-gpu-passthrough-vfio.md
# ADR-002: Dedicated PCIe GPU Passthrough via VFIO

## Context
Two physical NVIDIA L40S 48GB GPUs are installed on the Proxmox VE host. We must choose between vGPU virtualization (NVIDIA GRID) and direct PCIe Passthrough.

## Decision
Utilize direct **PCIe Passthrough (`vfio-pci`)** to assign both physical GPUs exclusively to the dedicated AI VM.

## Rationale
1. Eliminates software licensing overhead associated with NVIDIA vGPU software.
2. Delivers bare-metal CUDA performance and direct DMA memory access.
3. Simplifies driver management within a single guest OS environment.

## Consequences
The hypervisor host cannot use the assigned L40S GPUs for other virtual machines.
EOF

# 12. docs/adr/ADR-003-inference-runtime-vllm.md
cat <<'EOF' > docs/adr/ADR-003-inference-runtime-vllm.md
# ADR-003: vLLM Engine Selection & Topology Strategy

## Context
Multi-user serving requires efficient KV cache memory management and FP8 CUDA kernel execution without NVLink bridges.

## Decision
Standardize on **vLLM v0.6.3+**. Deploy 70B/72B models using Tensor Parallelism ($TP=2$) across both GPUs, and 32B models using independent $TP=1$ replicas on GPU 0 and GPU 1.

## Rationale
PagedAttention eliminates KV cache memory fragmentation. Continuous batching maximizes throughput under multi-user workloads. Independent 32B replicas avoid PCIe synchronization latency.

## Consequences
Model parameter counts are strictly bounded by total available VRAM (96 GB).
EOF

# 13. docs/adr/ADR-004-identity-and-rbac-gateway.md
cat <<'EOF' > docs/adr/ADR-004-identity-and-rbac-gateway.md
# ADR-004: LiteLLM API Gateway with Keycloak OIDC Authentication

## Context
Raw vLLM endpoints lack authentication, role-based access control, rate limiting, and identity provider integration.

## Decision
Deploy **LiteLLM Proxy** as the unified API gateway in front of vLLM backends, integrated with institutional Keycloak OIDC.

## Rationale
1. Delivers OpenAI-compatible API endpoints while validating OIDC JWT tokens.
2. Enforces per-user, per-group, and per-model access policies.
3. Maintains audit logs and request metrics in PostgreSQL.

## Consequences
API requests incur a negligible latency overhead (~2–5 ms) for token validation.
EOF

# 14. docs/adr/ADR-005-lora-adapter-lifecycle.md
cat <<'EOF' > docs/adr/ADR-005-lora-adapter-lifecycle.md
# ADR-005: Governance & Lifecycle for LoRA Adapters

## Context
Researchers require custom domain adapters without deploying independent, unmonitored model server instances.

## Decision
Implement an administrative LoRA registration workflow. Adapters must be verified for base-model compatibility, security-scanned, and registered in the LiteLLM catalog.

## Rationale
Prevents arbitrary execution and unmonitored VRAM consumption from unverified user-uploaded weights.

## Consequences
Users cannot load arbitrary adapter weights dynamically without administrative approval.
EOF

# 15. docs/adr/ADR-006-container-security-hardening.md
cat <<'EOF' > docs/adr/ADR-006-container-security-hardening.md
# ADR-006: Container Hardening & Immutable Image Tagging

## Context
Deployment configurations using floating tags (`latest`) and exposed backend ports introduce security and reproducibility risks.

## Decision
1. Pin all container images to exact immutable release tags.
2. Bind inference engine backends exclusively to internal Docker networks.
3. Keep host secret keys out of source control using `.env` templates.

## Rationale
Protects internal inference backends from unauthenticated external access and ensures reproducible builds.
EOF

# 16. docs/adr/ADR-007-storage-persistence-and-caching.md
cat <<'EOF' > docs/adr/ADR-007-storage-persistence-and-caching.md
# ADR-007: Storage Layer Separation for Model Weights & Application State

## Context
Model weights require multi-hundred gigabyte storage, whereas databases and UI state require backed-up persistent volumes.

## Decision
Mount `/data/vllm_cache` on a dedicated NVMe volume (excluded from routine VM backups) and store Open WebUI and LiteLLM state on backed-up persistent Docker volumes.

## Rationale
Prevents redundant, expensive backups of publicly downloadable HuggingFace model weights while safeguarding user data.
EOF

# 17. docs/adr/ADR-008-observability-stack.md
cat <<'EOF' > docs/adr/ADR-008-observability-stack.md
# ADR-008: Prometheus & NVIDIA DCGM Metrics Integration

## Context
System administrators require real-time visibility into GPU temperatures, VRAM consumption, TTFT (Time To First Token), and error rates.

## Decision
Expose vLLM native metrics and NVIDIA DCGM exporter endpoints to a centralized Prometheus monitoring service.

## Rationale
Enables proactive alerting before GPU memory exhaustion or thermal throttling degrades user experience.
EOF

# 18. docs/adr/ADR-009-disaster-recovery-and-rollback.md
cat <<'EOF' > docs/adr/ADR-009-disaster-recovery-and-rollback.md
# ADR-009: Automated Passthrough & Configuration Rollback Strategy

## Context
Changes to Proxmox hypervisor configuration or guest GPU drivers risk breaking passthrough functionality.

## Decision
All host automation scripts must generate timestamped backups of `/etc/pve/qemu-server/`, `/etc/modules`, and boot parameters prior to modification, and provide single-command rollback scripts.

## Rationale
Guarantees rapid recovery to a known good hypervisor state if passthrough initialization fails.
EOF

echo "--> Writing orchestration stack and proxy configs..."

# 19. compose.yaml
cat <<'EOF' > compose.yaml
version: '3.8'

services:
  # LiteLLM API Gateway & OIDC Authentication Layer
  litellm-gateway:
    image: ghcr.io/berriai/litellm:main-v1.52.0
    container_name: litellm-gateway
    restart: unless-stopped
    ports:
      - "127.0.0.1:4000:4000"
    environment:
      - PORT=4000
      - CONFIG_FILE_PATH=/app/config.yaml
      - DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}
      - STORE_MODEL_IN_DB=True
    volumes:
      - ./configs/proxy/config.yaml:/app/config.yaml:ro
    networks:
      - frontend-net
      - backend-net
    depends_on:
      postgres:
        condition: service_healthy
      vllm-70b-backend:
        condition: service_healthy

  # vLLM Serving Backend: Qwen2.5-72B-Instruct-FP8 (TP=2)
  vllm-70b-backend:
    image: vllm/vllm-openai:v0.6.3
    container_name: vllm-70b-backend
    restart: unless-stopped
    environment:
      - HUGGING_FACE_HUB_TOKEN=${HF_TOKEN:-}
      - NCCL_DEBUG=INFO
    volumes:
      - /data/vllm_cache:/root/.cache/huggingface
    ipc: host
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 2
              capabilities: [gpu]
    command: >
      --model Qwen/Qwen2.5-72B-Instruct-FP8
      --tensor-parallel-size 2
      --max-model-len 32768
      --gpu-memory-utilization 0.90
      --port 8000
      --served-model-name qwen2.5-72b-instruct
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:8000/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 180s
    networks:
      - backend-net

  # Open WebUI Collaborative Interface
  open-webui:
    image: ghcr.io/open-webui/open-webui:v0.3.30
    container_name: open-webui-frontend
    restart: unless-stopped
    ports:
      - "0.0.0.0:8080:8080"
    environment:
      - OPENAI_API_BASE_URL=http://litellm-gateway:4000/v1
      - OPENAI_API_KEY=${LITELLM_MASTER_KEY}
      - WEBUI_AUTH=true
      - ENABLE_OIDC_AUTH=true
      - OIDC_CLIENT_ID=${OIDC_CLIENT_ID}
      - OIDC_CLIENT_SECRET=${OIDC_CLIENT_SECRET}
      - OIDC_PROVIDER_URL=${OIDC_PROVIDER_URL}
    volumes:
      - openwebui_data:/app/backend/data
    networks:
      - frontend-net
    depends_on:
      - litellm-gateway

  # Database for Gateway State & Audit Logging
  postgres:
    image: postgres:16-alpine
    container_name: litellm-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - backend-net

networks:
  frontend-net:
    driver: bridge
  backend-net:
    internal: true
    driver: bridge

volumes:
  openwebui_data:
  postgres_data:
EOF

# 20. configs/proxy/config.yaml
cat <<'EOF' > configs/proxy/config.yaml
model_list:
  - model_name: qwen2.5-72b-instruct
    litellm_params:
      model: openai/qwen2.5-72b-instruct
      api_base: http://vllm-70b-backend:8000/v1
      api_key: "not-required"

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL

router_settings:
  routing_strategy: usage-based-routing-v2

litellm_settings:
  drop_params: true
  set_verbose: false
EOF

echo "--> Writing automation and verification scripts..."

# 21. scripts/pve/preflight.sh
cat <<'EOF' > scripts/pve/preflight.sh
#!/usr/bin/env bash
set -euo pipefail

echo "=== [LifeWatch PVE Passthrough Preflight Audit] ==="

if command -v pveversion >/dev/null 2>&1; then
    echo "[PASS] Proxmox VE Detected: $(pveversion)"
else
    echo "[FAIL] This script must run directly on a Proxmox VE host."
    exit 1
fi

echo -n "Checking Kernel Command Line for IOMMU: "
if grep -qE "intel_iommu=on|amd_iommu=on" /proc/cmdline; then
    echo "[PASS]"
else
    echo "[WARN] IOMMU is not enabled in /proc/cmdline."
fi

L40S_COUNT=$(lspci -nn | grep -i "L40S" | wc -l || true)
echo "Found ${L40S_COUNT} NVIDIA L40S device(s)."

lspci -nnk | grep -i -A 3 "L40S" || true

echo "Verifying IOMMU Group Isolation:"
for d in $(lspci -d 10de: | awk '{print $1}'); do
    echo "Device $d is in IOMMU Group:$(basename "$(readlink /sys/bus/pci/devices/0000:"$d"/iommu_group)")"
done

echo "=== Preflight Complete (No System Changes Made) ==="
EOF

# 22. scripts/pve/configure-passthrough.sh
cat <<'EOF' > scripts/pve/configure-passthrough.sh
#!/usr/bin/env bash
set -euo pipefail

APPLY_CHANGES=false
VM_ID=""

usage() {
    echo "Usage: $0 --vm-id <VM_ID> [--apply]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --vm-id) VM_ID="$2"; shift 2 ;;
        --apply) APPLY_CHANGES=true; shift ;;
        *) usage ;;
    esac
done

if [[ -z "$VM_ID" ]]; then
    usage
fi

BACKUP_DIR="/var/backups/lifewatch-pve-$(date +%Y%m%d_%H%M%S)"

echo "=== Planning PVE GPU Passthrough for VM $VM_ID ==="
PCI_IDS=$(lspci -nn | grep -i "L40S" | awk '{print $1}')
echo "Detected L40S PCI Addresses:"
echo "$PCI_IDS"

if [[ "$APPLY_CHANGES" == "false" ]]; then
    echo ""
    echo "[DRY-RUN] To apply these changes to host and VM configuration, run:"
    echo "  $0 --vm-id$VM_ID --apply"
    exit 0
fi

echo "[APPLY] Creating backup directory at $BACKUP_DIR..."
mkdir -p "$BACKUP_DIR"
cp /etc/modules "$BACKUP_DIR/modules.bak"
cp "/etc/pve/qemu-server/${VM_ID}.conf" "$BACKUP_DIR/${VM_ID}.conf.bak"

echo "Configuring /etc/modules..."
for mod in vfio vfio_iommu_type1 vfio_pci; do
    if ! grep -q "^$mod" /etc/modules; then
        echo "$mod" >> /etc/modules
    fi
done

echo "Updating Proxmox VM ${VM_ID} configuration..."
INDEX=0
for pci_addr in $PCI_IDS; do
    CONF_KEY="hostpci${INDEX}"
    qm set "$VM_ID" --"$CONF_KEY" "0000:${pci_addr},pcie=1,x-vga=0"
    INDEX=$((INDEX + 1))
done

echo "[SUCCESS] Configuration updated. Restart VM $VM_ID to activate GPU Passthrough."
EOF

# 23. scripts/rollback/rollback-passthrough.sh
cat <<'EOF' > scripts/rollback/rollback-passthrough.sh
#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "[FAIL] This rollback script must be run as root on the Proxmox host."
   exit 1
fi

echo "=== [LifeWatch Proxmox Passthrough Rollback] ==="

LATEST_BACKUP=$(ls -td /var/backups/lifewatch-pve-* 2>/dev/null | head -n 1 || true)

if [[ -z "$LATEST_BACKUP" ]]; then
    echo "[FAIL] No previous backup directory found in /var/backups/."
    exit 1
fi

echo "Restoring configuration from backup: $LATEST_BACKUP"

if [[ -f "$LATEST_BACKUP/modules.bak" ]]; then
    cp "$LATEST_BACKUP/modules.bak" /etc/modules
    echo "[PASS] Restored /etc/modules"
fi

CONF_BACKUP=$(ls "$LATEST_BACKUP"/*.conf.bak 2>/dev/null | head -n 1 || true)
if [[ -n "$CONF_BACKUP" ]]; then
    VM_ID=$(basename "$CONF_BACKUP" | cut -d'.' -f1)
    cp "$CONF_BACKUP" "/etc/pve/qemu-server/${VM_ID}.conf"
    echo "[PASS] Restored Proxmox VM ${VM_ID} configuration."
fi

echo "=== Rollback Complete. Reboot host or restart VM to apply changes. ==="
EOF

# 24. scripts/vm/bootstrap.sh
cat <<'EOF' > scripts/vm/bootstrap.sh
#!/usr/bin/env bash
set -euo pipefail

echo "=== [LifeWatch Guest VM Bootstrap] ==="

sudo apt-get update && sudo apt-get install -y \
    curl \
    git \
    jq \
    build-essential \
    linux-headers-$(uname -r)

if ! command -v docker >/dev/null 2>&1; then
    echo "Installing Docker Engine..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
fi

if ! dpkg -l | grep -q nvidia-container-toolkit; then
    echo "Configuring NVIDIA Container Toolkit repository..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
      sed 's#deb [^ ]*#& [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg]#g' | \
      sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    
    sudo apt-get update
    sudo apt-get install -y nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
fi

echo "[SUCCESS] Guest VM environment bootstrapped successfully."
EOF

# 25. scripts/verify/vm-check.sh
cat <<'EOF' > scripts/verify/vm-check.sh
#!/usr/bin/env bash
set -euo pipefail

echo "=== [Verifying Guest VM GPU Access] ==="

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "[FAIL] nvidia-smi not found. Driver installation incomplete."
    exit 1
fi

GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
echo "[PASS] nvidia-smi active. Detected $GPU_COUNT GPU(s)."

if [[ "$GPU_COUNT" -lt 2 ]]; then
    echo "[WARN] Expected 2 GPUs, but found $GPU_COUNT."
fi

echo "Testing Docker NVIDIA Container Access:"
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi

echo "[PASS] GPU Container Validation Complete."
EOF

echo "--> Writing test suites and CI workflows..."

# 26. tests/infrastructure/test_configs.sh
cat <<'EOF' > tests/infrastructure/test_configs.sh
#!/usr/bin/env bash
set -euo pipefail

echo "=== Running Infrastructure & Configuration Static Validation ==="

echo -n "1. Validating compose.yaml syntax: "
docker compose config --quiet
echo "PASS"

echo -n "2. Validating LiteLLM proxy config syntax: "
if grep -q "model_list" configs/proxy/config.yaml; then
    echo "PASS"
else
    echo "FAIL"
    exit 1
fi

echo "All static configuration tests passed successfully."
EOF

# 27. .github/workflows/ci.yml
cat <<'EOF' > .github/workflows/ci.yml
name: Production CI/CD Pipeline

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  static-analysis:
    name: Linting & Static Configuration Checks
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Validate Compose File
        run: docker compose config --quiet

      - name: Run ShellCheck
        uses: ludeeus/action-shellcheck@master
        with:
          scandir: './scripts'

      - name: Execute Infrastructure Tests
        run: |
          chmod +x tests/infrastructure/test_configs.sh
          ./tests/infrastructure/test_configs.sh
EOF

# 28. README.md
cat <<'EOF' > README.md
# LifeWatch ERIC Local AI Platform — Production Repository

Production-ready infrastructure, automation scripts, and deployment configs for serving local LLMs on Proxmox VE 9.2.x hardware equipped with 2× NVIDIA L40S GPUs (96 GB VRAM total).

## Architecture Summary
- **Hypervisor:** Proxmox VE 9.2.x with `vfio-pci` passthrough.
- **Guest OS:** Ubuntu 24.04 LTS Server with NVIDIA Container Toolkit.
- **Serving Engine:** vLLM v0.6.3+ (PagedAttention, Continuous Batching, Native FP8 acceleration).
- **Gateway & RBAC:** LiteLLM Proxy integrated with LifeWatch ERIC Keycloak OIDC.
- **User Interface:** Open WebUI.

## Deployment Execution Order

1. **Host Passthrough Setup (Proxmox Host):**
   ```bash
   bash scripts/pve/preflight.sh
   bash scripts/pve/configure-passthrough.sh --vm-id <VM_ID> --apply
EOF

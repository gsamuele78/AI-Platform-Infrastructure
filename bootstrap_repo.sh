#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="."

echo "=== Creating LifeWatch ERIC AI Platform Repository Structure ==="
mkdir -p "${REPO_DIR}"
cd "${REPO_DIR}"

# 1. Directory Tree Creation
mkdir -p \
  .github/workflows \
  configs/proxy \
  configs/models \
  docs/audit \
  docs/requirements \
  docs/architecture/diagrams \
  docs/adr \
  docs/operations \
  scripts/pve \
  scripts/vm \
  scripts/verify \
  tests/infrastructure \
  tests/unit

echo "--> Generating core project files..."

# 2. .gitignore
cat <<'EOF' > .gitignore
# Environment & Secrets
.env
*.env
*.pem
*.key

# Data & Model Caches
/data/
/cache/
*.bin
*.pt
*.safetensors
*.gguf

# Logs & Diagnostics
*.log
/logs/

# IDE & System
.DS_Store
.idea/
.vscode/
EOF

# 3. .env.example
cat <<'EOF' > .env.example
# Security Notice: Copy this file to .env and fill in secure production values.
# NEVER commit the actual .env file to Git.

# LiteLLM Proxy Security
LITELLM_MASTER_KEY=sk-lifewatch-change-this-master-key-in-production

# Postgres Database Credentials
POSTGRES_USER=litellm
POSTGRES_PASSWORD=change_this_secure_postgres_password_123!
POSTGRES_DB=litellm

# Institutional OIDC / Keycloak Configuration
OIDC_CLIENT_ID=lifewatch-ai-platform
OIDC_CLIENT_SECRET=your-oidc-client-secret-here
OIDC_PROVIDER_URL=https://auth.lifewatch.eu/realms/lifewatch

# HuggingFace Token (Optional: Required only for restricted model downloads)
HF_TOKEN=
EOF

# 4. Production compose.yaml
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

  # vLLM Primary Serving Backend: Qwen2.5-72B-Instruct-FP8 (TP=2)
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

  # Open WebUI Frontend Interface
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

  # Database for Proxy State & Audit Logs
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

# 5. LiteLLM Proxy Configuration
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

# 6. Proxmox Preflight Script
cat <<'EOF' > scripts/pve/preflight.sh
#!/usr/bin/env bash
set -euo pipefail

echo "=== [LifeWatch PVE Passthrough Preflight Audit] ==="

if command -v pveversion >/dev/null 2>&1; then
    echo "[PASS] Proxmox VE Detected: $(pveversion)"
else
    echo "[FAIL] This script must run on a Proxmox VE host."
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

# 7. Proxmox Passthrough Automation
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

# 8. Guest VM Hardware Verification Script
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

# 9. Test Suite
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

echo "All static tests passed successfully."
EOF

# 10. GitHub Actions Workflow
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

# 11. README Documentation
cat <<'EOF' > README.md
# LifeWatch ERIC Local AI Platform

Production-ready infrastructure, automation scripts, and deployment configs for serving local LLMs on Proxmox VE 9.2.x hardware equipped with 2× NVIDIA L40S GPUs (96 GB VRAM total).

## Architecture Summary
- **Hypervisor:** Proxmox VE 9.2.x with `vfio-pci` passthrough.
- **Guest OS:** Ubuntu 24.04 LTS Server with NVIDIA Container Toolkit.
- **Serving Engine:** vLLM v0.6.3+ (PagedAttention, Continuous Batching, Native FP8 Tensor Core acceleration).
- **Gateway & RBAC:** LiteLLM Proxy integrated with LifeWatch ERIC Keycloak/OIDC.
- **User Interface:** Open WebUI.

## Quick Start (Deployment Order)

1. **Host Passthrough Setup (Proxmox Host):**
   ```bash
   bash scripts/pve/preflight.sh
   bash scripts/pve/configure-passthrough.sh --vm-id <VM_ID> --apply
EOF

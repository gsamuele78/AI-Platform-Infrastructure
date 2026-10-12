# Proxmox VE 9.2: Passing One or Two NVIDIA L40S to the AI VM

| | |
| :-- | :-- |
| **Applies to** | Proxmox VE 9.2 (Debian 13.5, kernel 7.0, QEMU 11.0; released 2026-05-21). The steps also hold for 9.0 and 9.1. |
| **Result** | One Ubuntu 24.04 VM owns 1 or 2 L40S through `vfio-pci`. The guest detects the count and deploys the matching profile (`l40s-1` or `l40s-2`, [ADR-012](../adr/ADR-012-gpu-profiles-from-hardware-detection.md)) |
| **Scripts** | `scripts/pve/preflight.sh` (read-only), `scripts/pve/configure-passthrough.sh` (plan, then `--apply`), `scripts/rollback/rollback-passthrough.sh` (manifest-driven undo) |
| **Sources** | Proxmox VE admin guide, chapter "QEMU/KVM Virtual Machines", sections PCI(e) Passthrough and Resource Mapping; Proxmox VE Roadmap (9.0-9.2 release notes) |

Every command runs as `root` on the Proxmox host unless stated otherwise. The scripts change nothing without `--apply`, and every apply writes a backup and a manifest **before** touching anything.

## 0. What you need

| Item | Requirement | Why |
| :-- | :-- | :-- |
| Firmware | VT-d (Intel) or AMD-Vi/IOMMU **enabled**, "Above 4G decoding" **enabled**, "Resizable BAR" as the server vendor recommends for L40S | The L40S exposes a 64-bit BAR of tens of GB; without above-4G decoding the card cannot be mapped |
| Slots | Each L40S in its own IOMMU group (one slot per root port). Check in §2 | Passing a shared group would hand other devices to the VM. The ACS override patch is **not** acceptable in production |
| Host driver | No NVIDIA driver in use on the host for these cards | The host must not own a passthrough card |
| VM | `machine: q35`, `bios: ovmf` (with an EFI disk), `cpu: host`, `balloon: 0`, ≥ 64 GiB RAM (128 GiB for two GPUs), ≥ 200 GB disk plus a separate disk for model weights (≥ 200 GB) | PCIe passthrough needs q35; OVMF maps large 64-bit BARs; passthrough pins all guest RAM |
| Repository | A checkout of this repository on the host (`git clone`, read-only use) | The scripts run from it |

## 1. Enable the IOMMU (once per host)

- **AMD:** the IOMMU is on by default.
- **Intel, kernel ≥ 6.8** (every PVE 9.x kernel): on by default. Older kernels needed `intel_iommu=on`; PVE 9.2 does not.
- **Optional, performance:** `iommu=pt` on the kernel command line (passthrough mode for host devices). Add it only if you want it:
  - GRUB: append to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then `update-grub`.
  - systemd-boot (ZFS root installs): append to `/etc/kernel/cmdline`, then `proxmox-boot-tool refresh`.

  The scripts never edit the kernel command line, because how to do it depends on the bootloader.

Reboot if you changed anything, then:

```bash
ls /sys/kernel/iommu_groups | wc -l      # > 0 means the IOMMU is active
dmesg | grep -iE 'DMAR|AMD-Vi|IOMMU' | head
```

## 2. Inspect the host (read-only)

```bash
cd /root/AI-Platform-Infrastructure
bash scripts/pve/preflight.sh
```

Expected output:

```text
[PASS] Proxmox VE: pve-manager/9.2.x/...
[PASS] IOMMU active (NN groups)
[PASS] Found 2 GPU(s) with ID 10de:26b9: 0000:41:00.0 0000:c1:00.0
[PASS] Selected for the VM: 0000:41:00.0 0000:c1:00.0 (profile l40s-2)
[PASS] 0000:41:00.0: IOMMU group 30 is isolated
[PASS] 0000:c1:00.0: IOMMU group 70 is isolated
```

To pass **only one** card, name it with `--gpu`. The short forms `41:00`, `41:00.0` and `0000:41:00.0` are all accepted:

```bash
bash scripts/pve/preflight.sh --gpu 0000:41:00.0      # -> profile l40s-1
```

The isolation check covers only the selected cards. A card you keep for another VM, or one that will move to another server ([ADR-015](../adr/ADR-015-second-gpu-allocation-by-benchmark.md)), may sit in a shared group without blocking this VM.

What the checks mean:

| Message | Meaning | Action |
| :-- | :-- | :-- |
| `IOMMU not active` | firmware or kernel IOMMU off | §1 |
| `No GPU with ID 10de:26b9` | no L40S visible (different card, or a PCI ID override) | `lspci -nn \| grep -i nvidia`; set `LW_GPU_PCI_ID` only for a different, deliberately supported card |
| `IOMMU group N also contains …` | the slot shares its group | move the card to another slot, or check ACS in firmware |
| `host driver 'nvidia' is bound` (WARN) | the host loaded a driver for the card | fixed by step 4 (vfio binding) after the reboot |
| `N GPU(s) selected; the VM takes 1 or 2` | more than two L40S on the host | choose the cards with `--gpu` |
| `/etc/modules-load.d/modules.conf is missing` (WARN) | Debian would not read `/etc/modules` | vfio still loads through the softdep rules. To be explicit: `ln -s ../modules /etc/modules-load.d/modules.conf` |

## 3. Create the VM (once)

Use the GUI or the CLI. The values below match the checks in `configure-passthrough.sh`:

```bash
VMID=100
qm create $VMID --name lifewatch-ai --ostype l26 \
  --machine q35 --bios ovmf --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0 \
  --cpu host --sockets 1 --cores 32 --numa 1 \
  --memory 131072 --balloon 0 \
  --scsihw virtio-scsi-single \
  --scsi0 local-lvm:200,iothread=1,discard=on \
  --scsi1 local-lvm:300,iothread=1,discard=on \
  --net0 virtio,bridge=vmbr0 \
  --agent enabled=1 \
  --serial0 socket --vga std
# then attach the Ubuntu 24.04 ISO (or a cloud-init image) and install
```

Notes:
- `pre-enrolled-keys=0` disables Secure Boot. With Secure Boot on, the NVIDIA kernel modules must be signed: Ubuntu's precompiled `*-server` modules are signed by Canonical, but turning it off removes a common failure mode. Keep it on only if your policy requires it, and then check `mokutil --sb-state` in the guest.
- `scsi1` is the model-weight disk (`/data/vllm_cache`, [ADR-007](../adr/ADR-007-storage-persistence-and-caching.md)). Exclude it from `vzdump` backups (in the GUI, uncheck "Backup" on the disk; on the CLI, add `backup=0`), because the weights can be downloaded again at their pinned revision.
- Two GPUs: 128 GiB RAM and 32 cores. One GPU: 64-96 GiB is enough.
- If the guest logs `BAR … no space` or `failed to assign` for the GPU, add the physical address bits explicitly: `qm set $VMID --cpu host,phys-bits=host`. PVE 9.x also offers `guest-phys-bits` for some Intel CPUs (Roadmap, issue 6378).

## 4. Configure passthrough

**Plan first** (changes nothing):

```bash
bash scripts/pve/configure-passthrough.sh --vm-id 100                     # every L40S (max 2)
bash scripts/pve/configure-passthrough.sh --vm-id 100 --gpu 0000:41:00.0  # one card
```

The plan lists exactly what apply will do:
- `qm set 100 hostpciN: 0000:41:00,pcie=1` for each selected card, in free `hostpci` slots only. Existing entries are never overwritten, and a card already passed to **another** VM is refused;
- append `vfio vfio_iommu_type1 vfio_pci` to `/etc/modules` if missing;
- write `/etc/modprobe.d/lifewatch-vfio.conf`: `options vfio-pci ids=10de:26b9` plus `softdep` rules so that `vfio-pci` claims the cards before `nouveau`/`nvidia`;
- `update-initramfs -u -k all`.

**Apply** with the VM stopped:

```bash
qm shutdown 100
bash scripts/pve/configure-passthrough.sh --vm-id 100 --apply            # add --gpu … for one card
reboot                                                                   # the HOST, to bind vfio-pci
```

After the reboot:

```bash
bash scripts/pve/preflight.sh                       # each card now: "bound to vfio-pci"
lspci -nnk -d 10de:26b9 | grep 'Kernel driver'      # Kernel driver in use: vfio-pci
qm config 100 | grep hostpci
qm start 100
```

Running the apply again is a no-op ("already configured; nothing to do"): no new backup, no `qm` calls.

### One card here, the other elsewhere

- **Another VM on the same host** (for example TensorFlow): `configure-passthrough.sh --vm-id 101 --gpu 0000:c1:00.0 --apply`. Both cards stay bound to `vfio-pci` on the host, so the host never uses either.
- **Another physical server:** shut the host down, move the card, start it, run `preflight.sh` (it now finds one L40S) and redeploy the guest. The guest detects one GPU and switches to `l40s-1`. The `hostpci` entry of the removed card has to go: roll back the original apply (§6) and apply again with the remaining card.

## 5. Inside the VM

```bash
sudo bash scripts/vm/bootstrap.sh       # NVIDIA 580-server driver, Docker, NVIDIA Container Toolkit (held)
sudo reboot
sudo bash scripts/verify/vm-check.sh    # every L40S on the PCI bus: visible, >= 45000 MiB, usable from containers
```

`vm-check.sh` counts the cards on the guest's PCI bus (`lspci -d 10de:26b9`), so a card that is passed through but not working is a failure, not a silent drop to one GPU. The profile is chosen the same way at deploy time:

```bash
source scripts/lib/common.sh; source scripts/lib/profile.sh; detect_profile    # l40s-1 or l40s-2
```

Then continue with [RUNBOOK §3](RUNBOOK.md#3-first-deployment).

With two GPUs, leave `NCCL_P2P_DISABLE=1` unless `nvidia-smi topo -p2p r` reports `OK` between GPU0 and GPU1. Peer-to-peer through a virtual root complex usually does not work, and NCCL can hang trying ([RUNBOOK §2](RUNBOOK.md#2-guest-vm-bootstrap)).

## 6. Roll back

```bash
bash scripts/rollback/rollback-passthrough.sh --list
bash scripts/rollback/rollback-passthrough.sh --backup-dir /var/backups/lifewatch-pve/<id>           # plan
qm shutdown 100
bash scripts/rollback/rollback-passthrough.sh --backup-dir /var/backups/lifewatch-pve/<id> --apply
reboot
```

Rollback removes only the `hostpci` keys that apply added, and restores host files only if they still match what apply wrote. If anything drifted (someone edited the VM or the files since), it stops before changing anything and names the file. Compare it with `<dir>/*.orig` and resolve by hand.

## 7. Troubleshooting

| Symptom | Likely cause | Check / fix |
| :-- | :-- | :-- |
| VM start: `Cannot reset device …`, or the VM hangs at start | card not bound to vfio-pci (host not rebooted after apply) | `lspci -nnk -d 10de:26b9`; reboot the host |
| VM start: `IOMMU group is not viable` | shared IOMMU group | §2; different slot |
| Guest `lspci` shows the card, `nvidia-smi`: "No devices were found" | driver not loaded, Secure Boot blocks unsigned modules, or BAR not mapped | `dmesg \| grep -iE 'nvidia\|NVRM\|BAR'`; `mokutil --sb-state`; `phys-bits=host` (§3) |
| Guest `dmesg`: `BAR 1: no space for [mem size 0x…]` | 64-bit MMIO window too small | `qm set <vmid> --cpu host,phys-bits=host`; firmware "Above 4G decoding" on |
| `vm-check.sh`: GPU with less than 45000 MiB | wrong card, or a vGPU/MIG slice | the L40S has no MIG; check the PCI ID and the VM config |
| vLLM hangs at "Initializing NCCL" (two GPUs) | P2P inside the VM | keep `NCCL_P2P_DISABLE=1` (default) |
| After a PVE upgrade the VM no longer starts with the cards | kernel/QEMU change, or a vfio module missing from the initramfs | `lsmod \| grep vfio`; `update-initramfs -u -k all`; reboot; `preflight.sh` |

## 8. Optional: cluster resource mapping

PVE 9.x can map a card to a named, cluster-wide resource. The VM then references `mapping=<name>` instead of a PCI address. Proxmox checks the device's ID and IOMMU group at VM start (a moved or replaced card is refused), and a non-root operator can be given `Mapping.Use` on `/mapping/pci/<name>` without host rights. Example from the admin guide:

```bash
pvesh create /cluster/mapping/pci --id lw-l40s-0 --map node=<node>,path=0000:41:00.0,id=10de:26b9
qm set 100 --hostpci0 mapping=lw-l40s-0,pcie=1
```

`configure-passthrough.sh` does not create mappings yet: the format of the `map` entry (IOMMU group, subsystem ID) has to be confirmed on the real host first. Until then, use either the script (raw address, with manifest rollback) **or** a mapping created in the GUI (Datacenter → Resource Mappings), never both for the same card.

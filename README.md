# Linux Kernel Livepatch Automation & Management Toolkit

Automated build pipeline, preflight verification, and runtime management toolkit for Linux Kernel Livepatching (`kpatch`), targeting Ubuntu 5.15 LTS kernels.

## 📁 Repository Structure

| File | Description |
|---|---|
| [`build_all.sh`](./build_all.sh) | Automated batch builder for all 5.15.0-NN.MMM kernels. Enforces resource limits (40GB), inlining suppression flags, cleanups, and sequential compiling. |
| [`check_req.sh`](./check_req.sh) | Preflight verification tool. Checks environment, tools, configs, vmlinux, certs, and patch compatibility matrix. |
| [`livepatch.sh`](./livepatch.sh) | Production host loader/unloader. Automatically resolves KVM vCPU transition stalls via OpenStack Libvirt container. |
| [`KVM_LIVEPATCH_CPU_RING_MECHANISM.md`](./KVM_LIVEPATCH_CPU_RING_MECHANISM.md) | Architectural documentation on KVM vCPU CPU Rings, Safe Points, and transition stall resolution. |
| `*.diff` / `*.patch` | Multi-CVE security hotfix patches for KVM MMU and networking stack. |

## 🚀 Quick Start

### 1. Preflight Check
```bash
./check_req.sh
```

### 2. Batch Build Modules
```bash
# Build all 33 versions sequentially:
./build_all.sh

# Or build a specific target version:
./build_all.sh 5.15.0-91.101
```

### 3. Deploy Livepatch on Host
```bash
# Load module:
./livepatch.sh load aio-fci-cve-def-5-15-0-185-195.ko

# Unload module:
./livepatch.sh unload
```

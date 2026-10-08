# Portable GLM 5.3

Copy the self-contained `glm53-install.sh` to a new GPU instance and run:

```bash
sudo bash glm53-install.sh --data-dir /mnt/nvme/glm-5.3
```

The installer writes its deployment into `/opt/glm53`, pulls the pinned vLLM
image, downloads the official FP8 weights, builds the HTTP proxy, starts both
containers, and waits for a healthy API. Containers restart after reboot.
Existing cached weights are reused. The first run downloads about 750 GB and
can take several minutes for loading, compilation, and autotuning afterward.

Prerequisites: GPU-ready Linux x86_64 with Docker Engine, Compose v2.30+,
NVIDIA Container Toolkit configured for Docker, r580+ NVIDIA driver, exactly
eight GPUs with at least 170000 MiB VRAM each (B200/B300 class), and about
850 GiB of storage. The installer validates these and never changes GPU
drivers or restarts Docker on an existing production host.
Use the cloud provider's NVIDIA/Docker GPU image for a new instance.

The vLLM arguments are exactly the user's recipe; batch sizes, GPU memory,
context size, prefix caching, and decoding use vLLM defaults. Rust frontend
is enabled. MTP is not explicitly enabled. The Docker image digest is pinned;
model weights follow `zai-org/GLM-5.3` main, matching the serving command.

The API binds on `0.0.0.0:8000` and uses model name `zai-org/GLM-5.3`.
The proxy maps reasoning effort, rejects unsupported reasoning-disable
requests, removes tool definitions for tool choice `none`, and passes streamed
usage through unchanged. Provider adapters must consume the final SSE usage
event, even when its choices list is empty.

Alternate storage, port, or bind address:

```bash
sudo bash glm53-install.sh --data-dir /scratch/glm-5.3 --port 8001
sudo bash glm53-install.sh --check
bash glm53-install.sh --render-only /tmp/glm53-preview
```

Manage after installation:

```bash
cd /opt/glm53
sudo docker compose ps
sudo docker compose logs -f vllm
sudo docker compose down  # stops this deployment; caches remain
sudo docker compose up -d
curl http://localhost:8000/v1/models
curl http://localhost:8000/metrics
```

The installer does not change cloud firewall or NAT mappings. Allow TCP 8000
in your provider's networking settings, or choose an SSH tunnel. Docker's
published ports bypass typical UFW INPUT rules, so enforce public access rules
at the cloud firewall or Docker forwarding chain. This mirrors the existing
API's unauthenticated access; it does not add an API key or TLS.

The installer is intended for new hosts. It refuses deployment if GPUs or the
selected port are already occupied by another service. Re-running the same
deployment reuses the Compose project and cache, and does not stop unrelated
containers. Running it on the current production VM is unnecessary.

Prerequisite references:
- https://docs.docker.com/engine/install/ubuntu/
- https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
- https://recipes.vllm.ai/zai-org/GLM-5.3

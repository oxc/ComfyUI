<div align="center">

# ComfyUI Docker Images

**Automatically built, always up-to-date Docker images of [ComfyUI](https://github.com/Comfy-Org/ComfyUI).**

</div>

This repository is a lightweight fork of [ComfyUI](https://github.com/Comfy-Org/ComfyUI)
whose only purpose is to build and publish Docker images. It tracks the upstream
`master` branch (rebased several times a day) and adds nothing but a `Dockerfile`
and the CI needed to publish images for the common GPU backends.

> **Not affiliated with the ComfyUI project.** For everything about ComfyUI
> itself — features, models, workflows, docs and support — please head to the
> [upstream repository](https://github.com/Comfy-Org/ComfyUI) and
> [comfy.org](https://www.comfy.org/). Upstream has decided not to maintain an
> official Dockerfile for now, which is why these images live here instead.

## What is ComfyUI?

ComfyUI is a powerful and modular node-graph engine for generative AI. It lets you
build image, video, audio and 3D generation pipelines by wiring together nodes,
with native support for the latest open-source models (SD/SDXL/SD3, Flux, Qwen
Image, Wan, Hunyuan, and many more). See the
[upstream README](https://github.com/Comfy-Org/ComfyUI#readme) for the full
picture.

## Images

Images are published to the GitHub Container Registry:

**[`ghcr.io/oxc/comfyui`](https://github.com/oxc/ComfyUI/pkgs/container/comfyui)**

A separate image variant is built for each supported PyTorch backend. Pick the one
that matches your hardware:

| Variant tag suffix | Backend | Use for |
|--------------------|---------|---------|
| `-cu130` | CUDA 13.0 | NVIDIA GPUs (latest) |
| `-cu128` | CUDA 12.8 | NVIDIA GPUs |
| `-cu126` | CUDA 12.6 | NVIDIA GPUs (older drivers) |
| `-rocm7.2` | ROCm 7.2 | AMD GPUs |
| `-cpu` | CPU only | No GPU (slow) |

### Tags

Every variant is published under several tags:

- `latest-<variant>` — the newest published release, e.g. `latest-cu130`
- `<version>-<variant>` / `<major>.<minor>-<variant>` — a specific ComfyUI release
- `master-<variant>` — the tip of upstream `master` (bleeding edge)
- `sha-<commit>-<variant>` — a specific commit

```shell
# NVIDIA
docker pull ghcr.io/oxc/comfyui:latest-cu130
# AMD
docker pull ghcr.io/oxc/comfyui:latest-rocm7.2
# CPU only
docker pull ghcr.io/oxc/comfyui:latest-cpu
```

## Running

ComfyUI listens on port `8188`. Mount volumes for your models and I/O so they
survive container restarts.

### NVIDIA

Requires the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html).

```shell
docker run --rm -it \
  --gpus all \
  -p 8188:8188 \
  -v "$PWD/models:/app/models" \
  -v "$PWD/input:/app/input" \
  -v "$PWD/output:/app/output" \
  -v "$PWD/user:/app/user" \
  ghcr.io/oxc/comfyui:latest-cu130
```

### AMD (ROCm)

```shell
docker run --rm -it \
  --device /dev/kfd --device /dev/dri \
  --group-add video \
  --security-opt seccomp=unconfined \
  -p 8188:8188 \
  -v "$PWD/models:/app/models" \
  -v "$PWD/input:/app/input" \
  -v "$PWD/output:/app/output" \
  -v "$PWD/user:/app/user" \
  ghcr.io/oxc/comfyui:latest-rocm7.2
```

### CPU only

```shell
docker run --rm -it \
  -p 8188:8188 \
  -v "$PWD/models:/app/models" \
  -v "$PWD/input:/app/input" \
  -v "$PWD/output:/app/output" \
  -v "$PWD/user:/app/user" \
  ghcr.io/oxc/comfyui:latest-cpu
```

Then open <http://localhost:8188>.

### docker compose

```yaml
services:
  comfyui:
    image: ghcr.io/oxc/comfyui:latest-cu130
    ports:
      - "8188:8188"
    volumes:
      - ./models:/app/models
      - ./input:/app/input
      - ./output:/app/output
      - ./user:/app/user
      # persist packages installed by custom nodes (see below)
      - ./custom_nodes:/app/custom_nodes
      - custom_venv:/app/custom_venv
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

volumes:
  custom_venv:
```

## Configuration

The container is configured through environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `COMFYUI_ADDRESS` | `0.0.0.0` | Address ComfyUI binds to |
| `COMFYUI_PORT` | `8188` | Port ComfyUI listens on |
| `COMFYUI_EXTRA_ARGS` | *(empty)* | Extra arguments appended to `main.py`, e.g. `--preview-method taesd` |

For example, to enable high-quality previews:

```shell
docker run ... -e COMFYUI_EXTRA_ARGS="--preview-method taesd" ghcr.io/oxc/comfyui:latest-cu130
```

## Custom nodes

Custom nodes often install their own Python dependencies. To keep those installs
across container restarts, mount a volume at **`/app/custom_venv`**. On startup the
container copies the baked-in virtual environment into that volume (if empty) and
uses it from then on, so any packages installed by
[ComfyUI-Manager](https://github.com/Comfy-Org/ComfyUI-Manager) or by hand persist.
Mount `/app/custom_nodes` alongside it to keep the nodes themselves.

## Building yourself

The images are built from the [`Dockerfile`](Dockerfile) in this repo. Pass a
`PYTORCH_INSTALL_ARGS` build arg to select the backend:

```shell
# NVIDIA
docker build --build-arg PYTORCH_INSTALL_ARGS="--index-url https://download.pytorch.org/whl/cu130" -t comfyui .

# AMD
docker build --build-arg PYTORCH_INSTALL_ARGS="--index-url https://download.pytorch.org/whl/rocm7.2" -t comfyui .

# CPU only (also bake in the --cpu flag)
docker build \
  --build-arg PYTORCH_INSTALL_ARGS="--index-url https://download.pytorch.org/whl/cpu" \
  --build-arg EXTRA_ARGS=--cpu \
  -t comfyui .
```

BuildKit is required (it is the default on modern Docker; otherwise set
`DOCKER_BUILDKIT=1`).

## How the images stay current

A scheduled [GitHub Action](.github/workflows/sync.yml) rebases this fork onto
upstream `master` several times a day. Each successful sync — and every upstream
release — triggers the [image build workflow](.github/workflows/docker.yml), so the
published tags follow upstream closely without any manual work.

## License

ComfyUI is licensed under the [GPL-3.0 License](LICENSE); this fork inherits it.
All credit for ComfyUI goes to the
[ComfyUI authors and contributors](https://github.com/Comfy-Org/ComfyUI/graphs/contributors).

# syntax=docker/dockerfile:1

ARG PYTHON_VERSION=3.13

FROM python:${PYTHON_VERSION}-slim

ARG PYTORCH_INSTALL_ARGS=""
# Override the torch package set to pin versions (e.g. to keep a build that still
# ships Pascal sm_60 kernels for pre-Turing GPUs). Empty = use the default below.
ARG TORCH_PACKAGES=""
ARG EXTRA_ARGS=""
ARG USERNAME=comfyui
ARG USER_UID=1000
ARG USER_GID=${USER_UID}

# Fail fast on errors or unset variables
SHELL ["/bin/bash", "-eux", "-o", "pipefail", "-c"]

RUN <<EOF
	groupadd --gid ${USER_GID} ${USERNAME}
	useradd --uid ${USER_UID} --gid ${USER_GID} -m ${USERNAME}
EOF

RUN <<EOF
	apt-get update
	apt-get install -y --no-install-recommends \
		git \
		git-lfs \
		rsync \
		fonts-recommended
	# keep the image small: the package lists are not needed at runtime
	rm -rf /var/lib/apt/lists/*
EOF

ENV XDG_CACHE_HOME=/cache
ENV PIP_CACHE_DIR=/cache/pip

# create the cache directory while we are still root and hand it to the build
# user. During build a cache mount masks it (below), but it must exist and be
# writable in the final image so that pip installs from custom nodes at runtime
# can cache into it. The non-root user cannot create it under / itself.
RUN mkdir -p ${PIP_CACHE_DIR} && chown -R ${USER_UID}:${USER_GID} ${XDG_CACHE_HOME}

# run instructions as user
USER ${USER_UID}:${USER_GID}

WORKDIR /app

ENV VIRTUAL_ENV=/app/venv
ENV VIRTUAL_ENV_CUSTOM=/app/custom_venv

# create virtual environment to manage packages
RUN python -m venv ${VIRTUAL_ENV}

# run python from venv (prefer custom_venv over baked-in one)
ENV PATH="${VIRTUAL_ENV_CUSTOM}/bin:${VIRTUAL_ENV}/bin:${PATH}"

RUN --mount=type=cache,target=/cache/,uid=${USER_UID},gid=${USER_GID} <<EOF
	pip install ${TORCH_PACKAGES:-torch torchvision torchaudio} ${PYTORCH_INSTALL_ARGS}
	# requirements.txt lists torch/torchvision/torchaudio unpinned and without an
	# index-url, so a later `pip install -r` can pull a newer torch from PyPI while
	# leaving an already-satisfied torchaudio behind -> ABI mismatch (undefined
	# symbol: torch_library_impl). Freeze exactly what we just installed and feed it
	# back as constraints so the torch stack cannot be upgraded or clobbered.
	pip freeze | grep -iE '^(torch|torchvision|torchaudio)==' > ${VIRTUAL_ENV}/torch-constraints.txt
EOF

# copy requirements files first so packages can be cached separately
COPY --chown=${USER_UID}:${USER_GID} requirements.txt .
RUN --mount=type=cache,target=/cache/,uid=${USER_UID},gid=${USER_GID} \
	pip install -c ${VIRTUAL_ENV}/torch-constraints.txt -r requirements.txt

# Not strictly required for comfyui, but prevents non-working variants of
# cv2 being pulled in by custom nodes
RUN --mount=type=cache,target=/cache/,uid=${USER_UID},gid=${USER_GID} \
	pip install opencv-python-headless

COPY --chown=${USER_UID}:${USER_GID} . .

COPY --chown=nobody:${USER_GID} .git .git

# default environment variables
ENV COMFYUI_ADDRESS=0.0.0.0
ENV COMFYUI_PORT=8188
ENV COMFYUI_EXTRA_BUILD_ARGS="${EXTRA_ARGS}"
ENV COMFYUI_EXTRA_ARGS=""

# document the port ComfyUI listens on (informational only; expands the ENV
# above at build time)
EXPOSE ${COMFYUI_PORT}

# The startup logic lives in this heredoc rather than a checked-in script file
# because release builds overlay *only* Dockerfile + .dockerignore onto the
# upstream release tag (see .github/workflows/docker-build.yml); a separate file
# would be dropped and every versioned image would fail to start.
COPY --chmod=0755 --chown=${USER_UID}:${USER_GID} <<'ENTRYPOINT' /app/docker-entrypoint.sh
#!/bin/sh
set -eu

# custom_venv is a persistent volume layering runtime pip installs (custom node
# dependencies) on top of the venv baked into the image. Syncing it with a plain
# `rsync -a` only ever adds and updates, so a package upgraded in the image left
# its old files behind: three generations of comfy_kitchen-*.dist-info piled up,
# importlib.metadata resolved the first (lowest) one and reported a stale
# version, and superseded modules stayed importable alongside the new ones.
#
# `--delete` is not an option - it would wipe the user-installed packages this
# volume exists to preserve. Instead, record what each sync installed so the next
# boot can remove exactly the image-owned leftovers. Anything absent from the
# manifest was installed at runtime and is left alone.
if [ -d "${VIRTUAL_ENV_CUSTOM}" ]; then
	manifest="${VIRTUAL_ENV_CUSTOM}/.image-manifest"
	current="$(mktemp)"
	(cd "${VIRTUAL_ENV}" && find . \( -type f -o -type l \) | LC_ALL=C sort) > "${current}"

	if [ -f "${manifest}" ]; then
		LC_ALL=C comm -23 "${manifest}" "${current}" | while IFS= read -r stale; do
			rm -f "${VIRTUAL_ENV_CUSTOM}/${stale}"
		done
		# prune directories the removals emptied; -mindepth 1 keeps this from
		# trying to unlink the volume mount point itself
		find "${VIRTUAL_ENV_CUSTOM}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
	fi

	rsync -a "${VIRTUAL_ENV}/" "${VIRTUAL_ENV_CUSTOM}/"
	cat "${current}" > "${manifest}"
	rm -f "${current}"

	sed -i "s!${VIRTUAL_ENV}!${VIRTUAL_ENV_CUSTOM}!g" "${VIRTUAL_ENV_CUSTOM}/pyvenv.cfg"
fi

# unquoted on purpose: both hold multiple whitespace-separated CLI flags
exec python -u main.py \
	--listen "${COMFYUI_ADDRESS}" \
	--port "${COMFYUI_PORT}" \
	${COMFYUI_EXTRA_BUILD_ARGS:-} ${COMFYUI_EXTRA_ARGS:-}
ENTRYPOINT

# default start command
CMD ["/app/docker-entrypoint.sh"]

FROM debian:bookworm

RUN apt-get update && apt-get install -y \
    sudo time git-core subversion build-essential g++ bash make \
    libssl-dev patch libncurses5 libncurses5-dev zlib1g-dev gawk \
    flex gettext wget unzip xz-utils \
    python3 python3-pip python3-setuptools \
    swig rsync curl ccache quilt \
    libsnmp-dev liblzma-dev libpam0g-dev cpio gcc-multilib qemu-utils file && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir --break-system-packages pyelftools

# Create user — UID/GID matched to host at runtime, NOT baked in here.
# The compose file passes user: "${UID}:${GID}" at runtime.
RUN useradd -m user && echo 'user ALL=NOPASSWD: ALL' > /etc/sudoers.d/user

RUN git config --system user.name "user" && \
    git config --system user.email "user@example.com"

# Create volume mount points; make world-writable so any runtime UID can use them
RUN mkdir -p /builder/ccache /builder/dl /builder/artifacts /builder/uci-defaults-extra /builder/repo && \
    chmod 1777 /builder/ccache /builder/dl /builder/artifacts /builder/uci-defaults-extra

# Embed defaults and scripts
COPY scripts/ /app/scripts/
COPY shared/ /app/shared/

# Symlink builder to /usr/local/bin for global access
RUN ln -s /app/scripts/builder /usr/local/bin/builder

# ccache max size is configured at runtime via CCACHE_MAX_SIZE env var (see 07-compile.sh)

USER user
WORKDIR /builder

# Container sleeps; user execs in — it's a workbench, not a pipeline
CMD ["sleep", "infinity"]

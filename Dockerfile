# =====================================================================
# CloudLens Ansible for Azure: Deployment Image
# =====================================================================
# Zero-install deployment for any team. Works from any machine with Docker.
#
# Build:
#   docker build -t cloudlens-ansible-azure .
#
# Run (interactive), from the folder that holds customer_input.yaml:
#   docker run --rm -it --platform linux/amd64 \
#     -v "$(pwd)/customer_input.yaml:/work/customer_input.yaml:ro" \
#     -v "$(pwd)/files:/work/files:ro" \
#     -v "$HOME/.ssh/id_rsa:/root/.ssh/id_rsa:ro" \
#     -e AZURE_SUBSCRIPTION_ID -e AZURE_TENANT -e AZURE_CLIENT_ID -e AZURE_SECRET \
#     -e ANSIBLE_WINRM_PASSWORD \
#     ghcr.io/keysight-tech/cloudlens-ansible-azure:latest
#
# CI/CD: the same command without -it (a CI runner has no TTY), with the image
# pinned to a commit tag (:main-<sha>). Never mount the whole working directory
# over /work: that hides the image's own playbooks and entrypoint.
# =====================================================================

FROM python:3.12-slim AS base

LABEL maintainer="Keysight Technologies"
LABEL description="Automated CloudLens sensor deployment for Azure VMs (Linux + Windows)"

# ANSIBLE_COLLECTIONS_PATH: a world-readable location, so the image also
#   works when a CI runner starts it as a non-root user.
# ANSIBLE_HOME / ANSIBLE_CACHE_PLUGIN_CONNECTION: Ansible's scratch and fact
#   cache under /tmp, writable by any user, instead of ~/.ansible and /work.
# ANSIBLE_INVENTORY_UNPARSED_FAILED: an inventory that cannot be read (bad
#   credentials, no access) is an error. By default Ansible only warns, runs
#   every play against no hosts and exits 0.
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    ANSIBLE_HOST_KEY_CHECKING=False \
    ANSIBLE_RETRY_FILES_ENABLED=False \
    ANSIBLE_FORCE_COLOR=True \
    ANSIBLE_COLLECTIONS_PATH=/usr/share/ansible/collections \
    ANSIBLE_HOME=/tmp/.ansible \
    ANSIBLE_CACHE_PLUGIN_CONNECTION=/tmp/.ansible_facts_cache \
    ANSIBLE_INVENTORY_UNPARSED_FAILED=True

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    curl \
    ca-certificates \
    sshpass \
    sudo \
    gnupg lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Azure CLI (official install)
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# Python deps: Ansible, Azure SDKs, WinRM (Basic + NTLM transports).
# Note: requests-kerberos is intentionally excluded. It needs C build deps
# (libkrb5-dev, gcc) not present in python:3.12-slim, and our playbooks
# use Basic / NTLM transport for WinRM. Add it back here and install
# libkrb5-dev + gcc above if a customer ever needs Kerberos transport.
#
# ansible-core stays on 2.16: it is the last release that can manage Python
# 3.6 targets, which is what RHEL 7 and RHEL 8 ship, and the docs support
# RHEL 7/8/9. 2.17 dropped Python 3.6, so every RHEL 8 VM would fail.
RUN pip install --no-cache-dir \
    "ansible-core>=2.16,<2.17" \
    "pywinrm>=0.4,<0.6" \
    "requests-ntlm>=1.1,<2" \
    "azure-identity>=1.15" \
    "azure-mgmt-compute>=30" \
    "azure-mgmt-network>=25" \
    "azure-mgmt-resource>=23" \
    "msgraph-core>=1"

# Ansible collections, from requirements.yml so the version bounds there are
# what ships (this used to install unpinned, ignoring that file). Upstream test
# trees are removed: they hold fixture private keys that set off every
# customer's secret scanner and nothing at runtime reads them.
COPY requirements.yml /tmp/requirements.yml
RUN ansible-galaxy collection install -r /tmp/requirements.yml -p "$ANSIBLE_COLLECTIONS_PATH" \
    && find "$ANSIBLE_COLLECTIONS_PATH"/ansible_collections/*/* -maxdepth 1 -type d -name tests -exec rm -rf {} + \
    && rm -f /tmp/requirements.yml \
    && rm -rf "$ANSIBLE_HOME"
# (galaxy created $ANSIBLE_HOME as root with mode 700; left in the image, a
# non-root user could not create its temp dir and every command failed)

# azure_rm plugin Python requirements. The full list is needed: the plugin's
# common code imports every SDK in it and refuses to load if one is missing.
RUN pip install --no-cache-dir -r "$ANSIBLE_COLLECTIONS_PATH"/ansible_collections/azure/azcollection/requirements.txt

# Copy repo content
WORKDIR /work
COPY . /work/

# Make scripts executable
RUN chmod +x scripts/*.sh deploy/*.sh quickstart.sh 2>/dev/null || true

# Entrypoint
ENTRYPOINT ["/work/scripts/docker-entrypoint.sh"]
CMD ["deploy"]

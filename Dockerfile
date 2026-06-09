# =====================================================================
# CloudLens Ansible for Azure: Deployment Image
# =====================================================================
# Zero-install deployment for any team. Works from any machine with Docker.
#
# Build:
#   docker build -t cloudlens-ansible-azure .
#
# Run (interactive):
#   docker run --rm -it \
#     -v $(pwd)/customer_input.yaml:/work/customer_input.yaml \
#     -v $HOME/.ssh:/root/.ssh:ro \
#     -v $(pwd)/files:/work/files:ro \
#     -e ANSIBLE_WINRM_PASSWORD="${ANSIBLE_WINRM_PASSWORD}" \
#     -e AZURE_SUBSCRIPTION_ID -e AZURE_TENANT \
#     -e AZURE_CLIENT_ID -e AZURE_SECRET \
#     cloudlens-ansible-azure
#
# CI/CD (single command):
#   docker run --rm \
#     -v $(pwd):/work \
#     -e AZURE_SUBSCRIPTION_ID -e AZURE_TENANT \
#     -e AZURE_CLIENT_ID -e AZURE_SECRET \
#     cloudlens-ansible-azure deploy
# =====================================================================

FROM python:3.12-slim AS base

LABEL maintainer="Keysight Technologies"
LABEL description="Automated CloudLens sensor deployment for Azure VMs (Linux + Windows)"

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    ANSIBLE_HOST_KEY_CHECKING=False \
    ANSIBLE_RETRY_FILES_ENABLED=False \
    ANSIBLE_FORCE_COLOR=True

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
RUN pip install --no-cache-dir \
    "ansible-core>=2.16,<2.18" \
    pywinrm \
    requests-ntlm \
    "azure-identity>=1.15" \
    "azure-mgmt-compute>=30" \
    "azure-mgmt-network>=25" \
    "azure-mgmt-resource>=23" \
    "msgraph-core>=1"

# Ansible collections
RUN ansible-galaxy collection install \
    azure.azcollection \
    ansible.windows \
    community.windows \
    community.general \
    --upgrade

# Install azure_rm plugin Python requirements
RUN pip install --no-cache-dir -r /root/.ansible/collections/ansible_collections/azure/azcollection/requirements.txt

# Copy repo content
WORKDIR /work
COPY . /work/

# Make scripts executable
RUN chmod +x scripts/*.sh deploy/*.sh quickstart.sh 2>/dev/null || true

# Entrypoint
ENTRYPOINT ["/work/scripts/docker-entrypoint.sh"]
CMD ["deploy"]

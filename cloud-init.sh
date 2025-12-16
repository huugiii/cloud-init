#!/usr/bin/env bash

# Description:
# This script is used to initialize the server. 
# Run it as root as initial script setup.
#
# This will:
# - Update & Upgrade the system
# - Create a new user called "ansible" (with sudo access)
# 
# Note: This script only includes the minimum required to get the server up and ready for ansible to run.

# Variables
SSH_PORT=${1:-22}
SSH_USER=${2:-"debian"}
SSH_PUBKEY=${3:-""}
SSH_CONFIG="/etc/ssh/sshd_config"
SUDOERS_FILE="90-cloud-init-users"

# Pipefail
set -euo pipefail

# ------ Functions ------ #

# Check if user exists
check_user_exists() {
    id "$1" &>/dev/null
}

check_user_has_sudo() {
    sudo -l -U "$1" | grep -q "NOPASSWD" &>/dev/null
}

# Log
log() {
  echo "[INFO] $1"
}

# Log error and exit
fail() {
  echo "[ERROR] $1" >&2
  exit 1
}

# ------ Scripts ------ #

# Require root
if [[ "$(id -u)" -ne 0 ]]; then
    fail "This script must be run as root"
fi

if [ -z "${SSH_PUBKEY}" ]; then
  fail "SSH public key is required for authentication"
fi

# Update and upgrade system
log "Updating and upgrading system packages..."
apt update && apt upgrade -y
apt dist-upgrade -y
apt autoremove -y   
apt install -y sudo ufw openssh-server ca-certificates curl vim

# Create user if it doesn't exist
log "Ensuring admin user '${SSH_USER}' exists"
SSH_USER_HOME="/home/${SSH_USER}"
if ! check_user_exists "${SSH_USER}"; then
    log "Creating user ${SSH_USER}..."
    useradd -m -s /bin/bash "${SSH_USER}" -d ${SSH_USER_HOME}
else
    log "User ${SSH_USER} already exists"
fi

log "Checking sudo privileges for ${SSH_USER}"
if ! check_user_has_sudo "${SSH_USER}"; then
  log "Granting passwordless sudo to ${SSH_USER}"
  echo "${SSH_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${SUDOERS_FILE}
  chmod 0440 /etc/sudoers.d/${SUDOERS_FILE}
else
  log "${SSH_USER} already has sudo privileges, skipping"
fi

# Allow SSH_USER authentification using public key
log "Adding Public SSH key for authentification"
mkdir -p "${SSH_USER_HOME}/.ssh"
SSH_AUTHORIZED_KEYS_FILE="${SSH_USER_HOME}/.ssh/authorized_keys"
echo "${SSH_PUBKEY}" > "${SSH_AUTHORIZED_KEYS_FILE}"
chmod 600 "${SSH_AUTHORIZED_KEYS_FILE}"
chown -R "${SSH_USER}:${SSH_USER}" "${SSH_USER_HOME}/.ssh"

# Ensure sudo is available for the user if needed
if ! groups "${SSH_USER}" | grep -qw sudo; then
    log "Adding ${SSH_USER} to sudo group..."
    usermod -aG sudo "${SSH_USER}"
fi

# Harden SSH
log "Configuring SSH..."
cp "${SSH_CONFIG}" "${SSH_CONFIG}.$(date +%Y%m%d_%H%M).bak"
sed -i "s/^#Port .*/Port ${SSH_PORT}/" "${SSH_CONFIG}" || echo "Port ${SSH_PORT}" >> "${SSH_CONFIG}"
sed -i "s/^#PermitRootLogin .*/PermitRootLogin no/" "${SSH_CONFIG}" || echo "PermitRootLogin no" >> "${SSH_CONFIG}"
sed -i "s/^#PasswordAuthentication .*/PasswordAuthentication no/" "${SSH_CONFIG}" || echo "PasswordAuthentication yes" >> "${SSH_CONFIG}"
sed -i "s/^#PubkeyAuthentication .*/PubkeyAuthentication yes/" "${SSH_CONFIG}" || echo "PubkeyAuthentication yes" >> "${SSH_CONFIG}"
sed -i "s/^#PermitEmptyPasswords .*/PermitEmptyPasswords no/" "${SSH_CONFIG}" || echo "PermitEmptyPasswords no" >> "${SSH_CONFIG}"
sed -i "s/^#PermitUserEnvironment .*/PermitUserEnvironment no/" "${SSH_CONFIG}" || echo "PermitUserEnvironment no" >> "${SSH_CONFIG}"
sed -i "s/^#AllowTcpForwarding .*/AllowTcpForwarding no/" "${SSH_CONFIG}" || echo "AllowTcpForwarding no" >> "${SSH_CONFIG}"
sed -i "s/^#X11Forwarding .*/X11Forwarding no/" "${SSH_CONFIG}" || echo "X11Forwarding no" >> "${SSH_CONFIG}"
sed -i "s/^#MaxAuthTries .*/MaxAuthTries 10/" "${SSH_CONFIG}" || echo "MaxAuthTries 3" >> "${SSH_CONFIG}"
sed -i "s/^#MaxSessions .*/MaxSessions 3/" "${SSH_CONFIG}" || echo "MaxSessions 2" >> "${SSH_CONFIG}"
sed -i "s/^#ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/" "${SSH_CONFIG}" || echo "ChallengeResponseAuthentication no" >> "${SSH_CONFIG}"
sed -i "s/^#UsePAM .*/UsePAM yes/" "${SSH_CONFIG}" || echo "UsePAM yes" >> "${SSH_CONFIG}"
sshd -t || fail "Invalid SSH configuration detected"

# Setup basic firewall
log "Configuring UFW firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}"/tcp
ufw --force enable

# Restart SSH service
log "Restarting SSH service"
systemctl restart sshd

log "Bootstrap completed successfully"
log "Connect using: ssh -p ${SSH_PORT} ${SSH_USER}@<server_ip>"

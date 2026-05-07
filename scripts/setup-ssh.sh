#!/bin/bash

# Setup SSH configuration
# This script configures SSH public key for instance access

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]:-$0}")/utils.sh"

setup_ssh_config() {
    log_info "正在配置 SSH..."
    
    # Validate required environment variable
    require_env_var "INSTANCE_SSH_PUBLIC_KEY"
    
    # Create SSH directory if it doesn't exist
    mkdir -p ~/.ssh
    
    # Create SSH public key file
    echo "${INSTANCE_SSH_PUBLIC_KEY}" > ~/.ssh/public_key.pub
    chmod 644 ~/.ssh/public_key.pub
    
    log_success "SSH 公钥配置完成"
}

# Run setup if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_ssh_config
fi
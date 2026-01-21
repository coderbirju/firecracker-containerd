#!/bin/bash
set -euo pipefail

echo "=== Installing base dependencies on Ubuntu ==="

# Update package list
echo "Updating package lists..."
sudo apt-get update

# Install essential build tools
echo "Installing essential build tools..."
sudo apt-get install -y \
    make \
    git \
    curl \
    wget \
    jq \
    ca-certificates \
    gnupg \
    lsb-release \
    build-essential

# Install Docker if not already installed
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    # Add Docker's official GPG key
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Add Docker repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    # Start and enable Docker service
    sudo systemctl start docker
    sudo systemctl enable docker
else
    echo "Docker already installed"
fi

# Install AWS CLI if not already installed
if ! command -v aws &> /dev/null; then
    echo "Installing AWS CLI via snap..."
    sudo snap install aws-cli --classic
else
    echo "AWS CLI already installed"
fi

# Add current user to docker group
echo "Adding user $(whoami) to docker group..."
sudo usermod -aG docker $(whoami)

# Add current user to kvm group for /dev/kvm access (needed for integration tests)
echo "Adding user $(whoami) to kvm group..."
sudo usermod -aG kvm $(whoami)

# Verify installations
echo ""
echo "=== Verifying installations ==="
make --version
git --version
docker --version
curl --version
aws --version

echo ""
echo "✅ Setup complete!"
echo ""
echo "⚠️  IMPORTANT: You must log out and log back in for group memberships to take effect"
echo "    Or run: newgrp docker && newgrp kvm"
echo ""
echo "After relogin, verify access with:"
echo "  docker ps"
echo "  docker run hello-world"
echo "  ls -la /dev/kvm"
echo ""
echo "Next steps:"
echo "1. Configure AWS credentials: aws configure"
echo "2. Install GitHub Actions runner (see documentation)"
echo "3. Load KVM modules: sudo modprobe kvm && sudo modprobe kvm-intel (or kvm-amd)"

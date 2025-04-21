#!/bin/bash

# Script to automate LXC creation on Proxmox and install SOGo on Debian 12
# Requires: Proxmox VE, root privileges, internet access
# Logs to /var/log/sogo_lxc_setup.log

# Exit on error
set -e

# Logging setup
LOG_FILE="/var/log/sogo_lxc_setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[$(date)] Starting SOGo LXC setup script"

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Check if running on Proxmox
if ! command -v pveam >/dev/null 2>&1; then
    echo "Error: Proxmox VE tools not found. Is this a Proxmox host?"
    exit 1
fi

# Configuration variables
CTID=100
HOSTNAME="sogo-server"
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
DISK_SIZE=32
CPU_CORES=2
MEMORY=8192
SWAP=2048
BRIDGE="vmbr0"
IP="dhcp"
CONTAINER_TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"

# Function to check command success
check_status() {
    if [ $? -ne 0 ]; then
        echo "Error: $1 failed"
        exit 1
    fi
}

# Update container templates
echo "[$(date)] Updating Proxmox container templates"
pveam update
check_status "Updating container templates"

# Check if Debian 12 template exists, download if not
if [ ! -f "/var/lib/vz/template/cache/$CONTAINER_TEMPLATE" ]; then
    echo "[$(date)] Downloading Debian 12 template"
    pveam download "$TEMPLATE_STORAGE" "$CONTAINER_TEMPLATE"
    check_status "Downloading Debian 12 template"
else
    echo "[$(date)] Debian 12 template already exists"
fi

# Create LXC container
echo "[$(date)] Creating LXC container with CTID $CTID"
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$CONTAINER_TEMPLATE" \
    --unprivileged 1 \
    --features nesting=1 \
    --hostname "$HOSTNAME" \
    --storage "$STORAGE" \
    --cores "$CPU_CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --net0 name=eth0,bridge="$BRIDGE",ip="$IP",type=veth
check_status "Creating LXC container"

# Start the container
echo "[$(date)] Starting LXC container"
pct start "$CTID"
check_status "Starting LXC container"

# Wait for container to be ready
echo "[$(date)] Waiting for container to initialize"
sleep 10

# Update container and install prerequisites
echo "[$(date)] Updating container and installing prerequisites"
pct exec "$CTID" -- bash -c "
    apt-get update && apt-get upgrade -y &&
    apt-get install -y wget gnupg2 curl apt-transport-https ca-certificates
"
check_status "Updating container and installing prerequisites"

# Add SOGo repository
echo "[$(date)] Adding SOGo repository"
pct exec "$CTID" -- bash -c "
    echo 'deb http://packages.sogo.nu/nightly/5/debian/ bookworm bookworm' > /etc/apt/sources.list.d/sogo.list &&
    wget -q -O - 'http://keys.openpgp.org/pks/lookup?op=get&search=0x1B36D249B0F332D2' | apt-key add -
"
check_status "Adding SOGo repository"

# Install SOGo and dependencies
echo "[$(date)] Installing SOGo and dependencies"
pct exec "$CTID" -- bash -c "
    apt-get update &&
    apt-get install -y sogo sope4.9-gdl1-mysql mysql-server apache2 memcached &&
    apt-get clean
"
check_status "Installing SOGo and dependencies"

# Configure MySQL for SOGo
echo "[$(date)] Configuring MySQL for SOGo"
pct exec "$CTID" -- bash -c "
    mysql -e \"CREATE DATABASE sogo;\"
    mysql -e \"CREATE USER 'sogo'@'localhost' IDENTIFIED BY 'sogo_password';\"
    mysql -e \"GRANT ALL PRIVILEGES ON sogo.* TO 'sogo'@'localhost';\"
    mysql -e \"FLUSH PRIVILEGES;\"
"
check_status "Configuring MySQL"

# Initialize SOGo database schema
echo "[$(date)] Initializing SOGo database schema"
pct exec "$CTID" -- bash -c "
    sogo-tool update-autoreply -p /usr/share/doc/sogo/sogo.sql
"
check_status "Initializing SOGo database schema"

# Enable and start services
echo "[$(date)] Enabling and starting services"
pct exec "$CTID" -- bash -c "
    systemctl enable mysql apache2 memcached sogo &&
    systemctl start mysql apache2 memcached sogo
"
check_status "Enabling and starting services"

# Configure Apache2 for SOGo
echo "[$(date)] Configuring Apache2 for SOGo"
pct exec "$CTID" -- bash -c "
    a2enmod proxy proxy_http rewrite headers
    systemctl restart apache2
"
check_status "Configuring Apache2"

# Display access information
IP_ADDRESS=$(pct exec "$CTID" -- ip addr show eth0 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
echo "[$(date)] Setup complete!"
echo "SOGo is installed in LXC container $CTID ($HOSTNAME)"
echo "Access the SOGo web interface at: http://$IP_ADDRESS/SOGo"
echo "MySQL SOGo user: sogo, password: sogo_password"
echo "Log file: $LOG_FILE"

# Clean up
echo "[$(date)] Cleaning up"
pct exec "$CTID" -- apt-get autoremove -y
echo "[$(date)] Script execution completed"

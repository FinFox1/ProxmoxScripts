#!/usr/bin/env bash

# Copyright (c) 2025 xAI
# Idea: FinFox1 ( https://github.com/FinFox1 )
# License: MIT
# Description: Installs TYPO3 CMS with Apache and MySQL in a Proxmox LXC container on Debian 12

# Exit on error
set -e

# Helper functions
msg_info() { echo -e "\033[1;34m[*] $1\033[0m"; }
msg_ok() { echo -e "\033[1;32m[+] $1\033[0m"; }
msg_error() { echo -e "\033[1;31m[-] $1\033[0m"; exit 1; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  msg_error "This script must be run as root"
fi

# Check network connectivity
msg_info "Checking network connectivity"
ping -c 1 8.8.8.8 >/dev/null 2>&1 || msg_error "No internet connection"

# Update system
msg_info "Updating system"
apt-get update -y >/dev/null 2>&1
apt-get upgrade -y >/dev/null 2>&1
msg_ok "System updated"

# Install dependencies
msg_info "Installing dependencies"
apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  unzip \
  imagemagick \
  apache2 \
  libapache2-mod-php \
  php \
  php-cli \
  php-mysql \
  php-gd \
  php-imagick \
  php-curl \
  php-xml \
  php-mbstring \
  php-zip \
  php-intl >/dev/null 2>&1
msg_ok "Dependencies installed"

# Install MySQL
msg_info "Setting up MySQL repository"
echo "deb http://repo.mysql.com/apt/debian bookworm mysql-8.0" >/etc/apt/sources.list.d/mysql.list
curl -fsSL https://repo.mysql.com/RPM-GPG-KEY-mysql-2023 | gpg --dearmor -o /usr/share/keyrings/mysql.gpg >/dev/null 2>&1
apt-get update >/dev/null 2>&1
msg_info "Installing MySQL"
apt-get install -y mysql-server >/dev/null 2>&1
systemctl enable mysql >/dev/null 2>&1
systemctl start mysql >/dev/null 2>&1
msg_ok "MySQL installed and running"

# Configure MySQL
msg_info "Configuring MySQL"
DB_NAME=typo3
DB_USER=typo3
DB_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c13)
mysql -u root -e "CREATE DATABASE $DB_NAME;" || msg_error "Failed to create database"
mysql -u root -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';" || msg_error "Failed to create user"
mysql -u root -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';" || msg_error "Failed to grant privileges"
mysql -u root -e "FLUSH PRIVILEGES;" || msg_error "Failed to flush privileges"
{
  echo "TYPO3 MySQL Credentials"
  echo "Database Name: $DB_NAME"
  echo "Database User: $DB_USER"
  echo "Database Password: $DB_PASS"
} > /root/typo3.creds
chmod 600 /root/typo3.creds
msg_ok "MySQL configured"

# Configure Apache
msg_info "Configuring Apache"
IP_ADDR=$(hostname -I | awk '{print $1}')
cat <<EOF >/etc/apache2/sites-available/typo3.conf
<VirtualHost *:80>
    ServerAdmin admin@example.com
    ServerName ${IP_ADDR}
    DocumentRoot /var/www/typo3/public
    <Directory /var/www/typo3/public>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/typo3_error.log
    CustomLog \${APACHE_LOG_DIR}/typo3_access.log combined
</VirtualHost>
EOF
a2ensite typo3.conf >/dev/null 2>&1
a2enmod rewrite >/dev/null 2>&1
systemctl restart apache2 >/dev/null 2>&1
msg_ok "Apache configured"

# Install TYPO3
msg_info "Installing TYPO3"
TYPO3_VERSION="13.4.9"
cd /var/www
curl -fsSL "https://get.typo3.org/$TYPO3_VERSION" -o typo3.tar.gz || msg_error "Failed to download TYPO3"
tar -xzf typo3.tar.gz
mv typo3_src-* typo3
chown -R www-data:www-data typo3
rm typo3.tar.gz
msg_ok "TYPO3 installed"

# Set up TYPO3 configuration
msg_info "Configuring TYPO3"
cat <<EOF >/var/www/typo3/config/system/settings.yaml
db:
  Connections:
    Default:
      driver: mysqli
      host: 127.0.0.1
      port: 3306
      dbname: $DB_NAME
      user: $DB_USER
      password: $DB_PASS
EOF
chown www-data:www-data /var/www/typo3/config/system/settings.yaml
msg_ok "TYPO3 configured"

# Set up firewall
msg_info "Configuring firewall"
apt-get install -y ufw >/dev/null 2>&1
ufw allow 80 >/dev/null 2>&1
ufw allow 443 >/dev/null 2>&1
ufw allow 22 >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
msg_ok "Firewall configured"

# Clean up
msg_info "Cleaning up"
apt-get autoremove -y >/dev/null 2>&1
apt-get autoclean -y >/dev/null 2>&1
msg_ok "Cleanup completed"

# Display access information
msg_ok "Installation complete!"
echo "TYPO3 is installed and accessible at: http://$IP_ADDR/typo3"
echo "Backend: http://$IP_ADDR/typo3/install.php"
echo "Credentials stored in: /root/typo3.creds"
echo "Please complete the TYPO3 setup via the web interface"

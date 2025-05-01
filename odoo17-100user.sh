#!/bin/bash
# Lightweight Odoo 17 install script for up to 100 users in a single LXC
set -e

echo "🛠️ Starting complete installation of Odoo 17 components in a single LXC..."

############################################
echo "📦 Updating system and installing basic requirements..."
apt update && apt upgrade -y

# Install Python 3.11 specifically
echo "📦 Installing Python 3.11..."
apt install -y software-properties-common
add-apt-repository -y ppa:deadsnakes/ppa
apt update
apt install -y python3.11 python3.11-dev python3.11-venv python3.11-distutils

# Instead of changing system default Python, we'll use Python 3.11 for Odoo only
# This way system tools that depend on the default Python will continue to work
echo "📦 Keeping system Python intact to avoid apt_pkg errors..."

# Install gnupg first to avoid apt-key errors
echo "📦 Installing gnupg first to avoid apt-key errors..."
apt install -y gnupg gnupg1 gnupg2

# Add official PostgreSQL repository
echo "📦 Adding official PostgreSQL repository..."
sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
# Using updated method to add the PostgreSQL key
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
apt update

# Install build dependencies for Python packages by ali
echo "📦 Installing build dependencies for Python packages..."
apt install -y git python3-pip build-essential wget python3-dev libxml2-dev libxslt1-dev \
    zlib1g-dev libsasl2-dev libldap2-dev libpq-dev libjpeg-dev libpng-dev \
    node-less libjpeg8-dev liblcms2-dev libblas-dev libatlas-base-dev libssl-dev \
    libffi-dev libmysqlclient-dev libxrender1 xfonts-75dpi xfonts-base \
    python3-venv wkhtmltopdf npm nodejs curl htop net-tools lsb-release \
    python3-certbot-nginx redis-server ruby ruby-dev make gcc \
    postgresql-15 postgresql-client-15 python3-wheel python3-setuptools \
    python3-dev pkg-config libc-dev \
    python3-cffi libev-dev cython3

############################################
echo "📂 Setting up PostgreSQL..."
# Change to a directory the postgres user can access
cd /tmp

# Create user and set password from a location postgres user can access
sudo -u postgres psql -c "CREATE USER odoo WITH CREATEDB CREATEROLE PASSWORD 'odoo';"
sudo -u postgres psql -c "ALTER USER odoo WITH SUPERUSER;"

# Basic tuning for low resource
cat <<EOF >> /etc/postgresql/*/main/postgresql.conf
# Performance optimizations for Odoo
shared_buffers = '256MB'
work_mem = '32MB'
maintenance_work_mem = '64MB'
effective_cache_size = '512MB'
synchronous_commit = off
max_connections = 100
random_page_cost = 1.1
checkpoint_timeout = '30min'
max_wal_size = '256MB'
EOF

systemctl restart postgresql

############################################
cho "🚀 Setting up Redis..."
sed -i "s/^bind .*/bind 127.0.0.1/" /etc/redis/redis.conf
sed -i "s/^protected-mode yes/protected-mode no/" /etc/redis/redis.conf
# Configure Redis for better performance
sed -i "s/^# maxmemory .*/maxmemory 1gb/" /etc/redis/redis.conf
sed -i "s/^# maxmemory-policy .*/maxmemory-policy allkeys-lru/" /etc/redis/redis.conf
systemctl enable redis-server && systemctl restart redis-server

############################################
echo "📂 Installing Odoo 17..."
ODOO_USER=odoo
ODOO_HOME=/opt/odoo
ODOO_VERSION=17.0
ODOO_CONF=/etc/odoo.conf

adduser --system --quiet --shell=/bin/bash --home=$ODOO_HOME --group $ODOO_USER
git clone https://www.github.com/odoo/odoo --depth 1 --branch $ODOO_VERSION $ODOO_HOME/odoo-server
chown -R $ODOO_USER:$ODOO_USER $ODOO_HOME/odoo-server

python3.11 -m venv $ODOO_HOME/venv
source $ODOO_HOME/venv/bin/activate
pip install --upgrade pip setuptools wheel
# Pre-install problematic packages with compatible versions
echo "📦 Pre-installing compatible versions of problematic packages..."
pip install greenlet==2.0.2
pip install Cython==0.29.36
pip install gevent==22.10.2
pip install psycopg2-binary==2.9.9
pip install lxml==4.9.3
pip install Pillow==9.5.0
pip install Werkzeug==2.0.3
pip install cryptography==38.0.4
pip install PyPDF2==2.12.1
pip install reportlab==3.6.13

pip install -r $ODOO_HOME/odoo-server/requirements.txt
pip install psycopg2-binary redis
# Additional packages
pip install redis pyOpenSSL psycogreen

ADMIN_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
echo "$ADMIN_PASSWORD" > /root/odoo_admin_password.txt
chmod 600 /root/odoo_admin_password.txt

cat <<EOF > $ODOO_CONF
[options]
admin_passwd = $ADMIN_PASSWORD
db_host = 127.0.0.1
db_port = 5432
db_user = odoo
db_password = odoo
addons_path = $ODOO_HOME/odoo-server/addons
logfile = /var/log/odoo/odoo.log
logrotate = True
# Performance optimizations for 100 users
workers = 2
max_cron_threads = 1
limit_memory_hard = 1024000000
limit_memory_soft = 800000000
limit_request = 2048
limit_time_cpu = 60
limit_time_real = 120
db_maxconn = 64
http_port = 8069
proxy_mode = True
gevent_port = 8072
longpolling_port = 8072
server_wide_modules = web,queue_job
queue_job_channels = root:2

# Cache and performance settings
session_redis = True
session_redis_host = 127.0.0.1
session_redis_port = 6379
session_redis_prefix = odoo_session:
redis_host = 127.0.0.1
redis_port = 6379
EOF

mkdir -p /var/log/odoo && chown $ODOO_USER:$ODOO_USER /var/log/odoo

cat <<EOF > /etc/systemd/system/odoo.service
[Unit]
Description=Odoo
Requires=network.target postgresql.service redis-server.service
After=network.target postgresql.service redis-server.service

[Service]
Type=simple
SyslogIdentifier=odoo
PermissionsStartOnly=true
User=$ODOO_USER
Group=$ODOO_USER
ExecStart=$ODOO_HOME/venv/bin/python3.11 $ODOO_HOME/odoo-server/odoo-bin -c $ODOO_CONF
StandardOutput=journal+console
LimitNOFILE=65536
LimitNPROC=4096
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Add additional useful libraries for Odoo
cd $ODOO_HOME
git clone https://github.com/OCA/queue --depth 1 --branch $ODOO_VERSION queue
git clone https://github.com/OCA/server-tools --depth 1 --branch $ODOO_VERSION server-tools
git clone https://github.com/CybroOdoo/CybroAddons.git --depth 1 --branch $ODOO_VERSION cybro-addons

# Update addons path
sed -i "s#addons_path = .*#addons_path = $ODOO_HOME/odoo-server/addons,$ODOO_HOME/queue,$ODOO_HOME/server-tools,$ODOO_HOME/cybro-addons#" $ODOO_CONF
chown -R $ODOO_USER:$ODOO_USER $ODOO_HOME


systemctl daemon-reload
systemctl enable odoo
systemctl start odoo

cat <<MSG
✅ Lightweight Odoo 17 setup complete!
📊 Accessible at: http://your-server-ip:8069
🔐 Admin password saved to: /root/odoo_admin_password.txt
MSG

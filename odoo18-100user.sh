#!/bin/bash
# Create a unified script to install all components in a single LXC suitable for 100 users
set -e

echo "🛠️ Starting lightweight installation of Odoo 18 components on Ubuntu 24.04 with Python 3.12..."

############################################
echo "📦 Updating system and installing basic requirements..."
apt update && apt upgrade -y

# Install gnupg first to avoid apt-key errors
echo "📦 Installing gnupg first to avoid apt-key errors..."
apt install -y gnupg curl ca-certificates

# Add official PostgreSQL repository
echo "📦 Adding official PostgreSQL repository..."
sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
# Using the recommended method to import the PostgreSQL GPG key
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
apt update

# Install build dependencies for Python packages - adapted for Ubuntu 24.04
echo "📦 Installing build dependencies for Python packages..."
apt install -y git python3-pip build-essential wget python3-dev python3-venv libxml2-dev libxslt1-dev \
    zlib1g-dev libsasl2-dev libldap2-dev libpq-dev libjpeg-dev libpng-dev \
    node-less libjpeg8-dev liblcms2-dev libblas-dev libatlas-base-dev libssl-dev \
    libffi-dev libxrender1 xfonts-75dpi xfonts-base \
    python3-venv wkhtmltopdf npm nodejs curl htop net-tools lsb-release \
    python3-certbot-nginx redis-server ruby ruby-dev make gcc \
    postgresql-16 postgresql-client-16 python3-wheel python3-setuptools \
    python3-dev pkg-config libc6-dev \
    python3-cffi libev-dev cython3 \
    default-libmysqlclient-dev

############################################
echo "📂 Setting up PostgreSQL..."
cd /tmp

sudo -u postgres psql -c "CREATE USER odoo WITH CREATEDB CREATEROLE PASSWORD 'odoo';"
sudo -u postgres psql -c "ALTER USER odoo WITH SUPERUSER;"

cat <<EOF >> /etc/postgresql/16/main/postgresql.conf
# Performance optimizations for Odoo (100 users)
shared_buffers = '256MB'
work_mem = '64MB'
maintenance_work_mem = '128MB'
effective_cache_size = '1GB'
synchronous_commit = off
max_connections = 100
random_page_cost = 1.1
checkpoint_timeout = '15min'
max_wal_size = '512MB'
EOF

systemctl restart postgresql

############################################
echo "🚀 Setting up Redis..."
sed -i "s/^bind .*/bind 127.0.0.1/" /etc/redis/redis.conf
sed -i "s/^protected-mode yes/protected-mode no/" /etc/redis/redis.conf
sed -i "s/^# maxmemory .*/maxmemory 512mb/" /etc/redis/redis.conf
sed -i "s/^# maxmemory-policy .*/maxmemory-policy allkeys-lru/" /etc/redis/redis.conf
systemctl enable redis-server && systemctl restart redis-server

############################################
echo "📂 Setting up Odoo 18..."
ODOO_VERSION="18.0"
ODOO_USER="odoo"
ODOO_HOME="/opt/odoo"
ODOO_CONF="/etc/odoo.conf"

adduser --system --quiet --shell=/bin/bash --home=$ODOO_HOME --group $ODOO_USER
git clone https://www.github.com/odoo/odoo --depth 1 --branch $ODOO_VERSION $ODOO_HOME/odoo-server
chown -R $ODOO_USER:$ODOO_USER $ODOO_HOME/odoo-server

python3 -m venv $ODOO_HOME/venv
source $ODOO_HOME/venv/bin/activate
pip install --upgrade pip wheel setuptools

echo "📦 Pre-installing compatible versions of problematic packages for Python 3.12..."
pip install greenlet==3.0.1
pip install Cython==3.0.6
pip install gevent==23.9.1
pip install psycopg2-binary==2.9.9
pip install lxml==4.9.3
pip install Pillow==10.1.0
pip install Werkzeug==2.3.7
pip install cryptography==41.0.5
pip install PyPDF2==3.0.1
pip install reportlab==4.0.7
pip install qifparse

pip install -r $ODOO_HOME/odoo-server/requirements.txt || pip install --no-deps -r $ODOO_HOME/odoo-server/requirements.txt
pip install redis pyOpenSSL psycogreen

ADMIN_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
echo "Odoo admin password is: $ADMIN_PASSWORD"
echo "Password has been saved to /root/odoo_admin_password.txt"
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
limit_memory_hard = 1073741824
limit_memory_soft = 805306368
limit_request = 4096
limit_time_cpu = 60
limit_time_real = 120
db_maxconn = 50
http_port = 8069
proxy_mode = True
gevent_port = 8072
longpolling_port = 8072
server_wide_modules = web,queue_job
queue_job_channels = root:2

session_redis = True
session_redis_host = 127.0.0.1
session_redis_port = 6379
session_redis_prefix = odoo_session:
redis_host = 127.0.0.1
redis_port = 6379
EOF

chown $ODOO_USER:$ODOO_USER $ODOO_CONF
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
ExecStart=$ODOO_HOME/venv/bin/python3 $ODOO_HOME/odoo-server/odoo-bin -c $ODOO_CONF
StandardOutput=journal+console
LimitNOFILE=65536
LimitNPROC=2048
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

cd $ODOO_HOME
git clone https://github.com/OCA/queue --depth 1 --branch $ODOO_VERSION queue
git clone https://github.com/OCA/server-tools --depth 1 --branch $ODOO_VERSION server-tools
git clone https://github.com/CybroOdoo/CybroAddons.git --depth 1 --branch $ODOO_VERSION cybro-addons

sed -i "s#addons_path = .*#addons_path = $ODOO_HOME/odoo-server/addons,$ODOO_HOME/queue,$ODOO_HOME/server-tools,$ODOO_HOME/cybro-addons#" $ODOO_CONF
chown -R $ODOO_USER:$ODOO_USER $ODOO_HOME

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable odoo
systemctl start odoo

echo "✅ Lightweight Odoo installation for 100 users completed!"
echo "📊 Accessible on port 8069"
echo "🔐 Admin password saved in /root/odoo_admin_password.txt"

#!/bin/bash
# Lightweight Odoo 17 install script for up to 100 users in a single LXC
set -e

echo "🛠️ Starting lightweight Odoo 17 setup for low-resource environments..."

############################################
echo "📦 Updating system..."
apt update && apt upgrade -y

############################################
echo "📦 Installing Python 3.11..."
apt install -y software-properties-common
add-apt-repository -y ppa:deadsnakes/ppa
apt update
apt install -y python3.11 python3.11-dev python3.11-venv python3.11-distutils

############################################
echo "📦 Installing dependencies..."
apt install -y git build-essential wget curl python3-pip \
    libxml2-dev libxslt1-dev zlib1g-dev libldap2-dev libsasl2-dev \
    libjpeg-dev libpng-dev libpq-dev libffi-dev libssl-dev \
    node-less xfonts-75dpi xfonts-base wkhtmltopdf nginx \
    postgresql postgresql-client redis-server

############################################
echo "📂 Setting up PostgreSQL..."
sudo -u postgres psql -c "CREATE USER odoo WITH CREATEDB PASSWORD 'odoo';"
sudo -u postgres psql -c "ALTER USER odoo WITH SUPERUSER;"

# Basic tuning for low resource
cat <<EOF >> /etc/postgresql/*/main/postgresql.conf
shared_buffers = 256MB
work_mem = 32MB
effective_cache_size = 512MB
max_connections = 100
EOF

systemctl restart postgresql

############################################
echo "🚀 Configuring Redis (localhost only)..."
sed -i "s/^bind .*/bind 127.0.0.1/" /etc/redis/redis.conf
sed -i "s/^protected-mode yes/protected-mode yes/" /etc/redis/redis.conf
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
pip install -r $ODOO_HOME/odoo-server/requirements.txt
pip install psycopg2-binary redis

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
# Performance optimizations for 500 users
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

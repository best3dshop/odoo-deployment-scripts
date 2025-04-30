# Odoo Installation Scripts 
 
A collection of scripts for installing and configuring Odoo v17 and v18 with high efficiency to support 500 users. 
 
## Contents 
 
- `allinone17.sh`: Script for installing Odoo 17 with all required components (Redis, PostgreSQL) 
- `allinone18.sh`: Script for installing Odoo 18 with all required components (Redis, PostgreSQL) 
- Additional scripts for setting up LXC and various services 
 
## Features 
 
- Support for up to 500 concurrent users 
- Database performance optimization 
- Redis configuration for caching  
- Nginx setup as a front-end proxy 
## Install 
apt-get install git
git clone https://github.com/best3dshop/odoo-deployment-scripts --depth 1 --branch main
cd cd odoo-deployment-scripts/
chmod +x allinone17.sh
chmod +x allinone18.sh

## if install odoo17
./chmod +x allinone17.sh 
## if install odoo17
./chmod +x allinone18.sh 
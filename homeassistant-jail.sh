#!/bin/sh
# Build an iocage jail under TrueNAS 13.0 using the current release of Caddy with Homeassistant Core
# git clone https://github.com/tschettervictor/truenas-iocage-homeassistant

# Check for root privileges
if ! [ $(id -u) = 0 ]; then
   echo "This script must be run with root privileges"
   exit 1
fi

#####
#
# General configuration
#
#####

# Initialize defaults
JAIL_IP=""
JAIL_INTERFACES=""
DEFAULT_GW_IP=""
INTERFACE="vnet0"
VNET="on"
POOL_PATH=""
CONFIG_PATH=""
JAIL_NAME="homeassistant"
HOST_NAME=""
SELFSIGNED_CERT=0
STANDALONE_CERT=0
DNS_CERT=0
NO_CERT=0
CERT_EMAIL=""
CONFIG_NAME="homeassistant-config"

# Check for homeassistant-config and set configuration
SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "${SCRIPT}")
if ! [ -e "${SCRIPTPATH}"/"${CONFIG_NAME}" ]; then
  echo "${SCRIPTPATH}/${CONFIG_NAME} must exist."
  exit 1
fi
. "${SCRIPTPATH}"/"${CONFIG_NAME}"
INCLUDES_PATH="${SCRIPTPATH}"/includes

JAILS_MOUNT=$(zfs get -H -o value mountpoint $(iocage get -p)/iocage)
RELEASE=$(freebsd-version | cut -d - -f -1)"-RELEASE"

#####
#
# Input/Config Sanity checks
#
#####

# Check that necessary variables were set by homeassistant-config
if [ -z "${JAIL_IP}" ]; then
  echo 'Configuration error: JAIL_IP must be set'
  exit 1
fi
if [ -z "${JAIL_INTERFACES}" ]; then
  echo 'JAIL_INTERFACES not set, defaulting to: vnet0:bridge0'
JAIL_INTERFACES="vnet0:bridge0"
fi
if [ -z "${DEFAULT_GW_IP}" ]; then
  echo 'Configuration error: DEFAULT_GW_IP must be set'
  exit 1
fi
if [ -z "${POOL_PATH}" ]; then
  echo 'Configuration error: POOL_PATH must be set'
  exit 1
fi
if [ -z "${HOST_NAME}" ]; then
  echo 'Configuration error: HOST_NAME must be set'
  exit 1
fi

# Check cert config
if [ $STANDALONE_CERT -eq 0 ] && [ $DNS_CERT -eq 0 ] && [ $NO_CERT -eq 0 ] && [ $SELFSIGNED_CERT -eq 0 ]; then
  echo 'Configuration error: Either STANDALONE_CERT, DNS_CERT, NO_CERT,'
  echo 'or SELFSIGNED_CERT must be set to 1.'
  exit 1
fi
if [ $STANDALONE_CERT -eq 1 ] && [ $DNS_CERT -eq 1 ] ; then
  echo 'Configuration error: Only one of STANDALONE_CERT and DNS_CERT'
  echo 'may be set to 1.'
  exit 1
fi
if [ $DNS_CERT -eq 1 ] && [ -z "${DNS_PLUGIN}" ] ; then
  echo "DNS_PLUGIN must be set to a supported DNS provider."
  echo "See https://caddyserver.com/download for available plugins."
  echo "Use only the last part of the name.  E.g., for"
  echo "\"github.com/caddy-dns/cloudflare\", enter \"coudflare\"."
  exit 1
fi
if [ $DNS_CERT -eq 1 ] && [ "${CERT_EMAIL}" = "" ] ; then
  echo "CERT_EMAIL must be set when using Let's Encrypt certs."
  exit 1
fi
if [ $STANDALONE_CERT -eq 1 ] && [ "${CERT_EMAIL}" = "" ] ; then
  echo "CERT_EMAIL must be set when using Let's Encrypt certs."
  exit 1
fi

# Extract IP and netmask, sanity check netmask
IP=$(echo ${JAIL_IP} | cut -f1 -d/)
NETMASK=$(echo ${JAIL_IP} | cut -f2 -d/)
if [ "${NETMASK}" = "${IP}" ]
then
  NETMASK="24"
fi
if [ "${NETMASK}" -lt 8 ] || [ "${NETMASK}" -gt 30 ]
then
  NETMASK="24"
fi

#####
#
# Jail Creation
#
#####

# List packages to be auto-installed after jail creation
cat <<__EOF__ >/tmp/pkg.json
{
  "pkgs": [
  "nano",
  "bash",
  "go",
  "git",
  "autoconf",
  "ca_root_nss",
  "curl",
  "ffmpeg",
  "gcc",
  "gmake",
  "libjpeg-turbo",
  "libxml2",
  "libxslt",
  "pkgconf",
  "python310",
  "py310-sqlite3",
  "rust",
  "sudo",
  "wget",
  "zip"
  ]
}
__EOF__

# Create the jail and install previously listed packages
if ! iocage create --name "${JAIL_NAME}" -p /tmp/pkg.json -r "${RELEASE}" interfaces="${JAIL_INTERFACES}" ip4_addr="${INTERFACE}|${IP}/${NETMASK}" defaultrouter="${DEFAULT_GW_IP}" boot="on" allow_raw_sockets="1" host_hostname="${JAIL_NAME}" vnet="${VNET}"
then
	echo "Failed to create jail"
	exit 1
fi
rm /tmp/pkg.json

#####
#
# Directory Creation and Mounting
#
#####

# Create homeassistant directory on selected pool
mkdir -p "${POOL_PATH}"/homeassistant

# Create directories for homeassistant data, rc.d, and includes
iocage exec "${JAIL_NAME}" mkdir -p /home/homeassistant
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/rc.d
iocage exec "${JAIL_NAME}" mkdir -p /mnt/includes
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/www

# Mount directory for data and includes inside jail
iocage fstab -a "${JAIL_NAME}" "${POOL_PATH}"/homeassistant /home/homeassistant nullfs rw 0 0
iocage fstab -a "${JAIL_NAME}" "${INCLUDES_PATH}" /mnt/includes nullfs rw 0 0

#####
#
# User creation for running homeassistant
#
#####

iocage exec "${JAIL_NAME}" "install -d -g 8123 -o 8123 -m 775 -- /home/homeassistant"
iocage exec "${JAIL_NAME}" "pw adduser -u 8123 -n homeassistant -d /home/homeassistant -w no -s /usr/local/bin/bash -G dialer"

#####
#
# Additional Dependency installation
#
#####

# Build xcaddy, use it to build Caddy
if ! iocage exec "${JAIL_NAME}" "go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest"
then
  echo "Failed to get xcaddy, terminating."
  exit 1
fi
if ! iocage exec "${JAIL_NAME}" cp /root/go/bin/xcaddy /usr/local/bin/xcaddy
then
  echo "Failed to move xcaddy to path, terminating."
  exit 1
fi
if [ ${DNS_CERT} -eq 1 ]; then
  if ! iocage exec "${JAIL_NAME}" xcaddy build --output /usr/local/bin/caddy --with github.com/caddy-dns/"${DNS_PLUGIN}"
  then
    echo "Failed to build Caddy with ${DNS_PLUGIN} plugin, terminating."
    exit 1
  fi  
else
  if ! iocage exec "${JAIL_NAME}" xcaddy build --output /usr/local/bin/caddy
  then
    echo "Failed to build Caddy without plugin, terminating."
    exit 1
  fi  
fi

# Generate and insall self-signed cert, if necessary
if [ $SELFSIGNED_CERT -eq 1 ]; then
	iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/pki/tls/private
	iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/pki/tls/certs
	openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=${HOST_NAME}" -keyout "${INCLUDES_PATH}"/privkey.pem -out "${INCLUDES_PATH}"/fullchain.pem
	iocage exec "${JAIL_NAME}" cp /mnt/includes/privkey.pem /usr/local/etc/pki/tls/private/privkey.pem
	iocage exec "${JAIL_NAME}" cp /mnt/includes/fullchain.pem /usr/local/etc/pki/tls/certs/fullchain.pem
fi

# Copy Caddyfile and homeassistant files (rc.d included)
if [ $STANDALONE_CERT -eq 1 ] || [ $DNS_CERT -eq 1 ]; then
  iocage exec "${JAIL_NAME}" cp -f /mnt/includes/remove-staging.sh /root/
fi
if [ $NO_CERT -eq 1 ]; then
	echo "Copying Caddyfile for no SSL"
	iocage exec "${JAIL_NAME}" cp -f /mnt/includes/Caddyfile-nossl /usr/local/www/Caddyfile
elif [ $SELFSIGNED_CERT -eq 1 ]; then
	echo "Copying Caddyfile for self-signed cert"
	iocage exec "${JAIL_NAME}" cp -f /mnt/includes/Caddyfile-selfsigned /usr/local/www/Caddyfile
elif [ $DNS_CERT -eq 1 ]; then
	echo "Copying Caddyfile for Lets's Encrypt DNS cert"
	iocage exec "${JAIL_NAME}" cp -f /mnt/includes/Caddyfile-dns /usr/local/www/Caddyfile
else
	echo "Copying Caddyfile for Let's Encrypt cert"
	iocage exec "${JAIL_NAME}" cp -f /mnt/includes/Caddyfile-standalone /usr/local/www/Caddyfile	
fi
iocage exec "${JAIL_NAME}" cp -f /mnt/includes/homeassistant /usr/local/etc/rc.d/
iocage exec "${JAIL_NAME}" cp -f /mnt/includes/caddy /usr/local/etc/rc.d/

# download latest rc service script (usidn copy from repo for now...)
# iocage exec "${JAIL_NAME}" wget -O /usr/local/etc/rc.d/homeassistant https://raw.githubusercontent.com/tschettervictor/truenas-iocage-homeassistant/includes/homeassistant
# iocage exec "${JAIL_NAME}" chmod +x /usr/local/etc/rc.d/homeassistant

# Edit Caddyfile
iocage exec "${JAIL_NAME}" sed -i '' "s/yourhostnamehere/${HOST_NAME}/" /usr/local/www/Caddyfile
iocage exec "${JAIL_NAME}" sed -i '' "s/dns_plugin/${DNS_PLUGIN}/" /usr/local/www/Caddyfile
iocage exec "${JAIL_NAME}" sed -i '' "s/api_token/${DNS_TOKEN}/" /usr/local/www/Caddyfile
iocage exec "${JAIL_NAME}" sed -i '' "s/youremailhere/${CERT_EMAIL}/" /usr/local/www/Caddyfile

# Set RCVARS for homeassistant using sysrc and enable service
iocage exec "${JAIL_NAME}" sysrc homeassistant_python=/usr/local/bin/python3.10
iocage exec "${JAIL_NAME}" sysrc homeassistant_venv=/usr/local/share/homeassistant
iocage exec "${JAIL_NAME}" sysrc homeassistant_user=homeassistant
iocage exec "${JAIL_NAME}" sysrc homeassistant_config_dir=/home/homeassistant/config
iocage exec "${JAIL_NAME}" sysrc homeassistant_enable=yes

# Install homeassistant and copy configuration.yaml
iocage exec "${JAIL_NAME}" service homeassistant install homeassistant
iocage exec "${JAIL_NAME}" service homeassistant start homeassistant

echo "Choose either to copy the default configuration.yaml, or if you have one, choose no."
ecdho "If you choose anything other than "n" the file will be copied."

# prompt to copy default file
echo "Do you want to copy the default configuration.yaml? [y/n]"
	read ANSWER
case "$ANSWER" in
	[y]* )
		echo "You have chosen to copy the default file. Copying..."
		iocage exec "${JAIL_NAME}" cp -f /mnt/includes/configuration.yaml /home/homeassistant/config/
		;;
	[n]* )
		echo "You have chosen to not copy the provided configuration.yaml file."
		echo "Please make sure you have one, or if this is a reinstall, it will be there."
		;;
	* )
		echo "You have chosen other than [y/n] Copying default file..."
		iocage exec "${JAIL_NAME}" cp -f /mnt/includes/configuration.yaml /home/homeassistant/config/
esac

# Don't need /mnt/includes any more, so unmount it
iocage fstab -r "${JAIL_NAME}" "${INCLUDES_PATH}" /mnt/includes nullfs rw 0 0

iocage exec "${JAIL_NAME}" sysrc caddy_config="/usr/local/www/Caddyfile"
iocage exec "${JAIL_NAME}" sysrc caddy_enable="YES"

iocage restart "${JAIL_NAME}"

echo ""
if [ $STANDALONE_CERT -eq 1 ] || [ $DNS_CERT -eq 1 ]; then
  echo "You have obtained your Let's Encrypt certificate using the staging server."
  echo "This certificate will not be trusted by your browser and will cause SSL errors"
  echo "when you connect.  Once you've verified that everything else is working"
  echo "correctly, you should issue a trusted certificate.  To do this, run:"
  echo "  iocage exec ${JAIL_NAME} /root/remove-staging.sh"
  echo ""
elif [ $SELFSIGNED_CERT -eq 1 ]; then
  echo "You have chosen to create a self-signed TLS certificate for your installation."
  echo "installation.  This certificate will not be trusted by your browser and"
  echo "will cause SSL errors when you connect.  If you wish to replace this certificate"
  echo "with one obtained elsewhere, the private key is located at:"
  echo "/usr/local/etc/pki/tls/private/privkey.pem"
  echo "The full chain (server + intermediate certificates together) is at:"
  echo "/usr/local/etc/pki/tls/certs/fullchain.pem"
  echo ""
fi

echo "Installation complete."

if [ $NO_CERT -eq 1 ]; then
  echo "Using your web browser, go to http://${HOST_NAME} to log in"
else
  echo "Using your web browser, go to https://${HOST_NAME} to log in"
fi

echo "It will take 5-10 minutes to fully start homeassistant the first time."
echo "Please also allow some additional time to configure extra packages."

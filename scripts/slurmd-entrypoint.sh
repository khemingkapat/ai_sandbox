#!/bin/bash
set -e

if [ -f /etc/sssd/sssd.conf ]; then
    # ConfigMap mounts are read-only — copy to writable location
    mkdir -p /run/sssd
    cp /etc/sssd/sssd.conf /run/sssd/sssd.conf
    chmod 600 /run/sssd/sssd.conf
    mkdir -p /var/log/sssd
    echo "sssd.conf copied to /run/sssd/sssd.conf, SSSD will be started by supervisord"
else
    echo "WARNING: /etc/sssd/sssd.conf not found, SSSD will not start"
fi

exec /usr/local/bin/entrypoint.sh "$@"

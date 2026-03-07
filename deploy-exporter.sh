#!/bin/bash
# Deploy script to run on the PiNodeXMR as root
set -e

# Create textfile collector directory
mkdir -p /var/lib/node_exporter/textfile_collector
chown pinodexmr:pinodexmr /var/lib/node_exporter/textfile_collector

# Update node_exporter to use textfile collector
grep -q 'textfile' /etc/systemd/system/node_exporter.service || \
    sed -i 's|ExecStart=/usr/local/bin/node_exporter.*|ExecStart=/usr/local/bin/node_exporter --collector.textfile.directory=/var/lib/node_exporter/textfile_collector|' /etc/systemd/system/node_exporter.service

# Make exporter script executable
chmod +x /home/pinodexmr/monerod-exporter.sh

# Install monerod-exporter service
cp /tmp/monerod-exporter.service /etc/systemd/system/monerod-exporter.service

# Reload and restart services
systemctl daemon-reload
systemctl restart node_exporter
systemctl enable monerod-exporter
systemctl start monerod-exporter

echo "=== node_exporter status ==="
systemctl is-active node_exporter
echo "=== monerod-exporter status ==="
systemctl is-active monerod-exporter
echo "=== node_exporter config ==="
grep ExecStart /etc/systemd/system/node_exporter.service
echo "=== Done ==="

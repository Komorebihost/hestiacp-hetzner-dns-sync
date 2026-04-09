#!/bin/bash
set -e
PLUGIN_DIR="/usr/local/hestia/plugins/hetzner-dns"
SERVICE_FILE="/etc/systemd/system/hetzner-dns.service"

for pkg in jq curl inotify-tools; do
    command -v "${pkg/inotify-tools/inotifywait}" &>/dev/null && continue
    echo "Installing $pkg..."
    if command -v apt-get &>/dev/null; then apt-get install -y -q "$pkg" 2>/dev/null || true
    elif command -v yum &>/dev/null;   then yum install -y -q "$pkg" 2>/dev/null || true
    fi
done

mkdir -p "$PLUGIN_DIR/mapping"
chmod 750 "$PLUGIN_DIR/mapping"

if [ ! -f "$PLUGIN_DIR/config.conf" ]; then
    cp "$PLUGIN_DIR/config.conf.example" "$PLUGIN_DIR/config.conf"
    chmod 600 "$PLUGIN_DIR/config.conf"
    echo "→ Edit $PLUGIN_DIR/config.conf and set your HETZNER_API_TOKENS"
fi

chmod 750 "$PLUGIN_DIR/hetzner-dns.sh"
chmod 750 "$PLUGIN_DIR/hetzner-dns-watcher.sh"

touch "$PLUGIN_DIR/hetzner-dns.log"
chmod 640 "$PLUGIN_DIR/hetzner-dns.log"

cp "$PLUGIN_DIR/hetzner-dns.service" "$SERVICE_FILE"
systemctl daemon-reload
systemctl enable hetzner-dns
systemctl start  hetzner-dns

echo "✅ Hetzner DNS Plugin installed."
echo "   Edit: $PLUGIN_DIR/config.conf"
echo "   Then run: $PLUGIN_DIR/hetzner-dns.sh sync_all"
exit 0

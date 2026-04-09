# HestiaCP → Hetzner DNS Sync

Automatically synchronize DNS zones and records from [HestiaCP](https://hestiacp.com) to [Hetzner Cloud DNS](https://www.hetzner.com/dns-console) in real time.

When a DNS record is added, modified, or deleted in HestiaCP, this plugin detects the change via `inotifywait` and immediately syncs the zone to Hetzner — no manual intervention required.

---

## Features

- **Real-time sync** — file watcher detects HestiaCP DNS changes instantly
- **Full record support** — A, AAAA, CNAME, MX, TXT, NS, SRV, CAA, PTR
- **Multi-value RRsets** — correctly groups multiple records of the same type (e.g. multiple MX or A records) into a single Hetzner RRset
- **Subdomain support** — subdomains managed by separate HestiaCP users are synced as prefixed records inside the parent zone (e.g. `shop.example.com` → records `shop`, `www.shop` inside the `example.com` zone)
- **Multi-project support** — configure multiple Hetzner API tokens to manage zones across different projects
- **Automatic zone creation** — zones are created on Hetzner when a new domain is added in HestiaCP
- **Automatic zone deletion** — zones are removed from Hetzner when a domain is deleted in HestiaCP
- **Duplicate-safe** — detects existing RRsets and updates them instead of failing
- **Lock-based debounce** — prevents duplicate syncs when HestiaCP writes a file multiple times in quick succession
- **Compatible** — Ubuntu 20/22/24, Debian 11/12, Rocky Linux / AlmaLinux 8/9

---

## Requirements

- HestiaCP installed and running
- Hetzner Cloud account with DNS zones enabled
- Hetzner API token with **Read & Write** permissions
- `jq`, `curl`, `inotify-tools` (installed automatically by `install.sh`)

---

## Installation

```bash
# 1. Clone the repository
git clone https://github.com/Komorebihost/hestiacp-hetzner-dns-sync
cd hestiacp-hetzner-dns-sync

# 2. Copy files to plugin directory
mkdir -p /usr/local/hestia/plugins/hetzner-dns
cp hetzner-dns.sh hetzner-dns-watcher.sh hetzner-dns.service config.conf.example install.sh \
   /usr/local/hestia/plugins/hetzner-dns/

# 3. Run installer
bash /usr/local/hestia/plugins/hetzner-dns/install.sh

# 4. Configure your API token
nano /usr/local/hestia/plugins/hetzner-dns/config.conf

# 5. Initial sync of all existing zones
/usr/local/hestia/plugins/hetzner-dns/hetzner-dns.sh sync_all
```

---

## Configuration

Edit `/usr/local/hestia/plugins/hetzner-dns/config.conf`:

```bash
# Hetzner API token (required)
HETZNER_API_TOKENS="your_token_here"

# Multiple projects (space-separated) — new zones go to the first token's project
# HETZNER_API_TOKENS="token_project1 token_project2"

# Default TTL for new zones in seconds
DEFAULT_TTL=86400
```

Get your API token at: **Hetzner Cloud Console → Your Project → Security → API Tokens**  
The token must have **Read & Write** permissions.

---

## How It Works

```
HestiaCP DNS change
       │
       ▼
inotifywait detects .conf file write
       │
       ▼
Lock acquired (prevents duplicate syncs)
       │
       ▼  sleep 2s (waits for HestiaCP to finish all writes)
hetzner-dns.sh sync DOMAIN
       │
       ├─ Zone exists on Hetzner? → sync records
       │
       └─ Zone missing? → create zone → sync records
              │
              └─ Records: delete old RRsets → push fresh RRsets from HestiaCP conf
```

### Subdomain logic

If HestiaCP has both `example.com` (user A) and `shop.example.com` (user B):

- `example.com` gets its own Hetzner zone
- Records from `shop.example.com` are synced as `shop`, `www.shop`, `mail.shop`, etc. **inside the `example.com` zone** — no separate zone is created for the subdomain

When `shop.example.com` is modified, only its prefixed records are updated. Records belonging to `example.com` are never touched.

---

## Manual Commands

```bash
ENGINE=/usr/local/hestia/plugins/hetzner-dns/hetzner-dns.sh

# Sync a specific domain
$ENGINE sync example.com

# Sync all domains for a specific user
$ENGINE sync_all username

# Sync all domains on the server
$ENGINE sync_all

# Delete a zone from Hetzner
$ENGINE delete example.com

# Debug: show HestiaCP records and current Hetzner state
$ENGINE debug example.com
```

---

## Service Management

```bash
# Check watcher status
systemctl status hetzner-dns

# View live log
tail -f /usr/local/hestia/plugins/hetzner-dns/hetzner-dns.log

# Restart watcher
systemctl restart hetzner-dns
```

---

## File Structure

```
/usr/local/hestia/plugins/hetzner-dns/
├── hetzner-dns.sh          # Main sync engine
├── hetzner-dns-watcher.sh  # inotifywait file watcher
├── hetzner-dns.service     # systemd unit
├── config.conf             # Your configuration (not in repo)
├── config.conf.example     # Configuration template
├── install.sh              # Installer
├── hetzner-dns.log         # Runtime log
└── mapping/
    ├── zones.json           # Zone ID cache {"domain": {"id": "...", "token": "..."}}
    └── rrsets_DOMAIN.json   # RRset ownership cache per zone
```

---

## Update

To update the plugin without losing your configuration:

```bash
# Download the latest version
git clone https://github.com/Komorebihost/hestiacp-hetzner-dns-sync /tmp/hetzner-dns-update

# Copy only the scripts — config.conf is never overwritten
cp /tmp/hetzner-dns-update/hetzner-dns.sh        /usr/local/hestia/plugins/hetzner-dns/
cp /tmp/hetzner-dns-update/hetzner-dns-watcher.sh /usr/local/hestia/plugins/hetzner-dns/
cp /tmp/hetzner-dns-update/hetzner-dns.service    /usr/local/hestia/plugins/hetzner-dns/
cp /tmp/hetzner-dns-update/install.sh             /usr/local/hestia/plugins/hetzner-dns/

# Set permissions
chmod 750 /usr/local/hestia/plugins/hetzner-dns/hetzner-dns.sh
chmod 750 /usr/local/hestia/plugins/hetzner-dns/hetzner-dns-watcher.sh

# Restart watcher
systemctl restart hetzner-dns

# Cleanup
rm -rf /tmp/hetzner-dns-update
```

> `config.conf` and `mapping/` are **never touched** during an update.


---

## Uninstall

```bash
systemctl stop hetzner-dns
systemctl disable hetzner-dns
rm -f /etc/systemd/system/hetzner-dns.service
systemctl daemon-reload

# Backup is saved automatically to /root/hetzner_dns_bak_TIMESTAMP/
rm -rf /usr/local/hestia/plugins/hetzner-dns
```

---

## Disclaimer

> This plugin is an independent, community-developed tool. It is **not affiliated with, endorsed by, or supported by** Hetzner Online GmbH or HestiaCP.
>
> Use at your own risk. Always keep backups of your DNS configuration before performing bulk sync operations. The authors accept no responsibility for DNS outages, data loss, or misconfiguration resulting from the use of this software.
>
> Hetzner Cloud API usage is subject to [Hetzner's Terms of Service](https://www.hetzner.com/legal/terms-and-conditions).

---

## License

MIT License — © 2024 [Komorebihost](https://komorebihost.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the software, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the software.

**THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.**

---

## Contributing

Issues and pull requests are welcome.  
Repository: [github.com/Komorebihost/hestiacp-hetzner-dns-sync](https://github.com/Komorebihost/hestiacp-hetzner-dns-sync)
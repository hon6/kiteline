# Self-hosted relay

Kiteline's remote access connects your phone and computer peer-to-peer whenever possible and only falls back to a relay when a direct connection can't be made. It uses the Kiteline relay (tars.betac.cn, Shanghai) by default; you can switch to a relay you run yourself, for example on a server closer to you or reachable inside your company network.

A few things up front:

- **Remote access still requires a Kiteline Pro subscription**, with a self-hosted relay too. Everything on the same Wi-Fi is always free.
- The relay only forwards end-to-end encrypted traffic and can't see your sessions. That holds for a self-hosted relay as well.
- The relay software is the official open-source [iroh-relay](https://github.com/n0-computer/iroh) from the iroh project, unmodified.

## What you need

- A Linux server (x86_64 or arm64) with a public IP;
- A domain pointing at it, e.g. `relay.example.com`;
- Open ports: TCP 80 and 443 (relay and certificate issuance), UDP 7842 (helps phones discover their public address, which raises the direct-connection rate).

## 1. Install iroh-relay

The version must match the iroh version Kiteline uses, currently **v1.3.0** (upgrades are noted in the changelog). Download `iroh-relay-v1.3.0-<arch>-unknown-linux-gnu.tar.gz` for your architecture from [the iroh release page](https://github.com/n0-computer/iroh/releases/tag/v1.3.0), check its SHA-256 against the page, then unpack it:

```bash
sudo install -m 755 iroh-relay /usr/local/bin/iroh-relay
sudo useradd --system --home-dir /var/lib/iroh-relay --shell /usr/sbin/nologin iroh-relay
sudo install -d -o iroh-relay -g iroh-relay /var/lib/iroh-relay /etc/iroh-relay
```

## 2. Configure

`/etc/iroh-relay/relay.toml` (use your own domain and email):

```toml
enable_relay = true
http_bind_addr = "[::]:80"
# Helps phones discover their public address (UDP 7842) for more direct connections
enable_quic_addr_discovery = true
# Metrics don't need to be exposed
enable_metrics = false

[tls]
# The relay gets and renews its own Let's Encrypt certificate
cert_mode = "LetsEncrypt"
hostname = "relay.example.com"
contact = "you@example.com"
cert_dir = "/var/lib/iroh-relay/certs"
```

## 3. Run it as a service

`/etc/systemd/system/iroh-relay.service`:

```ini
[Unit]
Description=iroh relay
After=network-online.target
Wants=network-online.target

[Service]
User=iroh-relay
Group=iroh-relay
WorkingDirectory=/var/lib/iroh-relay
ExecStart=/usr/local/bin/iroh-relay --config-path /etc/iroh-relay/relay.toml
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/iroh-relay
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now iroh-relay
```

The first start requests a certificate. After a moment, check:

```bash
curl -I https://relay.example.com/ping     # 200 means it's working
```

If nginx already uses ports 80 and 443 on the server, let the relay listen on a local port and have nginx forward to it (WebSocket upgrade on, buffering off); see the iroh-relay documentation.

## 4. Point Kiteline at your relay

- **Mac**: Settings → Remote Access → Relay server: enter `https://relay.example.com` and click Apply.
- **Windows / Linux**: Settings → Remote Access → Relay server: enter it the same way and click Apply.

Nothing to change on the phone: it switches to the relay your computer uses the next time it connects. Clear the field to go back to the Kiteline relay.

## FAQ

**Can a self-hosted relay see my sessions?** No. It only forwards encrypted traffic; the keys stay on your phone and computer.

**Do I still need a subscription?** Yes. Remote access is a Kiteline Pro feature, whichever relay you use.

**What if the relay goes down?** Everything on the same Wi-Fi keeps working. Away from it, devices that can connect directly still do; others can't connect until the relay is back, and then reconnect automatically.

# 自建中继

Kiteline 的远程访问优先让手机和电脑点对点直连；连不上时，才经中继转发。默认用 Kiteline 中继（tars.betac.cn，上海），你也可以换成自己部署的中继，比如放在离你更近、或公司内网能访问的服务器上。

几点先说清楚：

- **远程访问仍需要 Kiteline Pro 订阅**，换成自建中继也一样；同一 Wi-Fi 下的全部功能始终免费。
- 中继只转发端到端加密的数据，看不到会话内容；自建中继同样如此。
- 中继软件用的是 iroh 官方开源的 [iroh-relay](https://github.com/n0-computer/iroh)，Kiteline 没有改动它。

## 需要准备

- 一台有公网 IP 的 Linux 服务器（x86_64 或 arm64）；
- 一个指向这台服务器的域名，例如 `relay.example.com`；
- 开放端口：TCP 80、443（中继和申请证书），UDP 7842（帮手机识别自己的公网地址，提高直连成功率）。

## 1. 安装 iroh-relay

版本要和 Kiteline 使用的 iroh 一致，目前是 **v1.3.0**（以后升级会写在更新记录里）。到 [iroh 的发布页](https://github.com/n0-computer/iroh/releases/tag/v1.3.0) 下载对应架构的 `iroh-relay-v1.3.0-<架构>-unknown-linux-gnu.tar.gz`，核对页面上的 SHA-256 后解压：

```bash
sudo install -m 755 iroh-relay /usr/local/bin/iroh-relay
sudo useradd --system --home-dir /var/lib/iroh-relay --shell /usr/sbin/nologin iroh-relay
sudo install -d -o iroh-relay -g iroh-relay /var/lib/iroh-relay /etc/iroh-relay
```

## 2. 写配置

`/etc/iroh-relay/relay.toml`（把域名和邮箱换成你自己的）：

```toml
enable_relay = true
http_bind_addr = "[::]:80"
# 帮手机认出自己的公网地址（UDP 7842），提高直连率
enable_quic_addr_discovery = true
# 不需要对外开放监控指标
enable_metrics = false

[tls]
# 证书由中继自己向 Let's Encrypt 申请、自动续
cert_mode = "LetsEncrypt"
hostname = "relay.example.com"
contact = "you@example.com"
cert_dir = "/var/lib/iroh-relay/certs"
```

## 3. 作为系统服务运行

`/etc/systemd/system/iroh-relay.service`：

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

第一次启动会申请证书，稍等一会儿后检查：

```bash
curl -I https://relay.example.com/ping     # 返回 200 即正常
```

服务器上 80 / 443 已经被 nginx 占用时，可以让中继只监听本机端口，由 nginx 转发（需要支持 WebSocket 升级、关闭缓冲）；做法见 iroh-relay 的文档。

## 4. 在 Kiteline 里改用自建中继

- **Mac**：设置 → 远程访问 → 中继服务器，填 `https://relay.example.com`，点「应用」；
- **Windows / Linux**：设置 → 远程访问 → 中继服务器，同样填写后点「应用」。

手机不用改，下次连接时会自动切换到电脑设置的中继。清空这一栏即恢复使用 Kiteline 中继。

## 常见问题

**自建中继能看到我的会话吗？** 看不到。中继只转发加密数据，密钥只在手机和电脑上。

**还需要订阅吗？** 需要。远程访问是 Kiteline Pro 的功能，用哪个中继都一样。

**中继挂了会怎样？** 同一 Wi-Fi 下照常使用；在外面时，能直连的照样直连，直连不了的会连不上，恢复后自动重连。

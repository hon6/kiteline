# 远程访问

[English](remote-access.md)

## 同一个网络里

手机和电脑连同一个 Wi-Fi 时，手机自动找到电脑，直接走 HTTPS 连接。电脑有自己的根证书，配对时手机锁定它的指纹。不经过 Kiteline 的服务器，全部功能免费。

## 在别的网络

在电脑上打开「远程访问」，手机在同一个网络里打开一次 iPhone App 完成绑定。之后在任何网络：

1. 先尝试点对点直连：基于 [iroh](https://github.com/n0-computer/iroh) 的 QUIC，UDP 打洞；
2. 打不通时才经 Kiteline 中继转发（tars.betac.cn，上海）。

两种方式都是端到端加密：中继看不到内容，不存储，也不记录 IP 地址。Wi-Fi 和移动网络之间切换，连接不断。不需要公网 IP、自己的服务器或开放端口。也可以用自己部署的中继，见[自建中继](self-hosted-relay.zh-CN.md)。

远程访问需要订阅 **Kiteline Pro**（按月或按年，价格见 App Store），用来支付中继服务器的费用。

## 通知

通知在电脑上先用 Web Push（RFC 8291）加密再发出，推送网关和 Apple 只能看到密文，由手机解密。

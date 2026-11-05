# Remote access

[简体中文](remote-access.zh-CN.md)

## On the same network

When your phone and computer are on the same Wi-Fi, the phone finds the computer automatically and connects directly over HTTPS. The computer has its own certificate authority, and the phone pins its fingerprint at pairing. Nothing goes through Kiteline's servers. Every feature is free.

## From another network

Turn on **Remote Access** on the computer, then open the iPhone app once while it's on the same network to bind it. After that, from any network:

1. Kiteline first tries a direct peer-to-peer connection: QUIC over [iroh](https://github.com/n0-computer/iroh), with UDP hole punching.
2. Only if that fails does traffic pass through the Kiteline relay (tars.betac.cn, Shanghai).

Either way, everything is end-to-end encrypted. The relay can't read the traffic, doesn't store it and doesn't log IP addresses. Moving from Wi-Fi to cellular keeps the connection alive. You don't need a public IP, a server of your own or an open port. Self-hosted relays are supported.

Remote access requires a **Kiteline Pro** subscription, monthly or annual, priced on the App Store. It pays for the relay servers.

## Notifications

Notifications are encrypted on your computer with Web Push (RFC 8291) before they leave it. The push gateway and Apple only ever see ciphertext; the phone decrypts them.

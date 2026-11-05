# Install and first run

[简体中文](install.zh-CN.md)

## What you need

| | |
|---|---|
| Mac | macOS 14 or later, Apple silicon or Intel. The app is notarized by Apple. |
| Windows | Windows 10 or 11, 64-bit. |
| Linux | x86_64, X11 or Wayland, Python 3.10 or later. |
| Phone | iPhone or iPad with iOS / iPadOS 18 or later. Apple Watch with watchOS 10 or later. |

## Install on your computer

### One command

```bash
# macOS and Linux
curl -fsSL https://tars.betac.cn/install.sh | sh
```

```powershell
# Windows (PowerShell)
irm https://tars.betac.cn/install.ps1 | iex
```

The script downloads the latest release from tars.betac.cn, checks it against the published SHA-256 checksum, then:

- **Mac**: copies Kiteline.app into Applications (your own `~/Applications` if you can't write to the system one) and opens it. If Kiteline is running, it quits it first.
- **Windows**: unpacks it into `%LOCALAPPDATA%\Programs\Kiteline`, adds a Start menu shortcut and opens it.
- **Linux**: runs the bundled `install.sh`, which installs into `~/.local/share/kiteline` with its own Python virtual environment, adds the `kiteline` command and a menu entry, and starts Kiteline when you log in.

Run the same command again at any time to install the latest version.

### Package managers

```bash
# macOS (Homebrew)
brew install --cask hon6/kiteline/kiteline
```

```powershell
# Windows (Scoop)
scoop bucket add kiteline https://github.com/hon6/scoop-kiteline
scoop install kiteline
```

### Linux server without a desktop

```bash
curl -fsSL https://tars.betac.cn/install.sh | sh -s -- --service
```

This installs Kiteline as a systemd user service that starts with the machine. Read the pairing code with `journalctl --user -u kiteline -n 20`.

### Installer instead

Download from [tars.betac.cn](https://tars.betac.cn/en/) or [GitHub Releases](https://github.com/hon6/kiteline/releases):

- **Mac**: open the disk image and drag Kiteline into Applications.
- **Windows**: unzip and run `Kiteline.exe`. If SmartScreen appears on first launch, choose **More info → Run anyway**.
- **Linux**: extract the archive and run `./install.sh` in the Kiteline folder.

## First run

Kiteline opens a **readiness check** that lists anything still missing and explains what each permission is for. On the Mac this includes Device Control and Data Access, which Kiteline uses to submit your messages and confirmations in VS Code. On Linux it may ask for tmux and keyboard access for VS Code.

Keep the computer on and online while you're away: turn off automatic sleep. The readiness check watches for this too.

## Pair your phone

1. Install Kiteline from the [App Store](https://apps.apple.com/app/id6825244029) and allow Local Network access. The Apple Watch app installs alongside.
2. Open **Phone Access** on the computer: the menu bar icon on the Mac, the tray icon or the main window on Windows and Linux.
3. Scan the QR code, or type the 6-digit code. Codes expire after 10 minutes and work once.

No account is needed. Your existing agent sessions appear on the phone right away.

## Sessions on a Remote-SSH host

Claude Code sessions in VS Code Remote-SSH windows are followed over the same SSH connection. The host needs key-based SSH and Python 3.8 or later; Kiteline deploys a small read-only watcher that uses only the standard library. Terminal sessions on the host need to run inside tmux to accept replies from your phone.

## Updates

The desktop app checks for new versions. When one is available, an arrow appears in the top-right corner: confirm, and it downloads and installs in the background, then asks you to restart. The phone app updates through the App Store, and each side reminds you when the other is out of date.

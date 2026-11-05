# 安装与首次使用

[English](install.md)

## 需要什么

| | |
|---|---|
| Mac | macOS 14 及以上，Apple 芯片或 Intel 均可；已通过 Apple 公证 |
| Windows | Windows 10 或 11，64 位 |
| Linux | x86_64，X11 或 Wayland，Python 3.10 及以上 |
| 手机 | iPhone、iPad：iOS / iPadOS 18 及以上；Apple Watch：watchOS 10 及以上 |

## 在电脑上安装

### 一行命令

```bash
# macOS、Linux
curl -fsSL https://tars.betac.cn/install.sh | sh
```

```powershell
# Windows（PowerShell）
irm https://tars.betac.cn/install.ps1 | iex
```

脚本从 tars.betac.cn 下载最新版，按官网公布的 SHA-256 校验，然后：

- **Mac**：把 Kiteline.app 拷进「应用程序」（没有写权限时装到自己的 `~/Applications`）并打开；Kiteline 正在运行的话先退出它。
- **Windows**：解压到 `%LOCALAPPDATA%\Programs\Kiteline`，在开始菜单建快捷方式并打开。
- **Linux**：运行包里的 `install.sh`，装到 `~/.local/share/kiteline`（自带 Python 虚拟环境），添加 `kiteline` 命令和菜单项，登录时自动启动。

想装最新版时，再运行一次同样的命令即可。

### 包管理器

```bash
# macOS（Homebrew）
brew install --cask hon6/kiteline/kiteline
```

```powershell
# Windows（Scoop）
scoop bucket add kiteline https://github.com/hon6/scoop-kiteline
scoop install kiteline
```

### 没有图形界面的 Linux 服务器

```bash
curl -fsSL https://tars.betac.cn/install.sh | sh -s -- --service
```

装成 systemd 用户服务，开机自动启动。配对码用 `journalctl --user -u kiteline -n 20` 查看。

### 用安装包

到[官网](https://tars.betac.cn)或 [GitHub Releases](https://github.com/hon6/kiteline/releases) 下载：

- **Mac**：打开安装包，把 Kiteline 拖进「应用程序」。
- **Windows**：解压后运行 `Kiteline.exe`；首次运行如出现 SmartScreen 提示，选「更多信息 → 仍要运行」。
- **Linux**：解压后在 Kiteline 目录里运行 `./install.sh`。

## 首次使用

Kiteline 会打开「就绪检查」，列出还缺的组件和权限，并说明每一项的用途。Mac 上包括「设备控制和数据访问」，用于在 VS Code 里提交你的消息和确认操作；Linux 上可能需要装 tmux、开启 VS Code 的键盘模拟权限。

人离开时电脑要开着、联着网：请关闭自动睡眠，就绪检查也会提醒。

## 配对手机

1. 在 [App Store](https://apps.apple.com/app/id6825244029) 下载 Kiteline，允许访问本地网络；Apple Watch App 随之安装。
2. 在电脑上打开「手机访问」：Mac 上点菜单栏图标，Windows、Linux 上点托盘图标或主窗口。
3. 扫二维码，或输入 6 位配对码。配对码 10 分钟内有效，只能用一次。

不用注册账号。电脑上已有的 Agent 会话会马上出现在手机上。

## Remote-SSH 远端上的会话

VS Code Remote-SSH 窗口里的 Claude Code 会话，通过同一条 SSH 连接跟随。远端需要能用密钥登录 SSH、装有 Python 3.8 及以上；Kiteline 会部署一个只用标准库的只读监听脚本。远端终端里的会话要能从手机回复，需要跑在 tmux 里。

## 更新

电脑端会自己检查新版本，有新版时右上角出现箭头：确认后在后台下载安装，再提示重启。手机端通过 App Store 更新；任何一端落后时，另一端都会提醒。

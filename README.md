# AmneziaVPN Setup for Void Linux

<p align="center">
  <b>English</b> | <b><a href="README.ru.md">Русский</a></b>
</p>

Installation script and system components to run the official desktop client **AmneziaVPN** (Qt6 GUI + `AmneziaVPN-service` daemon) on **Void Linux** (glibc x86_64, `runit` init system, without `systemd` or `systemd-resolved`).

---

## Architecture & Solution Overview

The official AmneziaVPN client is tightly coupled with `systemd` and `systemd-resolved`. To provide seamless and native operation on Void Linux with runit, this project implements:

1. **Installer Shim:** Bypasses installer requirements by providing a dummy `systemctl` stub during the execution of the official `.run` installer (Qt Installer Framework).
2. **D-Bus DNS Bridge (`amnezia-dns-bridge`):**
   - A Python daemon implementing the `org.freedesktop.resolve1` interface on the D-Bus system bus (`SetLinkDNS`, `SetLinkDNSEx`, `SetLinkDomains`, `RevertLink`, `RevertLinkDNS`).
   - Intercepts DNS configuration requests from AmneziaVPN and translates them into `openresolv` (`resolvconf -a amnezia-vpn -x -m 0`) in exclusive mode, preventing DNS leaks.
   - Passes search domains for seamless domain resolution across private subnets.
   - Supports multiple protocol tunnel interfaces: **AmneziaWG (`awg*`)**, **WireGuard (`wg*`)**, **OpenVPN (`tun*`)**, `tap*`, `amn*`, `ppp*`, `vpn*`.
   - Built-in **Kernel Watchdog**: Periodically monitors network interface states and automatically flushes DNS configuration upon unexpected tunnel drops or disconnects.
3. **D-Bus Security:** Isolated security policy in `/etc/dbus-1/system.d/org.freedesktop.resolve1.conf` restricted to `root`.
4. **Runit Services:** Automated service definitions for `AmneziaVPN` and `amnezia-dns-bridge` under `/etc/sv/` with integrated streaming logs and rotation via `svlogd`.
5. **Desktop Integration:** Symlinks in `/usr/local/bin`, XDG `.desktop` launcher registration, and system icon placement.

---

## Repository Structure

```text
.
├── install_amnezia_void.sh     # Automated installation script
├── uninstall_amnezia_void.sh   # Complete uninstallation script
├── assets/
│   └── AmneziaVPN.png          # Official application icon
├── src/
│   └── amnezia-dns-bridge.py   # D-Bus DNS Bridge (org.freedesktop.resolve1)
├── conf/
│   ├── org.freedesktop.resolve1.conf  # D-Bus security policy
│   └── AmneziaVPN.desktop             # XDG desktop launcher
└── services/
    ├── AmneziaVPN/             # Runit service for AmneziaVPN-service (+ svlogd)
    │   ├── run
    │   └── log/run
    └── amnezia-dns-bridge/     # Runit service for DNS bridge (+ svlogd)
        ├── run
        └── log/run
```

---

## System Dependencies

The installation script automatically installs required packages via `xbps-install`:

- **Networking & Utilities:** `curl`, `wireguard-tools`, `openvpn`, `openresolv`, `iptables`, `iproute2`
- **DNS Bridge & D-Bus:** `dbus`, `python3`, `python3-dbus`, `python3-gobject`, `procps-ng`
- **GUI Environment & Qt6:** `libsecret`, `libglvnd`, `libxcb`, `xcb-util-cursor`, `xcb-util-wm`, `xcb-util-keysyms`, `xcb-util-image`, `xcb-util-renderutil`, `libxkbcommon`, `libxkbcommon-x11`
- **Kernel:** `tun` module (`modprobe tun`)

---

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/yar101/amnezia-vpn-setup-for-void-linux.git
   cd amnezia-vpn-setup-for-void-linux
   ```

2. Make scripts executable:
   ```bash
   chmod +x install_amnezia_void.sh uninstall_amnezia_void.sh
   ```

3. Run the installer:
   ```bash
   ./install_amnezia_void.sh
   ```

   > [!NOTE]
   > If the `AmneziaVPN_*_linux_x64.run` installer package is not present in the directory, the script will automatically fetch the latest release from GitHub Releases.
   > You can specify a specific version as an argument: `./install_amnezia_void.sh 5.0.0.5`

---

## Usage and Service Management (runit)

Once installation finishes, both `AmneziaVPN` and `amnezia-dns-bridge` services are **automatically registered and started**.

### 1. Check Service Status
```bash
sudo sv status amnezia-dns-bridge AmneziaVPN
```

### 2. Launching the GUI
Launch AmneziaVPN from your desktop application menu or run from a terminal:
```bash
AmneziaVPN
```

### 3. Service Control
- **Stop services:**
  ```bash
  sudo sv down AmneziaVPN amnezia-dns-bridge
  ```
- **Start services:**
  ```bash
  sudo sv up AmneziaVPN amnezia-dns-bridge
  ```
- **Disable autostart:**
  ```bash
  sudo rm /var/service/AmneziaVPN /var/service/amnezia-dns-bridge
  ```

---

## Logging and Diagnostics

- **VPN Service logs:**
  ```bash
  tail -f /var/log/AmneziaVPN/current
  ```
- **DNS Bridge logs:**
  ```bash
  tail -f /var/log/amnezia-dns-bridge/current
  ```
- **Inspect active openresolv DNS records:**
  ```bash
  resolvconf -l
  ```
- **Manually flush VPN DNS (if needed):**
  ```bash
  sudo resolvconf -f -d amnezia-vpn && sudo resolvconf -u
  ```

---

## Troubleshooting

1. **GUI displays: "AmneziaVPN service is not running" / "Service connection failed":**
   - Check the runit service status:
     ```bash
     sudo sv status AmneziaVPN
     ```
   - Check the logs in `/var/log/AmneziaVPN/current`.

2. **DNS names do not resolve after connecting:**
   - Verify that `amnezia-dns-bridge` service is active:
     ```bash
     sudo sv status amnezia-dns-bridge
     ```
   - Check `/etc/resolv.conf` and the output of `resolvconf -l`. An active tunnel should show a `nameserver` entry associated with `amnezia-vpn`.

3. **Conflicts with NetworkManager / dhcpcd:**
   - `openresolv` dynamically manages DNS configurations. The DNS configuration created for `amnezia-vpn` sets the exclusive flag (`-x`) and highest metric priority (`-m 0`), preventing queries from leaking via local network adapter resolvers.

---

## Uninstallation

To completely remove AmneziaVPN, runit services, the DNS bridge, and desktop entries:
```bash
./uninstall_amnezia_void.sh
```

For unattended / automated uninstallation without interactive prompts:
```bash
./uninstall_amnezia_void.sh -y
```

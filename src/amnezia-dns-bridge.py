#!/usr/bin/env python3
"""
amnezia-dns-bridge: D-Bus shim providing org.freedesktop.resolve1 on Void Linux / non-systemd systems.
Translates AmneziaVPN SetLinkDNS calls directly into openresolv updates.
Includes kernel interface watchdog and exclusive DNS routing to prevent DNS leaks.
Supports AmneziaWG (awg), OpenVPN (tun), WireGuard (wg), and other tunnel interfaces.
"""
import os
import signal
import socket
import subprocess
import sys
import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

# Нативная интеграция сигналов с GLib MainLoop
try:
    from gi.repository import GLibUnix
    unix_signal_add = GLibUnix.signal_add
except ImportError:
    unix_signal_add = getattr(GLib, "unix_signal_add", None)

# Настройка небуферизованного вывода для корректного логирования в svlogd
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(line_buffering=True)
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(line_buffering=True)

RESOLVE_SERVICE = "org.freedesktop.resolve1"
RESOLVE_PATH = "/org/freedesktop/resolve1"
RESOLVE_MANAGER_IFACE = "org.freedesktop.resolve1.Manager"

TUNNEL_PREFIXES = ("tun", "amn", "awg", "wg", "tap", "ppp", "vpn")


class ResolveManager(dbus.service.Object):
    def __init__(self, bus_name):
        super().__init__(bus_name, RESOLVE_PATH)
        self.link_dns = {}
        self.link_domains = {}

    def _parse_resolvers(self, resolvers):
        ips = []
        for item in resolvers:
            try:
                family = item[0]
                raw_addr = bytes(item[1])
                if family == socket.AF_INET and len(raw_addr) == 4:
                    ips.append(socket.inet_ntop(socket.AF_INET, raw_addr))
                elif family == socket.AF_INET6 and len(raw_addr) == 16:
                    ips.append(socket.inet_ntop(socket.AF_INET6, raw_addr))
            except Exception as e:
                print(f"[DNS Bridge] Ошибка разбора IP: {e}")
        return ips

    def _parse_resolvers_ex(self, resolvers):
        ips = []
        for item in resolvers:
            try:
                family = item[0]
                raw_addr = bytes(item[1])
                # item[2] is port (uint16), item[3] is server_name (string)
                if family == socket.AF_INET and len(raw_addr) == 4:
                    ips.append(socket.inet_ntop(socket.AF_INET, raw_addr))
                elif family == socket.AF_INET6 and len(raw_addr) == 16:
                    ips.append(socket.inet_ntop(socket.AF_INET6, raw_addr))
            except Exception as e:
                print(f"[DNS Bridge] Ошибка разбора IP (Ex): {e}")
        return ips

    @dbus.service.method(RESOLVE_MANAGER_IFACE, in_signature='ia(iay)', out_signature='')
    def SetLinkDNS(self, ifindex, resolvers):
        ifindex = int(ifindex)
        print(f"[DNS Bridge] SetLinkDNS для интерфейса #{ifindex}")
        ips = self._parse_resolvers(resolvers)
        if ips:
            print(f"[DNS Bridge] Установка DNS серверов для #{ifindex}: {ips}")
            self.link_dns[ifindex] = ips
        else:
            print(f"[DNS Bridge] Очистка DNS серверов для #{ifindex}")
            self.link_dns.pop(ifindex, None)
        self.apply_dns()

    @dbus.service.method(RESOLVE_MANAGER_IFACE, in_signature='ia(iayqs)', out_signature='')
    def SetLinkDNSEx(self, ifindex, resolvers):
        ifindex = int(ifindex)
        print(f"[DNS Bridge] SetLinkDNSEx для интерфейса #{ifindex}")
        ips = self._parse_resolvers_ex(resolvers)
        if ips:
            print(f"[DNS Bridge] Установка DNS серверов (Ex) для #{ifindex}: {ips}")
            self.link_dns[ifindex] = ips
        else:
            print(f"[DNS Bridge] Очистка DNS серверов (Ex) для #{ifindex}")
            self.link_dns.pop(ifindex, None)
        self.apply_dns()

    @dbus.service.method(RESOLVE_MANAGER_IFACE, in_signature='ia(sb)', out_signature='')
    def SetLinkDomains(self, ifindex, domains):
        ifindex = int(ifindex)
        dom_list = [(str(d), bool(s)) for d, s in domains]
        print(f"[DNS Bridge] SetLinkDomains для #{ifindex}: {dom_list}")
        if dom_list:
            self.link_domains[ifindex] = dom_list
        else:
            self.link_domains.pop(ifindex, None)
        self.apply_dns()

    @dbus.service.method(RESOLVE_MANAGER_IFACE, in_signature='ib', out_signature='')
    def SetLinkDefaultRoute(self, ifindex, enable):
        pass

    @dbus.service.method(RESOLVE_MANAGER_IFACE, in_signature='is', out_signature='')
    def SetLinkLLMNR(self, ifindex, mode):
        pass

    @dbus.service.method(RESOLVE_MANAGER_IFACE, in_signature='is', out_signature='')
    def SetLinkMulticastDNS(self, ifindex, mode):
        pass

    @dbus.service.method(RESOLVE_MANAGER_IFACE, in_signature='is', out_signature='')
    def SetLinkDNSSEC(self, ifindex, mode):
        pass

    @dbus.service.method(RESOLVE_MANAGER_IFACE, in_signature='is', out_signature='')
    def SetLinkRoutingPolicy(self, ifindex, mode):
        pass

    @dbus.service.method(RESOLVE_MANAGER_IFACE, in_signature='i', out_signature='')
    def RevertLinkDNS(self, ifindex):
        ifindex = int(ifindex)
        print(f"[DNS Bridge] RevertLinkDNS для интерфейса #{ifindex}")
        if self.link_dns.pop(ifindex, None) is not None:
            self.apply_dns()

    @dbus.service.method(RESOLVE_MANAGER_IFACE, in_signature='i', out_signature='')
    def RevertLinkDomains(self, ifindex):
        ifindex = int(ifindex)
        print(f"[DNS Bridge] RevertLinkDomains для интерфейса #{ifindex}")
        if self.link_domains.pop(ifindex, None) is not None:
            self.apply_dns()

    @dbus.service.method(RESOLVE_MANAGER_IFACE, in_signature='i', out_signature='')
    def RevertLink(self, ifindex):
        ifindex = int(ifindex)
        print(f"[DNS Bridge] RevertLink для интерфейса #{ifindex}")
        removed_dns = self.link_dns.pop(ifindex, None)
        removed_dom = self.link_domains.pop(ifindex, None)
        if removed_dns is not None or removed_dom is not None:
            self.apply_dns()

    @dbus.service.method(RESOLVE_MANAGER_IFACE, in_signature='', out_signature='')
    def FlushCaches(self):
        print("[DNS Bridge] FlushCaches вызван (no-op)")

    @dbus.service.method(RESOLVE_MANAGER_IFACE, in_signature='', out_signature='')
    def ResetServerFeatures(self):
        print("[DNS Bridge] ResetServerFeatures вызван (no-op)")

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature='ss', out_signature='v')
    def Get(self, interface_name, property_name):
        if property_name == "Domains":
            domains_list = []
            for ifidx, dlist in self.link_domains.items():
                for dom, search_domain in dlist:
                    domains_list.append((dbus.Int32(ifidx), dbus.String(dom), dbus.Boolean(search_domain)))
            return dbus.Array(domains_list, signature='(isb)')
        return ""

    def apply_dns(self):
        vpn_ips = []
        other_ips = []
        for ifidx, ips in self.link_dns.items():
            ifname = ""
            try:
                ifname = socket.if_indextoname(ifidx)
            except OSError:
                pass

            is_tunnel = any(ifname.startswith(pfx) for pfx in TUNNEL_PREFIXES)
            for ip in ips:
                if is_tunnel:
                    if ip not in vpn_ips:
                        vpn_ips.append(ip)
                else:
                    if ip not in other_ips:
                        other_ips.append(ip)

        # Туннельные VPN DNS идут первыми для предотвращения DNS Leak
        all_ips = vpn_ips + [ip for ip in other_ips if ip not in vpn_ips]

        # Сбор search domains (только реальные поисковые домены, исключая routing-only маркера вроде '~.')
        search_domains = []
        for dlist in self.link_domains.values():
            for dom, is_search in dlist:
                clean_dom = dom.strip().lstrip('~.')
                # В resolv.conf добавляются только домены с флагом поиска (не routing-only)
                if is_search and not dom.strip().startswith('~') and clean_dom and clean_dom not in search_domains:
                    search_domains.append(clean_dom)

        if all_ips:
            resolv_lines = ["# Generated by amnezia-dns-bridge"]
            for ip in all_ips:
                resolv_lines.append(f"nameserver {ip}")
            if search_domains:
                resolv_lines.append(f"search {' '.join(search_domains)}")
            resolv_data = "\n".join(resolv_lines) + "\n"

            try:
                proc = subprocess.run(
                    ["resolvconf", "-a", "amnezia-vpn", "-x", "-m", "0"],
                    input=resolv_data.encode(),
                    capture_output=True,
                    check=False,
                )
                if proc.returncode == 0:
                    print(f"[DNS Bridge] DNS успешно применен через resolvconf: {all_ips} (domains: {search_domains})")
                else:
                    print(f"[DNS Bridge] Предупреждение resolvconf (код {proc.returncode}): {proc.stderr.decode().strip()}")
            except FileNotFoundError:
                print("[DNS Bridge] Утилита resolvconf не найдена! Установите пакет openresolv.")
        else:
            try:
                subprocess.run(["resolvconf", "-f", "-d", "amnezia-vpn"], capture_output=True, check=False)
                print("[DNS Bridge] Записи DNS для amnezia-vpn удалены из resolvconf.")
            except FileNotFoundError:
                pass

    def cleanup(self):
        self.link_dns.clear()
        self.link_domains.clear()
        self.apply_dns()

    def check_interfaces(self):
        """Watchdog: проверяет, живы ли интерфейсы. Если VPN туннель закрыт, автоматически сбрасывает DNS."""
        if not self.link_dns and not self.link_domains:
            return True
        changed = False
        for ifidx in list(self.link_dns.keys()):
            try:
                socket.if_indextoname(ifidx)
            except OSError:
                print(f"[DNS Bridge] Интерфейс #{ifidx} удален/закрыт. Автоматический сброс DNS...")
                self.link_dns.pop(ifidx, None)
                self.link_domains.pop(ifidx, None)
                changed = True

        for ifidx in list(self.link_domains.keys()):
            if ifidx not in self.link_dns:
                try:
                    socket.if_indextoname(ifidx)
                except OSError:
                    self.link_domains.pop(ifidx, None)
                    changed = True

        if changed:
            self.apply_dns()
        return True


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    try:
        bus = dbus.SystemBus()
    except Exception as e:
        print(f"[DNS Bridge] Ошибка подключения к системной шине D-Bus: {e}")
        sys.exit(1)

    try:
        bus_name = dbus.service.BusName(RESOLVE_SERVICE, bus, do_not_queue=True)
    except dbus.exceptions.NameExistsException:
        print(f"[DNS Bridge] Ошибка: имя {RESOLVE_SERVICE} уже зарегистрировано другим процессом на D-Bus!")
        sys.exit(1)
    except Exception as e:
        print(f"[DNS Bridge] Не удалось зарегистрировать имя {RESOLVE_SERVICE} на D-Bus: {e}")
        sys.exit(1)

    manager = ResolveManager(bus_name)
    loop = GLib.MainLoop()

    # Запуск периодического watchdog каждые 2 секунды
    GLib.timeout_add_seconds(2, manager.check_interfaces)

    def handle_signal(*args):
        print("\n[DNS Bridge] Получен сигнал остановки, восстановление DNS...")
        manager.cleanup()
        loop.quit()
        return False

    # Регистрация сигналов ОС: предпочтительно через GLibUnix для нативной интеграции с GLib.MainLoop
    if unix_signal_add is not None:
        unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGTERM, handle_signal)
        unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGINT, handle_signal)
        unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGHUP, handle_signal)
    else:
        signal.signal(signal.SIGTERM, lambda s, f: handle_signal())
        signal.signal(signal.SIGINT, lambda s, f: handle_signal())
        signal.signal(signal.SIGHUP, lambda s, f: handle_signal())

    print("[DNS Bridge] D-Bus DNS-мост успешно запущен и ожидает запросов.")
    try:
        loop.run()
    except (KeyboardInterrupt, SystemExit):
        manager.cleanup()


if __name__ == "__main__":
    main()

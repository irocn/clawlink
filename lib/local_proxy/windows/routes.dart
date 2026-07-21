import 'package:flutter/foundation.dart';

import 'process.dart';

/// OS routes for local proxy (iedux-style bypass + tunneled DNS).
class WindowsRoutes {
  final List<String> _activeBypassIps = [];
  int _tunnelIfIndex = 0;
  String? _tunnelAlias;

  int get tunnelIfIndex => _tunnelIfIndex;

  /// RFC 2544 fake-IP space — never install as LAN bypass (iedux RoutingService).
  static bool isFakeIpTunnelIpv4(String ip) {
    final parts = ip.trim().split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;
    return a == 198 && (b == 18 || b == 19);
  }

  static String endpointHost(String endpoint) {
    final ep = endpoint.trim();
    if (ep.isEmpty) return '';
    if (ep.startsWith('[')) {
      final end = ep.indexOf(']');
      if (end > 1) return ep.substring(1, end);
    }
    final colon = ep.lastIndexOf(':');
    if (colon > 0 && ep.contains('.')) return ep.substring(0, colon);
    if (colon > 0 && int.tryParse(ep.substring(colon + 1)) != null) {
      return ep.substring(0, colon);
    }
    return ep;
  }

  static bool isIpv4(String host) {
    final p = host.split('.');
    if (p.length != 4) return false;
    for (final o in p) {
      final n = int.tryParse(o);
      if (n == null || n < 0 || n > 255) return false;
    }
    return true;
  }

  /// Resolve Wintun / ClawLink / itunnel adapter ifIndex + alias.
  Future<({int ifIndex, String alias})?> resolveTunnel(String ifaceAlias) async {
    final alias = ifaceAlias.trim();
    final script = '''
\$ProgressPreference = 'SilentlyContinue'
\$a = \$null
if (${WinProcess.q(alias)} -ne '') {
  \$a = Get-NetAdapter -Name ${WinProcess.q(alias)} -ErrorAction SilentlyContinue |
    Where-Object { \$_.Status -eq 'Up' } | Select-Object -First 1
}
if (-not \$a) {
  \$a = Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object {
      \$_.InterfaceDescription -like '*Wintun*' -or
      \$_.Name -like '*Claw*' -or \$_.Name -like '*claw*' -or
      \$_.Name -eq 'itunnel'
    } | Where-Object { \$_.Status -eq 'Up' } | Select-Object -First 1
}
if (\$a) { Write-Output ("{0}|{1}" -f \$a.ifIndex, \$a.Name) }
''';
    final out = await WinProcess.powershell(script);
    if (out == null) return null;
    final line = out.trim().split(RegExp(r'\r?\n')).lastWhere(
          (l) => l.contains('|'),
          orElse: () => '',
        );
    final parts = line.split('|');
    if (parts.length != 2) return null;
    final idx = int.tryParse(parts[0].trim());
    final name = parts[1].trim();
    if (idx == null || idx <= 0 || name.isEmpty) return null;
    _tunnelIfIndex = idx;
    _tunnelAlias = name;
    return (ifIndex: idx, alias: name);
  }

  /// Physical default IPv4 route (lowest metric), excluding tunnel ifIndex.
  /// Like iedux `_fetchDefaultRouteInfo`, plus exclude TUN.
  Future<({int ifIndex, String gateway})?> physicalDefaultRoute() async {
    final exclude = _tunnelIfIndex;
    final script = '''
\$ProgressPreference = 'SilentlyContinue'
\$exclude = $exclude
Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object {
    \$_.NextHop -and \$_.NextHop -ne '0.0.0.0' -and
    (\$exclude -le 0 -or \$_.InterfaceIndex -ne \$exclude)
  } |
  Sort-Object RouteMetric, InterfaceMetric |
  Select-Object -First 1 |
  ForEach-Object { "{0}|{1}" -f \$_.InterfaceIndex, \$_.NextHop }
''';
    final out = await WinProcess.powershell(script);
    if (out == null) return null;
    final line = out.trim().split(RegExp(r'\r?\n')).lastWhere(
          (l) => l.contains('|'),
          orElse: () => '',
        );
    final parts = line.split('|');
    if (parts.length != 2) return null;
    final idx = int.tryParse(parts[0].trim());
    final gw = parts[1].trim();
    if (idx == null || idx <= 0 || gw.isEmpty) return null;
    return (ifIndex: idx, gateway: gw);
  }

  /// iedux `_setupBypassRouting`: `route add <ip> mask 255.255.255.255 <gw>`.
  /// Always include [endpoint] host when IPv4. Call **before** Global default route.
  Future<int> setupBypassRoutes({
    required String endpoint,
    List<String> extraIps = const [],
  }) async {
    final phys = await physicalDefaultRoute();
    if (phys == null) {
      debugPrint('local_proxy: no physical gateway for bypass routes');
      return 0;
    }

    final ips = <String>{};
    final host = endpointHost(endpoint);
    if (isIpv4(host) && !isFakeIpTunnelIpv4(host)) ips.add(host);
    for (final raw in extraIps) {
      final ip = raw.trim();
      if (ip.isEmpty || !ip.contains('.') || isFakeIpTunnelIpv4(ip)) continue;
      if (isIpv4(ip)) ips.add(ip);
    }

    await clearBypassRoutes();
    var ok = 0;
    for (final ip in ips) {
      final r = await WinProcess.run([
        'route',
        'add',
        ip,
        'mask',
        '255.255.255.255',
        phys.gateway,
      ]);
      if (r.exitCode == 0) {
        _activeBypassIps.add(ip);
        ok++;
        debugPrint('local_proxy: bypass $ip via ${phys.gateway}');
      } else {
        // Treat "already exists" as success.
        final print = await WinProcess.run(['route', 'print', ip]);
        if (print.stdout.toString().contains(ip)) {
          _activeBypassIps.add(ip);
          ok++;
        } else {
          debugPrint('local_proxy: bypass failed for $ip: ${print.stderr}');
        }
      }
    }
    return ok;
  }

  Future<void> clearBypassRoutes() async {
    final ips = List<String>.from(_activeBypassIps);
    _activeBypassIps.clear();
    for (final ip in ips) {
      await WinProcess.run(
        ['route', 'delete', ip],
        timeout: const Duration(seconds: 5),
      );
    }
  }

  /// Google DNS must enter tunnel (iedux `_tunneledGoogleDnsRoutes`).
  Future<bool> addTunneledDnsRoutes() async {
    final alias = _tunnelAlias;
    final idx = _tunnelIfIndex;
    if (alias == null || idx <= 0) return false;

    var ok = true;
    for (final prefix in ['8.8.8.8/32', '8.8.4.4/32']) {
      final r = await WinProcess.run([
        'netsh',
        'interface',
        'ipv4',
        'add',
        'route',
        prefix,
        alias,
        'metric=1',
        'store=active',
      ]);
      if (r.exitCode != 0) {
        // Fallback: route.exe IF
        final host = prefix.split('/').first;
        final r2 = await WinProcess.run([
          'route',
          'add',
          host,
          'mask',
          '255.255.255.255',
          '0.0.0.0',
          'IF',
          '$idx',
        ]);
        if (r2.exitCode != 0) {
          ok = false;
          debugPrint('local_proxy: tunneled DNS route $prefix failed');
        }
      }
    }
    return ok;
  }

  Future<void> removeTunneledDnsRoutes() async {
    final alias = _tunnelAlias;
    if (alias != null) {
      for (final prefix in ['8.8.8.8/32', '8.8.4.4/32', '0.0.0.0/0']) {
        await WinProcess.run([
          'netsh',
          'interface',
          'ipv4',
          'delete',
          'route',
          prefix,
          alias,
        ]);
      }
    }
    await WinProcess.run(['route', 'delete', '8.8.8.8', 'mask', '255.255.255.255']);
    await WinProcess.run(['route', 'delete', '8.8.4.4', 'mask', '255.255.255.255']);
  }

  void reset() {
    _tunnelIfIndex = 0;
    _tunnelAlias = null;
    _activeBypassIps.clear();
  }
}

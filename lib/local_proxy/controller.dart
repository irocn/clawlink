import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../fakeip/libfakeip.dart';
import 'mode.dart';
import 'session.dart';
import 'windows/dns.dart';
import 'windows/process.dart';
import 'windows/routes.dart';

/// Independent local-traffic proxy (iedux Windows model).
///
/// **Smart** — gfwlist + `8.8.8.8/32` via TUN; no `0.0.0.0/0`.
/// **Global** — same + Rust/`updateGlobalRoute` default via TUN; endpoint/bypass
/// stay on physical gateway (`route add …/32 <gw>`), matching iedux R4.
///
/// Tunnel/WG stays outside; UI passes [LocalProxySession] after connect.
class LocalProxyController {
  LocalProxyMode mode = LocalProxyMode.off;
  bool running = false;
  String? lastError;

  final _dns = WindowsDns();
  final _routes = WindowsRoutes();

  bool get enabled => mode.enabled;

  Future<void> loadPref() async {
    final dir = _homeDir();
    if (dir.isEmpty) return;
    for (final name in ['proxy_mode.txt', 'proxy_local.txt']) {
      final f = File(p.join(dir, name));
      if (!await f.exists()) continue;
      try {
        mode = LocalProxyModeX.parse(await f.readAsString());
        return;
      } catch (_) {}
    }
  }

  Future<void> savePref() async {
    final dir = _homeDir();
    if (dir.isEmpty) return;
    try {
      await Directory(dir).create(recursive: true);
      await File(p.join(dir, 'proxy_mode.txt')).writeAsString('${mode.storageValue}\n');
    } catch (_) {}
  }

  /// Persist mode; if [session] is set and tunnel is up, apply immediately.
  Future<void> setMode(LocalProxyMode next, {LocalProxySession? session}) async {
    if (next == mode) return;
    mode = next;
    await savePref();
    lastError = null;

    if (session == null) return;
    if (!next.enabled) {
      await stop();
      return;
    }
    if (running) {
      await _pinBypass(session);
      await _applyRustMode();
      await WinProcess.flushDns();
      return;
    }
    await start(session);
  }

  /// After WG/core is connected.
  Future<void> start(LocalProxySession session) async {
    lastError = null;
    if (!mode.enabled) return;

    if (running) {
      await _pinBypass(session);
      await _applyRustMode();
      return;
    }
    if (!libFakeIp.isAvailable) {
      lastError = 'Local proxy unavailable (missing libfakeip.dll)';
      return;
    }

    final elevated = await WinProcess.isElevated();
    if (!elevated) {
      debugPrint('local_proxy: not elevated — DNS/route changes may fail');
    }

    final tun = await _routes.resolveTunnel(session.ifaceAlias);
    if (tun == null) {
      lastError = 'Local proxy: cannot resolve tunnel adapter "${session.ifaceAlias}"';
      return;
    }

    try {
      // 1) Bypass / endpoint on physical GW *before* any global default (iedux R4).
      final bypassOk = await _pinBypass(session);
      if (mode.isGlobal && bypassOk == 0) {
        lastError =
            'Local proxy: could not exclude endpoint from VPN (need Admin / IPv4 endpoint)';
      }

      // 2) libfakeip session (Windows = real-IP + /32, like iedux).
      libFakeIp.init();
      libFakeIp.setIfIndex(tun.ifIndex);
      libFakeIp.setDnsFakeIpForProxied(false);

      // 3) Proxied upstream DNS must use the tunnel.
      await _routes.addTunneledDnsRoutes();

      // 4) Rules + local :53.
      final rules = await rootBundle.loadString('assets/gfwlist.txt');
      if (!libFakeIp.loadRulesStr(rules)) {
        throw StateError('Could not load proxy rules');
      }
      if (!libFakeIp.startDnsProxy(53)) {
        libFakeIp.cleanup();
        throw StateError('Could not bind 127.0.0.1:53 (run as Administrator)');
      }

      // 5) Smart vs Global flags (iedux setGlobalMode + updateGlobalRoute).
      await _applyRustMode();

      // 6) System DNS → stub resolver.
      final dnsOk = await _dns.redirectToLocal();
      if (dnsOk == 0 && lastError == null) {
        lastError =
            'Local proxy DNS needs Administrator to point system DNS at 127.0.0.1';
      }

      running = true;
      debugPrint(
        'local_proxy: started mode=${mode.name} ifIndex=${tun.ifIndex} '
        'alias=${tun.alias} bypass=$bypassOk dnsAdapters=$dnsOk '
        'elevated=$elevated build=${libFakeIp.buildId}',
      );
    } catch (e) {
      running = false;
      lastError = e.toString();
      await _teardownNetworkOnly();
    }
  }

  /// When the live peer endpoint changes under Global.
  Future<void> refreshEndpoint(LocalProxySession session) async {
    if (!running) return;
    await _pinBypass(session);
  }

  Future<void> stop() async {
    if (!running && !libFakeIp.isAvailable) {
      await _teardownNetworkOnly();
      return;
    }
    try {
      libFakeIp.updateGlobalRoute(false);
      libFakeIp.cleanup();
    } catch (_) {}
    await _teardownNetworkOnly();
    running = false;
    debugPrint('local_proxy: stopped');
  }

  Future<void> _applyRustMode() async {
    libFakeIp.setGlobalMode(mode.isGlobal);
    libFakeIp.updateGlobalRoute(mode.isGlobal);
  }

  Future<int> _pinBypass(LocalProxySession session) {
    return _routes.setupBypassRoutes(
      endpoint: session.endpoint,
      extraIps: session.bypassIps,
    );
  }

  Future<void> _teardownNetworkOnly() async {
    await _dns.restore();
    await _routes.removeTunneledDnsRoutes();
    await _routes.clearBypassRoutes();
    _routes.reset();
    await WinProcess.flushDns();
  }

  String _homeDir() {
    final override = Platform.environment['CLAWLINK_HOME'] ??
        Platform.environment['KEY_DIR'] ??
        '';
    if (override.isNotEmpty) return override;
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    if (home.isEmpty) return '';
    return p.join(home, '.clawlink');
  }
}

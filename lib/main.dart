import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'core_client.dart';
import 'fakeip/libfakeip.dart';
import 'local_proxy/local_proxy.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  if (libFakeIp.isAvailable) {
    debugPrint('libfakeip: ${libFakeIp.buildId} (${libFakeIp.loadedPath})');
  } else {
    debugPrint('libfakeip: not loaded (run scripts/sync-libfakeip.ps1)');
  }

  const winOpts = WindowOptions(
    size: Size(440, 600),
    minimumSize: Size(400, 560),
    center: true,
    title: 'ClawLink',
  );
  await windowManager.setPreventClose(true);
  await windowManager.waitUntilReadyToShow(winOpts, () async {
    // Window chrome icon comes from the PE resource (win32_window.cpp).
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const ClawLinkApp());
}

/// Tray icon path inside packaged Flutter assets (not a loose output\app_icon.ico).
String? _trayIconPath() {
  final bundled = p.join(
    p.dirname(Platform.resolvedExecutable),
    'data',
    'flutter_assets',
    'assets',
    'app_icon.ico',
  );
  if (File(bundled).existsSync()) return bundled;
  final dev = p.join(Directory.current.path, 'assets', 'app_icon.ico');
  if (File(dev).existsSync()) return dev;
  final runner = p.join(
    Directory.current.path,
    'windows',
    'runner',
    'resources',
    'app_icon.ico',
  );
  if (File(runner).existsSync()) return runner;
  return null;
}

class ClawLinkApp extends StatelessWidget {
  const ClawLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClawLink',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1F6F5B),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TrayListener, WindowListener {
  final _client = CoreClient();
  final _inviteCtrl = TextEditingController();
  Timer? _poll;
  CoreStatus _status = CoreStatus(state: 'disconnected');
  String? _message;
  bool _busy = false;
  /// Full saved invite URI (empty = none).
  String _savedInvite = '';
  String _localTunIp = '';
  bool _trayConnected = false;
  bool _statusInFlight = false;
  final _localProxy = LocalProxyController();

  bool get _hasSavedInvite => _savedInvite.isNotEmpty;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    _initTray();
    _loadLocalProxyPref();
    _loadSavedInvite();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_busy) _refreshStatus(silent: true);
    });
    _refreshStatus(silent: true);
  }

  /// Start core (if needed) so endpoint list / failover prefs are available before Connect.
  Future<void> _prepareEndpointOptions() async {
    try {
      await _client.ensureCoreRunning();
      await _refreshStatus(silent: true);
    } catch (_) {
      // UAC denied or core missing: Connect will retry.
    }
  }

  Future<void> _initTray() async {
    try {
      final icon = _trayIconPath();
      if (icon != null) {
        await trayManager.setIcon(icon);
      }
      await trayManager.setToolTip('ClawLink');
      await _updateTrayMenu(force: true);
    } catch (_) {
      // Tray is best-effort in early builds.
    }
  }

  bool get _isActive =>
      _status.state == 'connected' || _status.state == 'connecting';

  bool get _isConnected => _status.state == 'connected';

  Future<void> _updateTrayMenu({bool force = false}) async {
    final connected = _isConnected;
    if (!force && connected == _trayConnected) return;
    _trayConnected = connected;
    try {
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Show ClawLink'),
        MenuItem.separator(),
        if (connected)
          MenuItem(key: 'disconnect', label: 'Disconnect')
        else
          MenuItem(key: 'connect', label: 'Connect'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: 'Exit'),
      ]));
    } catch (_) {}
  }

  @override
  void dispose() {
    _poll?.cancel();
    _inviteCtrl.dispose();
    if (_localProxy.running) {
      unawaited(_localProxy.stop());
    }
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _refreshStatus({bool silent = false}) async {
    if (_statusInFlight) return;
    _statusInFlight = true;
    try {
      if (!await _client.isPipeAvailable()) {
        if (!silent) {
          setState(() {
            _status = CoreStatus(
              state: 'disconnected',
              endpoint: _status.endpoint,
              endpoints: _status.endpoints,
              failover: _status.failover,
              tunIp: _status.tunIp.isNotEmpty ? _status.tunIp : _localTunIp,
            );
            _message = 'clawlink-core is not running';
          });
        } else if (mounted) {
          // Keep endpoint picker state while core is briefly unavailable.
          setState(() {
            _status = CoreStatus(
              state: 'disconnected',
              endpoint: _status.endpoint,
              endpoints: _status.endpoints,
              failover: _status.failover,
              tunIp: _status.tunIp.isNotEmpty ? _status.tunIp : _localTunIp,
            );
          });
        }
        await _updateTrayMenu();
        return;
      }
      final st = await _client.status();
      if (!mounted) return;
      var tunIp = st.tunIp;
      if (tunIp.isEmpty) {
        final local = await _readLocalTunIp();
        if (local.isNotEmpty) {
          tunIp = local;
          _localTunIp = local;
        } else {
          tunIp = _localTunIp;
        }
      } else {
        _localTunIp = tunIp;
      }
      setState(() {
        _status = CoreStatus(
          state: st.state,
          endpoint: st.endpoint,
          endpoints: st.endpoints,
          failover: st.failover,
          handshakeAgeMs: st.handshakeAgeMs,
          rxBytes: st.rxBytes,
          txBytes: st.txBytes,
          error: st.error,
          iface: st.iface,
          tunIp: tunIp,
        );
        if (!silent) _message = null;
      });
      await _updateTrayTooltip();
      await _updateTrayMenu();
    } catch (e) {
      if (!silent && mounted) {
        setState(() => _message = e.toString());
      }
    } finally {
      _statusInFlight = false;
    }
  }

  Future<void> _updateTrayTooltip() async {
    try {
      await trayManager.setToolTip('ClawLink — ${_status.state}');
    } catch (_) {}
  }

  Future<void> _run(Future<void> Function() op) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    // Let the spinner paint before heavy IPC work starts.
    await Future<void>.delayed(Duration.zero);
    try {
      await _client.ensureCoreRunning();
      await op();
      await _refreshStatus();
    } catch (e) {
      if (mounted) setState(() => _message = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadLocalProxyPref() async {
    await _localProxy.loadPref();
    if (mounted) setState(() {});
  }

  LocalProxySession? _proxySessionOrNull() {
    if (!_isConnected) return null;
    final iface = _status.iface.trim();
    if (iface.isEmpty) return null;
    return LocalProxySession(ifaceAlias: iface, endpoint: _status.endpoint);
  }

  Future<void> _setLocalProxyMode(LocalProxyMode mode) async {
    await _localProxy.setMode(mode, session: _proxySessionOrNull());
    if (!mounted) return;
    setState(() {
      if (_localProxy.lastError != null) _message = _localProxy.lastError;
    });
  }

  /// Wait until core reports connected + iface (needed for ifIndex / routes).
  Future<bool> _waitTunnelReady({Duration timeout = const Duration(seconds: 12)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await _refreshStatus(silent: true);
      if (_status.state == 'connected' && _status.iface.trim().isNotEmpty) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return _status.state == 'connected';
  }

  Future<void> _startLocalProxy() async {
    if (!_localProxy.enabled) return;
    final ready = await _waitTunnelReady();
    if (!ready || _status.iface.trim().isEmpty) {
      if (mounted) setState(() => _message = 'Local proxy: tunnel not ready yet');
      return;
    }
    await _localProxy.start(
      LocalProxySession(ifaceAlias: _status.iface, endpoint: _status.endpoint),
    );
    if (!mounted) return;
    setState(() {
      if (_localProxy.lastError != null) _message = _localProxy.lastError;
    });
  }

  Future<void> _loadSavedInvite() async {
    // Prefer core when running; otherwise read ~/.clawlink/invite.txt locally.
    try {
      if (await _client.isPipeAvailable()) {
        final uri = await _client.getInvite();
        if (!mounted) return;
        _applySavedInvite(uri);
        if (_hasSavedInvite) await _prepareEndpointOptions();
        return;
      }
    } catch (_) {}
    final local = await _readLocalInviteFile();
    if (!mounted) return;
    _applySavedInvite(local);
    if (_hasSavedInvite) await _prepareEndpointOptions();
  }

  void _applySavedInvite(String uri) {
    setState(() {
      _savedInvite = uri.trim();
      if (_savedInvite.isNotEmpty) {
        _inviteCtrl.clear();
      }
    });
  }

  Future<String> _readLocalInviteFile() async {
    final dir = _clawlinkHomeDir();
    if (dir.isEmpty) return '';
    final f = File(p.join(dir, 'invite.txt'));
    if (!await f.exists()) return '';
    try {
      return (await f.readAsString()).trim();
    } catch (_) {
      return '';
    }
  }

  String _clawlinkHomeDir() {
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

  /// TUN_IP from ~/.clawlink/device.env (fallback when core status omits tun_ip).
  Future<String> _readLocalTunIp() async {
    final dir = _clawlinkHomeDir();
    if (dir.isEmpty) return '';
    final f = File(p.join(dir, 'device.env'));
    if (!await f.exists()) return '';
    try {
      for (final line in (await f.readAsString()).split('\n')) {
        final t = line.trim();
        if (t.startsWith('TUN_IP=')) {
          return t.substring('TUN_IP='.length).trim();
        }
      }
    } catch (_) {}
    return '';
  }

  Future<void> _importAndConnect() async {
    final uri = _inviteCtrl.text.trim();
    final importingNew = uri.isNotEmpty;
    await _run(() async {
      if (importingNew) {
        await _client.importInvite(uri);
        _savedInvite = uri;
      } else if (!_hasSavedInvite) {
        throw CoreException('invalid_invite', 'paste an invite URI first');
      }

      final saved = await _client.getInvite();
      if (saved.isNotEmpty) _savedInvite = saved;

      // Fresh import with multiple endpoints: stop here so the user can pick
      // an endpoint (and failover) before connecting.
      if (importingNew) {
        final st = await _client.status();
        if (st.endpoints.length >= 2) {
          return;
        }
      }
      await _client.connect();
      if (_localProxy.enabled) {
        await _startLocalProxy();
      }
    });
    if (mounted) setState(() {});
  }

  Future<void> _disconnect() async {
    await _run(() async {
      await _localProxy.stop();
      await _client.disconnect();
    });
  }

  Future<void> _toggleConnect() async {
    if (_isActive) {
      await _disconnect();
    } else {
      await _importAndConnect();
    }
  }

  Future<void> _setFailover(bool enabled) async {
    await _run(() => _client.setFailover(enabled));
  }

  Future<void> _setEndpoint(String endpoint) async {
    await _run(() async {
      await _client.setEndpoint(endpoint);
      await _refreshStatus(silent: true);
      final session = _proxySessionOrNull();
      if (session != null) await _localProxy.refreshEndpoint(session);
    });
  }

  bool get _showEndpointControls => _status.endpoints.length >= 2;

  String? get _selectedEndpoint {
    final eps = _status.endpoints;
    if (eps.isEmpty) return null;
    final cur = _status.endpoint;
    if (cur.isNotEmpty && eps.contains(cur)) return cur;
    // Live address may differ by port (hop/roam); match candidate by host.
    if (cur.isNotEmpty) {
      final host = _endpointHost(cur);
      for (final ep in eps) {
        if (_endpointHost(ep) == host) return ep;
      }
    }
    return eps.first;
  }

  String _endpointHost(String ep) => WindowsRoutes.endpointHost(ep);

  String get _handshakeAgeLabel {
    if (_status.handshakeAgeMs <= 0) return '—';
    final secs = _status.handshakeAgeMs ~/ 1000;
    return '$secs s';
  }

  String _formatBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) {
      return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _clearInvite() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete saved invite?'),
        content: const Text(
          'The stored invite URI will be removed. '
          'You will need to paste a new invite to connect again.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (await _client.isPipeAvailable()) {
        // Drop active tunnel first so we do not keep using a deleted invite.
        try {
          await _localProxy.stop();
          await _client.disconnect();
        } catch (_) {}
        await _client.clearInvite();
      } else {
        final f = File(p.join(
          Platform.environment['CLAWLINK_HOME'] ??
              Platform.environment['KEY_DIR'] ??
              p.join(
                Platform.environment['USERPROFILE'] ??
                    Platform.environment['HOME'] ??
                    '',
                '.clawlink',
              ),
          'invite.txt',
        ));
        if (await f.exists()) await f.delete();
      }
      if (!mounted) return;
      setState(() {
        _savedInvite = '';
        _inviteCtrl.clear();
        _message = 'Saved invite deleted';
      });
      await _refreshStatus(silent: true);
    } catch (e) {
      if (mounted) setState(() => _message = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _invitePreview(String uri) {
    if (uri.length <= 48) return uri;
    return '${uri.substring(0, 28)}…${uri.substring(uri.length - 12)}';
  }

  Color get _stateColor {
    switch (_status.state) {
      case 'connected':
        return const Color(0xFF1F6F5B);
      case 'connecting':
        return const Color(0xFFC9852A);
      case 'error':
        return const Color(0xFFB33A3A);
      default:
        return const Color(0xFF6B7280);
    }
  }

  @override
  void onWindowClose() async {
    await windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    // Windows does not auto-popup; must show the context menu explicitly.
    trayManager.popUpContextMenu();
  }

  Future<void> _exitApp() async {
    _poll?.cancel();
    await _localProxy.stop();
    // Best-effort shutdown off the UI thread; --parent-pid also stops core on exit.
    unawaited(_client.shutdown());
    try {
      await trayManager.destroy();
    } catch (_) {}
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {}
    exit(0);
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await windowManager.show();
        await windowManager.focus();
        break;
      case 'connect':
        await _importAndConnect();
        break;
      case 'disconnect':
        await _disconnect();
        break;
      case 'exit':
        await _exitApp();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('ClawLink'),
        actions: [
          IconButton(
            tooltip: 'Refresh status',
            onPressed: _busy ? null : () => _refreshStatus(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                border: Border.all(color: _stateColor.withValues(alpha: 0.35)),
                borderRadius: BorderRadius.circular(12),
                color: _stateColor.withValues(alpha: 0.08),
              ),
              child: Row(
                children: [
                  Icon(Icons.circle, size: 14, color: _stateColor),
                  const SizedBox(width: 10),
                  Text(
                    _status.state.toUpperCase(),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: _stateColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  if (_busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_hasSavedInvite) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                ),
                child: Row(
                  children: [
                    Icon(Icons.link, size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Saved: ${_invitePreview(_savedInvite)}',
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: _busy ? null : _clearInvite,
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ] else ...[
              TextField(
                controller: _inviteCtrl,
                minLines: 3,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Invite URI',
                  hintText: 'itunnel://...',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_showEndpointControls) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto failover'),
                subtitle: const Text('Rotate to another endpoint after handshake failures'),
                value: _status.failover,
                onChanged: _busy ? null : _setFailover,
              ),
              const SizedBox(height: 4),
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Endpoint',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: _selectedEndpoint,
                    items: [
                      for (final ep in _status.endpoints)
                        DropdownMenuItem(value: ep, child: Text(ep, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) {
                            if (v != null && v != _selectedEndpoint) {
                              _setEndpoint(v);
                            }
                          },
                  ),
                ),
              ),
              if (!_isActive) ...[
                const SizedBox(height: 6),
                Text(
                  'Choose an endpoint, then Connect.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                ),
              ],
              const SizedBox(height: 12),
            ],
            Text(
              'Local traffic',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            SegmentedButton<LocalProxyMode>(
              segments: const [
                ButtonSegment(
                  value: LocalProxyMode.off,
                  label: Text('Off'),
                  tooltip: 'Do not proxy this PC',
                ),
                ButtonSegment(
                  value: LocalProxyMode.smart,
                  label: Text('Smart'),
                  tooltip: 'Blocked sites via tunnel; others direct',
                ),
                ButtonSegment(
                  value: LocalProxyMode.global,
                  label: Text('Global'),
                  tooltip: 'Most traffic via tunnel; endpoint + LAN stay direct',
                ),
              ],
              selected: {_localProxy.mode},
              onSelectionChanged: _busy
                  ? null
                  : (s) {
                      if (s.isNotEmpty) _setLocalProxyMode(s.first);
                    },
            ),
            const SizedBox(height: 6),
            Text(
              switch (_localProxy.mode) {
                LocalProxyMode.off => 'Tunnel only for ClawLink itself',
                LocalProxyMode.smart => 'Blocked sites use the tunnel; the rest stay direct',
                LocalProxyMode.global =>
                  'All sites via tunnel; endpoint IP and LAN stay direct',
              },
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const Spacer(),
            Text('ClawLink IP: ${_status.tunIp.isEmpty ? '—' : _status.tunIp}'),
            if (!_showEndpointControls)
              Text('Endpoint: ${_status.endpoint.isEmpty ? '—' : _status.endpoint}'),
            if (_isConnected && _localProxy.enabled)
              Text(
                _localProxy.running
                    ? 'Local proxy: ${_localProxy.mode.name}'
                    : 'Local proxy: starting…',
              ),
            Text('Handshake age: $_handshakeAgeLabel'),
            Text('RX / TX: ${_formatBytes(_status.rxBytes)} / ${_formatBytes(_status.txBytes)}'),
            if (_status.error.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_status.error, style: TextStyle(color: theme.colorScheme.error)),
            ],
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(_message!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _toggleConnect,
              child: Text(
                _isActive
                    ? 'Disconnect'
                    : (_hasSavedInvite ? 'Connect' : 'Import & Connect'),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'GUI talks to clawlink-core.exe via $controlPipePath.\n'
              'Core must run elevated to create the Wintun adapter.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ],
        ),
      ),
    );
  }
}

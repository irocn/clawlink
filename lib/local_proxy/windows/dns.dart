import 'package:flutter/foundation.dart';

import 'process.dart';

/// System DNS → 127.0.0.1 so libfakeip sees queries; restore on stop.
///
/// Patterned after iedux `_redirectSystemDnsToLocal` / `_restoreSystemDnsOverrides`.
class WindowsDns {
  final Map<int, String> _overrideTargets = {};

  Map<int, String> get overrideTargets => Map.unmodifiable(_overrideTargets);

  /// Redirect Up adapters to local stub. Returns how many adapters succeeded.
  Future<int> redirectToLocal() async {
    _overrideTargets.clear();
    final admin = await WinProcess.isElevated();
    if (!admin) {
      debugPrint('local_proxy: DNS redirect usually needs Administrator');
    }

    final out = await WinProcess.powershell(r'''
$ProgressPreference = 'SilentlyContinue'
Get-NetAdapter | Where-Object {
  $_.Status -eq 'Up' -and $_.Name -notmatch '(?i)(Loopback|环回)'
} | ForEach-Object {
  $alias = $_.Name
  $idx = $_.ifIndex
  try {
    Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses @('127.0.0.1') -ErrorAction Stop
    Write-Output ("OK|$idx|$alias")
  } catch {
    Write-Output ("FAIL|$idx|$alias")
  }
}
''');

    var ok = 0;
    for (final line in (out ?? '').split(RegExp(r'\r?\n'))) {
      final t = line.trim();
      if (!t.startsWith('OK|')) continue;
      final parts = t.split('|');
      if (parts.length < 3) continue;
      final idx = int.tryParse(parts[1]);
      if (idx == null) continue;
      _overrideTargets[idx] = parts[2];
      ok++;
    }

    // Fallback: netsh on tunnel-ish names if PowerShell got nothing.
    if (ok == 0) {
      for (final name in ['ClawLink', 'clawlink', 'itunnel', 'Wintun']) {
        final r = await WinProcess.run([
          'netsh',
          'interface',
          'ipv4',
          'set',
          'dnsservers',
          'name=$name',
          'static',
          '127.0.0.1',
          'register=primary',
          'validate=no',
        ]);
        if (r.exitCode == 0) ok++;
      }
    }

    await WinProcess.flushDns();
    return ok;
  }

  /// Restore adapters we overrode (DHCP), best-effort.
  Future<void> restore() async {
    final targets = Map<int, String>.from(_overrideTargets);
    _overrideTargets.clear();
    for (final e in targets.entries) {
      final alias = e.value;
      await WinProcess.run([
        'netsh',
        'interface',
        'ipv4',
        'set',
        'dnsservers',
        'name=$alias',
        'source=dhcp',
      ]);
      await WinProcess.powershell('''
\$ProgressPreference = 'SilentlyContinue'
try {
  Set-DnsClientServerAddress -InterfaceIndex ${e.key} -ResetServerAddresses -AddressFamily IPv4 -ErrorAction SilentlyContinue
} catch {}
''');
    }
    await WinProcess.flushDns();
  }
}

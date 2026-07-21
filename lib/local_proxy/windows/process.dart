import 'dart:io';

import 'package:flutter/foundation.dart';

/// Low-level process helpers (patterned after iedux `windows_tunnel.dart`).
class WinProcess {
  WinProcess._();

  static Future<ProcessResult> run(
    List<String> args, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      return await Process.run(args.first, args.skip(1).toList()).timeout(timeout);
    } catch (e) {
      return ProcessResult(0, 1, '', e.toString());
    }
  }

  static Future<String?> powershell(String script) async {
    final r = await run([
      'powershell',
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);
    if (r.exitCode != 0) {
      debugPrint('local_proxy ps exit ${r.exitCode}: ${r.stderr}');
      return null;
    }
    return r.stdout.toString();
  }

  static String q(String s) => "'${s.replaceAll("'", "''")}'";

  /// `net session` succeeds only when elevated (iedux `_isRunningAsAdminSync`).
  static Future<bool> isElevated() async {
    final r = await run(['net', 'session'], timeout: const Duration(seconds: 5));
    return r.exitCode == 0;
  }

  static Future<void> flushDns() async {
    await run(['ipconfig', '/flushdns']);
  }
}

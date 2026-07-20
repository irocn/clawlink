import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

/// Windows named pipe path for clawlink-core control protocol.
const controlPipePath = r'\\.\pipe\clawlink\control';

class CoreException implements Exception {
  CoreException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

class CoreStatus {
  CoreStatus({
    required this.state,
    this.endpoint = '',
    this.endpoints = const [],
    this.failover = false,
    this.handshakeAgeMs = 0,
    this.rxBytes = 0,
    this.txBytes = 0,
    this.error = '',
    this.iface = '',
    this.tunIp = '',
  });

  final String state;
  final String endpoint;
  final List<String> endpoints;
  final bool failover;
  final int handshakeAgeMs;
  final int rxBytes;
  final int txBytes;
  final String error;
  final String iface;
  final String tunIp;

  factory CoreStatus.fromJson(Map<String, dynamic> j) {
    final eps = <String>[];
    final raw = j['endpoints'];
    if (raw is List) {
      for (final e in raw) {
        final s = '$e'.trim();
        if (s.isNotEmpty) eps.add(s);
      }
    }
    return CoreStatus(
      state: '${j['state'] ?? 'disconnected'}',
      endpoint: '${j['endpoint'] ?? ''}',
      endpoints: eps,
      failover: j['failover'] == true,
      handshakeAgeMs: (j['handshake_age_ms'] as num?)?.toInt() ?? 0,
      rxBytes: (j['rx_bytes'] as num?)?.toInt() ?? 0,
      txBytes: (j['tx_bytes'] as num?)?.toInt() ?? 0,
      error: '${j['error'] ?? ''}',
      iface: '${j['iface'] ?? ''}',
      tunIp: '${j['tun_ip'] ?? ''}',
    );
  }
}

/// NDJSON client for clawlink-core control pipe.
class CoreClient {
  int _nextId = 1;

  /// Run blocking Win32 pipe I/O off the UI isolate.
  Future<T> _io<T>(T Function() fn) => Isolate.run(fn);

  Future<bool> isPipeAvailable() => _io(_pipeAvailableSync);

  Future<void> ensureCoreRunning({Duration timeout = const Duration(seconds: 25)}) async {
    if (await isPipeAvailable()) return;
    final corePath = _coreExecutablePath();
    if (corePath == null) {
      throw CoreException(
        'core_missing',
        'clawlink-core.exe not found. Expected under libs/ next to the GUI, '
            'next to clawlink.exe, or (dev) ./libs/clawlink-core.exe',
      );
    }
    final wintunPath = p.join(p.dirname(corePath), 'wintun.dll');
    if (!await File(wintunPath).exists()) {
      throw CoreException(
        'wintun_missing',
        'wintun.dll must sit next to clawlink-core.exe:\n$wintunPath\n'
            'Place amd64 wintun.dll from https://www.wintun.net/ in libs/',
      );
    }
    final ok = await _io(() => _launchElevated(corePath));
    if (!ok) {
      throw CoreException(
        'elevation_required',
        'Administrator approval is required to start clawlink-core',
      );
    }
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await isPipeAvailable()) return;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    throw CoreException(
      'core_timeout',
      'clawlink-core did not open the control pipe.\n'
          'Approve UAC, and keep clawlink-core.exe running as Administrator.',
    );
  }

  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? params]) async {
    final id = _nextId++;
    return _io(() => _callSync(id, method, params));
  }

  Future<CoreStatus> status() async {
    final r = await call('status');
    return CoreStatus.fromJson(r);
  }

  Future<void> importInvite(String uri) => call('import_invite', {'uri': uri});

  Future<String> getInvite() async {
    final r = await call('get_invite');
    return '${r['uri'] ?? ''}';
  }

  Future<void> clearInvite() => call('clear_invite');

  Future<void> connect() => call('connect');

  Future<void> disconnect() => call('disconnect');

  Future<void> setFailover(bool enabled) => call('set_failover', {'enabled': enabled});

  Future<void> setEndpoint(String endpoint) => call('set_endpoint', {'endpoint': endpoint});

  /// Ask core to disconnect and exit. Best-effort; ignores transport errors.
  Future<void> shutdown() async {
    try {
      await call('shutdown');
    } catch (_) {}
  }

  /// Resolve clawlink-core.exe: exe-dir/libs, exe-dir, then ./libs (flutter run).
  String? _coreExecutablePath() {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final candidates = <String>[
      p.join(exeDir, 'libs', 'clawlink-core.exe'),
      p.join(exeDir, 'clawlink-core.exe'),
      p.join(Directory.current.path, 'libs', 'clawlink-core.exe'),
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }
}

bool _pipeAvailableSync() {
  final h = _openPipeOnce();
  if (h == INVALID_HANDLE_VALUE) return false;
  CloseHandle(h);
  return true;
}

Map<String, dynamic> _callSync(int id, String method, Map<String, dynamic>? params) {
  final req = <String, dynamic>{
    'id': id,
    'method': method,
    'params': ?params,
  };
  final line = '${jsonEncode(req)}\n';
  final h = _openPipe(retries: 3);
  if (h == INVALID_HANDLE_VALUE) {
    final err = GetLastError();
    throw CoreException(
      'core_unavailable',
      'cannot open $controlPipePath (Win32=$err). Is clawlink-core running elevated?',
    );
  }
  try {
    _writeAll(h, utf8.encode(line));
    final respLine = _readLine(h);
    if (respLine.isEmpty) {
      throw CoreException('io', 'empty response from clawlink-core');
    }
    final decoded = jsonDecode(respLine) as Map<String, dynamic>;
    if (decoded['ok'] == true) {
      final result = decoded['result'];
      if (result is Map<String, dynamic>) return result;
      return <String, dynamic>{};
    }
    final err = decoded['error'];
    if (err is Map<String, dynamic>) {
      throw CoreException('${err['code'] ?? 'error'}', '${err['message'] ?? 'unknown'}');
    }
    throw CoreException('error', 'request failed');
  } finally {
    CloseHandle(h);
  }
}

int _openPipe({int retries = 1}) {
  for (var i = 0; i < retries; i++) {
    final h = _openPipeOnce();
    if (h != INVALID_HANDLE_VALUE) return h;
    sleep(const Duration(milliseconds: 150));
  }
  return INVALID_HANDLE_VALUE;
}

int _openPipeOnce() {
  final path = controlPipePath.toNativeUtf16();
  try {
    return CreateFile(
      path,
      GENERIC_READ | GENERIC_WRITE,
      0,
      nullptr,
      OPEN_EXISTING,
      0,
      NULL,
    );
  } finally {
    free(path);
  }
}

bool _launchElevated(String exePath) {
  final op = 'runas'.toNativeUtf16();
  final file = exePath.toNativeUtf16();
  final dir = p.dirname(exePath).toNativeUtf16();
  final args = '--parent-pid $pid'.toNativeUtf16();
  try {
    final rc = ShellExecute(NULL, op, file, args, dir, SW_HIDE);
    return rc > 32;
  } finally {
    free(op);
    free(file);
    free(dir);
    free(args);
  }
}

void _writeAll(int handle, List<int> bytes) {
  final buf = calloc<Uint8>(bytes.length);
  final written = calloc<DWORD>();
  try {
    for (var i = 0; i < bytes.length; i++) {
      buf[i] = bytes[i];
    }
    final ok = WriteFile(handle, buf, bytes.length, written, nullptr);
    if (ok == 0 || written.value != bytes.length) {
      throw CoreException('io', 'WriteFile failed (${GetLastError()})');
    }
  } finally {
    free(buf);
    free(written);
  }
}

String _readLine(int handle) {
  const chunkSize = 4096;
  final chunks = <int>[];
  final buf = calloc<Uint8>(chunkSize);
  final read = calloc<DWORD>();
  try {
    while (true) {
      final ok = ReadFile(handle, buf, chunkSize, read, nullptr);
      if (ok == 0 || read.value == 0) break;
      for (var i = 0; i < read.value; i++) {
        final b = buf[i];
        if (b == 10) return utf8.decode(chunks);
        if (b != 13) chunks.add(b);
      }
    }
    return utf8.decode(chunks);
  } finally {
    free(buf);
    free(read);
  }
}

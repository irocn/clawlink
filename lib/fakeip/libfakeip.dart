import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

typedef LogCallbackNative = ffi.Void Function(ffi.Pointer<Utf8>);

typedef _RustInitNative = ffi.Void Function(ffi.Pointer<Utf8> config);
typedef _RustInit = void Function(ffi.Pointer<Utf8> config);

typedef _RustSetIfIndexNative = ffi.Void Function(ffi.Uint32 idx);
typedef _RustSetIfIndex = void Function(int idx);

typedef _RustMatchDomainNative = ffi.Int32 Function(ffi.Pointer<Utf8> domain);
typedef _RustMatchDomain = int Function(ffi.Pointer<Utf8> domain);

typedef _RustGetFakeIpNative = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8> domain);
typedef _RustGetFakeIp = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8> domain);

typedef _RustGetDomainByIpNative = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8> ip);
typedef _RustGetDomainByIp = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8> ip);

typedef _RustFreeStringNative = ffi.Void Function(ffi.Pointer<Utf8> s);
typedef _RustFreeString = void Function(ffi.Pointer<Utf8> s);

typedef _RustLoadRulesNative = ffi.Int32 Function(ffi.Pointer<Utf8> path);
typedef _RustLoadRules = int Function(ffi.Pointer<Utf8> path);

typedef _RustLoadRulesStrNative = ffi.Int32 Function(ffi.Pointer<Utf8> content);
typedef _RustLoadRulesStr = int Function(ffi.Pointer<Utf8> content);

typedef _RustSetGlobalModeNative = ffi.Void Function(ffi.Bool enabled);
typedef _RustSetGlobalMode = void Function(bool enabled);

typedef _RustUpdateGlobalRouteNative = ffi.Void Function(ffi.Bool enabled);
typedef _RustUpdateGlobalRoute = void Function(bool enabled);

typedef _RustStartDnsProxyNative = ffi.Int32 Function(ffi.Uint16 port);
typedef _RustStartDnsProxy = int Function(int port);

typedef _RustSetDnsFakeIpNative = ffi.Void Function(ffi.Bool enabled);
typedef _RustSetDnsFakeIp = void Function(bool enabled);

typedef _RustCleanupNative = ffi.Void Function();
typedef _RustCleanup = void Function();

typedef _RustGetBuildIdNative = ffi.Pointer<Utf8> Function();
typedef _RustGetBuildId = ffi.Pointer<Utf8> Function();

/// Dart FFI loader for **libfakeip.dll** (DNS / Fake-IP).
///
/// Crate lives outside this repo:
///   `E:\github\itunnel\crates\libfakeip`
/// Build:
///   `cargo build --release` → `target/release/libfakeip.dll`
/// Sync into clawlink:
///   `scripts/sync-libfakeip.ps1`
class LibFakeIp {
  String? _buildId;
  String? _loadedPath;

  late final _RustInit _rustInit;
  late final _RustMatchDomain _rustMatchDomain;
  late final _RustGetFakeIp _rustGetFakeIp;
  late final _RustGetDomainByIp _rustGetDomainByIp;
  late final _RustFreeString _rustFreeString;
  late final void Function(ffi.Pointer<ffi.NativeFunction<LogCallbackNative>>)
      _setLogger;
  late final _RustLoadRules _rustLoadRules;
  late final _RustLoadRulesStr _rustLoadRulesStr;
  late final _RustSetGlobalMode _rustSetGlobalMode;
  late final _RustUpdateGlobalRoute _rustUpdateGlobalRoute;
  late final _RustSetIfIndex _rustSetIfIndex;
  late final _RustStartDnsProxy _rustStartDnsProxy;
  _RustSetDnsFakeIp? _rustSetDnsFakeIpForProxied;
  late final _RustCleanup _rustCleanup;
  late final _RustGetBuildId _rustGetBuildId;

  bool _isInitialized = false;
  bool get isAvailable => _isInitialized;
  String get buildId => _buildId ?? 'unknown';
  String? get loadedPath => _loadedPath;

  LibFakeIp() {
    if (!Platform.isWindows) return;
    final lib = _openLibrary();
    if (lib == null) return;

    try {
      _rustInit = lib.lookupFunction<_RustInitNative, _RustInit>('rust_init');
      _rustMatchDomain =
          lib.lookupFunction<_RustMatchDomainNative, _RustMatchDomain>(
            'rust_match_domain',
          );
      _rustGetFakeIp = lib.lookupFunction<_RustGetFakeIpNative, _RustGetFakeIp>(
        'rust_get_fake_ip',
      );
      _rustGetDomainByIp =
          lib.lookupFunction<_RustGetDomainByIpNative, _RustGetDomainByIp>(
            'rust_get_domain_by_ip',
          );
      _rustFreeString =
          lib.lookupFunction<_RustFreeStringNative, _RustFreeString>(
            'rust_free_string',
          );
      _setLogger = lib
          .lookup<
            ffi.NativeFunction<
              ffi.Void Function(
                ffi.Pointer<ffi.NativeFunction<LogCallbackNative>>,
              )
            >
          >('rust_set_logger')
          .asFunction();
      _rustLoadRules = lib.lookupFunction<_RustLoadRulesNative, _RustLoadRules>(
        'rust_load_rules',
      );
      _rustLoadRulesStr =
          lib.lookupFunction<_RustLoadRulesStrNative, _RustLoadRulesStr>(
            'rust_load_rules_str',
          );
      _rustSetGlobalMode =
          lib.lookupFunction<_RustSetGlobalModeNative, _RustSetGlobalMode>(
            'rust_set_global_mode',
          );
      _rustUpdateGlobalRoute = lib
          .lookupFunction<_RustUpdateGlobalRouteNative, _RustUpdateGlobalRoute>(
            'rust_update_global_route',
          );
      _rustSetIfIndex =
          lib.lookupFunction<_RustSetIfIndexNative, _RustSetIfIndex>(
            'rust_set_if_index',
          );
      _rustStartDnsProxy =
          lib.lookupFunction<_RustStartDnsProxyNative, _RustStartDnsProxy>(
            'rust_start_dns_proxy',
          );
      try {
        _rustSetDnsFakeIpForProxied =
            lib.lookupFunction<_RustSetDnsFakeIpNative, _RustSetDnsFakeIp>(
              'rust_set_dns_fakeip_for_proxied',
            );
      } catch (_) {
        _rustSetDnsFakeIpForProxied = null;
      }
      _rustCleanup = lib.lookupFunction<_RustCleanupNative, _RustCleanup>(
        'rust_cleanup',
      );
      _rustGetBuildId =
          lib.lookupFunction<_RustGetBuildIdNative, _RustGetBuildId>(
            'rust_get_build_id',
          );

      final buildIdPtr = _rustGetBuildId();
      _buildId = buildIdPtr.address == 0
          ? 'unknown'
          : buildIdPtr.toDartString();
      _isInitialized = true;
    } catch (_) {
      _isInitialized = false;
    }
  }

  ffi.DynamicLibrary? _openLibrary() {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final candidates = <String>[
      p.join(exeDir, 'libs', 'libfakeip.dll'),
      p.join(exeDir, 'libfakeip.dll'),
      p.join(exeDir, 'data', 'libfakeip.dll'),
      p.join(Directory.current.path, 'libs', 'libfakeip.dll'),
      p.join(Directory.current.path, 'windows', 'lib', 'libfakeip.dll'),
    ];
    for (final path in candidates) {
      if (!File(path).existsSync()) continue;
      try {
        final lib = ffi.DynamicLibrary.open(path);
        _loadedPath = path;
        return lib;
      } catch (_) {}
    }
    try {
      final lib = ffi.DynamicLibrary.open('libfakeip.dll');
      _loadedPath = 'libfakeip.dll';
      return lib;
    } catch (_) {
      return null;
    }
  }

  void init({String? config}) {
    if (!_isInitialized) return;
    _rustCleanup();
    final cfg = (config ?? '').toNativeUtf8();
    try {
      _rustInit(cfg);
    } finally {
      malloc.free(cfg);
    }
  }

  void cleanup() {
    if (!_isInitialized) return;
    _rustCleanup();
  }

  void setLogger(ffi.NativeCallable<LogCallbackNative> cb) {
    if (!_isInitialized) return;
    _setLogger(cb.nativeFunction);
  }

  /// Returns `true` when the DNS proxy bound successfully.
  bool startDnsProxy(int port) {
    if (!_isInitialized) return false;
    return _rustStartDnsProxy(port) == 0;
  }

  void setDnsFakeIpForProxied(bool enabled) {
    final f = _rustSetDnsFakeIpForProxied;
    if (!_isInitialized || f == null) return;
    f(enabled);
  }

  void setGlobalMode(bool enabled) {
    if (!_isInitialized) return;
    _rustSetGlobalMode(enabled);
  }

  void updateGlobalRoute(bool enabled) {
    if (!_isInitialized) return;
    _rustUpdateGlobalRoute(enabled);
  }

  void setIfIndex(int idx) {
    if (!_isInitialized) return;
    _rustSetIfIndex(idx);
  }

  bool loadRules(String path) {
    if (!_isInitialized) return false;
    final pathPtr = path.toNativeUtf8();
    try {
      return _rustLoadRules(pathPtr) == 0;
    } finally {
      malloc.free(pathPtr);
    }
  }

  bool loadRulesStr(String content) {
    if (!_isInitialized) return false;
    final contentPtr = content.toNativeUtf8();
    try {
      return _rustLoadRulesStr(contentPtr) == 0;
    } finally {
      malloc.free(contentPtr);
    }
  }

  int matchDomain(String domain) {
    if (!_isInitialized) return 0;
    final domainPtr = domain.toNativeUtf8();
    try {
      return _rustMatchDomain(domainPtr);
    } finally {
      malloc.free(domainPtr);
    }
  }

  String? getFakeIp(String domain) {
    if (!_isInitialized) return null;
    final domainPtr = domain.toNativeUtf8();
    final ipPtr = _rustGetFakeIp(domainPtr);
    malloc.free(domainPtr);
    if (ipPtr.address == 0) return null;
    final ip = ipPtr.toDartString();
    _rustFreeString(ipPtr);
    return ip;
  }

  String? getDomainByIp(String ip) {
    if (!_isInitialized) return null;
    final ipPtr = ip.toNativeUtf8();
    final domainPtr = _rustGetDomainByIp(ipPtr);
    malloc.free(ipPtr);
    if (domainPtr.address == 0) return null;
    final domain = domainPtr.toDartString();
    _rustFreeString(domainPtr);
    return domain;
  }
}

/// Process-wide libfakeip handle (lazy-loaded).
final libFakeIp = LibFakeIp();

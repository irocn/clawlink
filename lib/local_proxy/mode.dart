/// Local traffic proxy modes (libfakeip + OS routes).
///
/// Mirrors iedux Windows: Smart ≈ Auto/split, Global ≈ isGlobalProxy.
enum LocalProxyMode {
  /// Do not proxy this PC.
  off,

  /// gfwlist hits via tunnel; others direct (iedux Auto / split).
  smart,

  /// Most traffic via tunnel; endpoint (+ bypass) and LAN stay direct.
  global,
}

extension LocalProxyModeX on LocalProxyMode {
  String get storageValue => name;

  static LocalProxyMode parse(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'smart':
      case 'split':
      case 'auto':
      case '1':
      case 'true':
      case 'yes':
        return LocalProxyMode.smart;
      case 'global':
      case 'full':
        return LocalProxyMode.global;
      default:
        return LocalProxyMode.off;
    }
  }

  bool get enabled => this != LocalProxyMode.off;

  bool get isGlobal => this == LocalProxyMode.global;

  bool get isSmart => this == LocalProxyMode.smart;
}

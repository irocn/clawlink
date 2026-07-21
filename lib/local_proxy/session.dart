/// Live tunnel info needed to attach [LocalProxyController].
class LocalProxySession {
  const LocalProxySession({
    required this.ifaceAlias,
    required this.endpoint,
    this.bypassIps = const [],
  });

  /// Tunnel adapter alias from core (`iface`), e.g. Wintun / ClawLink.
  final String ifaceAlias;

  /// Active peer endpoint `host:port` (host must be IPv4 for OS exclude route).
  final String endpoint;

  /// Extra IPv4s that must never enter the tunnel (API hosts, etc.).
  final List<String> bypassIps;
}

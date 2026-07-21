/// Local traffic proxy for ClawLink (Smart / Global).
///
/// Independent of the tray UI and clawlink-core WG session. Design follows
/// iedux Windows tunnel helpers: DNS redirect, physical-gateway bypass for
/// endpoint IPs, tunneled Google DNS, libfakeip real-IP mode.
library;

export 'controller.dart';
export 'mode.dart';
export 'session.dart';
export 'windows/dns.dart';
export 'windows/process.dart';
export 'windows/routes.dart';

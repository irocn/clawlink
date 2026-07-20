import 'package:clawlink/core_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CoreStatus.fromJson maps fields', () {
    final st = CoreStatus.fromJson({
      'state': 'connected',
      'endpoint': '1.2.3.4:61820',
      'endpoints': ['1.2.3.4:61820', '5.6.7.8:61820'],
      'failover': true,
      'handshake_age_ms': 1200,
      'rx_bytes': 10,
      'tx_bytes': 20,
      'tun_ip': '10.99.0.5/32',
    });
    expect(st.state, 'connected');
    expect(st.endpoint, '1.2.3.4:61820');
    expect(st.endpoints, ['1.2.3.4:61820', '5.6.7.8:61820']);
    expect(st.failover, isTrue);
    expect(st.handshakeAgeMs, 1200);
    expect(st.rxBytes, 10);
    expect(st.txBytes, 20);
    expect(st.tunIp, '10.99.0.5/32');
  });
}

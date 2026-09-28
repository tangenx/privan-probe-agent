import 'dart:async';
import 'dart:io';

import 'package:privan_probe_agent/src/prober.dart';
import 'package:test/test.dart';

/// A SOCKS5 proxy that accepts CONNECT and then stalls: the TLS handshake
/// through it never completes, like a server blackholed on the way.
Future<(ServerSocket, List<Socket>)> _stallingSocks() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final clients = <Socket>[];
  server.listen((socket) {
    clients.add(socket);
    var stage = 0;
    socket.listen((_) {
      switch (stage++) {
        case 0: // greeting -> no auth
          socket.add([5, 0]);
        case 1: // CONNECT -> succeeded, bound 127.0.0.1:80
          socket.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 80]);
        default: // swallow the TLS ClientHello, never answer
      }
    }, onError: (_) {});
  });
  return (server, clients);
}

void main() {
  test(
    'a handshake cut off after the timeout does not leak an error',
    () async {
      final (server, clients) = await _stallingSocks();
      addTearDown(server.close);

      await expectLater(
        socksHttpsGet(
          server.port,
          Uri.parse('https://example.com/generate_204'),
          timeout: const Duration(milliseconds: 300),
        ),
        throwsA(isA<TimeoutException>()),
      );

      // The prober kills xray right after: the pending handshake dies. Before
      // the fix this surfaced as an unhandled HandshakeException that crashed
      // the agent.
      for (final socket in clients) {
        socket.destroy();
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    },
  );
}

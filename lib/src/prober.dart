// Copyright (C) 2026 tangenx <me@tangenx.dev>
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:socks5_proxy/socks_client.dart';

import 'logger.dart';
import 'proxy_config.dart';
import 'probe_job.dart';
import 'probe_result.dart';

/// Runs the actual network checks. Used by the probe agent; knows nothing
/// about the panel, redis or telegram.
class Prober {
  Prober({this.xrayBinary = 'xray', Directory? logRoot})
    : logRoot = logRoot ?? Directory('/var/lib/probe-agent/xray');

  static final _logger = Logger('Prober');

  final String xrayBinary;

  /// Per-run xray configs and logs; failed runs keep theirs for inspection.
  final Directory logRoot;

  Future<List<ProbeResult>> run(ProbeJob job) async {
    final results = <ProbeResult>[await panelProbe(job.panelUrl)];

    for (final proxy in job.proxies) {
      final isHysteria = proxy.raw['transport'] == 'hysteria';
      final name = proxy.finalRemark ?? proxy.address;

      if (isHysteria) {
        // Hysteria is UDP/QUIC; TCP to its port proves nothing.
        results.add(await probeIcmp(proxy.address, name));
      } else {
        results.add(
          await probeTcp(proxy.address, proxy.port, ProbeTarget.node, name),
        );
      }

      results.add(await probeXray(proxy));
      results.add(await probeFullPing(proxy, probeUrl: job.probeUrl));
    }
    return results;
  }

  /// `xray version` first line, e.g. "Xray 26.3.27 (...)".
  Future<String?> xrayVersion() async {
    try {
      final result = await Process.run(xrayBinary, ['version']);
      final firstLine = (result.stdout as String).split('\n').first.trim();
      return firstLine.isEmpty ? null : firstLine;
    } on ProcessException {
      return null;
    }
  }

  /// Deletes kept xray run dirs (failed runs) older than [maxAge].
  Future<void> pruneLogs(Duration maxAge) async {
    if (!await logRoot.exists()) return;
    final cutoff = DateTime.now().subtract(maxAge);
    await for (final entry in logRoot.list()) {
      if (entry is! Directory) continue;
      try {
        if ((await entry.stat()).modified.isBefore(cutoff)) {
          await entry.delete(recursive: true);
        }
      } on FileSystemException catch (e) {
        _logger.warning('Failed to prune ${entry.path}: $e');
      }
    }
  }

  Future<ProbeResult> probeXray(RawSubscriptionProxyConfig proxy) async {
    final stopwatch = Stopwatch()..start();
    XrayProcess? xray;
    var keepLogs = false;
    try {
      xray = await _startXray(proxy);
      stopwatch.stop();
      return _result(
        proxy,
        ProbeType.vless,
        true,
        stopwatch.elapsedMilliseconds,
      );
    } catch (error, trace) {
      keepLogs = true;
      stopwatch.stop();
      _logger.error(error.toString(), trace);
      final details = '$error${xray == null ? '' : await xray.diagnostics()}';
      return _result(
        proxy,
        ProbeType.vless,
        false,
        stopwatch.elapsedMilliseconds,
        details,
      );
    } finally {
      await xray?.close(keepLogs: keepLogs);
    }
  }

  Future<ProbeResult> probeFullPing(
    RawSubscriptionProxyConfig proxy, {
    required Uri probeUrl,
  }) async {
    final stopwatch = Stopwatch()..start();
    XrayProcess? xray;
    var keepLogs = false;
    try {
      xray = await _startXray(proxy);
      final status = await socksHttpsGet(xray.port, probeUrl);
      stopwatch.stop();
      final ok = status == HttpStatus.noContent;
      return _result(
        proxy,
        ProbeType.full,
        ok,
        stopwatch.elapsedMilliseconds,
        ok ? null : 'Expected HTTP 204, got $status',
      );
    } catch (error, trace) {
      keepLogs = true;
      stopwatch.stop();
      _logger.error(error.toString(), trace);
      final details = '$error${xray == null ? '' : await xray.diagnostics()}';
      return _result(
        proxy,
        ProbeType.full,
        false,
        stopwatch.elapsedMilliseconds,
        details,
      );
    } finally {
      await xray?.close(keepLogs: keepLogs);
    }
  }

  Future<XrayProcess> _startXray(RawSubscriptionProxyConfig proxy) async {
    final raw = proxy.raw;
    final options = Map<String, dynamic>.from(raw['protocolOptions'] as Map);
    final security = Map<String, dynamic>.from(raw['securityOptions'] as Map);
    if ((raw['protocol'] != 'vless' || raw['security'] != 'reality') &&
        raw['protocol'] != 'hysteria') {
      throw const FormatException(
        'Only VLESS Reality and Hysteria probes are currently supported',
      );
    }

    final port = 20000 + Random().nextInt(20000);
    await logRoot.create(recursive: true);
    final file = Directory(
      '${logRoot.path}/xray-$port-${DateTime.now().microsecondsSinceEpoch}',
    );
    await file.create(recursive: true);
    final accessLogFile = File('${file.path}/access.log');
    final errorLogFile = File('${file.path}/error.log');
    final config = {
      'log': {
        'loglevel': 'debug',
        'access': accessLogFile.path,
        'error': errorLogFile.path,
      },
      'inbounds': [
        {
          'listen': '127.0.0.1',
          'port': port,
          'protocol': 'socks',
          'settings': {'auth': 'noauth', 'udp': true},
          'sniffing': {
            'destOverride': ['http', 'tls', 'quic'],
            'enabled': true,
            'routeOnly': false,
          },
          'tag': 'socks',
        },
      ],
      'outbounds': [
        if (raw['protocol'] == 'hysteria')
          {
            'protocol': 'hysteria',
            'settings': {
              'address': proxy.address,
              'port': proxy.port,
              'version': options['version'],
            },
            'streamSettings': {
              'network': 'hysteria',
              'hysteriaSettings': {
                'version': (raw['transportOptions'] as Map)['version'],
                'auth': (raw['transportOptions'] as Map)['auth'],
              },
              'security': 'tls',
              'tlsSettings': {
                'serverName': security['serverName'],
                'fingerprint': security['fingerprint'],
                'alpn': [security['apln']],
              },
              'finalmask': {
                'quicParams': {'debug': false, 'congestion': 'bbr'},
              },
            },
          },
        if (raw['protocol'] == 'vless')
          {
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': proxy.address,
                  'port': proxy.port,
                  'users': [
                    {
                      'id': options['id'],
                      'encryption': options['encryption'] ?? 'none',
                      if (options['flow'] != null && options['flow'] != '')
                        'flow': options['flow'],
                    },
                  ],
                },
              ],
            },
            'streamSettings': {
              'network': raw['transport'] ?? 'tcp',
              'security': 'reality',
              if (raw['transport'] == 'xhttp')
                'xhttpSettings': {
                  'path': (raw['transportOptions'] as Map?)?['path'] ?? '/',
                  'mode': (raw['transportOptions'] as Map?)?['mode'] ?? 'auto',
                },
              'realitySettings': {
                'serverName': security['serverName'],
                'publicKey': security['publicKey'],
                'shortId': security['shortId'],
                'fingerprint': security['fingerprint'] ?? 'firefox',
                'spiderX': security['spiderX'] ?? '',
              },
            },
          },
      ],
    };

    final configFile = File('${file.path}/config.json')
      ..writeAsStringSync(jsonEncode(config));
    final process = await Process.start(xrayBinary, [
      'run',
      '-c',
      configFile.path,
    ]);
    final xray = XrayProcess(process, port, file, accessLogFile, errorLogFile);
    process.stderr.transform(utf8.decoder).listen(xray.errors.add);
    process.stdout.transform(utf8.decoder).listen(xray.errors.add);
    await xray.waitUntilReady();
    return xray;
  }

  Future<ProbeResult> panelProbe(Uri uri) {
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    return uri.scheme == 'https'
        ? tlsPing(uri.host, port, ProbeTarget.panel, 'Panel')
        : probeTcp(uri.host, port, ProbeTarget.panel, 'Panel');
  }

  /// ICMP echo liveness check. Used for UDP-only protocols (e.g. Hysteria)
  /// where neither the service port nor arbitrary TCP ports prove anything.
  Future<ProbeResult> probeIcmp(
    String host,
    String probeTargetName, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final sw = Stopwatch()..start();
    try {
      final result = await Process.run('ping', [
        '-c',
        '1',
        '-W',
        '${timeout.inSeconds}',
        host,
      ]);
      sw.stop();
      final ok = result.exitCode == 0;
      return ProbeResult(
        type: ProbeType.icmp,
        target: ProbeTarget.node,
        probeTargetName: probeTargetName,
        ok: ok,
        error: ok ? null : (result.stderr as String? ?? '').trim(),
        latencyMs: sw.elapsedMilliseconds,
        host: host,
        port: 0,
      );
    } catch (error, trace) {
      sw.stop();
      _logger.error(error.toString(), trace);
      return ProbeResult(
        type: ProbeType.icmp,
        target: ProbeTarget.node,
        probeTargetName: probeTargetName,
        ok: false,
        error: error.toString(),
        latencyMs: sw.elapsedMilliseconds,
        host: host,
        port: 0,
      );
    }
  }

  Future<ProbeResult> probeTcp(
    String host,
    int port,
    ProbeTarget target,
    String probeTargetName, {
    Duration timeout = const Duration(seconds: 3),
  }) async => _socketProbe(host, port, target, probeTargetName, false, timeout);
  Future<ProbeResult> tlsPing(
    String host,
    int port,
    ProbeTarget target,
    String probeTargetName, {
    Duration timeout = const Duration(seconds: 5),
  }) async => _socketProbe(host, port, target, probeTargetName, true, timeout);

  Future<ProbeResult> _socketProbe(
    String host,
    int port,
    ProbeTarget target,
    String probeTargetName,
    bool tls,
    Duration timeout,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final socket = tls
          ? await SecureSocket.connect(host, port, timeout: timeout)
          : await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      sw.stop();
      return ProbeResult(
        type: tls ? ProbeType.tls : ProbeType.tcp,
        target: target,
        probeTargetName: probeTargetName,
        ok: true,
        error: null,
        latencyMs: sw.elapsedMilliseconds,
        host: host,
        port: port,
      );
    } catch (error, trace) {
      sw.stop();
      _logger.error(error.toString(), trace);
      return ProbeResult(
        type: tls ? ProbeType.tls : ProbeType.tcp,
        target: target,
        probeTargetName: probeTargetName,
        ok: false,
        error: error.toString(),
        latencyMs: sw.elapsedMilliseconds,
        host: host,
        port: port,
      );
    }
  }

  ProbeResult _result(
    RawSubscriptionProxyConfig proxy,
    ProbeType type,
    bool ok,
    int latency, [
    String? error,
  ]) => ProbeResult(
    type: type,
    target: ProbeTarget.node,
    probeTargetName: proxy.finalRemark ?? proxy.address,
    ok: ok,
    error: error,
    latencyMs: latency,
    host: proxy.address,
    port: proxy.port,
  );
}

/// GET [uri] through the SOCKS5 proxy on [socksPort]; returns the status.
Future<int> socksHttpsGet(
  int socksPort,
  Uri uri, {
  Duration timeout = const Duration(seconds: 7),
}) async {
  final proxies = [ProxySettings(InternetAddress.loopbackIPv4, socksPort)];
  // Not SocksTCPClient.assignToHttpClient*: its cancel callback awaits the
  // pending TLS handshake and rethrows its failure where nobody listens. After
  // a timeout the client is closed and xray killed, the handshake dies, and
  // that unhandled HandshakeException took the whole agent down.
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..connectionFactory = (target, _, _) {
      final socks = SocksTCPClient.connect(
        proxies,
        // Hostname as-is, resolved by the proxy (same as socks5_proxy does).
        InternetAddress(target.host, type: InternetAddressType.unix),
        target.port,
      );
      final Future<Socket> socket = target.scheme == 'https'
          ? socks.then((s) => s.secure(target.host))
          : socks;
      return Future.value(
        ConnectionTask.fromSocket(socket, () {
          // Cancelled: drop the connection whenever it settles; a late
          // failure has nobody left to report to.
          socket.then((s) => s.destroy(), onError: (Object _) {});
        }),
      );
    };

  try {
    final request = await client.getUrl(uri).timeout(timeout);
    request.headers.set(HttpHeaders.connectionHeader, 'close');

    final response = await request.close().timeout(timeout);
    await response.drain<void>(); // 204 без тела, но на всякий случай сливаем
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

final class XrayProcess {
  final Process process;
  final int port;
  final Directory directory;
  final File accessLogFile;
  final File errorLogFile;
  final List<String> errors = [];

  XrayProcess(
    this.process,
    this.port,
    this.directory,
    this.accessLogFile,
    this.errorLogFile,
  );

  Future<String> diagnostics({int tailLines = 80}) async {
    final buffer = StringBuffer();

    if (errors.isNotEmpty) {
      buffer.writeln('');
      buffer.writeln('Process logs:');
      buffer.writeln(errors.join());
    }

    final accessLog = await _tailLog(accessLogFile, tailLines);
    final errorLog = await _tailLog(errorLogFile, tailLines);

    if (accessLog.isNotEmpty) {
      buffer.writeln('');
      buffer.writeln('Access log:');
      buffer.writeln(accessLog);
    }

    if (errorLog.isNotEmpty) {
      buffer.writeln('');
      buffer.writeln('Error log:');
      buffer.writeln(errorLog);
    }

    if (buffer.isEmpty) {
      buffer.writeln('\nXray log directory: ${directory.path}');
    } else {
      buffer.writeln('\nXray log directory: ${directory.path}');
    }

    return buffer.toString();
  }

  Future<void> waitUntilReady() async {
    for (var i = 0; i < 30; i++) {
      try {
        final socket = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(milliseconds: 200),
        );
        socket.destroy();
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    throw StateError('Xray SOCKS inbound did not become ready');
  }

  Future<void> close({bool keepLogs = false}) async {
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () => -1,
    );
    if (!keepLogs) {
      await directory.delete(recursive: true);
    }
  }
}

Future<String> _tailLog(File file, int lines) async {
  if (!await file.exists()) return '';
  final content = await file.readAsLines();
  final tail = content.length <= lines
      ? content
      : content.sublist(content.length - lines);
  return tail.join('\n');
}

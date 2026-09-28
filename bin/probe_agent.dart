// Copyright (C) 2026 tangenx <me@tangenx.dev>
// SPDX-License-Identifier: AGPL-3.0-only

/// Probe agent: long-polls the bot for probe jobs, runs them, reports back.
/// Needs no inbound ports and holds nothing but its own token.
///
/// Env:
///   PROBE_API_URL       bot http api origin, e.g. https://api.privan.network
///   PROBE_AGENT_TOKEN   from /agent_add
///   PROBE_AGENT_LOG_DIR xray configs/logs of failed runs
///                       (default /var/lib/probe-agent/xray)
///   XRAY_BINARY         default: xray from PATH
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:privan_probe_agent/prober.dart';
import 'package:privan_probe_agent/protocol.dart';
import 'package:privan_probe_agent/src/logger.dart';

const _pollWait = Duration(seconds: 25);
const _keepFailedLogs = Duration(days: 2);
final _logger = const Logger('ProbeAgent');

Future<void> main() async {
  // PID 1 in a container ignores signals it doesn't handle.
  for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    signal.watch().listen((_) => exit(0));
  }

  final env = Platform.environment;
  final apiUrl = env['PROBE_API_URL']?.trim() ?? '';
  final token = env['PROBE_AGENT_TOKEN']?.trim() ?? '';
  if (apiUrl.isEmpty || token.isEmpty) {
    stderr.writeln('PROBE_API_URL and PROBE_AGENT_TOKEN are required');
    exit(64);
  }

  final prober = Prober(
    xrayBinary: env['XRAY_BINARY'] ?? 'xray',
    logRoot: Directory(
      env['PROBE_AGENT_LOG_DIR'] ?? '/var/lib/probe-agent/xray',
    ),
  );
  final xrayVersion = await prober.xrayVersion();
  if (xrayVersion == null) {
    _logger.fatal('xray binary not found or not runnable');
    exit(69);
  }

  final api = _BotApi(Uri.parse(apiUrl), token);
  _logger.info('Started ($xrayVersion), polling $apiUrl');

  var backoff = const Duration(seconds: 5);
  while (true) {
    try {
      final job = await api.nextJob();
      backoff = const Duration(seconds: 5);
      if (job == null) continue;

      _logger.info('Job ${job.id}: ${job.proxies.length} servers');
      final results = await prober.run(job);
      final failed = results.where((r) => !r.ok).length;
      _logger.info('Job ${job.id} done, $failed/${results.length} failed');
      await api.report(
        ProbeReport(jobId: job.id, xrayVersion: xrayVersion, results: results),
      );
      await prober.pruneLogs(_keepFailedLogs);
    } on _Unauthorized {
      _logger.error('Token rejected (agent removed?), retrying in 5 min');
      await Future<void>.delayed(const Duration(minutes: 5));
    } on Object catch (e, st) {
      _logger.error('Bot api error, retrying in ${backoff.inSeconds}s', e, st);
      await Future<void>.delayed(backoff);
      if (backoff < const Duration(minutes: 1)) backoff *= 2;
    }
  }
}

final class _Unauthorized implements Exception {}

final class _BotApi {
  _BotApi(this.origin, this.token);

  final Uri origin;
  final String token;
  final _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 5);

  /// `null` when the bot had nothing within [_pollWait].
  Future<ProbeJob?> nextJob() async {
    final uri = origin.replace(
      path: '/probe/jobs/next',
      queryParameters: {'wait': '${_pollWait.inSeconds}'},
    );
    final (status, body) = await _send('GET', uri);
    if (status == HttpStatus.noContent) return null;
    return ProbeJob.fromJson(jsonDecode(body) as Map<String, dynamic>);
  }

  /// Retries a few times: a lost report means a lost round.
  Future<void> report(ProbeReport report) async {
    final uri = origin.replace(path: '/probe/reports');
    final body = jsonEncode(report.toJson());
    for (var attempt = 1; ; attempt++) {
      try {
        await _send('POST', uri, body: body);
        return;
      } on _Unauthorized {
        rethrow;
      } on Object catch (e) {
        if (attempt == 3) rethrow;
        _logger.warning('Report attempt $attempt failed: $e');
        await Future<void>.delayed(Duration(seconds: 5 * attempt));
      }
    }
  }

  Future<(int, String)> _send(String method, Uri uri, {String? body}) async {
    final request = await _client.openUrl(method, uri);
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..set(HttpHeaders.userAgentHeader, 'privan-probe-agent');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body);
    }
    final response = await request.close().timeout(
      _pollWait + const Duration(seconds: 20),
    );
    final text = await response.transform(utf8.decoder).join();
    return switch (response.statusCode) {
      HttpStatus.unauthorized => throw _Unauthorized(),
      final status when status >= 200 && status < 300 => (status, text),
      final status => throw HttpException('HTTP $status: $text', uri: uri),
    };
  }
}

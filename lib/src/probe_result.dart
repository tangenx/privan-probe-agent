// Copyright (C) 2026 tangenx <me@tangenx.dev>
// SPDX-License-Identifier: AGPL-3.0-only

enum ProbeType { tcp, tls, icmp, vless, full }

enum ProbeTarget { panel, node }

class ProbeResult {
  final ProbeType type;
  final ProbeTarget target;
  final String probeTargetName;
  final bool ok;
  final String? error;
  final int latencyMs;
  final String host;
  final int port;

  const ProbeResult({
    required this.type,
    required this.target,
    required this.probeTargetName,
    required this.ok,
    required this.error,
    required this.latencyMs,
    required this.host,
    required this.port,
  });

  factory ProbeResult.fromJson(Map<String, dynamic> json) {
    return ProbeResult(
      type: ProbeType.values.byName(json['type'] as String),
      target: ProbeTarget.values.byName(json['target'] as String),
      probeTargetName: json['probeTargetName'] as String,
      ok: json['ok'] as bool,
      error: json['error'] as String?,
      latencyMs: (json['latencyMs'] as num).toInt(),
      host: json['host'] as String,
      port: (json['port'] as num).toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'target': target.name,
      'probeTargetName': probeTargetName,
      'ok': ok,
      'error': error,
      'latencyMs': latencyMs,
      'host': host,
      'port': port,
    };
  }

  @override
  toString() {
    return 'ProbeResult{type: $type, target: $target, probeTargetName: $probeTargetName, ok: $ok, error: $error, latencyMs: $latencyMs, host: $host, port: $port}';
  }
}

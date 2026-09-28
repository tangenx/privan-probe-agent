// Copyright (C) 2026 tangenx <me@tangenx.dev>
// SPDX-License-Identifier: AGPL-3.0-only

import 'proxy_config.dart';
import 'probe_result.dart';

/// Work the bot hands to a probe agent: what to check and how.
final class ProbeJob {
  const ProbeJob({
    required this.id,
    required this.panelUrl,
    required this.probeUrl,
    required this.proxies,
  });

  factory ProbeJob.fromJson(Map<String, dynamic> json) => ProbeJob(
    id: json['id'] as String,
    panelUrl: Uri.parse(json['panelUrl'] as String),
    probeUrl: Uri.parse(json['probeUrl'] as String),
    proxies: (json['proxies'] as List<dynamic>)
        .map(
          (p) => RawSubscriptionProxyConfig.fromJson(
            Map<String, dynamic>.from(p as Map),
          ),
        )
        .toList(growable: false),
  );

  final String id;

  /// Reachability of the panel itself (TLS handshake).
  final Uri panelUrl;

  /// URL fetched through each server for the full check (expects 204).
  final Uri probeUrl;

  /// Resolved proxy configs of the probe user (panel raw subscription).
  final List<RawSubscriptionProxyConfig> proxies;

  Map<String, dynamic> toJson() => {
    'id': id,
    'panelUrl': panelUrl.toString(),
    'probeUrl': probeUrl.toString(),
    'proxies': [for (final p in proxies) p.raw],
  };
}

/// What an agent sends back after running a [ProbeJob].
final class ProbeReport {
  const ProbeReport({
    required this.jobId,
    required this.results,
    this.xrayVersion,
  });

  factory ProbeReport.fromJson(Map<String, dynamic> json) => ProbeReport(
    jobId: json['jobId'] as String,
    xrayVersion: json['xrayVersion'] as String?,
    results: (json['results'] as List<dynamic>)
        .map((r) => ProbeResult.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList(growable: false),
  );

  final String jobId;
  final String? xrayVersion;
  final List<ProbeResult> results;

  Map<String, dynamic> toJson() => {
    'jobId': jobId,
    'xrayVersion': ?xrayVersion,
    'results': [for (final r in results) r.toJson()],
  };
}

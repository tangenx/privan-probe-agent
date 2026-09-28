// Copyright (C) 2026 tangenx <me@tangenx.dev>
// SPDX-License-Identifier: AGPL-3.0-only

final class RawSubscriptionProxyConfig {
  final String? finalRemark;
  final String address;
  final int port;
  final String? protocol;
  final Map<String, dynamic> raw;

  const RawSubscriptionProxyConfig({
    required this.finalRemark,
    required this.address,
    required this.port,
    required this.protocol,
    required this.raw,
  });

  factory RawSubscriptionProxyConfig.fromJson(Map<String, dynamic> json) {
    return RawSubscriptionProxyConfig(
      finalRemark: json['finalRemark'] as String?,
      address: json['address'] as String,
      port: (json['port'] as num).toInt(),
      protocol: json['protocol'] as String?,
      raw: Map<String, dynamic>.from(json),
    );
  }

  @override
  String toString() {
    return 'RawSubscriptionProxyConfig{finalRemark: $finalRemark, address: $address, port: $port, protocol: $protocol, raw: $raw}';
  }
}

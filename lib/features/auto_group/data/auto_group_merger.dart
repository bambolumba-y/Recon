import 'dart:convert';

/// One member profile's parsed sing-box config (the file the core wrote after `Parse()`).
class AutoGroupSource {
  const AutoGroupSource({required this.profileId, required this.profileName, required this.config});

  final String profileId;
  final String profileName;
  final Map<String, dynamic> config;
}

class AutoGroupTagOrigin {
  const AutoGroupTagOrigin({required this.profileId, required this.profileName, required this.originalTag});

  final String profileId;
  final String profileName;
  final String originalTag;

  Map<String, dynamic> toJson() => {'profileId': profileId, 'profileName': profileName, 'originalTag': originalTag};
}

class AutoGroupMergeResult {
  const AutoGroupMergeResult({required this.config, required this.origins, required this.warnings});

  final Map<String, dynamic> config;
  final Map<String, AutoGroupTagOrigin> origins;
  final List<String> warnings;

  int get serverCount => (config['outbounds'] as List).length + (config['endpoints'] as List).length;
}

/// Concatenates the leaf outbounds/endpoints of several profiles into one flat list.
/// Groups are dropped because the core rebuilds `select`/`lowest`/`balance` itself
/// (`hiddify-core/v2/config/builder.go`, `setOutbounds`).
class AutoGroupMerger {
  AutoGroupMerger._();

  static const String separator = ' · ';
  static const int prefixMaxLength = 12;
  static const String fallbackPrefix = 'Sub';
  static const Set<String> groupTypes = {'selector', 'urltest', 'balancer'};
  static const Set<String> reservedTags = {'direct', 'block', 'dns-out', 'dns', 'bypass'};
  static const Set<String> reservedTypes = {'direct', 'block', 'dns'};

  static String prefixFor(String profileName) {
    final collapsed = profileName.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (collapsed.isEmpty) return fallbackPrefix;
    if (collapsed.length <= prefixMaxLength) return collapsed;
    return collapsed.substring(0, prefixMaxLength).trimRight();
  }

  static AutoGroupMergeResult merge(List<AutoGroupSource> sources) {
    final outbounds = <Map<String, dynamic>>[];
    final endpoints = <Map<String, dynamic>>[];
    final origins = <String, AutoGroupTagOrigin>{};
    final warnings = <String>[];
    final seenCanonical = <String, String>{}; // canonical json -> merged tag
    final usedPrefixes = <String>{};

    for (final src in sources) {
      final prefix = _uniquePrefix(prefixFor(src.profileName), usedPrefixes);
      final rawOutbounds = _leafList(src.config['outbounds']);
      final rawEndpoints = _leafList(src.config['endpoints']);
      if (rawOutbounds.isEmpty && rawEndpoints.isEmpty) {
        warnings.add('"${src.profileName}" contains no servers and was skipped');
        continue;
      }

      // first pass: tag map for detour rewriting within this profile
      final tagMap = <String, String>{};
      for (final item in [...rawOutbounds, ...rawEndpoints]) {
        final tag = item['tag'] as String;
        tagMap[tag] = '$prefix$separator$tag';
      }

      void add(List<Map<String, dynamic>> raw, List<Map<String, dynamic>> target) {
        for (final item in raw) {
          final originalTag = item['tag'] as String;
          final merged = Map<String, dynamic>.from(item)..['tag'] = tagMap[originalTag];
          if (merged['detour'] is String && tagMap.containsKey(merged['detour'])) {
            merged['detour'] = tagMap[merged['detour']];
          }
          final canonical = _canonical(merged);
          final duplicateOf = seenCanonical[canonical];
          if (duplicateOf != null) {
            warnings.add('duplicate server "${merged['tag']}" skipped (same as "$duplicateOf")');
            continue;
          }
          seenCanonical[canonical] = merged['tag'] as String;
          origins[merged['tag'] as String] = AutoGroupTagOrigin(
            profileId: src.profileId,
            profileName: src.profileName,
            originalTag: originalTag,
          );
          target.add(merged);
        }
      }

      add(rawOutbounds, outbounds);
      add(rawEndpoints, endpoints);
    }

    return AutoGroupMergeResult(
      config: {'outbounds': outbounds, 'endpoints': endpoints},
      origins: origins,
      warnings: warnings,
    );
  }

  static String _uniquePrefix(String base, Set<String> used) {
    var candidate = base;
    var n = 2;
    while (used.contains(candidate)) {
      candidate = '$base $n';
      n++;
    }
    used.add(candidate);
    return candidate;
  }

  /// Leaf servers only: no groups, no infrastructure outbounds, and every item must carry a string tag.
  static List<Map<String, dynamic>> _leafList(Object? list) {
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .where((e) => e['tag'] is String && e['type'] is String)
        .where((e) => !groupTypes.contains(e['type']))
        .where((e) => !reservedTypes.contains(e['type']))
        .where((e) => !reservedTags.contains(e['tag']))
        .toList();
  }

  /// Stable JSON of the item without its tag, used to detect the same server offered twice.
  static String _canonical(Map<String, dynamic> item) {
    final copy = Map<String, dynamic>.from(item)..remove('tag');
    return jsonEncode(_sorted(copy));
  }

  static Object? _sorted(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      return {for (final k in keys) k: _sorted(value[k])};
    }
    if (value is List) return value.map(_sorted).toList();
    return value;
  }
}

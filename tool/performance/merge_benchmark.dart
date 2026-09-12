import 'dart:convert';
import 'dart:io';

// Keep this standalone AOT runner usable without Flutter package resolution.
// ignore: avoid_relative_lib_imports
import '../../lib/features/auto_group/data/auto_group_merger.dart';

// Synthetic inputs only: no subscription files, network or Flutter engine.
List<AutoGroupSource> fixture(String scenario, int nodes) {
  final profiles = scenario == 'single' ? 1 : 2;
  return List.generate(profiles, (p) {
    return AutoGroupSource(
      profileId: 'p$p',
      profileName: 'Pool $p',
      config: {
        'outbounds': List.generate(nodes, (i) {
          final shared = scenario == 'overlap' && i < nodes ~/ 2;
          return <String, dynamic>{
            'type': 'vless',
            'tag': 'node-$i',
            'server': '${shared ? 'shared' : 'pool$p'}-$i.invalid',
            'server_port': 443,
            'uuid': '00000000-0000-0000-0000-000000000000',
            'tls': {
              'enabled': true,
              'alpn': ['h2', 'http/1.1'],
            },
            if (scenario == 'detours' && i > 0) 'detour': 'node-0',
          };
        }),
      },
    );
  });
}

void verify(AutoGroupMergeResult result, int expected) {
  final items = (result.config['outbounds'] as List).cast<Map<String, dynamic>>();
  final tags = items.map((item) => item['tag']).toSet();
  if (result.serverCount != expected || tags.length != expected || result.origins.length != expected) {
    throw StateError('Unexpected count, duplicate tag or missing provenance');
  }
  for (final item in items) {
    if (item.containsKey('detour') && !tags.contains(item['detour'])) {
      throw StateError('Dangling detour');
    }
  }
}

void main(List<String> args) {
  if (args.length != 4) throw ArgumentError('scenario nodes iterations samples');
  final scenario = args[0];
  final nodes = int.parse(args[1]);
  final iterations = int.parse(args[2]);
  final samples = int.parse(args[3]);
  if (!['single', 'disjoint', 'overlap', 'detours'].contains(scenario) || nodes < 2 || iterations < 1 || samples < 1) {
    throw ArgumentError('Invalid benchmark parameters');
  }
  final sources = fixture(scenario, nodes);
  final inputBefore = jsonEncode(sources.map((s) => s.config).toList());
  final expected = scenario == 'single' ? nodes : nodes * 2 - (scenario == 'overlap' ? nodes ~/ 2 : 0);
  final expectedWarnings = scenario == 'overlap' ? nodes ~/ 2 : 0;
  for (var i = 0; i < 20; i++) {
    verify(AutoGroupMerger.merge(sources), expected);
  }
  for (var sample = 0; sample < samples; sample++) {
    AutoGroupMergeResult? result;
    var checksum = 0;
    final watch = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      result = AutoGroupMerger.merge(sources);
      checksum += result.serverCount;
    }
    watch.stop();
    verify(result!, expected);
    if (checksum != expected * iterations || result.warnings.length != expectedWarnings) {
      throw StateError('Unexpected checksum or warnings');
    }
    if (jsonEncode(sources.map((s) => s.config).toList()) != inputBefore) {
      throw StateError('Merge mutated its input');
    }
    stdout.writeln(
      jsonEncode({
        'scenario': scenario,
        'nodes_per_profile': nodes,
        'profiles': sources.length,
        'output_nodes': expected,
        'sample': sample,
        'iterations': iterations,
        'elapsed_us': watch.elapsedMicroseconds,
        'us_per_merge': watch.elapsedMicroseconds / iterations,
        // Process RSS after validation, including runtime/fixtures; not allocations.
        'rss_after_validation_bytes': ProcessInfo.currentRss,
        'checksum': checksum,
      }),
    );
  }
}

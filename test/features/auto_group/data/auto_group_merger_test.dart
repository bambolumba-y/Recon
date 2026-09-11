import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/auto_group/data/auto_group_merger.dart';

Map<String, dynamic> vless(String tag, String server, {String? detour}) => {
  'type': 'vless',
  'tag': tag,
  'server': server,
  'server_port': 443,
  'uuid': '00000000-0000-0000-0000-000000000000',
  if (detour != null) 'detour': detour,
};

AutoGroupSource source(
  String id,
  String name,
  List<Map<String, dynamic>> outbounds, {
  List<Map<String, dynamic>>? endpoints,
}) => AutoGroupSource(
  profileId: id,
  profileName: name,
  config: {'outbounds': outbounds, if (endpoints != null) 'endpoints': endpoints},
);

void main() {
  group('AutoGroupMerger.merge', () {
    test('prefixes tags with the profile name and records origins', () {
      final result = AutoGroupMerger.merge([
        source('p1', 'Alpha', [vless('NL-1', 'nl.example.com')]),
        source('p2', 'Beta', [vless('NL-1', 'nl2.example.com')]),
      ]);
      final tags = (result.config['outbounds'] as List).map((e) => (e as Map)['tag']).toList();
      expect(tags, ['Alpha · NL-1', 'Beta · NL-1']);
      expect(result.origins['Alpha · NL-1']!.profileId, 'p1');
      expect(result.origins['Beta · NL-1']!.originalTag, 'NL-1');
      expect(result.serverCount, 2);
      expect(result.warnings, isEmpty);
    });

    test('rewrites detour references inside the same profile', () {
      final result = AutoGroupMerger.merge([
        source('p1', 'Alpha', [vless('front', 'a.example.com'), vless('chained', 'b.example.com', detour: 'front')]),
      ]);
      final outbounds = (result.config['outbounds'] as List).cast<Map>();
      expect(outbounds[1]['detour'], 'Alpha · front');
    });

    test('drops group outbounds and reserved tags', () {
      final result = AutoGroupMerger.merge([
        source('p1', 'Alpha', [
          {
            'type': 'selector',
            'tag': 'select',
            'outbounds': ['auto', 'NL-1'],
          },
          {
            'type': 'urltest',
            'tag': 'auto',
            'outbounds': ['NL-1'],
          },
          {
            'type': 'balancer',
            'tag': 'lowest',
            'outbounds': ['NL-1'],
          },
          {'type': 'direct', 'tag': 'direct'},
          {'type': 'block', 'tag': 'block'},
          {'type': 'dns', 'tag': 'dns-out'},
          vless('NL-1', 'nl.example.com'),
        ]),
      ]);
      final tags = (result.config['outbounds'] as List).map((e) => (e as Map)['tag']).toList();
      expect(tags, ['Alpha · NL-1']);
    });

    test('deduplicates identical servers across profiles and warns', () {
      final result = AutoGroupMerger.merge([
        source('p1', 'Alpha', [vless('NL-1', 'same.example.com')]),
        source('p2', 'Beta', [vless('Netherlands', 'same.example.com')]),
      ]);
      expect(result.serverCount, 1);
      expect(result.warnings.single, contains('Beta · Netherlands'));
    });

    test('keeps endpoints and prefixes them too', () {
      final result = AutoGroupMerger.merge([
        source(
          'p1',
          'Alpha',
          [],
          endpoints: [
            {
              'type': 'wireguard',
              'tag': 'wg',
              'address': ['10.0.0.2/32'],
              'private_key': 'x',
              'peers': [],
            },
          ],
        ),
      ]);
      final endpoints = (result.config['endpoints'] as List).cast<Map>();
      expect(endpoints.single['tag'], 'Alpha · wg');
      expect(result.serverCount, 1);
    });

    test('profile without servers produces a warning and is skipped', () {
      final result = AutoGroupMerger.merge([
        source('p1', 'Empty', []),
        source('p2', 'Alpha', [vless('NL-1', 'nl.example.com')]),
      ]);
      expect(result.serverCount, 1);
      expect(result.warnings.single, contains('Empty'));
    });

    test('empty input yields zero servers', () {
      final result = AutoGroupMerger.merge([]);
      expect(result.serverCount, 0);
      expect(result.config['outbounds'], isEmpty);
    });

    test('duplicate profile names get numeric suffixes', () {
      final result = AutoGroupMerger.merge([
        source('p1', 'Sub', [vless('A', 'a.example.com')]),
        source('p2', 'Sub', [vless('A', 'b.example.com')]),
      ]);
      final tags = (result.config['outbounds'] as List).map((e) => (e as Map)['tag']).toList();
      expect(tags, ['Sub · A', 'Sub 2 · A']);
    });
  });

  test('prefixFor collapses whitespace and truncates to 12 characters', () {
    expect(AutoGroupMerger.prefixFor('  My   very long subscription name '), 'My very long');
    expect(AutoGroupMerger.prefixFor(''), 'Sub');
  });
}

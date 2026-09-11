import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/features/auto_group/data/auto_group_repository.dart';
import 'package:hiddify/features/auto_group/model/auto_group_failure.dart';
import 'package:hiddify/features/profile/data/profile_path_resolver.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory workDir;
  late ProfilePathResolver resolver;

  ProfileEntity profile(String id, String name) => ProfileEntity.remote(
    id: id,
    active: false,
    name: name,
    url: 'https://x/$id',
    lastUpdate: DateTime(2026),
    includeInAuto: true,
  );

  void writeProfile(String id, List<Map<String, dynamic>> outbounds) {
    resolver.file(id).writeAsStringSync(jsonEncode({'outbounds': outbounds}));
  }

  Map<String, dynamic> vless(String tag, String host) => {
    'type': 'vless',
    'tag': tag,
    'server': host,
    'server_port': 443,
    'uuid': '00000000-0000-0000-0000-000000000000',
  };

  setUp(() {
    workDir = Directory.systemTemp.createTempSync('recon_auto_group');
    resolver = ProfilePathResolver(workDir);
    resolver.directory.createSync(recursive: true);
  });

  tearDown(() => workDir.deleteSync(recursive: true));

  AutoGroupRepositoryImpl repo(
    List<ProfileEntity> members, {
    Future<Either<String, Unit>> Function(String, String)? validate,
  }) => AutoGroupRepositoryImpl(
    profilePathResolver: resolver,
    watchMembersSource: () => Stream.value(right(members)),
    setMembershipSource: (_, __) async {},
    validate:
        validate ??
        (path, tempPath) async {
          // emulate the core: copy temp to final
          File(path).writeAsStringSync(File(tempPath).readAsStringSync());
          return right(unit);
        },
  );

  test('fails with noMembers when nothing is included', () async {
    final result = await repo([]).buildConfig().run();
    expect(result.getLeft().toNullable(), isA<AutoGroupNoMembers>());
  });

  test('merges member files, writes config and meta, records lastBuild', () async {
    writeProfile('a', [vless('NL', 'a.example.com')]);
    writeProfile('b', [vless('DE', 'b.example.com')]);
    final r = repo([profile('a', 'Alpha'), profile('b', 'Beta')]);

    final build = (await r.buildConfig().run()).getOrElse((l) => fail(l.message));
    expect(build.profileCount, 2);
    expect(build.serverCount, 2);
    expect(build.configPath, resolver.file(AutoGroupRepository.configId).path);
    expect(r.lastBuild, same(build));

    final written = jsonDecode(File(build.configPath).readAsStringSync()) as Map;
    expect((written['outbounds'] as List).length, 2);
    final meta = jsonDecode(File(p.join(resolver.directory.path, 'auto-group.meta.json')).readAsStringSync()) as Map;
    expect((meta['origins'] as Map).keys, containsAll(['Alpha · NL', 'Beta · DE']));
    expect(resolver.tempFile(AutoGroupRepository.configId).existsSync(), isFalse);
  });

  test('skips a member whose file is missing and warns', () async {
    writeProfile('a', [vless('NL', 'a.example.com')]);
    final r = repo([profile('a', 'Alpha'), profile('missing', 'Ghost')]);
    final build = (await r.buildConfig().run()).getOrElse((l) => fail(l.message));
    expect(build.profileCount, 1);
    expect(build.warnings.single, contains('Ghost'));
  });

  test('fails with noServers when every member is empty or broken', () async {
    resolver.file('a').writeAsStringSync('not json');
    final result = await repo([profile('a', 'Broken')]).buildConfig().run();
    final failure = result.getLeft().toNullable();
    expect(failure, isA<AutoGroupNoServers>());
    expect((failure! as AutoGroupNoServers).warnings.single, contains('Broken'));
  });

  test('propagates core validation errors', () async {
    writeProfile('a', [vless('NL', 'a.example.com')]);
    final result = await repo([
      profile('a', 'Alpha'),
    ], validate: (_, __) async => left('bad config')).buildConfig().run();
    final failure = result.getLeft().toNullable();
    expect(failure, isA<AutoGroupInvalidConfig>());
    expect((failure! as AutoGroupInvalidConfig).detail, 'bad config');
  });
}

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/features/profile/data/profile_data_source.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';

void main() {
  late Db db;
  late ProfileDao dao;

  ProfileEntriesCompanion entry(String id, String name, {bool active = false}) => ProfileEntriesCompanion.insert(
    id: id,
    type: ProfileType.remote,
    active: active,
    name: name,
    url: Value('https://example.com/$id'),
    lastUpdate: DateTime(2026, 9, 12),
  );

  setUp(() {
    db = Db(NativeDatabase.memory());
    dao = ProfileDao(db);
  });

  tearDown(() => db.close());

  test('new profiles are not in the auto group', () async {
    await dao.insert(entry('a', 'A', active: true));
    final row = await dao.getById('a');
    expect(row!.includeInAuto, isFalse);
    expect(await dao.watchAutoGroupMembers().first, isEmpty);
  });

  test('setIncludeInAuto toggles membership without touching active', () async {
    await dao.insert(entry('a', 'A', active: true));
    await dao.insert(entry('b', 'B'));
    await dao.setIncludeInAuto('b', true);

    final members = await dao.watchAutoGroupMembers().first;
    expect(members.map((e) => e.id), ['b']);
    expect((await dao.getById('a'))!.active, isTrue);

    await dao.setIncludeInAuto('b', false);
    expect(await dao.watchAutoGroupMembers().first, isEmpty);
  });

  test('members are ordered by name', () async {
    await dao.insert(entry('z', 'Zeta'));
    await dao.insert(entry('m', 'Mid'));
    await dao.setIncludeInAuto('z', true);
    await dao.setIncludeInAuto('m', true);
    final members = await dao.watchAutoGroupMembers().first;
    expect(members.map((e) => e.name), ['Mid', 'Zeta']);
  });
}

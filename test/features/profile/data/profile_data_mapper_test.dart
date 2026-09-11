import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/features/profile/data/profile_data_mapper.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';

void main() {
  test('entry -> entity carries includeInAuto', () {
    final entry = ProfileEntry(
      id: 'a',
      type: ProfileType.remote,
      active: false,
      name: 'A',
      url: 'https://example.com/a',
      lastUpdate: DateTime(2026, 9, 12),
      includeInAuto: true,
    );
    expect(entry.toEntity().includeInAuto, isTrue);
  });

  test('insert entry keeps includeInAuto, update entry leaves it untouched', () {
    final entity = ProfileEntity.remote(
      id: 'a',
      active: false,
      name: 'A',
      url: 'https://example.com/a',
      lastUpdate: DateTime(2026, 9, 12),
      includeInAuto: true,
    );
    expect(entity.toInsertEntry().includeInAuto, const Value(true));
    expect(entity.toUpdateEntry().includeInAuto.present, isFalse);
  });
}

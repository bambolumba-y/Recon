import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/auto_group/data/auto_group_repository.dart';
import 'package:hiddify/features/auto_group/notifier/auto_group_notifier.dart';
import 'package:hiddify/features/auto_group/widget/auto_group_card.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAutoGroupNotifier extends AutoGroupNotifier {
  _FakeAutoGroupNotifier(this.value);

  final AutoGroupBuild? value;

  @override
  AutoGroupBuild? build() => value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences preferences;

  ProfileEntity member(String id) => ProfileEntity.remote(
    id: id,
    active: false,
    name: 'profile $id',
    url: 'https://example.com/$id',
    lastUpdate: DateTime(2026),
    includeInAuto: true,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({'auto_group_enabled': true});
    preferences = await SharedPreferences.getInstance();
  });

  testWidgets('renders title, counts and the switch', (tester) async {
    final build = AutoGroupBuild(
      configPath: 'auto-group.json',
      profileCount: 2,
      serverCount: 7,
      warnings: const [],
      builtAt: DateTime(2026),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWith((ref) => preferences),
          translationsProvider.overrideWith((ref) => AppLocale.en.buildSync()),
          autoGroupMembersProvider.overrideWith((ref) => Stream.value([member('a'), member('b')])),
          autoGroupNotifierProvider.overrideWith(() => _FakeAutoGroupNotifier(build)),
        ],
        child: const MaterialApp(home: Scaffold(body: AutoGroupCard())),
      ),
    );
    await tester.pump();

    final t = AppLocale.en.buildSync();
    expect(find.text(t.pages.home.autoGroup.title), findsOneWidget);
    expect(find.text(t.pages.home.autoGroup.enabled), findsOneWidget);
    expect(
      find.text('${t.pages.home.autoGroup.subscriptions(count: 2)}  ·  ${t.pages.home.autoGroup.servers(count: 7)}'),
      findsOneWidget,
    );
    expect(find.byType(Switch), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });
}

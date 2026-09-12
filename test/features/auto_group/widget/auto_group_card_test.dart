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

  Widget card(AutoGroupBuild? build, List<ProfileEntity> members) => ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWith((ref) => preferences),
      translationsProvider.overrideWith((ref) => AppLocale.en.buildSync()),
      autoGroupMembersProvider.overrideWith((ref) => Stream.value(members)),
      autoGroupNotifierProvider.overrideWith(() => _FakeAutoGroupNotifier(build)),
    ],
    child: const MaterialApp(home: Scaffold(body: AutoGroupCard())),
  );

  testWidgets('renders title, counts from the last build and the switch', (tester) async {
    // profileCount differs from the number of live members: the card must show the build's number.
    final build = AutoGroupBuild(
      configPath: 'auto-group.json',
      profileCount: 3,
      serverCount: 7,
      warnings: const [],
      builtAt: DateTime(2026),
    );

    await tester.pumpWidget(card(build, [member('a'), member('b')]));
    await tester.pump();

    final t = AppLocale.en.buildSync();
    expect(find.text(t.pages.home.autoGroup.title), findsOneWidget);
    expect(find.text(t.pages.home.autoGroup.enabled), findsOneWidget);
    expect(
      find.text('${t.pages.home.autoGroup.subscriptions(count: 3)}  ·  ${t.pages.home.autoGroup.servers(count: 7)}'),
      findsOneWidget,
    );
    expect(find.textContaining(t.pages.home.autoGroup.subscriptions(count: 2)), findsNothing);
    expect(find.byType(Switch), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('with zero members and auto mode on the card still renders its switch', (tester) async {
    // the switch is the only control that writes autoGroupEnabled: losing the last member must not
    // take it away, otherwise auto mode can no longer be turned off (home_page renders the card on
    // hasAutoMembers || autoGroupEnabled for the same reason)
    await tester.pumpWidget(card(null, const []));
    await tester.pump();

    final t = AppLocale.en.buildSync();
    expect(find.text(t.pages.home.autoGroup.title), findsOneWidget);
    expect(find.text(t.pages.home.autoGroup.enabled), findsOneWidget);
    expect(find.text(t.pages.home.autoGroup.subscriptions(count: 0)), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('without a build shows the live member count and no servers value', (tester) async {
    await tester.pumpWidget(card(null, [member('a'), member('b')]));
    await tester.pump();

    final t = AppLocale.en.buildSync();
    expect(find.text(t.pages.home.autoGroup.subscriptions(count: 2)), findsOneWidget);
    expect(find.textContaining('Servers'), findsNothing);
  });
}

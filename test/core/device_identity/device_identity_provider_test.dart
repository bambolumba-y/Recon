import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/device_identity/device_identity_provider.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _hwidPrefKey = 'device_hwid';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('deviceIdentityProvider', () {
    test('returns the already-stored hwid unchanged', () async {
      SharedPreferences.setMockInitialValues({_hwidPrefKey: 'stored-hwid'});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWith((ref) async => prefs)]);
      addTearDown(container.dispose);
      await container.read(sharedPreferencesProvider.future);

      final identity = container.read(deviceIdentityProvider);

      expect(identity.hwid, 'stored-hwid');
      expect(prefs.getString(_hwidPrefKey), 'stored-hwid');
    });

    test('generates and persists a new hwid when none is stored', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWith((ref) async => prefs)]);
      addTearDown(container.dispose);
      await container.read(sharedPreferencesProvider.future);

      final identity = container.read(deviceIdentityProvider);
      expect(identity.hwid, isNotEmpty);

      // Let the fire-and-forget persistence future run to completion.
      await Future<void>.delayed(Duration.zero);

      final reloaded = await SharedPreferences.getInstance();
      expect(reloaded.getString(_hwidPrefKey), identity.hwid);
    });
  });
}

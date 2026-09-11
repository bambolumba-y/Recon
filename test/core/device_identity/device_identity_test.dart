import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/device_identity/device_identity.dart';

void main() {
  group('DeviceIdentity', () {
    test('produces the four Remnawave headers', () {
      const identity = DeviceIdentity(hwid: 'abc-123', os: 'Android', osVersion: '14', model: 'Recon');
      final headers = identity.toSubscriptionHeaders();
      expect(headers, {'x-hwid': 'abc-123', 'x-device-os': 'Android', 'x-ver-os': '14', 'x-device-model': 'Recon'});
    });

    test('normalises the platform name', () {
      expect(DeviceIdentity.osNameFor('android'), 'Android');
      expect(DeviceIdentity.osNameFor('ios'), 'iOS');
      expect(DeviceIdentity.osNameFor('windows'), 'Windows');
      expect(DeviceIdentity.osNameFor('linux'), 'Linux');
      expect(DeviceIdentity.osNameFor('macos'), 'macOS');
      expect(DeviceIdentity.osNameFor('fuchsia'), 'fuchsia');
    });
  });
}

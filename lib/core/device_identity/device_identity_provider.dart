import 'dart:async';
import 'dart:io';

import 'package:hiddify/core/device_identity/device_identity.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:loggy/loggy.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

part 'device_identity_provider.g.dart';

const String _hwidPrefKey = 'device_hwid';
const String _deviceModel = 'Recon';

final _loggy = Loggy<InfraLogger>('DeviceIdentity');

@Riverpod(keepAlive: true)
DeviceIdentity deviceIdentity(Ref ref) {
  final prefs = ref.watch(sharedPreferencesProvider).requireValue;
  var hwid = prefs.getString(_hwidPrefKey);
  if (hwid == null || hwid.isEmpty) {
    hwid = const Uuid().v4();
    // The in-memory SharedPreferences cache is updated synchronously, so this
    // hwid stays stable for the rest of the current run even if the disk
    // write below fails; a failure only risks losing it across app restarts.
    unawaited(_persistHwid(prefs, hwid));
  }
  return DeviceIdentity(
    hwid: hwid,
    os: DeviceIdentity.osNameFor(Platform.operatingSystem),
    osVersion: Platform.operatingSystemVersion,
    model: _deviceModel,
  );
}

Future<void> _persistHwid(SharedPreferences prefs, String hwid) async {
  try {
    final success = await prefs.setString(_hwidPrefKey, hwid);
    if (!success) {
      _loggy.warning('failed to persist device hwid to disk');
    }
  } catch (e, stackTrace) {
    _loggy.warning('error persisting device hwid to disk', e, stackTrace);
  }
}

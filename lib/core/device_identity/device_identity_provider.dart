import 'dart:io';

import 'package:hiddify/core/device_identity/device_identity.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

part 'device_identity_provider.g.dart';

const String _hwidPrefKey = 'device_hwid';
const String _deviceModel = 'Recon';

@Riverpod(keepAlive: true)
DeviceIdentity deviceIdentity(Ref ref) {
  final prefs = ref.watch(sharedPreferencesProvider).requireValue;
  var hwid = prefs.getString(_hwidPrefKey);
  if (hwid == null || hwid.isEmpty) {
    hwid = const Uuid().v4();
    // fire and forget: the value is already in memory for this run
    prefs.setString(_hwidPrefKey, hwid);
  }
  return DeviceIdentity(
    hwid: hwid,
    os: DeviceIdentity.osNameFor(Platform.operatingSystem),
    osVersion: Platform.operatingSystemVersion,
    model: _deviceModel,
  );
}

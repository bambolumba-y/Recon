import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/auto_group/data/auto_group_data_providers.dart';
import 'package:hiddify/features/auto_group/data/auto_group_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'auto_group_notifier.g.dart';

@Riverpod(keepAlive: true)
Stream<List<ProfileEntity>> autoGroupMembers(Ref ref) {
  return ref.watch(autoGroupRepositoryProvider).watchMembers().map((event) => event.getOrElse((l) => throw l));
}

/// Holds the result of the latest merge so the UI can show counts and warnings.
@Riverpod(keepAlive: true)
class AutoGroupNotifier extends _$AutoGroupNotifier with AppLogger {
  @override
  AutoGroupBuild? build() => ref.read(autoGroupRepositoryProvider).lastBuild;

  Future<void> toggleMembership(String id, bool value) async {
    loggy.debug('auto group membership [$id] -> $value');
    await ref.read(hapticServiceProvider.notifier).lightImpact();
    await ref.read(autoGroupRepositoryProvider).setMembership(id, value).getOrElse((err) {
      loggy.warning('failed to change auto group membership', err);
      throw err;
    }).run();
  }

  Future<void> setEnabled(bool value) async {
    await ref.read(hapticServiceProvider.notifier).lightImpact();
    await ref.read(Preferences.autoGroupEnabled.notifier).update(value);
  }

  // Tasks 7 and 8 call this by name after a rebuild, so it stays a method, not a setter.
  // ignore: use_setters_to_change_properties
  void recordBuild(AutoGroupBuild build) => state = build;
}

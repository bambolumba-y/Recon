import 'package:hiddify/features/auto_group/data/auto_group_repository.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'auto_group_data_providers.g.dart';

@Riverpod(keepAlive: true)
AutoGroupRepository autoGroupRepository(Ref ref) {
  final profiles = ref.watch(profileRepositoryProvider).requireValue;
  final singbox = ref.watch(hiddifyCoreServiceProvider);
  return AutoGroupRepositoryImpl(
    profilePathResolver: ref.watch(profilePathResolverProvider),
    watchMembersSource: profiles.watchAutoGroupMembers,
    setMembershipSource: (id, value) => profiles.setIncludeInAuto(id, value).getOrElse((l) => throw l).run(),
    validate: (path, tempPath) => singbox.validateConfigByPath(path, tempPath, false).run(),
  );
}

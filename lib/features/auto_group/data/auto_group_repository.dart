import 'dart:convert';
import 'dart:io';

import 'package:fpdart/fpdart.dart';
import 'package:hiddify/features/auto_group/data/auto_group_merger.dart';
import 'package:hiddify/features/auto_group/model/auto_group_failure.dart';
import 'package:hiddify/features/profile/data/profile_path_resolver.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:path/path.dart' as p;

class AutoGroupBuild {
  const AutoGroupBuild({
    required this.configPath,
    required this.profileCount,
    required this.serverCount,
    required this.warnings,
    required this.builtAt,
  });

  final String configPath;
  final int profileCount;
  final int serverCount;
  final List<String> warnings;
  final DateTime builtAt;
}

typedef WatchMembersSource = Stream<Either<ProfileFailure, List<ProfileEntity>>> Function();
typedef SetMembershipSource = Future<void> Function(String id, bool value);
typedef ConfigValidator = Future<Either<String, Unit>> Function(String path, String tempPath);

abstract interface class AutoGroupRepository {
  static const String configId = 'auto-group';
  static const String metaFileName = 'auto-group.meta.json';
  static const String displayName = 'Recon Auto';

  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchMembers();
  TaskEither<ProfileFailure, Unit> setMembership(String id, bool value);
  TaskEither<AutoGroupFailure, AutoGroupBuild> buildConfig();
  AutoGroupBuild? get lastBuild;
}

class AutoGroupRepositoryImpl with InfraLogger implements AutoGroupRepository {
  AutoGroupRepositoryImpl({
    required ProfilePathResolver profilePathResolver,
    required WatchMembersSource watchMembersSource,
    required SetMembershipSource setMembershipSource,
    required ConfigValidator validate,
  }) : _resolver = profilePathResolver,
       _watchMembers = watchMembersSource,
       _setMembership = setMembershipSource,
       _validate = validate;

  final ProfilePathResolver _resolver;
  final WatchMembersSource _watchMembers;
  final SetMembershipSource _setMembership;
  final ConfigValidator _validate;

  AutoGroupBuild? _lastBuild;

  @override
  AutoGroupBuild? get lastBuild => _lastBuild;

  @override
  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchMembers() => _watchMembers();

  @override
  TaskEither<ProfileFailure, Unit> setMembership(String id, bool value) => TaskEither.tryCatch(() async {
    await _setMembership(id, value);
    return unit;
  }, ProfileUnexpectedFailure.new);

  @override
  TaskEither<AutoGroupFailure, AutoGroupBuild> buildConfig() => TaskEither(() async {
    try {
      final members = (await _watchMembers().first).getOrElse((l) => throw l);
      if (members.isEmpty) return left(const AutoGroupNoMembers());

      final sources = <AutoGroupSource>[];
      final warnings = <String>[];
      for (final member in members) {
        final file = _resolver.file(member.id);
        if (!file.existsSync()) {
          warnings.add('"${member.name}" has no downloaded config and was skipped');
          continue;
        }
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is! Map) throw const FormatException('config root is not an object');
          sources.add(
            AutoGroupSource(profileId: member.id, profileName: member.name, config: decoded.cast<String, dynamic>()),
          );
        } catch (e) {
          warnings.add('"${member.name}" config could not be read ($e) and was skipped');
        }
      }

      final merged = AutoGroupMerger.merge(sources);
      warnings.addAll(merged.warnings);
      if (merged.serverCount == 0) return left(AutoGroupNoServers(warnings));

      final target = _resolver.file(AutoGroupRepository.configId);
      final temp = _resolver.tempFile(AutoGroupRepository.configId);
      await temp.writeAsString(jsonEncode(merged.config));
      try {
        final validation = await _validate(target.path, temp.path);
        if (validation.isLeft()) {
          return left(AutoGroupInvalidConfig(validation.getLeft().toNullable() ?? 'unknown'));
        }
      } finally {
        if (temp.existsSync()) temp.deleteSync();
      }

      final metaFile = File(p.join(_resolver.directory.path, AutoGroupRepository.metaFileName));
      await metaFile.writeAsString(
        jsonEncode({
          'builtAt': DateTime.now().toIso8601String(),
          'origins': merged.origins.map((tag, origin) => MapEntry(tag, origin.toJson())),
          'warnings': warnings,
        }),
      );

      final build = AutoGroupBuild(
        configPath: target.path,
        profileCount: sources.length,
        serverCount: merged.serverCount,
        warnings: warnings,
        builtAt: DateTime.now(),
      );
      _lastBuild = build;
      loggy.info(
        'auto group built: ${build.profileCount} profiles, ${build.serverCount} servers, ${warnings.length} warnings',
      );
      return right(build);
    } catch (e, st) {
      loggy.error('auto group build failed', e, st);
      return left(AutoGroupUnexpected(e, st));
    }
  });
}

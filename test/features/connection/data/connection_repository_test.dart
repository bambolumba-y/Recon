import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/auto_group/data/auto_group_repository.dart';
import 'package:hiddify/features/connection/data/connection_repository.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/profile/data/profile_path_resolver.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records every call instead of touching the real core, so the auto-connect
/// selection order can be asserted without a native library or a device.
class FakeSingboxService extends HiddifyCoreService {
  FakeSingboxService(Ref ref) : super(ref);

  final List<String> calls = [];

  /// selectOutbound throws a GrpcError this many times before it succeeds.
  /// A negative value means it always throws.
  int selectOutboundThrowsRemaining = 0;

  /// selectOutbound returns a Left (instead of throwing) on every call.
  bool selectOutboundReturnsLeft = false;

  @override
  TaskEither<String, Unit> setup() {
    calls.add('setup');
    return TaskEither.of(unit);
  }

  @override
  TaskEither<String, Unit> changeOptions(SingboxConfigOption options) {
    calls.add('changeOptions');
    return TaskEither.of(unit);
  }

  @override
  TaskEither<ConnectionFailure, Unit> start(String path, String name, bool disableMemoryLimit) {
    calls.add('start');
    return TaskEither.of(unit);
  }

  @override
  TaskEither<String, Unit> restart(String path, String name, bool disableMemoryLimit) {
    calls.add('restart');
    return TaskEither.of(unit);
  }

  @override
  TaskEither<String, Unit> selectOutbound(String groupTag, String outboundTag) {
    calls.add('selectOutbound($groupTag, $outboundTag)');
    if (selectOutboundReturnsLeft) {
      return TaskEither.left('lowest balancer not ready');
    }
    if (selectOutboundThrowsRemaining != 0) {
      if (selectOutboundThrowsRemaining > 0) selectOutboundThrowsRemaining--;
      return TaskEither(() async => throw GrpcError.unavailable());
    }
    return TaskEither.of(unit);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workDir;
  late ProfilePathResolver resolver;
  late ProviderContainer container;
  late FakeSingboxService singbox;
  late ConnectionRepositoryImpl repo;

  ProfileEntity profile(String id, String name) => ProfileEntity.remote(
    id: id,
    active: false,
    name: name,
    url: 'https://x/$id',
    lastUpdate: DateTime(2026),
    includeInAuto: true,
  );

  final originalSelectLowestRetryDelay = ConnectionRepositoryImpl.selectLowestRetryDelay;

  setUp(() async {
    // Fake delay so the retry tests do not sleep for real between attempts.
    ConnectionRepositoryImpl.selectLowestRetryDelay = Duration.zero;

    workDir = Directory.systemTemp.createTempSync('recon_connection_repo');
    resolver = ProfilePathResolver(workDir);
    resolver.directory.createSync(recursive: true);
    resolver
        .file('a')
        .writeAsStringSync(
          '{"outbounds": [{"type": "vless", "tag": "NL", "server": "a.example.com", "server_port": 443, '
          '"uuid": "00000000-0000-0000-0000-000000000000"}]}',
        );

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWith((ref) async => prefs)]);
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);

    final refProvider = Provider<Ref>((ref) => ref);
    final ref = container.read(refProvider);

    singbox = FakeSingboxService(ref);

    final autoGroupRepository = AutoGroupRepositoryImpl(
      profilePathResolver: resolver,
      watchMembersSource: () => Stream.value(right([profile('a', 'Alpha')])),
      setMembershipSource: (_, __) async {},
      validate: (path, tempPath) async {
        File(path).writeAsStringSync(File(tempPath).readAsStringSync());
        return right(unit);
      },
    );

    final configOptionRepository = ConfigOptionRepository(
      preferences: prefs,
      getConfigOptions: () => container.read(ConfigOptions.singboxConfigOptions),
    );

    repo = ConnectionRepositoryImpl(
      ref: ref,
      directories: (baseDir: workDir, workingDir: workDir, tempDir: workDir),
      singbox: singbox,
      configOptionRepository: configOptionRepository,
      profilePathResolver: resolver,
      autoGroupRepository: autoGroupRepository,
    );
  });

  tearDown(() {
    ConnectionRepositoryImpl.selectLowestRetryDelay = originalSelectLowestRetryDelay;
    workDir.deleteSync(recursive: true);
  });

  test('connectAutoGroup starts the core then selects the lowest-delay balancer', () async {
    final result = await repo.connectAutoGroup(false).run();

    expect(result.isRight(), isTrue, reason: result.getLeft().toNullable()?.toString());
    expect(singbox.calls[singbox.calls.length - 2], 'start');
    expect(singbox.calls.last, 'selectOutbound(select, lowest)');
  });

  test('reconnectAutoGroup restarts the core then selects the lowest-delay balancer', () async {
    final result = await repo.reconnectAutoGroup(false).run();

    expect(result.isRight(), isTrue, reason: result.getLeft().toNullable()?.toString());
    expect(singbox.calls[singbox.calls.length - 2], 'restart');
    expect(singbox.calls.last, 'selectOutbound(select, lowest)');
  });

  test('connectAutoGroup still completes when selecting the lowest-delay balancer always returns Left', () async {
    singbox.selectOutboundReturnsLeft = true;

    final result = await repo.connectAutoGroup(false).run();

    expect(result.isRight(), isTrue, reason: result.getLeft().toNullable()?.toString());
    expect(singbox.calls[singbox.calls.length - 4], 'start');
    expect(singbox.calls.where((c) => c == 'selectOutbound(select, lowest)').length, 3);
  });

  test('reconnectAutoGroup still completes when selecting the lowest-delay balancer always returns Left', () async {
    singbox.selectOutboundReturnsLeft = true;

    final result = await repo.reconnectAutoGroup(false).run();

    expect(result.isRight(), isTrue, reason: result.getLeft().toNullable()?.toString());
    expect(singbox.calls[singbox.calls.length - 4], 'restart');
    expect(singbox.calls.where((c) => c == 'selectOutbound(select, lowest)').length, 3);
  });

  test('connectAutoGroup completes after selectOutbound throws twice and succeeds on the third attempt', () async {
    singbox.selectOutboundThrowsRemaining = 2;

    final result = await repo.connectAutoGroup(false).run();

    expect(result.isRight(), isTrue, reason: result.getLeft().toNullable()?.toString());
    expect(singbox.calls.where((c) => c == 'selectOutbound(select, lowest)').length, 3);
  });

  test('connectAutoGroup still completes when selectOutbound always throws a GrpcError', () async {
    singbox.selectOutboundThrowsRemaining = -1;

    final result = await repo.connectAutoGroup(false).run();

    expect(result.isRight(), isTrue, reason: result.getLeft().toNullable()?.toString());
    expect(singbox.calls.where((c) => c == 'selectOutbound(select, lowest)').length, 3);
  });

  test('connect never selects a balancer', () async {
    final result = await repo.connect(profile('a', 'Alpha'), false).run();

    expect(result.isRight(), isTrue, reason: result.getLeft().toNullable()?.toString());
    expect(singbox.calls.last, 'start');
    expect(singbox.calls, isNot(contains('selectOutbound(select, lowest)')));
  });

  test('reconnect never selects a balancer', () async {
    final result = await repo.reconnect(profile('a', 'Alpha'), false).run();

    expect(result.isRight(), isTrue, reason: result.getLeft().toNullable()?.toString());
    expect(singbox.calls.last, 'restart');
    expect(singbox.calls, isNot(contains('selectOutbound(select, lowest)')));
  });
}

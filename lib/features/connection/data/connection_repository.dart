import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/utils/exception_handler.dart';
import 'package:hiddify/features/auto_group/data/auto_group_repository.dart';
import 'package:hiddify/features/auto_group/model/auto_group_failure.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/profile/data/profile_path_resolver.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/settings/notifier/warp_option/warp_option_notifier.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hiddify/singbox/model/core_status.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:meta/meta.dart';

abstract interface class ConnectionRepository {
  SingboxConfigOption? get configOptionsSnapshot;

  TaskEither<ConnectionFailure, Unit> setup();
  Stream<ConnectionStatus> watchConnectionStatus();
  TaskEither<ConnectionFailure, Unit> connect(ProfileEntity activeProfile, bool disableMemoryLimit);
  TaskEither<ConnectionFailure, Unit> disconnect();
  TaskEither<ConnectionFailure, Unit> reconnect(ProfileEntity activeProfile, bool disableMemoryLimit);
  TaskEither<ConnectionFailure, Unit> connectAutoGroup(bool disableMemoryLimit);
  TaskEither<ConnectionFailure, Unit> reconnectAutoGroup(bool disableMemoryLimit);
}

class ConnectionRepositoryImpl with ExceptionHandler, InfraLogger implements ConnectionRepository {
  ConnectionRepositoryImpl({
    required this.ref,
    required this.directories,
    required this.singbox,
    required this.configOptionRepository,
    required this.profilePathResolver,
    required this.autoGroupRepository,
  });

  final Ref ref;

  final Directories directories;
  final HiddifyCoreService singbox;

  final ConfigOptionRepository configOptionRepository;
  final ProfilePathResolver profilePathResolver;
  final AutoGroupRepository autoGroupRepository;

  SingboxConfigOption? _configOptionsSnapshot;
  @override
  SingboxConfigOption? get configOptionsSnapshot => _configOptionsSnapshot;

  bool _initialized = false;

  @override
  TaskEither<ConnectionFailure, Unit> setup() {
    if (_initialized) return TaskEither.of(unit);
    return exceptionHandler(() {
      loggy.debug("setting up singbox");

      return singbox
          .setup()
          .map((r) {
            _initialized = true;
            return r;
          })
          .mapLeft(UnexpectedConnectionFailure.new)
          .run();
    }, UnexpectedConnectionFailure.new);
  }

  @override
  Stream<ConnectionStatus> watchConnectionStatus() {
    return singbox.watchStatus().map(
      (event) => switch (event) {
        CoreStopped() => Disconnected(event.getCoreAlert()),
        CoreStarting() => const Connecting(),
        CoreStarted() => const Connected(),
        CoreStopping() => const Disconnecting(),
      },
    );
  }

  @override
  TaskEither<ConnectionFailure, Unit> connect(ProfileEntity activeProfile, bool disableMemoryLimit) => setup().flatMap(
    (_) => applyConfigOption(activeProfile.profileOverride).flatMap(
      (_) => singbox.start(profilePathResolver.file(activeProfile.id).path, activeProfile.name, disableMemoryLimit),
      // .mapLeft(UnexpectedConnectionFailure.new),
    ),
  );

  @override
  TaskEither<ConnectionFailure, Unit> disconnect() => singbox.stop().mapLeft(UnexpectedConnectionFailure.new);

  @override
  TaskEither<ConnectionFailure, Unit> reconnect(ProfileEntity activeProfile, bool disableMemoryLimit) =>
      applyConfigOption(activeProfile.profileOverride).flatMap(
        (_) => singbox
            .restart(profilePathResolver.file(activeProfile.id).path, activeProfile.name, disableMemoryLimit)
            .mapLeft(UnexpectedConnectionFailure.new),
      );

  @override
  TaskEither<ConnectionFailure, Unit> connectAutoGroup(bool disableMemoryLimit) => setup()
      .flatMap(
        (_) => applyConfigOption(null).flatMap(
          (_) => _buildAutoGroup().flatMap(
            (build) => singbox.start(build.configPath, AutoGroupRepository.displayName, disableMemoryLimit),
          ),
        ),
      )
      .flatMap((_) => _selectLowest());

  @override
  TaskEither<ConnectionFailure, Unit> reconnectAutoGroup(bool disableMemoryLimit) => applyConfigOption(null)
      .flatMap(
        (_) => _buildAutoGroup().flatMap(
          (build) => singbox
              .restart(build.configPath, AutoGroupRepository.displayName, disableMemoryLimit)
              .mapLeft(UnexpectedConnectionFailure.new),
        ),
      )
      .flatMap((_) => _selectLowest());

  TaskEither<ConnectionFailure, AutoGroupBuild> _buildAutoGroup() => autoGroupRepository.buildConfig().mapLeft(
    (failure) => switch (failure) {
      AutoGroupInvalidConfig(:final detail) => ConnectionFailure.invalidConfig(detail),
      _ => ConnectionFailure.unexpected(failure.message),
    },
  );

  /// Auto mode must run on the core's lowest-delay balancer, not on the selector's default (`balance`).
  /// `HiddifyCoreService.selectOutbound` rethrows any `GrpcError` from the core (the 1 s call deadline
  /// during a core restart, `UNAVAILABLE` while the core is restarting, "outbound not found in
  /// selector" for a single-server group) instead of always returning a `Left`, so each attempt is
  /// wrapped in `TaskEither.tryCatch` to catch both outcomes and retried up to
  /// [_selectLowestMaxAttempts] times, [selectLowestRetryDelay] apart. A selection failure must not
  /// fail the composed connect: `start`/`restart` already succeeded and the tunnel is up (on the
  /// selector's default outbound), so failing here would show a spurious connect error and disable
  /// the boot auto-restart. Log a warning after the last attempt and complete with success instead.
  static const _selectLowestMaxAttempts = 3;

  @visibleForTesting
  static Duration selectLowestRetryDelay = const Duration(seconds: 1);

  TaskEither<ConnectionFailure, Unit> _selectLowest() => _selectLowestAttempt(1);

  TaskEither<ConnectionFailure, Unit> _selectLowestAttempt(int attempt) =>
      TaskEither<ConnectionFailure, Either<String, Unit>>.tryCatch(
        () => singbox.selectOutbound('select', 'lowest').run(),
        (error, stackTrace) => ConnectionFailure.unexpected(error, stackTrace),
      ).flatMap((either) => TaskEither.fromEither(either).mapLeft(ConnectionFailure.unexpected)).orElse((failure) {
        if (attempt >= _selectLowestMaxAttempts) {
          loggy.warning('failed to select lowest-delay balancer after auto connect', failure);
          return TaskEither.of(unit);
        }
        return TaskEither(() async {
          await Future<void>.delayed(selectLowestRetryDelay);
          return _selectLowestAttempt(attempt + 1).run();
        });
      });

  @visibleForTesting
  TaskEither<ConnectionFailure, Unit> applyConfigOption(String? profileOverride) =>
      TaskEither.fromEither(configOptionRepository.fullOptionsOverrided(profileOverride))
          .mapLeft((l) => ConnectionFailure.invalidConfigOption(null, l))
          .flatMap(
            (overridedOptions) => TaskEither.tryCatch(() async {
              final isWarpLicenseAgreed = ref.read(warpLicenseNotifierProvider);
              final isWarpEnabled = overridedOptions.warp.enable || overridedOptions.warp2.enable;
              if (!isWarpLicenseAgreed && isWarpEnabled) {
                final isAgreed = await ref.read(dialogNotifierProvider.notifier).showWarpLicense();
                if (isAgreed == true) {
                  await ref.read(warpLicenseNotifierProvider.notifier).agree();
                } else {
                  throw const MissingWarpLicense();
                }
              }
              _configOptionsSnapshot = overridedOptions;
              await singbox.changeOptions(overridedOptions).run();
              return unit;
            }, (err, st) => err is ConnectionFailure ? err : ConnectionFailure.unexpected(err, st)),
          );
}

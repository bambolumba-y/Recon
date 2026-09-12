import 'dart:io';

import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/auto_group/data/auto_group_data_providers.dart';
import 'package:hiddify/features/auto_group/notifier/auto_group_notifier.dart';
import 'package:hiddify/features/connection/data/connection_data_providers.dart';
import 'package:hiddify/features/connection/data/connection_repository.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/hiddifycore/init_signal.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:rxdart/rxdart.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

part 'connection_notifier.g.dart';

@Riverpod(keepAlive: true)
class ConnectionNotifier extends _$ConnectionNotifier with AppLogger {
  @override
  Stream<ConnectionStatus> build() async* {
    if (Platform.isIOS) {
      await _connectionRepo.setup().mapLeft((l) {
        loggy.error("error setting up connection repository", l);
      }).run();
    }

    listenSelf((previous, next) async {
      if (previous == next) return;
      if (previous case AsyncData(:final value) when !value.isConnected) {
        if (next case AsyncData(value: final Connected _)) {
          await ref.read(hapticServiceProvider.notifier).heavyImpact();

          if (Platform.isAndroid && !ref.read(Preferences.storeReviewedByUser)) {
            if (await InAppReview.instance.isAvailable()) {
              InAppReview.instance.requestReview();
              ref.read(Preferences.storeReviewedByUser.notifier).update(true);
            }
          }
        }
      }
    });

    ref.listen(activeProfileProvider.select((value) => value.asData?.value), (previous, next) async {
      if (previous == null) return;
      if (ref.read(Preferences.autoGroupEnabled)) return; // auto mode ignores the active profile
      final shouldReconnect = next == null || previous.id != next.id;
      if (shouldReconnect) {
        await reconnect(next);
      }
    });

    ref.listen(Preferences.autoGroupEnabled, (previous, next) async {
      if (previous == null || previous == next) return;
      await _reconnectForCurrentMode();
    });

    // membership set or a member's content changed -> rebuild the merged config while connected in auto mode
    ref.listen(
      autoGroupMembersProvider.select(
        (value) => value.asData?.value.map((p) => '${p.id}:${p.lastUpdate.millisecondsSinceEpoch}').join(','),
      ),
      (previous, next) async {
        if (previous == null || previous == next) return;
        // a transient ProfileFailure makes the selector yield null; that is not a membership change
        if (next == null) return;
        if (!ref.read(Preferences.autoGroupEnabled)) return;
        if (next.isEmpty) {
          // The last member left the group. Auto mode has nothing left to build, and the card that
          // owns the switch is the only way out of the mode, so turn it off here. The
          // autoGroupEnabled listener above then reconnects in manual mode.
          loggy.info("auto group has no members left, disabling auto mode");
          await ref.read(Preferences.autoGroupEnabled.notifier).update(false);
          return;
        }
        await _reconnectForCurrentMode();
      },
    );
    ref.watch(coreRestartSignalProvider);

    yield* _connectionRepo.watchConnectionStatus().doOnData((event) {
      if (event case Disconnected(connectionFailure: final _?) when PlatformUtils.isDesktop) {
        ref.read(Preferences.startedByUser.notifier).update(false);
      }
      loggy.info("connection status: ${event.format()}");
    });
  }

  ConnectionRepository get _connectionRepo => ref.read(connectionRepositoryProvider);

  Future<void> mayConnect() async {
    if (state case AsyncData(:final value)) {
      if (value case Disconnected()) return _connect();
    }
  }

  Future<void> toggleConnection() async {
    final haptic = ref.read(hapticServiceProvider.notifier);
    if (state case AsyncError()) {
      await haptic.lightImpact();
      await _connect();
    } else if (state case AsyncData(:final value)) {
      switch (value) {
        case Disconnected():
          await haptic.lightImpact();
          await ref.read(Preferences.startedByUser.notifier).update(true);
          await _connect();
        case Connected():
          // default:
          await haptic.mediumImpact();
          await ref.read(Preferences.startedByUser.notifier).update(false);
          await _disconnect();
        default:
          loggy.warning("switching status, debounce");
      }
    }
  }

  Future<void> reconnect(ProfileEntity? profile) async {
    if (state case AsyncData(:final value) when value == const Connected()) {
      // external callers pass the active profile; in auto mode that profile is not what the core runs on
      if (ref.read(Preferences.autoGroupEnabled)) return _runAutoReconnect();
      if (profile == null) {
        loggy.info("no active profile, disconnecting");
        return _disconnect();
      }
      loggy.info("active profile changed, reconnecting");
      await ref.read(Preferences.startedByUser.notifier).update(true);
      await _connectionRepo.reconnect(profile, ref.read(Preferences.disableMemoryLimit)).mapLeft((err) async {
        loggy.warning("error reconnecting", err);
        state = AsyncError(err, StackTrace.current);
        await ref
            .read(dialogNotifierProvider.notifier)
            .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
      }).run();
    }
  }

  Future<void> abortConnection() async {
    if (state case AsyncData(:final value)) {
      switch (value) {
        case Connected() || Connecting():
          loggy.debug("aborting connection");
          await _disconnect();
        default:
      }
    }
  }

  final _singleStart = SingleCall();

  Future<void> _connect() async {
    _singleStart.run(
      () async {
        await _connectThrottled();
      },
      onIgnored: () {
        loggy.debug("connect called while another connect/disconnect is still running, ignoring");
      },
    );
  }

  Future<void> _connectThrottled() async {
    if (ref.read(Preferences.autoGroupEnabled)) {
      final result = await _connectionRepo.connectAutoGroup(ref.read(Preferences.disableMemoryLimit)).run();
      await result.match<Future<void>>(_onConnectError, (_) async => _publishAutoGroupBuild());
      return;
    }
    final activeProfile = await ref.read(activeProfileProvider.future);
    if (activeProfile == null) {
      loggy.info("no active profile, not connecting");
      return;
    }
    await _connectionRepo
        .connect(activeProfile, ref.read(Preferences.disableMemoryLimit))
        .mapLeft(_onConnectError)
        .run();
  }

  Future<void> _onConnectError(ConnectionFailure err) async {
    loggy.warning("error connecting", err);
    //Go err is not normal object to see the go errors are string and need to be dumped
    await ref
        .read(dialogNotifierProvider.notifier)
        .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
    if (err.toString().contains("panic")) {
      await Sentry.captureException(Exception(err.toString()));
    }
    await ref.read(Preferences.startedByUser.notifier).update(false);
    state = AsyncError(err, StackTrace.current);
  }

  Future<void> _reconnectForCurrentMode() async {
    if (state case AsyncData(:final value) when value == const Connected()) {
      if (ref.read(Preferences.autoGroupEnabled)) {
        await _runAutoReconnect();
      } else {
        await reconnect(await ref.read(activeProfileProvider.future));
      }
    }
  }

  bool _autoReconnecting = false;
  bool _autoReconnectPending = false;

  /// Single entry point for every auto-mode restart: the mode toggle, the members listener and the delegated
  /// [reconnect]. The core accepts a restart RPC before the tunnel is up, so the connection state does not serialize
  /// these calls. A request that arrives while a restart runs is remembered and replayed once afterwards; it is not
  /// dropped, because it may carry a change the running restart did not read yet (a config option, for instance).
  Future<void> _runAutoReconnect() async {
    if (_autoReconnecting) {
      _autoReconnectPending = true;
      loggy.debug("auto group reconnect already running, coalescing");
      return;
    }
    _autoReconnecting = true;
    try {
      do {
        _autoReconnectPending = false;
        loggy.info("auto group changed, reconnecting");
        final result = await _connectionRepo.reconnectAutoGroup(ref.read(Preferences.disableMemoryLimit)).run();
        await result.match<Future<void>>(_onReconnectError, (_) async => _publishAutoGroupBuild());
      } while (_autoReconnectPending);
    } finally {
      _autoReconnecting = false;
    }
  }

  Future<void> _onReconnectError(ConnectionFailure err) async {
    loggy.warning("error reconnecting", err);
    state = AsyncError(err, StackTrace.current);
    await ref
        .read(dialogNotifierProvider.notifier)
        .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
  }

  void _publishAutoGroupBuild() {
    final build = ref.read(autoGroupRepositoryProvider).lastBuild;
    if (build != null) ref.read(autoGroupNotifierProvider.notifier).recordBuild(build);
  }

  Future<void> _disconnect() async {
    await _connectionRepo.disconnect().mapLeft((err) {
      loggy.warning("error disconnecting", err);
      ref
          .read(dialogNotifierProvider.notifier)
          .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
      state = AsyncError(err, StackTrace.current);
    }).run();
  }
}

@Riverpod(keepAlive: true)
Future<bool> serviceRunning(Ref ref) async {
  // ref.watch(coreRestartSignalProvider);
  return await ref
      .watch(connectionNotifierProvider.selectAsync((data) => data.isConnected))
      .onError((error, stackTrace) => false);
}

class SingleCall {
  bool _running = false;

  Future<T> run<T>(Future<T> Function() task, {required T onIgnored}) async {
    if (_running) return onIgnored;

    _running = true;
    try {
      return await task();
    } finally {
      _running = false;
    }
  }
}

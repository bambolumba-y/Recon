import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/utils/exception_handler.dart';
import 'package:hiddify/features/log/data/log_parser.dart';
import 'package:hiddify/features/log/data/log_path_resolver.dart';
import 'package:hiddify/features/log/data/log_retention.dart';
import 'package:hiddify/features/log/model/log_entity.dart';
import 'package:hiddify/features/log/model/log_failure.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/utils/custom_loggers.dart';

abstract interface class LogRepository {
  TaskEither<LogFailure, Unit> init();
  Stream<Either<LogFailure, List<LogEntity>>> watchLogs();
  TaskEither<LogFailure, Unit> clearLogs();
}

class LogRepositoryImpl with ExceptionHandler, InfraLogger implements LogRepository {
  LogRepositoryImpl({
    required this.singbox,
    required this.logPathResolver,
    this.logMaxBytes = coreLogMaxBytes,
    this.logKeepBytes = coreLogKeepBytes,
  });

  final HiddifyCoreService singbox;
  final LogPathResolver logPathResolver;
  final int logMaxBytes;
  final int logKeepBytes;

  // The core keeps appending to box.log for as long as the VPN service runs,
  // independently of the UI process; cap it well above a multi-day
  // failover/diag observation window instead of wiping it on every app start.
  static const coreLogMaxBytes = 64 * 1024 * 1024;
  // Trim back to half the cap so a trim does not fire again right away.
  static const coreLogKeepBytes = 32 * 1024 * 1024;

  @override
  TaskEither<LogFailure, Unit> init() {
    return exceptionHandler(() async {
      if (!kIsWeb) {
        if (!await logPathResolver.directory.exists()) {
          await logPathResolver.directory.create(recursive: true);
        }
        if (await logPathResolver.coreFile().exists()) {
          await trimLogFile(logPathResolver.coreFile(), maxBytes: logMaxBytes, keepBytes: logKeepBytes);
        } else {
          await logPathResolver.coreFile().create(recursive: true);
        }
        if (await logPathResolver.appFile().exists()) {
          await trimLogFile(logPathResolver.appFile(), maxBytes: logMaxBytes, keepBytes: logKeepBytes);
        } else {
          await logPathResolver.appFile().create(recursive: true);
        }
      }
      return right(unit);
    }, LogUnexpectedFailure.new);
  }

  @override
  Stream<Either<LogFailure, List<LogEntity>>> watchLogs() {
    return singbox
        .watchLogs(logPathResolver.coreFile().path)
        .map((event) => event.map(LogParser.parseLogProto).toList())
        .handleExceptions((error, stackTrace) {
          loggy.warning("error watching logs", error, stackTrace);
          return LogFailure.unexpected(error, stackTrace);
        });
  }

  @override
  TaskEither<LogFailure, Unit> clearLogs() {
    return exceptionHandler(() => singbox.clearLogs().mapLeft(LogFailure.unexpected).run(), LogFailure.unexpected);
  }
}

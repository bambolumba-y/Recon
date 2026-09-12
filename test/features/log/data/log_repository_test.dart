import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/log/data/log_path_resolver.dart';
import 'package:hiddify/features/log/data/log_repository.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';

/// init() never touches the core; every call is unexpected in this test.
class _NoopCore implements HiddifyCoreService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workDir;
  late LogPathResolver resolver;

  setUp(() async {
    workDir = await Directory.systemTemp.createTemp("log_repository_test");
    resolver = LogPathResolver(workDir);
  });

  tearDown(() async {
    await workDir.delete(recursive: true);
  });

  LogRepositoryImpl repo({int? logMaxBytes, int? logKeepBytes}) {
    return LogRepositoryImpl(
      singbox: _NoopCore(),
      logPathResolver: resolver,
      logMaxBytes: logMaxBytes ?? LogRepositoryImpl.coreLogMaxBytes,
      logKeepBytes: logKeepBytes ?? LogRepositoryImpl.coreLogKeepBytes,
    );
  }

  test("creates both log files when missing", () async {
    final result = await repo().init().run();

    expect(result.isRight(), isTrue);
    expect(await resolver.coreFile().exists(), isTrue);
    expect(await resolver.appFile().exists(), isTrue);
  });

  test("preserves existing content of both files when they are small", () async {
    await resolver.coreFile().create(recursive: true);
    await resolver.coreFile().writeAsString("failover: existing core line\n");
    await resolver.appFile().create(recursive: true);
    await resolver.appFile().writeAsString("existing app line\n");

    final result = await repo().init().run();

    expect(result.isRight(), isTrue);
    expect(await resolver.coreFile().readAsString(), "failover: existing core line\n");
    expect(await resolver.appFile().readAsString(), "existing app line\n");
  });

  test("trims an oversized box.log", () async {
    final lines = List.generate(200, (i) => "diag: line $i ${"x" * 10}").join("\n") + "\n";
    await resolver.coreFile().create(recursive: true);
    await resolver.coreFile().writeAsString(lines);
    await resolver.appFile().create(recursive: true);
    await resolver.appFile().writeAsString("small app content\n");

    final result = await repo(logMaxBytes: 1000, logKeepBytes: 400).init().run();

    expect(result.isRight(), isTrue);
    final coreLength = await resolver.coreFile().length();
    expect(coreLength, lessThanOrEqualTo(400));
    expect(coreLength, lessThan(lines.length));
    expect(await resolver.coreFile().readAsString(), endsWith("diag: line 199 ${"x" * 10}\n"));
    // app.log is well under the (small, test-only) cap, so it stays intact.
    expect(await resolver.appFile().readAsString(), "small app content\n");
  });
}

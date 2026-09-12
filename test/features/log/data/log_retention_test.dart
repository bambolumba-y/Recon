import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/log/data/log_retention.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp("log_retention_test");
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  File makeFile(String name, String content) {
    final file = File("${tempDir.path}/$name");
    file.writeAsStringSync(content);
    return file;
  }

  test("file below the cap is left byte-identical", () async {
    final content = "line one\nline two\nline three\n";
    final file = makeFile("small.log", content);

    final dropped = await trimLogFile(file, maxBytes: 1000, keepBytes: 400);

    expect(dropped, 0);
    expect(await file.readAsString(), content);
  });

  test("file above the cap is trimmed to at most keepBytes, starts and ends on line boundaries", () async {
    final lines = List.generate(200, (i) => "line $i " + "x" * 10).join("\n") + "\n";
    final file = makeFile("big.log", lines);
    final originalBytes = utf8.encode(lines);
    expect(originalBytes.length, greaterThan(1000));

    final dropped = await trimLogFile(file, maxBytes: 1000, keepBytes: 400);

    final resultBytes = await file.readAsBytes();
    expect(resultBytes.length, lessThanOrEqualTo(400));
    expect(dropped, originalBytes.length - resultBytes.length);

    // starts with a complete line: the first byte after a '\n' of the original
    final tailStart = originalBytes.length - 400;
    final tail = originalBytes.sublist(tailStart);
    final newlineIndex = tail.indexOf(0x0A);
    final expectedStart = tail.sublist(newlineIndex + 1);
    expect(resultBytes, expectedStart);

    // ends with the original last line
    expect(utf8.decode(resultBytes), endsWith("line 199 " + "x" * 10 + "\n"));
  });

  test("missing file is a no-op returning 0", () async {
    final file = File("${tempDir.path}/missing.log");

    final dropped = await trimLogFile(file, maxBytes: 1000, keepBytes: 400);

    expect(dropped, 0);
    expect(await file.exists(), isFalse);
  });

  test("a tail without any newline is kept whole", () async {
    // one giant line, no newlines anywhere in the file
    final content = "x" * 1200;
    final file = makeFile("no_newline.log", content);

    final dropped = await trimLogFile(file, maxBytes: 1000, keepBytes: 400);

    final resultBytes = await file.readAsBytes();
    expect(resultBytes.length, 400);
    expect(dropped, 1200 - 400);
    expect(utf8.decode(resultBytes), "x" * 400);
  });
}

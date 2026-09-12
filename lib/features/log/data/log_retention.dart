import 'dart:io';

/// Keeps a log file bounded without dropping it on every start.
/// If [file] is longer than [maxBytes], rewrites it to hold only the last
/// [keepBytes] bytes, starting at the first full line. Returns bytes dropped.
Future<int> trimLogFile(File file, {required int maxBytes, required int keepBytes}) async {
  assert(keepBytes < maxBytes, "keepBytes must be less than maxBytes");

  if (!await file.exists()) return 0;

  final length = await file.length();
  if (length <= maxBytes) return 0;

  final raf = await file.open();
  final List<int> tail;
  try {
    await raf.setPosition(length - keepBytes);
    tail = await raf.read(keepBytes);
  } finally {
    await raf.close();
  }

  // Drop the partial first line so the kept content starts on a line
  // boundary; if the tail has no newline at all, keep it whole.
  final newlineIndex = tail.indexOf(0x0A);
  final kept = newlineIndex == -1 ? tail : tail.sublist(newlineIndex + 1);

  // Write to a sibling temp file first and rename it over the original, so
  // a crash mid-write never leaves a truncated log in place.
  final tempFile = File("${file.path}.tmp");
  final sink = tempFile.openWrite(mode: FileMode.writeOnly);
  sink.add(kept);
  await sink.flush();
  await sink.close();
  await tempFile.rename(file.path);

  return length - kept.length;
}

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

  // Rewrite in place rather than rename a new file over the old one: the core
  // process keeps box.log open with O_APPEND, and a rename would leave it
  // writing to the unlinked inode until the next VPN start. After an in-place
  // truncate its next write lands after the kept tail.
  await file.writeAsBytes(kept, mode: FileMode.writeOnly, flush: true);

  return length - kept.length;
}

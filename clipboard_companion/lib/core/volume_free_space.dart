import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

const _storageChannel = MethodChannel('clipboard_companion/storage');

/// Reported when free space cannot be determined: unknown free space does not
/// block transfers.
const int unknownFreeSpace = 1 << 62;

/// Free bytes on the volume holding [directory] (its nearest existing
/// ancestor). Windows asks the OS directly; Android and iOS ask the host app
/// over `clipboard_companion/storage`; elsewhere the value is unknown.
Future<int> volumeFreeSpace(Directory directory) async {
  final path = _nearestExisting(directory).path;
  try {
    if (Platform.isWindows) return _windowsFreeSpace(path) ?? unknownFreeSpace;
    if (Platform.isAndroid || Platform.isIOS) {
      final bytes = await _storageChannel.invokeMethod<int>('freeSpace', {
        'path': path,
      });
      return bytes ?? unknownFreeSpace;
    }
  } catch (_) {
    // Fall through: an unavailable query must not break receiving.
  }
  return unknownFreeSpace;
}

Directory _nearestExisting(Directory directory) {
  var current = directory.absolute;
  while (!current.existsSync() && current.parent.path != current.path) {
    current = current.parent;
  }
  return current;
}

typedef _GetDiskFreeSpaceExNative =
    Int32 Function(
      Pointer<Utf16> directory,
      Pointer<Uint64> freeBytesAvailableToCaller,
      Pointer<Uint64> totalBytes,
      Pointer<Uint64> totalFreeBytes,
    );
typedef _GetDiskFreeSpaceExDart =
    int Function(
      Pointer<Utf16> directory,
      Pointer<Uint64> freeBytesAvailableToCaller,
      Pointer<Uint64> totalBytes,
      Pointer<Uint64> totalFreeBytes,
    );

int? _windowsFreeSpace(String path) {
  final getDiskFreeSpaceEx = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<_GetDiskFreeSpaceExNative, _GetDiskFreeSpaceExDart>(
        'GetDiskFreeSpaceExW',
      );
  final nativePath = path.toNativeUtf16();
  final available = calloc<Uint64>();
  try {
    final ok = getDiskFreeSpaceEx(nativePath, available, nullptr, nullptr);
    return ok != 0 ? available.value : null;
  } finally {
    calloc.free(nativePath);
    calloc.free(available);
  }
}

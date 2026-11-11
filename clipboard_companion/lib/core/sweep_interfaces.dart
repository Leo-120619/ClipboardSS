import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

/// One local IPv4 address the subnet sweep could start from.
class SweepInterface {
  final String name;
  final String address;
  final int prefixLength;

  /// True when the OS routes the default route through this interface
  /// (known on Android and Windows; false where it cannot be read).
  final bool isDefaultRoute;

  const SweepInterface({
    required this.name,
    required this.address,
    required this.prefixLength,
    this.isDefaultRoute = false,
  });
}

const _networkChannel = MethodChannel('clipboard_companion/network');

/// Local IPv4 interfaces with their real prefix lengths. Android asks the host
/// app (ConnectivityManager knows the default network); Windows asks the IP
/// Helper API; iOS and macOS read `getifaddrs`. Anything else, or a failed
/// query, falls back to `dart:io` with an assumed /24.
Future<List<SweepInterface>> listSweepInterfaces() async {
  try {
    if (Platform.isAndroid) {
      final raw = await _networkChannel.invokeListMethod<Map<Object?, Object?>>(
        'ipv4Interfaces',
      );
      final parsed = [
        for (final entry in raw ?? const <Map<Object?, Object?>>[])
          ?_fromChannel(entry),
      ];
      if (parsed.isNotEmpty) return parsed;
    } else if (Platform.isWindows) {
      final found = _windowsInterfaces();
      if (found.isNotEmpty) return found;
    } else if (Platform.isIOS || Platform.isMacOS) {
      final found = darwinInterfaces();
      if (found.isNotEmpty) return found;
    }
  } catch (_) {
    // Fall through to the portable listing.
  }
  return _dartIoInterfaces();
}

SweepInterface? _fromChannel(Map<Object?, Object?> entry) {
  final name = entry['name'];
  final address = entry['address'];
  final prefix = entry['prefixLength'];
  if (name is! String || address is! String || prefix is! int) return null;
  return SweepInterface(
    name: name,
    address: address,
    prefixLength: prefix,
    isDefaultRoute: entry['isDefaultRoute'] == true,
  );
}

Future<List<SweepInterface>> _dartIoInterfaces() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  return [
    for (final ni in interfaces)
      for (final address in ni.addresses)
        if (!address.isLoopback)
          SweepInterface(
            name: ni.name,
            address: address.address,
            prefixLength: 24,
          ),
  ];
}

int _prefixOfMask(List<int> maskBytes) {
  var bits = 0;
  for (final byte in maskBytes) {
    var b = byte;
    while (b & 0x80 != 0) {
      bits++;
      b = (b << 1) & 0xFF;
    }
    if (byte != 0xFF) break;
  }
  return bits;
}

// MARK: - Darwin (getifaddrs)

final class _IfAddrs extends Struct {
  external Pointer<_IfAddrs> next;
  external Pointer<Utf8> name;
  @Uint32()
  external int flags;
  external Pointer<Uint8> addr;
  external Pointer<Uint8> netmask;
  external Pointer<Void> dstaddr;
  external Pointer<Void> data;
}

typedef _GetIfAddrsNative = Int32 Function(Pointer<Pointer<_IfAddrs>>);
typedef _GetIfAddrsDart = int Function(Pointer<Pointer<_IfAddrs>>);
typedef _FreeIfAddrsNative = Void Function(Pointer<_IfAddrs>);
typedef _FreeIfAddrsDart = void Function(Pointer<_IfAddrs>);

const _iffUp = 0x1;
const _iffLoopback = 0x8;
const _afInet = 2;

/// Up, non-loopback IPv4 interfaces from `getifaddrs` (BSD `sockaddr_in`
/// layout: length byte, family byte, port, then the address).
List<SweepInterface> darwinInterfaces() {
  final lib = DynamicLibrary.process();
  final getifaddrs = lib.lookupFunction<_GetIfAddrsNative, _GetIfAddrsDart>(
    'getifaddrs',
  );
  final freeifaddrs = lib.lookupFunction<_FreeIfAddrsNative, _FreeIfAddrsDart>(
    'freeifaddrs',
  );
  final head = calloc<Pointer<_IfAddrs>>();
  try {
    if (getifaddrs(head) != 0) return const [];
    final result = <SweepInterface>[];
    try {
      for (var p = head.value; p != nullptr; p = p.ref.next) {
        final entry = p.ref;
        if (entry.flags & _iffUp == 0 || entry.flags & _iffLoopback != 0) {
          continue;
        }
        if (entry.addr == nullptr || entry.netmask == nullptr) continue;
        if (entry.addr[1] != _afInet) continue;
        final address = [for (var i = 4; i < 8; i++) entry.addr[i]].join('.');
        result.add(
          SweepInterface(
            name: entry.name.toDartString(),
            address: address,
            prefixLength: _prefixOfMask([
              for (var i = 4; i < 8; i++) entry.netmask[i],
            ]),
          ),
        );
      }
    } finally {
      freeifaddrs(head.value);
    }
    return result;
  } finally {
    calloc.free(head);
  }
}

// MARK: - Windows (IP Helper)

typedef _GetBestInterfaceNative = Uint32 Function(Uint32, Pointer<Uint32>);
typedef _GetBestInterfaceDart = int Function(int, Pointer<Uint32>);
typedef _GetIpAddrTableNative =
    Uint32 Function(Pointer<Uint8>, Pointer<Uint32>, Int32);
typedef _GetIpAddrTableDart =
    int Function(Pointer<Uint8>, Pointer<Uint32>, int);

const _errorInsufficientBuffer = 122;
const _mibIpAddrRowSize = 24;
const _mibIpAddrDisconnected = 0x0008;
const _mibIpAddrDeleted = 0x0040;

/// IPv4 rows of `GetIpAddrTable`; the row whose interface `GetBestInterface`
/// picks for a public destination holds the default route.
List<SweepInterface> _windowsInterfaces() {
  final iphlpapi = DynamicLibrary.open('iphlpapi.dll');
  final getBestInterface = iphlpapi
      .lookupFunction<_GetBestInterfaceNative, _GetBestInterfaceDart>(
        'GetBestInterface',
      );
  final getIpAddrTable = iphlpapi
      .lookupFunction<_GetIpAddrTableNative, _GetIpAddrTableDart>(
        'GetIpAddrTable',
      );

  final bestIndex = calloc<Uint32>();
  final size = calloc<Uint32>();
  Pointer<Uint8> table = nullptr;
  try {
    // 8.8.8.8 reads the same in either byte order.
    final hasBest = getBestInterface(0x08080808, bestIndex) == 0;
    if (getIpAddrTable(nullptr, size, 0) != _errorInsufficientBuffer) {
      return const [];
    }
    table = calloc<Uint8>(size.value);
    if (getIpAddrTable(table, size, 0) != 0) return const [];

    final count = table.cast<Uint32>().value;
    final result = <SweepInterface>[];
    for (var i = 0; i < count; i++) {
      final row = table + 4 + i * _mibIpAddrRowSize;
      final index = (row + 4).cast<Uint32>().value;
      final type = (row + 22).cast<Uint16>().value;
      if (type & (_mibIpAddrDisconnected | _mibIpAddrDeleted) != 0) continue;
      final addressBytes = [for (var b = 0; b < 4; b++) row[b]];
      if (addressBytes[0] == 127 || addressBytes.every((b) => b == 0)) {
        continue;
      }
      result.add(
        SweepInterface(
          name: 'if$index',
          address: addressBytes.join('.'),
          prefixLength: _prefixOfMask([for (var b = 8; b < 12; b++) row[b]]),
          isDefaultRoute: hasBest && index == bestIndex.value,
        ),
      );
    }
    return result;
  } finally {
    calloc.free(bestIndex);
    calloc.free(size);
    if (table != nullptr) calloc.free(table);
  }
}

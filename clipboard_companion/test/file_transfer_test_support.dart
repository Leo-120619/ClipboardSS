import 'dart:convert';
import 'dart:io';
import 'package:clipboard_companion/core/content_hasher.dart';
import 'package:clipboard_companion/core/crypto_utils.dart';
import 'package:clipboard_companion/core/file_receiver.dart';
import 'package:clipboard_companion/core/file_transfer_crypto.dart';
import 'package:clipboard_companion/core/file_transfer_models.dart';
import 'package:clipboard_companion/core/models.dart';
import 'package:clipboard_companion/core/paired_device_store.dart';
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Mutable clock for idle-GC tests.
class MutableClock {
  DateTime current;
  MutableClock(this.current);
  DateTime now() => current;
  void advance(Duration by) => current = current.add(by);
}

Future<PairedDeviceStore> makePairedStore(String peerId, SecretKey key) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final store = PairedDeviceStore(prefs);
  await store.addDevice(PairedDevice(id: peerId, name: 'Peer'), key);
  return store;
}

Directory makeTempDir(String prefix) =>
    Directory.systemTemp.createTempSync('clipss-$prefix-');

/// Builds an offer envelope + sealed chunks for [data] split at [chunkSize].
class PreparedTransfer {
  final ClipEnvelope offer;
  final List<List<int>> chunks;
  final String transferId;
  PreparedTransfer(this.offer, this.chunks, this.transferId);
}

Future<PreparedTransfer> prepareTransfer({
  required List<int> data,
  required int chunkSize,
  required String peerId,
  required SecretKey key,
  String fileName = 'file.bin',
  String? overrideHash,
}) async {
  final transferId = const Uuid().v4().toLowerCase();
  final fileKey = await FileTransferCrypto.deriveFileKey(key, transferId);
  final chunks = <List<int>>[];
  for (var offset = 0; offset < data.length; offset += chunkSize) {
    final end = (offset + chunkSize) < data.length ? offset + chunkSize : data.length;
    chunks.add(await FileTransferCrypto.sealChunk(data.sublist(offset, end), fileKey, chunks.length));
  }
  final payload = FileOfferPayload(
    transferId: transferId,
    fileName: fileName,
    fileSize: data.length,
    mimeType: 'application/octet-stream',
    fileHash: overrideHash ?? ContentHasher.fileHash(data),
    chunkSize: chunkSize,
    chunkCount: chunks.length,
    createdAt: DateTime.now(),
    sourceDeviceName: 'Peer',
  );
  final offer = await CryptoEnvelopeUtils.sealJson(payload.toJson(), peerId, key);
  return PreparedTransfer(offer, chunks, transferId);
}

Future<ClipEnvelope> sealControl(Map<String, dynamic> json, String peerId, SecretKey key) =>
    CryptoEnvelopeUtils.sealJson(json, peerId, key);

String statusOf(FileTransferResponse response) => response.body['status'] as String? ?? '';

String jsonBody(FileTransferResponse response) => jsonEncode(response.body);

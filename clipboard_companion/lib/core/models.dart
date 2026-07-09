enum ClipType { text, image }

String canonicalDeviceId(String id) => id.trim().toLowerCase();

class ClipPayload {
  final String id;
  final ClipType type;
  final DateTime createdAt;
  final String? text;
  final String? imageBase64;
  final String? imageExtension;
  final String? previewText;
  final String contentHash;
  final String sourceDeviceName;

  ClipPayload({
    required this.id,
    required this.type,
    required this.createdAt,
    this.text,
    this.imageBase64,
    this.imageExtension,
    this.previewText,
    required this.contentHash,
    required this.sourceDeviceName,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type == ClipType.text ? 'text' : 'image',
      'createdAt': '${createdAt.toUtc().toIso8601String().split('.').first.replaceAll('Z', '')}Z',
      'text': text,
      'imageBase64': imageBase64,
      'imageExtension': imageExtension,
      'previewText': previewText ?? (type == ClipType.text ? (text != null ? (text!.length > 100 ? '${text!.substring(0, 100)}...' : text!) : '') : 'Image clip'),
      'contentHash': contentHash,
      'sourceDeviceName': sourceDeviceName,
    };
  }

  factory ClipPayload.fromJson(Map<String, dynamic> json) {
    return ClipPayload(
      id: json['id'] as String,
      type: json['type'] == 'image' ? ClipType.image : ClipType.text,
      createdAt: DateTime.parse(json['createdAt'] as String),
      text: json['text'] as String?,
      imageBase64: json['imageBase64'] as String?,
      imageExtension: json['imageExtension'] as String?,
      previewText: json['previewText'] as String?,
      contentHash: json['contentHash'] as String,
      sourceDeviceName: json['sourceDeviceName'] as String,
    );
  }
}

class ClipEnvelope {
  final int v;
  final String sourceDeviceId;
  final String nonce;
  final String ciphertext;

  ClipEnvelope({
    required this.v,
    required String sourceDeviceId,
    required this.nonce,
    required this.ciphertext,
  }) : sourceDeviceId = canonicalDeviceId(sourceDeviceId);

  Map<String, dynamic> toJson() {
    return {
      'v': v,
      'sourceDeviceId': sourceDeviceId,
      'nonce': nonce,
      'ciphertext': ciphertext,
    };
  }

  factory ClipEnvelope.fromJson(Map<String, dynamic> json) {
    return ClipEnvelope(
      v: json['v'] as int,
      sourceDeviceId: json['sourceDeviceId'] as String,
      nonce: json['nonce'] as String,
      ciphertext: json['ciphertext'] as String,
    );
  }
}

class Peer {
  final String id;
  final String name;
  final String host;
  final int port;

  Peer({
    required String id,
    required this.name,
    required this.host,
    required this.port,
  }) : id = canonicalDeviceId(id);
}

class PairedDevice {
  final String id;
  final String name;
  final String? host;

  PairedDevice({
    required String id,
    required this.name,
    this.host,
  }) : id = canonicalDeviceId(id);

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      if (host != null) 'host': host,
    };
  }

  factory PairedDevice.fromJson(Map<String, dynamic> json) {
    return PairedDevice(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String?,
    );
  }
}

class DeviceIdentity {
  final String id;
  final String name;

  DeviceIdentity({
    required String id,
    required this.name,
  }) : id = canonicalDeviceId(id);
}

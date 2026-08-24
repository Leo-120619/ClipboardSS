import 'dart:convert';

import 'package:clipboard_companion/core/models.dart';
import 'package:clipboard_companion/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('image clips render an image preview', (tester) async {
    final clip = ClipPayload(
      id: 'image-1',
      type: ClipType.image,
      createdAt: DateTime(2026),
      imageBase64: base64Encode(_onePixelPng),
      imageExtension: 'png',
      previewText: 'Image',
      contentHash: 'image-hash',
      sourceDeviceName: 'Mac',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: ReceivedClipTile(
            clip: clip,
            isProminent: true,
            onCopyImage: (_) async {},
            onDelete: () {},
          ),
        ),
      ),
    );

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Image'), findsOneWidget);
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_return_rounded), findsOneWidget);
  });

  testWidgets('clip source name truncates in narrow cards with actions', (
    tester,
  ) async {
    final clip = ClipPayload(
      id: 'text-1',
      type: ClipType.text,
      createdAt: DateTime.now(),
      text: 'Hello',
      contentHash: 'text-hash',
      sourceDeviceName: 'A very long Android device name',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: ReceivedClipTile(
              clip: clip,
              onCopyImage: (_) async {},
              onDelete: () {},
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
  });
}

const _onePixelPng = <int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1f,
  0x15,
  0xc4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0a,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9c,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0d,
  0x0a,
  0x2d,
  0xb4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4e,
  0x44,
  0xae,
  0x42,
  0x60,
  0x82,
];

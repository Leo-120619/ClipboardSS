import 'dart:convert';

import 'package:clipboard_companion/core/app_state.dart';
import 'package:clipboard_companion/core/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'deleteClip removes one clip and persists the remaining clips',
    () async {
      final clips = [
        _clip('clip-1', 'First', DateTime.now()),
        _clip('clip-2', 'Second', DateTime.now()),
      ];
      SharedPreferences.setMockInitialValues({
        'saved_clips': jsonEncode(clips.map((clip) => clip.toJson()).toList()),
      });
      final prefs = await SharedPreferences.getInstance();
      final state = AppState();
      await state.init(prefs);

      await state.deleteClip('clip-1');

      expect(state.clips.map((clip) => clip.id), ['clip-2']);
      final saved =
          jsonDecode(prefs.getString('saved_clips')!) as List<dynamic>;
      expect(saved.map((clip) => (clip as Map<String, dynamic>)['id']), [
        'clip-2',
      ]);
    },
  );

  test('clearClips removes all clips and persists an empty list', () async {
    final clips = [
      _clip('clip-1', 'First', DateTime.now()),
      _clip('clip-2', 'Second', DateTime.now()),
    ];
    SharedPreferences.setMockInitialValues({
      'saved_clips': jsonEncode(clips.map((clip) => clip.toJson()).toList()),
    });
    final prefs = await SharedPreferences.getInstance();
    final state = AppState();
    await state.init(prefs);

    await state.clearClips();

    expect(state.clips, isEmpty);
    expect(jsonDecode(prefs.getString('saved_clips')!), isEmpty);
  });
}

ClipPayload _clip(String id, String text, DateTime createdAt) {
  return ClipPayload(
    id: id,
    type: ClipType.text,
    createdAt: createdAt,
    text: text,
    contentHash: '$id-hash',
    sourceDeviceName: 'Mac',
  );
}

import 'dart:convert';

import 'package:clipboard_companion/core/app_state.dart';
import 'package:clipboard_companion/core/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  ClipPayload clip(String id) => ClipPayload(
    id: id,
    type: ClipType.text,
    createdAt: DateTime.now(),
    text: 'text $id',
    contentHash: '$id-hash',
    sourceDeviceName: 'Phone',
  );

  Future<AppState> stateWith(List<ClipPayload> clips) async {
    SharedPreferences.setMockInitialValues({
      'saved_clips': jsonEncode(clips.map((c) => c.toJson()).toList()),
    });
    final state = AppState();
    await state.init(await SharedPreferences.getInstance());
    return state;
  }

  test('re-sending an existing clip does not insert a duplicate', () async {
    final state = await stateWith([clip('a'), clip('b')]);

    state.recordOutgoingClip(clip('b'));

    expect(state.clips.map((c) => c.id), ['a', 'b']);
  });

  test('a new outgoing clip is inserted at the top and saved', () async {
    final state = await stateWith([clip('a')]);

    state.recordOutgoingClip(clip('n'));

    expect(state.clips.map((c) => c.id), ['n', 'a']);
  });
}

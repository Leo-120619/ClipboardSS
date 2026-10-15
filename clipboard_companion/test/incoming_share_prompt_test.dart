import 'package:clipboard_companion/core/app_state.dart';
import 'package:clipboard_companion/core/incoming_share.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _shareChannel = MethodChannel('clipboard_companion/incoming_share');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final completedShareIds = <String>[];

  setUp(() {
    completedShareIds.clear();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_shareChannel, (call) async {
          if (call.method == 'completeShare') {
            completedShareIds.add(
              (call.arguments as Map)['id'] as String,
            );
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_shareChannel, null);
  });

  test('a share batch is consumed even when every attachment fails', () async {
    final prefs = await SharedPreferences.getInstance();
    final state = AppState();
    await state.init(prefs);
    state.stageIncomingShare(_batchMap('batch-1', 3));

    // Networking never started, so every send fails: the batch must still be
    // consumed, otherwise the prompt reopens from build() forever.
    final result = await state.sendPendingShareTo('missing-device');

    expect(result?.failed, 3);
    expect(result?.sent, 0);
    expect(state.pendingShareBatch, isNull);
    expect(completedShareIds, ['batch-1']);
  });

  test('a consumed batch is not staged again by a late native redelivery', () async {
    final prefs = await SharedPreferences.getInstance();
    final state = AppState();
    await state.init(prefs);
    state.stageIncomingShare(_batchMap('batch-2', 1));

    await state.dismissPendingShare();
    state.stageIncomingShare(_batchMap('batch-2', 1));

    expect(state.pendingShareBatch, isNull);
  });

  test('the share prompt is offered once per batch', () {
    final batch = IncomingShareBatch.fromMap(_batchMap('batch-3', 2));
    final handled = <String>{};

    expect(
      shouldPromptForShareBatch(
        batch: batch,
        isReady: true,
        promptVisible: false,
        handledBatchIds: handled,
      ),
      isTrue,
    );

    handled.add(batch.id);

    expect(
      shouldPromptForShareBatch(
        batch: batch,
        isReady: true,
        promptVisible: false,
        handledBatchIds: handled,
      ),
      isFalse,
    );
  });

  test('the share prompt waits for sync and never stacks', () {
    final batch = IncomingShareBatch.fromMap(_batchMap('batch-4', 1));

    expect(
      shouldPromptForShareBatch(
        batch: batch,
        isReady: false,
        promptVisible: false,
        handledBatchIds: const {},
      ),
      isFalse,
    );
    expect(
      shouldPromptForShareBatch(
        batch: batch,
        isReady: true,
        promptVisible: true,
        handledBatchIds: const {},
      ),
      isFalse,
    );
    expect(
      shouldPromptForShareBatch(
        batch: null,
        isReady: true,
        promptVisible: false,
        handledBatchIds: const {},
      ),
      isFalse,
    );
  });
}

Map<Object?, Object?> _batchMap(String id, int count) => {
  'id': id,
  'attachments': [
    for (var i = 0; i < count; i++)
      {
        'path': '/tmp/clipboardss-test/$id-$i.txt',
        'name': '$id-$i.txt',
        'mimeType': 'text/plain',
        'size': 4,
      },
  ],
};

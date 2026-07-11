import 'package:clipboard_companion/core/android_downloads.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('clipboard_companion/android_downloads');

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test('publishes a staged file with its name and MIME type', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return 'content://media/external/downloads/1';
        });

    await AndroidDownloads(channel: channel).publish(
      sourcePath: '/staging/report.pdf',
      fileName: 'report.pdf',
      mimeType: 'application/pdf',
    );

    expect(received?.method, 'publishReceivedFile');
    expect(received?.arguments, {
      'sourcePath': '/staging/report.pdf',
      'fileName': 'report.pdf',
      'mimeType': 'application/pdf',
    });
  });

  test('reports whether Android opened Downloads', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'openDownloads');
          return false;
        });

    expect(await AndroidDownloads(channel: channel).openDownloads(), isFalse);
  });

  test('surfaces a MediaStore publishing failure', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'save_failed');
        });

    expect(
      () => AndroidDownloads(channel: channel).publish(
        sourcePath: '/staging/report.pdf',
        fileName: 'report.pdf',
        mimeType: 'application/pdf',
      ),
      throwsA(isA<PlatformException>()),
    );
  });
}

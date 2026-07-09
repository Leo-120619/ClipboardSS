#ifndef RUNNER_CLIPBOARD_SERVICE_H_
#define RUNNER_CLIPBOARD_SERVICE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <windows.h>

#include <memory>

// Bridges the Win32 clipboard to Dart over the
// "clipboard_companion/win_clipboard" method channel.
//
// Dart -> native methods:
//   readClipboard -> {type: 'text'|'image', text?, bytes?, format: 'png'|'dib'} | null
//   writeText {text}
//   writeImage {png: bytes, dib: bytes}
// Native -> Dart: clipboardChanged (fired on WM_CLIPBOARDUPDATE).
class ClipboardService {
 public:
  ClipboardService(flutter::BinaryMessenger* messenger, HWND window);
  ~ClipboardService();

  // Forwards WM_CLIPBOARDUPDATE to Dart.
  void NotifyClipboardChanged();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  flutter::EncodableValue ReadClipboard();
  bool WriteText(const std::string& utf8_text);
  bool WriteImage(const std::vector<uint8_t>& png_bytes,
                  const std::vector<uint8_t>& dib_bytes);

  bool OpenClipboardWithRetry();

  HWND window_;
  UINT png_format_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_CLIPBOARD_SERVICE_H_

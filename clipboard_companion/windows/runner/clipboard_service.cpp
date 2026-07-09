#include "clipboard_service.h"

#include <flutter/standard_method_codec.h>

#include <string>
#include <vector>

namespace {

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  int size = ::WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                   static_cast<int>(wide.size()), nullptr, 0,
                                   nullptr, nullptr);
  std::string utf8(size, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                        static_cast<int>(wide.size()), utf8.data(), size,
                        nullptr, nullptr);
  return utf8;
}

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  int size = ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                   static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring wide(size, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                        static_cast<int>(utf8.size()), wide.data(), size);
  return wide;
}

// Copies the contents of a clipboard HGLOBAL into a byte vector.
bool ReadGlobalBytes(HANDLE handle, std::vector<uint8_t>* out) {
  const void* data = ::GlobalLock(handle);
  if (data == nullptr) {
    return false;
  }
  SIZE_T size = ::GlobalSize(handle);
  out->assign(static_cast<const uint8_t*>(data),
              static_cast<const uint8_t*>(data) + size);
  ::GlobalUnlock(handle);
  return true;
}

// Allocates an HGLOBAL holding |bytes| for SetClipboardData. Returns nullptr
// on failure; ownership passes to the clipboard on success.
HGLOBAL AllocGlobalBytes(const void* bytes, size_t size) {
  HGLOBAL handle = ::GlobalAlloc(GMEM_MOVEABLE, size);
  if (handle == nullptr) {
    return nullptr;
  }
  void* data = ::GlobalLock(handle);
  if (data == nullptr) {
    ::GlobalFree(handle);
    return nullptr;
  }
  memcpy(data, bytes, size);
  ::GlobalUnlock(handle);
  return handle;
}

const std::vector<uint8_t>* ByteArgument(const flutter::EncodableMap& args,
                                         const char* key) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) {
    return nullptr;
  }
  return std::get_if<std::vector<uint8_t>>(&it->second);
}

}  // namespace

ClipboardService::ClipboardService(flutter::BinaryMessenger* messenger,
                                   HWND window)
    : window_(window),
      png_format_(::RegisterClipboardFormatW(L"PNG")) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "clipboard_companion/win_clipboard",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
  ::AddClipboardFormatListener(window_);
}

ClipboardService::~ClipboardService() {
  ::RemoveClipboardFormatListener(window_);
  channel_->SetMethodCallHandler(nullptr);
}

void ClipboardService::NotifyClipboardChanged() {
  channel_->InvokeMethod("clipboardChanged", nullptr);
}

void ClipboardService::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "readClipboard") {
    result->Success(ReadClipboard());
    return;
  }

  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (call.method_name() == "writeText") {
    const std::string* text = nullptr;
    if (args != nullptr) {
      auto it = args->find(flutter::EncodableValue("text"));
      if (it != args->end()) {
        text = std::get_if<std::string>(&it->second);
      }
    }
    if (text == nullptr) {
      result->Error("bad_args", "writeText requires a 'text' string");
      return;
    }
    if (WriteText(*text)) {
      result->Success();
    } else {
      result->Error("clipboard_error", "Could not write text to clipboard");
    }
    return;
  }

  if (call.method_name() == "writeImage") {
    const std::vector<uint8_t>* png =
        args != nullptr ? ByteArgument(*args, "png") : nullptr;
    const std::vector<uint8_t>* dib =
        args != nullptr ? ByteArgument(*args, "dib") : nullptr;
    if (png == nullptr || dib == nullptr) {
      result->Error("bad_args", "writeImage requires 'png' and 'dib' bytes");
      return;
    }
    if (WriteImage(*png, *dib)) {
      result->Success();
    } else {
      result->Error("clipboard_error", "Could not write image to clipboard");
    }
    return;
  }

  result->NotImplemented();
}

bool ClipboardService::OpenClipboardWithRetry() {
  // Another process may hold the clipboard briefly right after a copy.
  for (int attempt = 0; attempt < 5; ++attempt) {
    if (::OpenClipboard(window_)) {
      return true;
    }
    ::Sleep(10);
  }
  return false;
}

flutter::EncodableValue ClipboardService::ReadClipboard() {
  if (!OpenClipboardWithRetry()) {
    return flutter::EncodableValue();
  }

  flutter::EncodableValue value;

  if (png_format_ != 0 && ::IsClipboardFormatAvailable(png_format_)) {
    HANDLE handle = ::GetClipboardData(png_format_);
    std::vector<uint8_t> bytes;
    if (handle != nullptr && ReadGlobalBytes(handle, &bytes)) {
      value = flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("type"), flutter::EncodableValue("image")},
          {flutter::EncodableValue("format"), flutter::EncodableValue("png")},
          {flutter::EncodableValue("bytes"),
           flutter::EncodableValue(std::move(bytes))},
      });
    }
  }

  if (value.IsNull() && ::IsClipboardFormatAvailable(CF_DIB)) {
    HANDLE handle = ::GetClipboardData(CF_DIB);
    std::vector<uint8_t> bytes;
    if (handle != nullptr && ReadGlobalBytes(handle, &bytes)) {
      value = flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("type"), flutter::EncodableValue("image")},
          {flutter::EncodableValue("format"), flutter::EncodableValue("dib")},
          {flutter::EncodableValue("bytes"),
           flutter::EncodableValue(std::move(bytes))},
      });
    }
  }

  if (value.IsNull() && ::IsClipboardFormatAvailable(CF_UNICODETEXT)) {
    HANDLE handle = ::GetClipboardData(CF_UNICODETEXT);
    if (handle != nullptr) {
      const wchar_t* data = static_cast<const wchar_t*>(::GlobalLock(handle));
      if (data != nullptr) {
        std::string text = WideToUtf8(std::wstring(data));
        ::GlobalUnlock(handle);
        value = flutter::EncodableValue(flutter::EncodableMap{
            {flutter::EncodableValue("type"), flutter::EncodableValue("text")},
            {flutter::EncodableValue("text"),
             flutter::EncodableValue(std::move(text))},
        });
      }
    }
  }

  ::CloseClipboard();
  return value;
}

bool ClipboardService::WriteText(const std::string& utf8_text) {
  std::wstring wide = Utf8ToWide(utf8_text);
  HGLOBAL handle =
      AllocGlobalBytes(wide.c_str(), (wide.size() + 1) * sizeof(wchar_t));
  if (handle == nullptr) {
    return false;
  }

  if (!OpenClipboardWithRetry()) {
    ::GlobalFree(handle);
    return false;
  }
  ::EmptyClipboard();
  bool ok = ::SetClipboardData(CF_UNICODETEXT, handle) != nullptr;
  if (!ok) {
    ::GlobalFree(handle);
  }
  ::CloseClipboard();
  return ok;
}

bool ClipboardService::WriteImage(const std::vector<uint8_t>& png_bytes,
                                  const std::vector<uint8_t>& dib_bytes) {
  if (!OpenClipboardWithRetry()) {
    return false;
  }
  ::EmptyClipboard();

  bool any = false;
  if (png_format_ != 0 && !png_bytes.empty()) {
    HGLOBAL handle = AllocGlobalBytes(png_bytes.data(), png_bytes.size());
    if (handle != nullptr) {
      if (::SetClipboardData(png_format_, handle) != nullptr) {
        any = true;
      } else {
        ::GlobalFree(handle);
      }
    }
  }
  if (!dib_bytes.empty()) {
    HGLOBAL handle = AllocGlobalBytes(dib_bytes.data(), dib_bytes.size());
    if (handle != nullptr) {
      if (::SetClipboardData(CF_DIB, handle) != nullptr) {
        any = true;
      } else {
        ::GlobalFree(handle);
      }
    }
  }

  ::CloseClipboard();
  return any;
}

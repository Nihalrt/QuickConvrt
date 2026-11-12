// Native Windows dialogs and process launch for the React Native UI.
#pragma once
#include "NativeModules.h"
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <stdexcept>
#include <vector>

namespace docenlume {
namespace fs = std::filesystem;
using namespace winrt::Microsoft::ReactNative;
inline HWND ownerWindow{};

inline std::vector<std::wstring> PickPaths(bool folder, bool allFiles) {
  auto dialog = winrt::create_instance<IFileOpenDialog>(CLSID_FileOpenDialog, CLSCTX_INPROC_SERVER);
  FILEOPENDIALOGOPTIONS options{};
  winrt::check_hresult(dialog->GetOptions(&options));
  options |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
  options |= folder ? FOS_PICKFOLDERS : (FOS_FILEMUSTEXIST | FOS_ALLOWMULTISELECT);
  winrt::check_hresult(dialog->SetOptions(options));
  winrt::check_hresult(dialog->SetTitle(folder ? L"Choose a save folder" : L"Choose files to convert"));
  if (!folder) {
    const COMDLG_FILTERSPEC filters[] = {
        {L"Supported documents and images", L"*.pdf;*.docx;*.doc;*.odt;*.rtf;*.txt;*.md;*.csv;*.json;*.log;*.xml;*.yaml;*.yml;*.png;*.jpg;*.jpeg;*.tif;*.tiff;*.webp;*.gif;*.bmp;*.psd"},
        {L"All files", L"*.*"}
    };
    winrt::check_hresult(dialog->SetFileTypes(2, filters));
    if (allFiles) winrt::check_hresult(dialog->SetFileTypeIndex(2));
  }
  const HRESULT selected = dialog->Show(ownerWindow);
  if (selected == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return {};
  winrt::check_hresult(selected);
  winrt::com_ptr<IShellItemArray> items;
  winrt::check_hresult(dialog->GetResults(items.put()));
  DWORD count{};
  winrt::check_hresult(items->GetCount(&count));
  std::vector<std::wstring> paths;
  for (DWORD index = 0; index < count; ++index) {
    winrt::com_ptr<IShellItem> item;
    winrt::check_hresult(items->GetItemAt(index, item.put()));
    PWSTR path{};
    winrt::check_hresult(item->GetDisplayName(SIGDN_FILESYSPATH, &path));
    std::unique_ptr<wchar_t, decltype(&CoTaskMemFree)> owned(path, CoTaskMemFree);
    paths.emplace_back(owned.get());
  }
  return paths;
}

// These are file paths or fixed option values. Double a trailing slash
// before the closing quote so drive roots parse correctly.
inline std::wstring Quote(std::wstring const &arg) {
  if (arg.find(L'"') != std::wstring::npos) throw std::invalid_argument("Invalid file path.");
  const auto last = arg.find_last_not_of(L'\\');
  const auto trailing = last == std::wstring::npos ? arg.size() : arg.size() - last - 1;
  return L"\"" + arg + std::wstring(trailing, L'\\') + L"\"";
}

struct TempResult {
  wchar_t path[MAX_PATH]{};
  TempResult() {
    wchar_t directory[MAX_PATH]{};
    const DWORD length = GetTempPathW(MAX_PATH, directory);
    if (!length || length >= MAX_PATH || !GetTempFileNameW(directory, L"ecv", 0, path)) {
      throw std::runtime_error("Couldn’t create a temporary conversion file.");
    }
  }
  ~TempResult() { DeleteFileW(path); }
};

inline std::string RunEngine(std::vector<std::wstring> const &arguments) {
  std::wstring appPath(32768, L'\0');
  const DWORD length = GetModuleFileNameW(nullptr, appPath.data(), static_cast<DWORD>(appPath.size()));
  if (!length || length >= appPath.size()) throw std::runtime_error("Couldn’t locate Docenlume.");
  appPath.resize(length);
  const auto executable = fs::path(appPath).parent_path() / L"engine" / L"docenlume-engine.exe";
  if (!fs::is_regular_file(executable)) throw std::runtime_error("The local conversion engine is missing. Rebuild Docenlume with its engine.");
  TempResult result;
  std::wstring command = Quote(executable.native());
  for (auto const &arg : arguments) command += L" " + Quote(arg);
  command += L" " + Quote(result.path);
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) {
    throw std::runtime_error("Couldn’t start the local conversion engine.");
  }
  winrt::handle processHandle{process.hProcess};
  winrt::handle threadHandle{process.hThread};
  if (WaitForSingleObject(processHandle.get(), INFINITE) != WAIT_OBJECT_0) {
    throw std::runtime_error("Couldn’t wait for the local conversion engine.");
  }
  std::ifstream response(fs::path(result.path), std::ios::binary);
  std::string status;
  std::getline(response, status);
  std::string body((std::istreambuf_iterator<char>(response)), std::istreambuf_iterator<char>());
  if (status == "OK" && !body.empty()) return body;
  throw std::runtime_error(status == "ERROR" && !body.empty() ? body : "Conversion couldn’t finish.");
}

inline winrt::fire_and_forget ConvertInBackground(
    std::vector<std::wstring> arguments, ReactPromise<std::string> result) {
  co_await winrt::resume_background();
  try {
    result.Resolve(RunEngine(arguments));
  } catch (std::exception const &error) {
    result.Reject(error.what());
  } catch (...) {
    result.Reject("Conversion couldn’t finish.");
  }
}

REACT_MODULE(DocenlumeFiles)
struct DocenlumeFiles {
  REACT_INIT(Initialize)
  void Initialize(ReactContext const &context) noexcept { context_ = context; }

  REACT_METHOD(Pick, L"pick")
  void Pick(bool folder, bool allFiles, ReactPromise<std::vector<std::wstring>> result) noexcept {
    context_.UIDispatcher().Post([folder, allFiles, result]() noexcept {
      try {
        result.Resolve(PickPaths(folder, allFiles));
      } catch (...) {
        result.Reject("Couldn’t open the Windows file picker.");
      }
    });
  }

  REACT_METHOD(Convert, L"convert")
  void Convert(std::vector<std::wstring> sources, std::wstring folder, std::wstring format, std::wstring mode,
               ReactPromise<std::string> result) noexcept {
    sources.push_back(std::move(folder));
    sources.push_back(std::move(format));
    sources.push_back(std::move(mode));
    ConvertInBackground(std::move(sources), result);
  }

  REACT_METHOD(ShowFolder, L"showFolder")
  void ShowFolder(std::wstring path, ReactPromise<void> result) noexcept {
    context_.UIDispatcher().Post([path = std::move(path), result]() noexcept {
      const auto opened = reinterpret_cast<INT_PTR>(ShellExecuteW(ownerWindow, L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
      if (opened > 32) result.Resolve();
      else result.Reject("Couldn’t open the save folder.");
    });
  }

 private:
  ReactContext context_;
};
} // namespace docenlume

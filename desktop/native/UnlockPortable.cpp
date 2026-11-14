#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <commdlg.h>
#include <shlobj.h>
#include <bcrypt.h>
#include <shellapi.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <functional>
#include <thread>
#include <memory>
#include <string>
#include <vector>

namespace {
constexpr WORD IDI_APP_ICON = 101;
constexpr UINT WM_TRAY = WM_APP + 1;
constexpr UINT WM_TASK_PROGRESS = WM_APP + 2;
constexpr UINT WM_TASK_DONE = WM_APP + 3;
constexpr UINT_PTR PROGRESS_CLOSE_TIMER = 1;
constexpr UINT ID_TRAY = 1;
constexpr UINT ID_OPEN = 100;
constexpr UINT ID_FILE = 101;
constexpr UINT ID_FOLDER = 102;
constexpr UINT ID_SCAN = 103;
constexpr UINT ID_DECRYPT = 104;
constexpr UINT ID_CANCEL = 105;
constexpr UINT ID_EXIT = 106;
constexpr UINT ID_FILE_SCAN = 107;
constexpr UINT ID_FILE_DECRYPT = 108;
constexpr UINT ID_FOLDER_SCAN = 109;
constexpr UINT ID_FOLDER_DECRYPT = 110;
constexpr UINT ID_SETTINGS = 111;
constexpr int IDC_PATH = 201;
constexpr int IDC_PICK_FILE = 202;
constexpr int IDC_PICK_FOLDER = 203;
constexpr int IDC_SCAN = 204;
constexpr int IDC_DECRYPT = 205;
constexpr int IDC_CANCEL = 206;
constexpr int IDC_PROGRESS = 207;
constexpr int IDC_STATUS = 208;
constexpr int IDC_RESULTS = 209;
constexpr uint64_t HEADER_SIZE = 4096;

struct ItemResult { std::wstring path, state, detail; };
struct ProgressData { int value; bool marquee; std::wstring text; };
struct ResultData { std::wstring path, state, detail; };
HWND g_main = nullptr, g_progress = nullptr, g_progressBar = nullptr, g_progressText = nullptr;
HICON g_appIcon = nullptr, g_smallIcon = nullptr;
HWND g_path = nullptr, g_status = nullptr, g_bar = nullptr, g_results = nullptr;
NOTIFYICONDATAW g_nid{};
HANDLE g_cancel = nullptr;
bool g_busy = false, g_exitAfter = false;
enum class CloseBehavior { Ask, Tray, Exit };
CloseBehavior g_closeBehavior = CloseBehavior::Ask;
int g_currentProgress = 0;
std::wstring g_currentStatus = L"选择文件或文件夹开始。";
std::vector<ItemResult> g_resultsData;

std::wstring SettingsPath() {
    wchar_t appData[MAX_PATH]{};
    DWORD length = GetEnvironmentVariableW(L"APPDATA", appData, MAX_PATH);
    if (!length || length >= MAX_PATH) return L"UnlockPortable-native-settings.ini";
    return std::wstring(appData) + L"\\UnlockPortable\\native-settings.ini";
}

void LoadSettings() {
    wchar_t value[16]{};
    GetPrivateProfileStringW(L"General", L"CloseBehavior", L"0", value, 16, SettingsPath().c_str());
    if (wcscmp(value, L"1") == 0) g_closeBehavior = CloseBehavior::Tray;
    else if (wcscmp(value, L"2") == 0) g_closeBehavior = CloseBehavior::Exit;
}

void SaveSettings() {
    std::wstring path = SettingsPath();
    size_t split = path.find_last_of(L"\\/");
    if (split != std::wstring::npos) {
        std::wstring directory = path.substr(0, split);
        CreateDirectoryW(directory.c_str(), nullptr);
    }
    const wchar_t* value = g_closeBehavior == CloseBehavior::Tray ? L"1" : L"2";
    WritePrivateProfileStringW(L"General", L"CloseBehavior", value, path.c_str());
}

bool PromptCloseBehavior(HWND owner) {
    int choice = MessageBoxW(owner, L"选择关闭方式：\n\n“是” 隐藏到系统托盘\n“否” 直接退出程序\n“取消” 保持窗口打开\n\n此选择会保存，可在设置中修改。",
        L"首次关闭设置", MB_YESNOCANCEL | MB_ICONQUESTION | MB_DEFBUTTON1);
    if (choice == IDCANCEL) return false;
    g_closeBehavior = choice == IDYES ? CloseBehavior::Tray : CloseBehavior::Exit;
    SaveSettings();
    return true;
}

void ShowSettings(HWND owner) {
    int current = g_closeBehavior == CloseBehavior::Tray ? 1 : (g_closeBehavior == CloseBehavior::Exit ? 2 : 0);
    int choice = MessageBoxW(owner, L"关闭主窗口时如何处理？\n\n“是” 隐藏到系统托盘\n“否” 直接退出程序\n“取消” 不修改设置",
        L"设置 · 关闭行为", MB_YESNOCANCEL | MB_ICONQUESTION | (current == 2 ? MB_DEFBUTTON2 : MB_DEFBUTTON1));
    if (choice == IDYES) g_closeBehavior = CloseBehavior::Tray;
    else if (choice == IDNO) g_closeBehavior = CloseBehavior::Exit;
    else return;
    SaveSettings();
}

std::wstring ErrorText(DWORD code = GetLastError()) {
    wchar_t* text = nullptr;
    FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr, code, 0, reinterpret_cast<wchar_t*>(&text), 0, nullptr);
    std::wstring result = text ? text : L"操作失败";
    if (text) LocalFree(text);
    while (!result.empty() && (result.back() == L'\r' || result.back() == L'\n')) result.pop_back();
    return result;
}

void SetStatus(const std::wstring& text, int value, bool marquee = false) {
    g_currentStatus = text;
    g_currentProgress = std::clamp(value, 0, 100);
    if (g_status) SetWindowTextW(g_status, text.c_str());
    if (g_progressText) SetWindowTextW(g_progressText, text.c_str());
    if (g_bar) {
        SendMessageW(g_bar, PBM_SETMARQUEE, marquee, marquee ? 30 : 0);
        if (!marquee) SendMessageW(g_bar, PBM_SETPOS, g_currentProgress, 0);
    }
    if (g_progressBar) {
        SendMessageW(g_progressBar, PBM_SETMARQUEE, marquee, marquee ? 30 : 0);
        if (!marquee) SendMessageW(g_progressBar, PBM_SETPOS, g_currentProgress, 0);
    }
}

void ShowProgressAtBottomRight(bool activate = false) {
    if (!g_progress) return;
    POINT anchor{};
    GetCursorPos(&anchor);
    HMONITOR monitor = MonitorFromPoint(anchor, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info{sizeof(info)};
    if (!GetMonitorInfoW(monitor, &info)) {
        info.rcWork = {0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN)};
    }
    RECT rect{};
    GetWindowRect(g_progress, &rect);
    int width = rect.right - rect.left;
    int height = rect.bottom - rect.top;
    int x = std::max(info.rcWork.left, info.rcWork.right - width - 12);
    int y = std::max(info.rcWork.top, info.rcWork.bottom - height - 12);
    SetWindowPos(g_progress, HWND_TOPMOST, x, y, 0, 0,
        SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    if (activate) SetForegroundWindow(g_progress);
}

void ReportStatus(const std::wstring& text, int value, bool marquee = false) {
    auto* data = new ProgressData{value, marquee, text};
    if (!PostMessageW(g_main, WM_TASK_PROGRESS, 0, reinterpret_cast<LPARAM>(data))) delete data;
}

void ReportResult(const std::wstring& path, const std::wstring& state, const std::wstring& detail) {
    auto* data = new ResultData{path, state, detail};
    if (!PostMessageW(g_main, WM_TASK_DONE, 1, reinterpret_cast<LPARAM>(data))) delete data;
}

void RefreshResults() {
    if (!g_results) return;
    ListView_DeleteAllItems(g_results);
    for (size_t i = 0; i < g_resultsData.size(); ++i) {
        LVITEMW item{}; item.mask = LVIF_TEXT; item.iItem = static_cast<int>(i);
        item.pszText = const_cast<wchar_t*>(g_resultsData[i].path.c_str());
        ListView_InsertItem(g_results, &item);
        ListView_SetItemText(g_results, static_cast<int>(i), 1, const_cast<wchar_t*>(g_resultsData[i].state.c_str()));
        ListView_SetItemText(g_results, static_cast<int>(i), 2, const_cast<wchar_t*>(g_resultsData[i].detail.c_str()));
    }
}

void AddResultUi(const std::wstring& path, const std::wstring& state, const std::wstring& detail) {
    g_resultsData.push_back({path, state, detail});
    RefreshResults();
}

uint8_t CrcStep(uint8_t state, uint8_t value) {
    int next = state ^ value;
    for (int i = 0; i < 8; ++i) next = (next >> 1) ^ ((next & 1) ? 0xe0 : 0);
    return static_cast<uint8_t>(next);
}

uint8_t HeaderCrc(const std::array<uint8_t, 512>& h) {
    uint8_t state = 255;
    for (int i = 8; i < 12; ++i) state = CrcStep(state, h[i]);
    for (int i = 28; i < 512; ++i) if (i != 46) state = CrcStep(state, h[i]);
    return static_cast<uint8_t>(255 - state);
}

void Rc4(const uint8_t* key, size_t keyLen, const uint8_t* input, uint8_t* output, size_t length) {
    uint8_t s[256]; for (int i = 0; i < 256; ++i) s[i] = static_cast<uint8_t>(i);
    int j = 0;
    for (int i = 0; i < 256; ++i) { j = (j + s[i] + key[i % keyLen]) & 255; std::swap(s[i], s[j]); }
    int x = 0; j = 0;
    for (size_t n = 0; n < length; ++n) { x = (x + 1) & 255; j = (j + s[x]) & 255; std::swap(s[x], s[j]); output[n] = input[n] ^ s[(s[x] + s[j]) & 255]; }
    SecureZeroMemory(s, sizeof(s));
}

std::array<uint8_t, 512> KeyStream(const std::array<uint8_t, 512>& h) {
    uint8_t check[8], selected[3], repeated[16], stage[16], key[16], zero[512]{};
    Rc4(h.data() + 8, 4, h.data() + 12, check, 8);
    selected[0] = check[6]; selected[1] = check[0]; selected[2] = check[5];
    for (int i = 0; i < 16; ++i) repeated[i] = h[8 + i % 4];
    Rc4(selected, 3, repeated, stage, 16);
    memcpy(stage, selected, 3);
    Rc4(h.data() + 8, 4, stage, key, 16);
    std::array<uint8_t, 512> result{};
    Rc4(key, 16, zero, result.data(), result.size());
    SecureZeroMemory(check, sizeof(check)); SecureZeroMemory(selected, sizeof(selected));
    SecureZeroMemory(repeated, sizeof(repeated)); SecureZeroMemory(stage, sizeof(stage)); SecureZeroMemory(key, sizeof(key));
    return result;
}

enum class Inspect { Plain, Supported, Invalid, Unsupported, Error };
Inspect InspectFile(const std::wstring& path, std::wstring& reason, uint64_t* fileSize = nullptr) {
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (f == INVALID_HANDLE_VALUE) { reason = ErrorText(); return Inspect::Error; }
    LARGE_INTEGER size{}; GetFileSizeEx(f, &size); if (fileSize) *fileSize = size.QuadPart;
    std::array<uint8_t, 512> h{}; DWORD got = 0;
    ReadFile(f, h.data(), 26, &got, nullptr);
    if (got < 2 || (h[0] & 0xf0) != 0x80 || h[1] != 0x7d) { CloseHandle(f); reason = L"未发现加密头"; return Inspect::Plain; }
    if (got < 26 || size.QuadPart < HEADER_SIZE) { CloseHandle(f); reason = L"加密头不完整"; return Inspect::Invalid; }
    if (h[0] != 0x89 || h[2] != 0x1c) { CloseHandle(f); reason = L"不支持的版本或模式"; return Inspect::Unsupported; }
    SetFilePointer(f, 0, nullptr, FILE_BEGIN); ReadFile(f, h.data(), 512, &got, nullptr); CloseHandle(f);
    if (got != 512 || HeaderCrc(h) != h[46]) { reason = L"加密头 CRC 校验失败"; return Inspect::Invalid; }
    reason = L"版本 9 / 已验证 RC4 格式"; return Inspect::Supported;
}

bool HashFile(const std::wstring& path, std::array<uint8_t, 32>& hash, uint64_t& size) {
    BCRYPT_ALG_HANDLE alg = nullptr; BCRYPT_HASH_HANDLE h = nullptr;
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) return false;
    if (BCryptCreateHash(alg, &h, nullptr, 0, nullptr, 0, 0) < 0) { BCryptCloseAlgorithmProvider(alg, 0); return false; }
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (f == INVALID_HANDLE_VALUE) { BCryptDestroyHash(h); BCryptCloseAlgorithmProvider(alg, 0); return false; }
    LARGE_INTEGER len{}; GetFileSizeEx(f, &len); size = len.QuadPart;
    std::vector<uint8_t> buf(1024 * 1024); DWORD n; bool ok = true;
    while (ReadFile(f, buf.data(), static_cast<DWORD>(buf.size()), &n, nullptr) && n) if (BCryptHashData(h, buf.data(), n, 0) < 0) { ok = false; break; }
    if (ok) ok = BCryptFinishHash(h, hash.data(), static_cast<ULONG>(hash.size()), 0) >= 0;
    CloseHandle(f); BCryptDestroyHash(h); BCryptCloseAlgorithmProvider(alg, 0); return ok;
}

bool DecryptFile(const std::wstring& path, const std::function<void(uint64_t,uint64_t)>& progress, std::wstring& error) {
    DWORD attrs = GetFileAttributesW(path.c_str());
    if (attrs == INVALID_FILE_ATTRIBUTES || (attrs & FILE_ATTRIBUTE_REPARSE_POINT)) { error = L"无法读取文件或不处理重解析点"; return false; }
    HANDLE input = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (input == INVALID_HANDLE_VALUE) { error = ErrorText(); return false; }
    LARGE_INTEGER sourceSize{}; GetFileSizeEx(input, &sourceSize); FILETIME writeTime{}; GetFileTime(input, nullptr, nullptr, &writeTime);
    std::array<uint8_t, 512> header{}; DWORD got = 0; ReadFile(input, header.data(), 512, &got, nullptr);
    if (got != 512 || HeaderCrc(header) != header[46]) { CloseHandle(input); error = L"加密头验证失败"; return false; }
    auto key = KeyStream(header);
    std::wstring temp = path + L".unlock-";
    wchar_t suffix[40]; swprintf(suffix, 40, L"%08lx%08lx.tmp", GetTickCount(), GetCurrentProcessId()); temp += suffix;
    HANDLE output = CreateFileW(temp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_TEMPORARY, nullptr);
    if (output == INVALID_HANDLE_VALUE) { CloseHandle(input); error = ErrorText(); return false; }
    SetFilePointer(input, static_cast<LONG>(HEADER_SIZE), nullptr, FILE_BEGIN);
    uint64_t total = static_cast<uint64_t>(sourceSize.QuadPart) - HEADER_SIZE, done = 0;
    BCRYPT_ALG_HANDLE hashAlg = nullptr; BCRYPT_HASH_HANDLE hashHandle = nullptr;
    bool hashReady = BCryptOpenAlgorithmProvider(&hashAlg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0 &&
        BCryptCreateHash(hashAlg, &hashHandle, nullptr, 0, nullptr, 0, 0) >= 0;
    std::array<uint8_t, 32> plaintextHash{};
    std::vector<uint8_t> buffer(1024 * 1024); bool ok = hashReady;
    progress(0, total);
    while (ReadFile(input, buffer.data(), static_cast<DWORD>(buffer.size()), &got, nullptr) && got) {
        if (WaitForSingleObject(g_cancel, 0) == WAIT_OBJECT_0) { error = L"已取消"; ok = false; break; }
        for (DWORD i = 0; i < got; ++i) buffer[i] ^= key[(done + i) & 511];
        if (BCryptHashData(hashHandle, buffer.data(), got, 0) < 0) { error = L"无法计算解密结果校验值"; ok = false; break; }
        DWORD written = 0;
        if (!WriteFile(output, buffer.data(), got, &written, nullptr) || written != got) { error = ErrorText(); ok = false; break; }
        done += got; progress(done, total);
    }
    FlushFileBuffers(output); CloseHandle(output); CloseHandle(input);
    if (ok && BCryptFinishHash(hashHandle, plaintextHash.data(), static_cast<ULONG>(plaintextHash.size()), 0) < 0) { error = L"无法完成解密结果校验"; ok = false; }
    if (hashHandle) BCryptDestroyHash(hashHandle);
    if (hashAlg) BCryptCloseAlgorithmProvider(hashAlg, 0);
    SecureZeroMemory(key.data(), key.size());
    if (ok && done != total) { error = L"读取源文件失败"; ok = false; }
    std::array<uint8_t, 32> readbackHash{}; uint64_t readbackSize = 0;
    if (ok && (!HashFile(temp, readbackHash, readbackSize) || readbackSize != total || readbackHash != plaintextHash)) { error = L"解密结果 SHA-256 校验失败"; ok = false; }
    HANDLE check = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (ok && check != INVALID_HANDLE_VALUE) {
        LARGE_INTEGER nowSize{}; FILETIME nowWrite{}; GetFileSizeEx(check, &nowSize); GetFileTime(check, nullptr, nullptr, &nowWrite); CloseHandle(check);
        if (nowSize.QuadPart != sourceSize.QuadPart || CompareFileTime(&writeTime, &nowWrite) != 0) { error = L"替换前源文件已发生变化"; ok = false; }
    }
    if (ok) {
        if ((attrs & FILE_ATTRIBUTE_READONLY) != 0) SetFileAttributesW(path.c_str(), attrs & ~FILE_ATTRIBUTE_READONLY);
        if (!ReplaceFileW(path.c_str(), temp.c_str(), nullptr, REPLACEFILE_IGNORE_MERGE_ERRORS, nullptr, nullptr)) { error = ErrorText(); ok = false; }
        if ((attrs & FILE_ATTRIBUTE_READONLY) != 0) SetFileAttributesW(path.c_str(), attrs);
    }
    if (!ok) DeleteFileW(temp.c_str());
    return ok;
}

void Enumerate(const std::wstring& root, std::vector<std::wstring>& files) {
    DWORD attr = GetFileAttributesW(root.c_str());
    if (attr == INVALID_FILE_ATTRIBUTES) return;
    if (!(attr & FILE_ATTRIBUTE_DIRECTORY)) { files.push_back(root); return; }
    std::vector<std::wstring> dirs{root};
    while (!dirs.empty()) {
        std::wstring dir = dirs.back(); dirs.pop_back();
        WIN32_FIND_DATAW data{}; HANDLE find = FindFirstFileW((dir + L"\\*").c_str(), &data);
        if (find == INVALID_HANDLE_VALUE) continue;
        do {
            if (!wcscmp(data.cFileName, L".") || !wcscmp(data.cFileName, L"..") || (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) continue;
            std::wstring full = dir + L"\\" + data.cFileName;
            if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) dirs.push_back(full);
            else if (full.find(L".unlock-") == std::wstring::npos) files.push_back(full);
        } while (FindNextFileW(find, &data));
        FindClose(find);
    }
}

void RunTaskWorker(std::vector<std::wstring> roots, bool decrypt) {
    std::vector<std::wstring> files;
    for (const auto& root : roots) Enumerate(root, files);
    std::vector<std::wstring> supported;
    for (size_t i = 0; i < files.size(); ++i) {
        if (WaitForSingleObject(g_cancel, 0) == WAIT_OBJECT_0) break;
        std::wstring reason; auto result = InspectFile(files[i], reason);
        if (result == Inspect::Supported) supported.push_back(files[i]);
        else if (result == Inspect::Invalid || result == Inspect::Unsupported || result == Inspect::Error) ReportResult(files[i], L"未处理", reason);
        int percent = files.empty() ? 100 : static_cast<int>((100ull * (i + 1)) / files.size());
        ReportStatus(L"扫描中：" + std::to_wstring(i + 1) + L"/" + std::to_wstring(files.size()) + L" · 发现加密文件 " + std::to_wstring(supported.size()), decrypt ? percent / 2 : percent);
    }
    if (WaitForSingleObject(g_cancel, 0) == WAIT_OBJECT_0) ReportStatus(L"已取消。", g_currentProgress);
    else if (!decrypt) ReportStatus(L"扫描完成：检查 " + std::to_wstring(files.size()) + L" 个 · 发现加密文件 " + std::to_wstring(supported.size()), 100);
    else if (supported.empty()) ReportStatus(L"扫描完成：没有发现支持的加密文件。", 100);
    else {
        int success = 0, failed = 0;
        for (size_t i = 0; i < supported.size(); ++i) {
            if (WaitForSingleObject(g_cancel, 0) == WAIT_OBJECT_0) break;
            std::wstring error;
            bool ok = DecryptFile(supported[i], [&](uint64_t current, uint64_t total) {
                int filePct = total ? static_cast<int>((100ull * current) / total) : 100;
                int overall = 50 + static_cast<int>((50ull * (i * 100 + filePct)) / (supported.size() * 100));
                ReportStatus(L"解密中：" + std::to_wstring(i + 1) + L"/" + std::to_wstring(supported.size()) + L" · " + std::to_wstring(filePct) + L"%", overall);
            }, error);
            if (ok) { ++success; ReportResult(supported[i], L"已解密", L"已验证并原位替换"); }
            else { ++failed; ReportResult(supported[i], L"失败", error); }
        }
        ReportStatus(L"处理完成：解密 " + std::to_wstring(success) + L" 个 · 失败 " + std::to_wstring(failed) + L" 个。", 100);
    }
    PostMessageW(g_main, WM_TASK_DONE, 0, 0);
}

void StartTask(std::vector<std::wstring> roots, bool decrypt) {
    if (g_busy) return;
    KillTimer(g_progress, PROGRESS_CLOSE_TIMER);
    g_busy = true; ResetEvent(g_cancel); g_resultsData.clear(); RefreshResults();
    EnableWindow(GetDlgItem(g_main, IDC_PICK_FILE), FALSE); EnableWindow(GetDlgItem(g_main, IDC_PICK_FOLDER), FALSE);
    EnableWindow(GetDlgItem(g_main, IDC_SCAN), FALSE); EnableWindow(GetDlgItem(g_main, IDC_DECRYPT), FALSE); EnableWindow(GetDlgItem(g_main, IDC_CANCEL), TRUE);
    if (IsWindowVisible(g_main)) ShowWindow(g_progress, SW_HIDE);
    else ShowProgressAtBottomRight();
    SetStatus(decrypt ? L"正在扫描并解密…" : L"正在扫描…", 0, true);
    std::thread(RunTaskWorker, std::move(roots), decrypt).detach();
}

std::wstring ChooseFile() {
    wchar_t file[MAX_PATH]{}; OPENFILENAMEW ofn{sizeof(ofn)}; ofn.hwndOwner = g_main; ofn.lpstrFile = file; ofn.nMaxFile = MAX_PATH; ofn.lpstrTitle = L"选择要扫描或解密的文件"; ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST;
    return GetOpenFileNameW(&ofn) ? file : L"";
}
std::wstring ChooseFolder() {
    BROWSEINFOW bi{}; bi.hwndOwner = g_main; bi.lpszTitle = L"选择要递归扫描的文件夹"; bi.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE;
    PIDLIST_ABSOLUTE pid = SHBrowseForFolderW(&bi); if (!pid) return L"";
    wchar_t path[MAX_PATH]{}; SHGetPathFromIDListW(pid, path); CoTaskMemFree(pid); return path;
}

bool ConfirmDecrypt(HWND owner) {
    return MessageBoxW(owner, L"检测到支持的加密文件后，将在验证解密结果后原位替换原文件。重要文件请先备份。继续吗？",
        L"确认原位解密", MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2) == IDYES;
}

void RunChosen(const std::wstring& path, bool decrypt) {
    if (path.empty()) return;
    if (decrypt && !ConfirmDecrypt(IsWindowVisible(g_main) ? g_main : nullptr)) return;
    StartTask({path}, decrypt);
}

void ShowTrayMenu() {
    HMENU menu = CreatePopupMenu();
    HMENU fileMenu = CreatePopupMenu(), folderMenu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING, ID_OPEN, L"打开操作面板");
    AppendMenuW(menu, MF_STRING | (g_progress && IsWindowVisible(g_progress) ? MF_ENABLED : MF_GRAYED), ID_TRAY + 10, L"显示任务进度");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(fileMenu, MF_STRING, ID_FILE_SCAN, L"仅扫描"); AppendMenuW(fileMenu, MF_STRING, ID_FILE_DECRYPT, L"扫描并解密…");
    AppendMenuW(folderMenu, MF_STRING, ID_FOLDER_SCAN, L"仅扫描"); AppendMenuW(folderMenu, MF_STRING, ID_FOLDER_DECRYPT, L"扫描并解密…");
    AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(fileMenu), L"选择文件");
    AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(folderMenu), L"选择文件夹");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr); AppendMenuW(menu, MF_STRING | (g_busy ? MF_ENABLED : MF_GRAYED), ID_CANCEL, L"取消当前任务");
    AppendMenuW(menu, MF_STRING, ID_EXIT, L"退出");
    POINT p; GetCursorPos(&p); SetForegroundWindow(g_main); TrackPopupMenu(menu, TPM_RIGHTBUTTON, p.x, p.y, 0, g_main, nullptr); DestroyMenu(menu);
}

void CreateMainControls(HWND hwnd) {
    HFONT font = static_cast<HFONT>(GetStockObject(DEFAULT_GUI_FONT));
    CreateWindowW(L"STATIC", L"Unlock Portable", WS_CHILD | WS_VISIBLE, 24, 20, 300, 32, hwnd, nullptr, nullptr, nullptr);
    HWND settings = CreateWindowW(L"BUTTON", L"设置", WS_CHILD | WS_VISIBLE, 716, 20, 94, 30, hwnd, reinterpret_cast<HMENU>(ID_SETTINGS), nullptr, nullptr);
    g_path = CreateWindowW(L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_BORDER | ES_READONLY, 24, 76, 540, 26, hwnd, reinterpret_cast<HMENU>(IDC_PATH), nullptr, nullptr);
    HWND b = CreateWindowW(L"BUTTON", L"选择文件", WS_CHILD | WS_VISIBLE, 578, 74, 112, 30, hwnd, reinterpret_cast<HMENU>(IDC_PICK_FILE), nullptr, nullptr);
    HWND f = CreateWindowW(L"BUTTON", L"选择文件夹", WS_CHILD | WS_VISIBLE, 698, 74, 112, 30, hwnd, reinterpret_cast<HMENU>(IDC_PICK_FOLDER), nullptr, nullptr);
    CreateWindowW(L"BUTTON", L"仅扫描", WS_CHILD | WS_VISIBLE, 24, 120, 100, 34, hwnd, reinterpret_cast<HMENU>(IDC_SCAN), nullptr, nullptr);
    CreateWindowW(L"BUTTON", L"扫描并解密", WS_CHILD | WS_VISIBLE, 136, 120, 132, 34, hwnd, reinterpret_cast<HMENU>(IDC_DECRYPT), nullptr, nullptr);
    CreateWindowW(L"BUTTON", L"取消", WS_CHILD | WS_VISIBLE | WS_DISABLED, 280, 120, 86, 34, hwnd, reinterpret_cast<HMENU>(IDC_CANCEL), nullptr, nullptr);
    g_results = CreateWindowW(WC_LISTVIEWW, L"", WS_CHILD | WS_VISIBLE | LVS_REPORT | LVS_SINGLESEL, 24, 174, 786, 244, hwnd, reinterpret_cast<HMENU>(IDC_RESULTS), nullptr, nullptr);
    ListView_SetExtendedListViewStyle(g_results, LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER);
    LVCOLUMNW col{}; col.mask = LVCF_TEXT | LVCF_WIDTH;
    col.pszText = const_cast<wchar_t*>(L"文件"); col.cx = 390; ListView_InsertColumn(g_results, 0, &col);
    col.pszText = const_cast<wchar_t*>(L"状态"); col.cx = 110; ListView_InsertColumn(g_results, 1, &col);
    col.pszText = const_cast<wchar_t*>(L"信息"); col.cx = 280; ListView_InsertColumn(g_results, 2, &col);
    g_status = CreateWindowW(L"STATIC", L"选择文件或文件夹开始。", WS_CHILD | WS_VISIBLE, 24, 432, 786, 22, hwnd, reinterpret_cast<HMENU>(IDC_STATUS), nullptr, nullptr);
    g_bar = CreateWindowW(PROGRESS_CLASSW, L"", WS_CHILD | WS_VISIBLE, 24, 458, 786, 14, hwnd, reinterpret_cast<HMENU>(IDC_PROGRESS), nullptr, nullptr);
    for (HWND h : {settings, g_path, b, f, GetDlgItem(hwnd, IDC_SCAN), GetDlgItem(hwnd, IDC_DECRYPT), GetDlgItem(hwnd, IDC_CANCEL), g_results, g_status}) SendMessageW(h, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
}

LRESULT CALLBACK ProgressProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_TIMER && wp == PROGRESS_CLOSE_TIMER) {
        KillTimer(hwnd, PROGRESS_CLOSE_TIMER);
        ShowWindow(hwnd, SW_HIDE);
        return 0;
    }
    if (msg == WM_CLOSE) { ShowWindow(hwnd, SW_HIDE); return 0; }
    if (msg == WM_COMMAND && LOWORD(wp) == IDC_CANCEL) { SetEvent(g_cancel); return 0; }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

LRESULT CALLBACK MainProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_CREATE) { CreateMainControls(hwnd); return 0; }
    if (msg == WM_TASK_PROGRESS) { std::unique_ptr<ProgressData> data(reinterpret_cast<ProgressData*>(lp)); SetStatus(data->text, data->value, data->marquee); return 0; }
    if (msg == WM_TASK_DONE) {
        if (wp == 1) { std::unique_ptr<ResultData> data(reinterpret_cast<ResultData*>(lp)); AddResultUi(data->path, data->state, data->detail); return 0; }
        if (g_busy) {
            g_busy = false;
            EnableWindow(GetDlgItem(hwnd, IDC_PICK_FILE), TRUE); EnableWindow(GetDlgItem(hwnd, IDC_PICK_FOLDER), TRUE);
            EnableWindow(GetDlgItem(hwnd, IDC_SCAN), TRUE); EnableWindow(GetDlgItem(hwnd, IDC_DECRYPT), TRUE); EnableWindow(GetDlgItem(hwnd, IDC_CANCEL), FALSE);
            NOTIFYICONDATAW n = g_nid; n.uFlags = NIF_INFO; wcscpy_s(n.szInfoTitle, L"Unlock Portable"); wcscpy_s(n.szInfo, g_currentStatus.c_str()); n.dwInfoFlags = NIIF_INFO; Shell_NotifyIconW(NIM_MODIFY, &n);
            if (IsWindowVisible(g_progress)) SetTimer(g_progress, PROGRESS_CLOSE_TIMER, 8000, nullptr);
            if (g_exitAfter) { g_exitAfter = false; DestroyWindow(hwnd); }
        }
        return 0;
    }
    if (msg == WM_TRAY) { if (lp == WM_RBUTTONUP || lp == WM_CONTEXTMENU) ShowTrayMenu(); else if (lp == WM_LBUTTONDBLCLK) ShowWindow(hwnd, SW_SHOW); return 0; }
    if (msg == WM_COMMAND) {
        switch (LOWORD(wp)) {
        case ID_OPEN: ShowWindow(hwnd, SW_SHOW); SetForegroundWindow(hwnd); return 0;
        case ID_SETTINGS: ShowSettings(hwnd); return 0;
        case ID_TRAY + 10: ShowProgressAtBottomRight(true); return 0;
        case IDC_PICK_FILE: { auto p = ChooseFile(); if (!p.empty()) SetWindowTextW(g_path, p.c_str()); return 0; }
        case IDC_PICK_FOLDER: { auto p = ChooseFolder(); if (!p.empty()) SetWindowTextW(g_path, p.c_str()); return 0; }
        case IDC_SCAN: case IDC_DECRYPT: { wchar_t p[32768]{}; GetWindowTextW(g_path, p, 32768); if (*p) RunChosen(p, LOWORD(wp) == IDC_DECRYPT); else MessageBoxW(hwnd, L"请选择有效的文件或文件夹。", L"Unlock", MB_OK | MB_ICONINFORMATION); return 0; }
        case ID_FILE_SCAN: case ID_FILE_DECRYPT: { auto p = ChooseFile(); RunChosen(p, LOWORD(wp) == ID_FILE_DECRYPT); return 0; }
        case ID_FOLDER_SCAN: case ID_FOLDER_DECRYPT: { auto p = ChooseFolder(); RunChosen(p, LOWORD(wp) == ID_FOLDER_DECRYPT); return 0; }
        case ID_CANCEL: SetEvent(g_cancel); return 0;
        case ID_EXIT: if (g_busy) { g_exitAfter = true; SetEvent(g_cancel); } else { g_exitAfter = true; DestroyWindow(hwnd); } return 0;
        case IDC_CANCEL: SetEvent(g_cancel); return 0;
        }
    }
    if (msg == WM_CLOSE) {
        if (g_exitAfter || wp == 1) { Shell_NotifyIconW(NIM_DELETE, &g_nid); DestroyWindow(hwnd); return 0; }
        if (g_closeBehavior == CloseBehavior::Ask && !PromptCloseBehavior(hwnd)) return 0;
        if (g_closeBehavior == CloseBehavior::Tray) ShowWindow(hwnd, SW_HIDE);
        else if (g_busy) { g_exitAfter = true; SetEvent(g_cancel); }
        else { g_exitAfter = true; Shell_NotifyIconW(NIM_DELETE, &g_nid); DestroyWindow(hwnd); }
        return 0;
    }
    if (msg == WM_DESTROY) { Shell_NotifyIconW(NIM_DELETE, &g_nid); PostQuitMessage(0); return 0; }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

int SelfTest(const wchar_t* encrypted, const wchar_t* expected) {
    wchar_t tempDir[MAX_PATH]; GetTempPathW(MAX_PATH, tempDir); std::wstring dir = std::wstring(tempDir) + L"unlock-native-test-" + std::to_wstring(GetTickCount()); CreateDirectoryW(dir.c_str(), nullptr);
    for (const wchar_t* ext : {L".dll", L".ps1"}) {
        std::wstring target = dir + L"\\sample" + ext;
        if (!CopyFileW(encrypted, target.c_str(), FALSE)) return 2;
        if (wcscmp(ext, L".dll") == 0) SetFileAttributesW(target.c_str(), FILE_ATTRIBUTE_READONLY);
        std::wstring reason; if (InspectFile(target, reason) != Inspect::Supported) return 3;
        std::wstring err; if (!DecryptFile(target, [](uint64_t,uint64_t){}, err)) { fwprintf(stderr, L"decrypt failed: %ls\n", err.c_str()); return 4; }
        std::array<uint8_t,32> a{}, b{}; uint64_t as=0, bs=0;
        if (!HashFile(target,a,as) || !HashFile(expected,b,bs) || as != bs || a != b) return 5;
        SetFileAttributesW(target.c_str(), FILE_ATTRIBUTE_NORMAL); DeleteFileW(target.c_str());
    }
    RemoveDirectoryW(dir.c_str()); puts("PASS native encrypted detection and exact decrypt for DLL/PS1"); return 0;
}

} // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    int argc = 0; LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (argc == 4 && wcscmp(argv[1], L"--self-test") == 0) { int r = SelfTest(argv[2], argv[3]); LocalFree(argv); return r; }
    if (argv) LocalFree(argv);
    INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_PROGRESS_CLASS | ICC_LISTVIEW_CLASSES}; InitCommonControlsEx(&controls);
    LoadSettings();
    g_cancel = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_appIcon = static_cast<HICON>(LoadImageW(instance, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON, 32, 32, 0));
    g_smallIcon = static_cast<HICON>(LoadImageW(instance, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON, 16, 16, 0));
    if (!g_appIcon) g_appIcon = LoadIcon(nullptr, IDI_APPLICATION);
    if (!g_smallIcon) g_smallIcon = g_appIcon;
    WNDCLASSW mainClass{}; mainClass.lpfnWndProc = MainProc; mainClass.hInstance = instance; mainClass.lpszClassName = L"UnlockPortableNativeMain"; mainClass.hCursor = LoadCursor(nullptr, IDC_ARROW); mainClass.hIcon = g_appIcon; RegisterClassW(&mainClass);
    WNDCLASSW progressClass{}; progressClass.lpfnWndProc = ProgressProc; progressClass.hInstance = instance; progressClass.lpszClassName = L"UnlockPortableNativeProgress"; progressClass.hCursor = LoadCursor(nullptr, IDC_ARROW); RegisterClassW(&progressClass);
    g_main = CreateWindowExW(0, mainClass.lpszClassName, L"Unlock Portable", WS_OVERLAPPEDWINDOW & ~WS_MAXIMIZEBOX, CW_USEDEFAULT, CW_USEDEFAULT, 850, 550, nullptr, nullptr, instance, nullptr);
    g_progress = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST, progressClass.lpszClassName, L"Unlock 任务进度", WS_CAPTION | WS_SYSMENU, 0, 0, 390, 150, nullptr, nullptr, instance, nullptr);
    SendMessageW(g_main, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(g_appIcon));
    SendMessageW(g_main, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(g_smallIcon));
    SendMessageW(g_progress, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(g_appIcon));
    SendMessageW(g_progress, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(g_smallIcon));
    g_progressText = CreateWindowW(L"STATIC", L"空闲", WS_CHILD | WS_VISIBLE, 18, 18, 340, 28, g_progress, nullptr, instance, nullptr);
    g_progressBar = CreateWindowW(PROGRESS_CLASSW, L"", WS_CHILD | WS_VISIBLE, 18, 58, 340, 18, g_progress, nullptr, instance, nullptr);
    CreateWindowW(L"BUTTON", L"取消", WS_CHILD | WS_VISIBLE, 282, 88, 76, 28, g_progress, reinterpret_cast<HMENU>(IDC_CANCEL), instance, nullptr);
    g_nid.cbSize = sizeof(g_nid); g_nid.hWnd = g_main; g_nid.uID = ID_TRAY; g_nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP; g_nid.uCallbackMessage = WM_TRAY; g_nid.hIcon = mainClass.hIcon; wcscpy_s(g_nid.szTip, L"Unlock Portable"); Shell_NotifyIconW(NIM_ADD, &g_nid);
    ShowWindow(g_main, SW_SHOWNORMAL);
    UpdateWindow(g_main);
    MSG msg; while (GetMessageW(&msg, nullptr, 0, 0) > 0) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    CloseHandle(g_cancel); return static_cast<int>(msg.wParam);
}

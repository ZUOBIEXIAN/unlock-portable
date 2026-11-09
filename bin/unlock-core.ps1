param(
    [Parameter(Position = 0)][string]$SourcePath,
    [Parameter(Position = 1)][string]$DestinationPath,
    [switch]$ScanOnly,
    [switch]$Help,
    [switch]$NoProgress,
    [switch]$Library
)

$ErrorActionPreference = 'Stop'

function Show-UnlockHelp {
    Write-Host @'
用法：unlock <文件或文件夹> [输出路径] [-ScanOnly]

  unlock "D:\资料\文件.docx"           原位解密单个文件
  unlock "D:\资料"                     递归识别并原位解密
  unlock "D:\资料" -ScanOnly           只扫描，不写入
  unlock "D:\资料\文件.docx" "D:\输出.docx"
  unlock "D:\资料" "D:\输出目录"      按相对路径导出匹配文件

无需 Node.js、联网或安装加密软件。支持已验证的版本 9 / RC4 模式。
普通文件跳过；损坏或不支持的加密头会报告并保留原文件。
默认原位替换。重要文件请先备份；本格式没有正文认证校验。
'@
}

if ($Help -or $SourcePath -in @('--help', '-h', '/?') -or (-not $SourcePath -and -not $Library)) {
    Show-UnlockHelp
    exit 0
}

# C# is compiled in memory by PowerShell's built-in Add-Type/.NET support.
# No external executable, package, driver, Node.js, or downloaded compiler is used.
if (-not ('UnlockPortable.EngineV2' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace UnlockPortable {
    public sealed class HeaderInfo {
        public string Kind;
        public string Reason;
        public long FileBytes;
    }

    public sealed class DecryptResult {
        public string Destination;
        public long PlainBytes;
        public string SHA256;
    }

    public static class EngineV2 {
        const int HeaderSize = 4096;
        const int Period = 512;

        static int ReadUpTo(Stream stream, byte[] bytes, int count) {
            int total = 0;
            while (total < count) {
                int read = stream.Read(bytes, total, count - total);
                if (read == 0) break;
                total += read;
            }
            return total;
        }

        static byte CRCStep(byte state, byte value) {
            int next = state ^ value;
            for (int i = 0; i < 8; i++) next = (next >> 1) ^ ((next & 1) != 0 ? 0xe0 : 0);
            return (byte)next;
        }

        static byte HeaderCRC(byte[] header) {
            byte state = 255;
            for (int i = 8; i < 12; i++) state = CRCStep(state, header[i]);
            for (int i = 28; i < 512; i++) if (i != 46) state = CRCStep(state, header[i]);
            return (byte)(255 - state);
        }

        static HeaderInfo InspectStream(FileStream stream, out byte[] header) {
            header = new byte[512];
            long length = stream.Length;
            HeaderInfo info = new HeaderInfo {Kind = "Plain", Reason = "未发现加密头", FileBytes = length};
            int count = ReadUpTo(stream, header, 26);
            // Magic family 0x7d8?. Do not treat an arbitrary binary extension as encrypted.
            if (count < 2 || (header[0] & 0xf0) != 0x80 || header[1] != 0x7d) return info;
            if (count < 26 || length < HeaderSize) {
                info.Kind = "Invalid"; info.Reason = "加密头不完整"; return info;
            }
            // The tested profile. Do not guess an unverified mode or version.
            if (header[0] != 0x89 || header[2] != 0x1c) {
                info.Kind = "Unsupported";
                info.Reason = String.Format("不支持的加密版本或模式（版本字节 0x{0:X2}，模式字节 0x{1:X2}）", header[0], header[2]);
                return info;
            }
            // Metadata byte 4 is deliberately not fixed to 0x25/0x40.
            // Bytes 6..7 are also metadata, not an encryption-mode selector.
            // Both 0x000f and 0x000d samples have the same verified derivation.
            // The enterprise marker/password index at 20..25 is not a universal magic.
            int more = 512 - count;
            while (more > 0) {
                int read = stream.Read(header, count, more);
                if (read == 0) break;
                count += read; more -= read;
            }
            if (count != 512 || HeaderCRC(header) != header[46]) {
                info.Kind = "Invalid"; info.Reason = "加密头 CRC 校验失败"; return info;
            }
            info.Kind = "Supported"; info.Reason = "版本 9 / 已验证的 RC4 格式";
            return info;
        }

        public static HeaderInfo Inspect(string filename) {
            using (FileStream stream = new FileStream(filename, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
                byte[] header;
                return InspectStream(stream, out header);
            }
        }

        static byte[] Slice(byte[] data, int offset, int count) {
            byte[] part = new byte[count];
            Buffer.BlockCopy(data, offset, part, 0, count);
            return part;
        }

        static byte[] RC4(byte[] key, byte[] input) {
            byte[] state = new byte[256];
            for (int n = 0; n < 256; n++) state[n] = (byte)n;
            int j = 0;
            for (int n = 0; n < 256; n++) {
                j = (j + state[n] + key[n % key.Length]) & 255;
                byte t = state[n]; state[n] = state[j]; state[j] = t;
            }
            int i = 0; j = 0;
            byte[] output = new byte[input.Length];
            for (int n = 0; n < input.Length; n++) {
                i = (i + 1) & 255;
                j = (j + state[i]) & 255;
                byte t = state[i]; state[i] = state[j]; state[j] = t;
                output[n] = (byte)(input[n] ^ state[(state[i] + state[j]) & 255]);
            }
            Array.Clear(state, 0, state.Length);
            return output;
        }

        static byte[] KeyStream(byte[] header) {
            byte[] parameter = Slice(header, 8, 4);
            byte[] check = RC4(parameter, Slice(header, 12, 8));
            byte[] selected = new byte[] {check[6], check[0], check[5]};
            byte[] repeated = new byte[16];
            for (int i = 0; i < 16; i++) repeated[i] = parameter[i % 4];
            byte[] stage1 = RC4(selected, repeated);
            Buffer.BlockCopy(selected, 0, stage1, 0, selected.Length);
            byte[] key = RC4(parameter, stage1);
            byte[] stream = RC4(key, new byte[Period]);
            Array.Clear(check, 0, check.Length);
            Array.Clear(selected, 0, selected.Length);
            Array.Clear(stage1, 0, stage1.Length);
            Array.Clear(key, 0, key.Length);
            return stream;
        }

        static string Hex(byte[] data) { return BitConverter.ToString(data).Replace("-", "").ToLowerInvariant(); }

        public static DecryptResult DecryptFile(string source, string destination, Action<long,long> progress) {
            source = Path.GetFullPath(source);
            destination = Path.GetFullPath(destination);
            bool inPlace = String.Equals(source, destination, StringComparison.OrdinalIgnoreCase);
            if ((File.GetAttributes(source) & FileAttributes.ReparsePoint) != 0) throw new IOException("不处理符号链接或重解析点");
            if (!inPlace && (File.Exists(destination) || Directory.Exists(destination))) throw new IOException("输出文件已存在，拒绝覆盖：" + destination);
            string parent = Path.GetDirectoryName(destination);
            Directory.CreateDirectory(parent);
            string temporary = Path.Combine(parent, "unlock_" + Guid.NewGuid().ToString("N") + "_" + Path.GetFileName(destination) + ".tmp");
            byte[] stream = null;
            bool committed = false;
            long plainBytes = 0;
            long originalLength = 0;
            DateTime originalWrite = File.GetLastWriteTimeUtc(source);
            string digest = null;
            try {
                // Disallow writers while reading. Scan results are revalidated here.
                using (FileStream input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                    originalLength = input.Length;
                    byte[] header;
                    HeaderInfo info = InspectStream(input, out header);
                    if (info.Kind != "Supported") throw new InvalidDataException(info.Reason);
                    stream = KeyStream(header);
                    long expected = originalLength - HeaderSize;
                    input.Position = HeaderSize;
                    using (SHA256 sha = SHA256.Create())
                    using (FileStream output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                        byte[] buffer = new byte[1024 * 1024];
                        Stopwatch clock = Stopwatch.StartNew();
                        if (progress != null) progress(0, expected);
                        int read;
                        while ((read = input.Read(buffer, 0, buffer.Length)) > 0) {
                            for (int i = 0; i < read; i++) buffer[i] ^= stream[(int)((plainBytes + i) & 511)];
                            sha.TransformBlock(buffer, 0, read, buffer, 0);
                            output.Write(buffer, 0, read);
                            plainBytes += read;
                            if (progress != null && clock.ElapsedMilliseconds >= 120) { progress(plainBytes, expected); clock.Restart(); }
                        }
                        sha.TransformFinalBlock(new byte[0], 0, 0);
                        digest = Hex(sha.Hash);
                        output.Flush(true);
                        if (plainBytes != expected) throw new IOException("读取期间原文件长度发生变化");
                        if (progress != null) progress(plainBytes, expected);
                    }
                }
                using (SHA256 sha = SHA256.Create())
                using (FileStream check = new FileStream(temporary, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                    if (check.Length != plainBytes || Hex(sha.ComputeHash(check)) != digest) throw new IOException("临时输出校验失败");
                }
                if (new FileInfo(source).Length != originalLength || File.GetLastWriteTimeUtc(source) != originalWrite) {
                    throw new IOException("替换前原文件已发生变化");
                }
                if (inPlace) {
                    // Atomic replacement, not delete-then-rename. Failure preserves the source.
                    FileAttributes originalAttributes = File.GetAttributes(source);
                    bool readOnly = (originalAttributes & FileAttributes.ReadOnly) != 0;
                    if (readOnly) File.SetAttributes(source, originalAttributes & ~FileAttributes.ReadOnly);
                    try {
                        File.Replace(temporary, source, null);
                    } finally {
                        if (readOnly && File.Exists(source)) File.SetAttributes(source, originalAttributes);
                    }
                } else {
                    File.Move(temporary, destination);
                }
                committed = true;
                return new DecryptResult {Destination = destination, PlainBytes = plainBytes, SHA256 = digest};
            } finally {
                if (stream != null) Array.Clear(stream, 0, stream.Length);
                if (!committed && File.Exists(temporary)) {
                    try { File.Delete(temporary); } catch { }
                }
            }
        }

        static T WithReadablePath<T>(string path, Func<string, T> action) {
            if (!String.Equals(Path.GetExtension(path), ".ps1", StringComparison.OrdinalIgnoreCase)) return action(path);
            string directory = Path.GetDirectoryName(path);
            string name = Path.GetFileName(path);
            string temporaryName = Path.GetFileNameWithoutExtension(name) + "." + Guid.NewGuid().ToString("N").Substring(0, 8) + ".txt";
            string temporary = Path.Combine(directory, temporaryName);
            File.Move(path, temporary);
            try {
                return action(temporary);
            } finally {
                try { File.Move(temporary, path); }
                catch (Exception ex) { throw new IOException("无法自动改回 .ps1 名称，请手动把 " + temporary + " 改回 " + name + "：" + ex.Message, ex); }
            }
        }

        public static ScanResult Scan(string root, Action<int> progress) {
            ScanResult result = new ScanResult();
            Regex temporaryPattern = new Regex("^unlock_[0-9a-f]{32}_.+\\.tmp$", RegexOptions.IgnoreCase);
            Stack<string> pending = new Stack<string>();
            int visited = 0;
            pending.Push(root);
            while (pending.Count > 0) {
                string directory = pending.Pop();
                string[] entries;
                try { entries = Directory.GetFileSystemEntries(directory); }
                catch (Exception ex) { result.Errors++; result.Issues.Add("目录读取失败：" + directory + " — " + ex.GetBaseException().Message); continue; }
                foreach (string entry in entries) {
                    FileAttributes attributes;
                    try { attributes = File.GetAttributes(entry); }
                    catch (Exception ex) { result.Errors++; result.Issues.Add("读取失败：" + entry + " — " + ex.GetBaseException().Message); continue; }
                    visited++;
                    if (progress != null && visited % 50 == 0) progress(visited);
                    if ((attributes & FileAttributes.ReparsePoint) != 0) { result.Links++; continue; }
                    if ((attributes & FileAttributes.Directory) != 0) { pending.Push(entry); continue; }
                    if (temporaryPattern.IsMatch(Path.GetFileName(entry))) continue;
                    result.Scanned++;
                    try {
                        HeaderInfo info = WithReadablePath(entry, p => Inspect(p));
                        switch (info.Kind) {
                            case "Supported": result.Files.Add(entry); break;
                            case "Plain": result.Plain++; break;
                            case "Invalid": result.Invalid++; result.Issues.Add("损坏或不完整：" + entry + " — " + info.Reason); break;
                            case "Unsupported": result.Unsupported++; result.Issues.Add("暂不支持：" + entry + " — " + info.Reason); break;
                        }
                    } catch (Exception ex) { result.Errors++; result.Issues.Add("读取失败：" + entry + " — " + ex.GetBaseException().Message); }
                }
            }
            return result;
        }

        public static BatchJob StartBatch(string[] sources, string[] targets, int workers) {
            BatchJob job = new BatchJob {Total = sources.Length};
            job.Task = Task.Run(() => DecryptBatch(sources, targets, workers, job));
            return job;
        }

        static BatchResult[] DecryptBatch(string[] sources, string[] targets, int workers, BatchJob job) {
            BatchResult[] results = new BatchResult[sources.Length];
            Parallel.For(0, sources.Length, new ParallelOptions {MaxDegreeOfParallelism = workers}, i => {
                BatchResult item = new BatchResult {Source = sources[i]};
                try {
                    bool inPlace = String.Equals(sources[i], targets[i], StringComparison.OrdinalIgnoreCase);
                    DecryptResult done = WithReadablePath(sources[i], readable => DecryptFile(readable, inPlace ? readable : targets[i], null));
                    item.Ok = true;
                    item.PlainBytes = done.PlainBytes;
                } catch (Exception ex) {
                    item.Error = ex.GetBaseException().Message;
                }
                results[i] = item;
                Interlocked.Increment(ref job.Done);
            });
            return results;
        }
    }

    public sealed class ScanResult {
        public List<string> Files = new List<string>();
        public List<string> Issues = new List<string>();
        public int Scanned;
        public int Plain;
        public int Invalid;
        public int Unsupported;
        public int Links;
        public int Errors;
    }

    public sealed class BatchJob {
        public int Total;
        public int Done;
        public Task<BatchResult[]> Task;
    }

    public sealed class BatchResult {
        public string Source;
        public bool Ok;
        public long PlainBytes;
        public string Error;
    }
}
'@
}

function Invoke-WithReadablePath([string]$Path, [scriptblock]$Action) {
    if ([IO.Path]::GetExtension($Path) -ine '.ps1') { return & $Action $Path }
    $directory = Split-Path -Parent $Path
    $name = Split-Path -Leaf $Path
    $temporaryName = [IO.Path]::GetFileNameWithoutExtension($name) + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt'
    Rename-Item -LiteralPath $Path -NewName $temporaryName -ErrorAction Stop
    $temporary = Join-Path $directory $temporaryName
    try { return & $Action $temporary }
    finally {
        try { Rename-Item -LiteralPath $temporary -NewName $name -ErrorAction Stop }
        catch { Write-Warning "无法自动改回 .ps1 名称，请手动把 $temporary 改回 $name：$($_.Exception.Message)" }
    }
}

function Show-Bar([string]$Label, [long]$Done, [long]$Total) {
    $width = 32
    $ratio = if ($Total -gt 0) { [Math]::Min(1.0, [double]$Done / $Total) } else { 0.0 }
    $filled = [int][Math]::Floor($ratio * $width)
    $fill = if ($ratio -lt 0.34) { 'Red' } elseif ($ratio -lt 0.7) { 'Yellow' } else { 'Green' }
    $percent = [int][Math]::Floor($ratio * 100)
    Write-Host "`r$Label " -NoNewline -ForegroundColor Cyan
    Write-Host ('█' * $filled) -NoNewline -ForegroundColor $fill
    Write-Host ('░' * ($width - $filled)) -NoNewline -ForegroundColor DarkGray
    Write-Host (' {0,3}%  {1}/{2}          ' -f $percent, $Done, $Total) -NoNewline -ForegroundColor White
}

function Find-UnlockFiles([string]$Root) {
    $script:scanTotal = 0
    try { $script:scanTotal = @([IO.Directory]::GetFiles($Root, '*', [IO.SearchOption]::AllDirectories)).Count } catch { $script:scanTotal = 0 }
    $report = $null
    if (-not $NoProgress) { $report = [Action[int]]{ param($n) Show-Bar '扫描' $n $script:scanTotal } }
    $result = [UnlockPortable.EngineV2]::Scan($Root, $report)
    if (-not $NoProgress) { Show-Bar '扫描' $script:scanTotal $script:scanTotal; Write-Host '' }
    $result
}

function Show-Failures($Failures) {
    if ($Failures.Count -eq 0) { return }
    Write-Host '失败明细：' -ForegroundColor Red
    foreach ($item in $Failures) { Write-Host "  $item" -ForegroundColor Red }
}

function Show-Report([int]$Success, [int]$Failed, [double]$Seconds, $Failures) {
    Write-Host "解密完成：成功 $Success 个，失败 $Failed 个，用时 $([Math]::Round($Seconds, 1)) 秒" -ForegroundColor Cyan
    Show-Failures $Failures
}

if ($Library) { return }

try {
    $sourceItem = Get-Item -LiteralPath $SourcePath -Force -ErrorAction Stop
    if ($sourceItem.PSProvider.Name -ne 'FileSystem') { throw '只支持本地或网络文件系统路径。' }
    if ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '不处理符号链接或重解析点。' }
    $source = $sourceItem.FullName
    $destination = $null
    if ($DestinationPath) { $destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationPath) }
    $files = New-Object 'System.Collections.Generic.List[string]'
    $failed = 0
    $failures = New-Object 'System.Collections.Generic.List[string]'
    if ($sourceItem.PSIsContainer) {
        if ($destination -and $destination.TrimEnd('\') -ieq $source.TrimEnd('\')) { $destination = $null }
        if ($destination -and $destination.StartsWith($source.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw '输出目录不能放在源目录内部。' }
        $scanStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $scan = Find-UnlockFiles $source
        $files = $scan.Files
        $failed = $scan.Invalid + $scan.Unsupported + $scan.Errors
        foreach ($issue in $scan.Issues) { $failures.Add($issue) }
        Write-Host "扫描完成：已扫描 $($scan.Scanned) 个，匹配 $($files.Count) 个，普通文件 $($scan.Plain) 个，用时 $([Math]::Round($scanStopwatch.Elapsed.TotalSeconds, 1)) 秒"
    } else {
        $info = Invoke-WithReadablePath $source { param($p) [UnlockPortable.EngineV2]::Inspect($p) }
        if ($info.Kind -eq 'Plain') { Write-Host '跳过：文件没有支持的加密包头。'; exit 0 }
        if ($info.Kind -ne 'Supported') { throw "$($info.Kind)：$($info.Reason)" }
        $files.Add($source)
    }
    if ($ScanOnly) {
        foreach ($file in $files) { Write-Output $file }
        Show-Failures $failures
        if ($failed) { exit 1 }; exit 0
    }
    if ($sourceItem.PSIsContainer) {
        $targets = New-Object 'System.Collections.Generic.List[string]'
        foreach ($file in $files) {
            if ($destination) { $targets.Add((Join-Path $destination $file.Substring($source.TrimEnd('\').Length + 1))) }
            else { $targets.Add($file) }
        }
        $workers = [Math]::Max(1, [Math]::Min(4, [Environment]::ProcessorCount))
        $batchStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $job = [UnlockPortable.EngineV2]::StartBatch([string[]]$files.ToArray(), [string[]]$targets.ToArray(), $workers)
        while (-not $job.Task.IsCompleted) {
            if (-not $NoProgress) { Show-Bar '解密' $job.Done $job.Total }
            Start-Sleep -Milliseconds 100
        }
        if (-not $NoProgress) { Show-Bar '解密' $job.Total $job.Total; Write-Host '' }
        $outcomes = $job.Task.Result
        $success = 0
        foreach ($outcome in $outcomes) {
            if ($outcome.Ok) { $success++ }
            else { $failed++; $failures.Add("$($outcome.Source) — $($outcome.Error)") }
        }
        Show-Report $success $failed $batchStopwatch.Elapsed.TotalSeconds $failures
        if ($failed) { exit 1 }
        exit 0
    }
    $success = 0
    $decryptStopwatch = [Diagnostics.Stopwatch]::StartNew()
    foreach ($file in $files) {
        $target = $file
        if ($destination) {
            if ($sourceItem.PSIsContainer) { $target = Join-Path $destination $file.Substring($source.TrimEnd('\').Length + 1) }
            else { $target = $destination }
        }
        $progress = $null
        if (-not $NoProgress) { $progress = [Action[long,long]]{ param($d, $t) Show-Bar '解密' $d $t } }
        try {
            $result = Invoke-WithReadablePath $file { param($p) $output = if ($target -ieq $file) { $p } else { $target }; [UnlockPortable.EngineV2]::DecryptFile($p, $output, $progress) }
            if (-not $NoProgress) { Show-Bar '解密' $result.PlainBytes $result.PlainBytes; Write-Host '' }
            $success++
        } catch {
            if (-not $NoProgress) { Write-Host '' }
            $failed++
            $failures.Add("$file — $($_.Exception.GetBaseException().Message)")
        }
    }
    Show-Report $success $failed $decryptStopwatch.Elapsed.TotalSeconds $failures
    if ($failed) { exit 1 }
    exit 0
} catch {
    Write-Warning $_.Exception.GetBaseException().Message
    exit 1
}

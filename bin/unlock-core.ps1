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
using System.Security.Cryptography;

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
            HeaderInfo info = new HeaderInfo {Kind = "Plain", Reason = "No encrypted header", FileBytes = length};
            int count = ReadUpTo(stream, header, 26);
            // Magic family 0x7d8?. Do not treat an arbitrary binary extension as encrypted.
            if (count < 2 || (header[0] & 0xf0) != 0x80 || header[1] != 0x7d) return info;
            if (count < 26 || length < HeaderSize) {
                info.Kind = "Invalid"; info.Reason = "Truncated encrypted header"; return info;
            }
            // The tested profile. Do not guess an unverified mode or version.
            if (header[0] != 0x89 || header[2] != 0x1c) {
                info.Kind = "Unsupported";
                info.Reason = String.Format("Unverified encryption version/mode (version byte=0x{0:X2}, mode byte=0x{1:X2})", header[0], header[2]);
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
                info.Kind = "Invalid"; info.Reason = "Encrypted header CRC mismatch"; return info;
            }
            info.Kind = "Supported"; info.Reason = "Version 9 / verified RC4 profile";
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
            if ((File.GetAttributes(source) & FileAttributes.ReparsePoint) != 0) throw new IOException("Links/reparse points are not processed");
            if (!inPlace && (File.Exists(destination) || Directory.Exists(destination))) throw new IOException("Output already exists; refusing to overwrite: " + destination);
            string parent = Path.GetDirectoryName(destination);
            Directory.CreateDirectory(parent);
            string temporary = Path.Combine(parent, "unlock_" + Guid.NewGuid().ToString("N") + "_" + Path.GetFileName(destination) + ".tmp");
            byte[] stream = null;
            bool ready = false;
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
                    if (info.Kind != "Supported") throw new InvalidDataException(info.Kind + ": " + info.Reason);
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
                        if (plainBytes != expected) throw new IOException("Source length changed while reading");
                        if (progress != null) progress(plainBytes, expected);
                    }
                }
                using (SHA256 sha = SHA256.Create())
                using (FileStream check = new FileStream(temporary, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                    if (check.Length != plainBytes || Hex(sha.ComputeHash(check)) != digest) throw new IOException("Temporary output verification failed");
                }
                ready = true;
                if (new FileInfo(source).Length != originalLength || File.GetLastWriteTimeUtc(source) != originalWrite) {
                    throw new IOException("Source changed before replacement");
                }
                if (inPlace) {
                    // Atomic replacement, not delete-then-rename. Failure preserves the source.
                    File.Replace(temporary, source, null);
                } else {
                    File.Move(temporary, destination);
                }
                committed = true;
                return new DecryptResult {Destination = destination, PlainBytes = plainBytes, SHA256 = digest};
            } catch (Exception ex) {
                if (ready && File.Exists(temporary)) throw new IOException(ex.Message + "; complete output retained at: " + temporary, ex);
                throw;
            } finally {
                if (stream != null) Array.Clear(stream, 0, stream.Length);
                if (!ready && !committed && File.Exists(temporary)) {
                    try { File.Delete(temporary); } catch { }
                }
            }
        }
    }
}
'@
}

function Find-UnlockFiles([string]$Root) {
    $found = New-Object 'System.Collections.Generic.List[string]'
    $issues = New-Object 'System.Collections.Generic.List[string]'
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Root)
    $scanned = 0; $plain = 0; $invalid = 0; $unsupported = 0; $links = 0; $errors = 0
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        try { $entries = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) }
        catch { $errors++; $issues.Add("目录读取失败：$directory — $($_.Exception.Message)"); continue }
        foreach ($entry in $entries) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { $links++; continue }
            if ($entry.PSIsContainer) { $pending.Push($entry.FullName); continue }
            if ($entry.Name -match '^unlock_[0-9a-f]{32}_.+\.tmp$') { continue }
            $scanned++
            try {
                $info = [UnlockPortable.EngineV2]::Inspect($entry.FullName)
                switch ($info.Kind) {
                    'Supported' { $found.Add($entry.FullName) }
                    'Plain' { $plain++ }
                    'Invalid' { $invalid++; $issues.Add("损坏或不完整：$($entry.FullName) — $($info.Reason)") }
                    'Unsupported' { $unsupported++; $issues.Add("暂不支持：$($entry.FullName) — $($info.Reason)") }
                }
            } catch { $errors++; $issues.Add("读取失败：$($entry.FullName) — $($_.Exception.GetBaseException().Message)") }
            if (-not $NoProgress -and $clock.ElapsedMilliseconds -ge 150) {
                Write-Progress -Id 1 -Activity '正在识别加密文件' -Status "已检查 $scanned 个文件，匹配 $($found.Count) 个" -CurrentOperation $entry.FullName
                $clock.Restart()
            }
        }
    }
    if (-not $NoProgress) { Write-Progress -Id 1 -Activity '正在识别加密文件' -Completed }
    [pscustomobject]@{Files=$found; Issues=$issues; Scanned=$scanned; Plain=$plain; Invalid=$invalid; Unsupported=$unsupported; Links=$links; Errors=$errors}
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
    if ($sourceItem.PSIsContainer) {
        if ($destination -and $destination.TrimEnd('\') -ieq $source.TrimEnd('\')) { $destination = $null }
        if ($destination -and $destination.StartsWith($source.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw '输出目录不能放在源目录内部。' }
        Write-Host '正在扫描文件头（普通文件只读前 26 字节，疑似加密文件校验前 512 字节）…'
        $scan = Find-UnlockFiles $source
        $files = $scan.Files
        $failed = $scan.Invalid + $scan.Unsupported + $scan.Errors
        Write-Host "已扫描 $($scan.Scanned) 个：匹配 $($files.Count)，普通文件 $($scan.Plain)，损坏 $($scan.Invalid)，不支持 $($scan.Unsupported)，读取失败 $($scan.Errors)，跳过链接 $($scan.Links)"
        foreach ($issue in $scan.Issues) { Write-Warning $issue }
    } else {
        $info = [UnlockPortable.EngineV2]::Inspect($source)
        if ($info.Kind -eq 'Plain') { Write-Host '跳过：文件没有支持的加密包头。'; exit 0 }
        if ($info.Kind -ne 'Supported') { throw "$($info.Kind)：$($info.Reason)" }
        $files.Add($source)
    }
    if ($ScanOnly) {
        foreach ($file in $files) { Write-Output $file }
        if ($failed) { exit 1 }; exit 0
    }
    $success = 0; $index = 0
    foreach ($file in $files) {
        $target = $file
        if ($destination) {
            if ($sourceItem.PSIsContainer) { $target = Join-Path $destination $file.Substring($source.TrimEnd('\').Length + 1) }
            else { $target = $destination }
        }
        $progress = $null
        if (-not $NoProgress) {
            $progress = [Action[long,long]]{
                param($done, $total)
                $fraction = 1.0
                if ($total -gt 0) { $fraction = [double]$done / $total }
                $percent = [int](100 * ($index + $fraction) / [Math]::Max(1, $files.Count))
                Write-Progress -Id 1 -Activity '正在解密' -Status "[$($index + 1)/$($files.Count)] $([IO.Path]::GetFileName($file)) — $done / $total 字节" -PercentComplete ([Math]::Min(100, $percent)) -CurrentOperation $file
            }
        }
        try {
            $result = [UnlockPortable.EngineV2]::DecryptFile($file, $target, $progress)
            $success++
            if (-not $sourceItem.PSIsContainer) { Write-Host "已解密：$($result.Destination)（$($result.PlainBytes) 字节）" -ForegroundColor Cyan }
        } catch {
            $failed++
            Write-Warning "解密失败：$file — $($_.Exception.Message)"
        }
        $index++
    }
    if (-not $NoProgress) { Write-Progress -Id 1 -Activity '正在解密' -Completed }
    Write-Host "处理完成：成功 $success，失败/不支持 $failed" -ForegroundColor Cyan
    if ($failed) { exit 1 }
    exit 0
} catch {
    if (-not $NoProgress) { Write-Progress -Id 1 -Activity '正在解密' -Completed }
    Write-Warning $_.Exception.GetBaseException().Message
    exit 1
}

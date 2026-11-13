using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace UnlockPortable.Desktop;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        if (Environment.GetCommandLineArgs().Length == 4 && Environment.GetCommandLineArgs()[1] == "--self-test")
        {
            Environment.ExitCode = SelfTest.Run(Environment.GetCommandLineArgs());
            return;
        }
        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm());
    }
}

internal sealed class MainForm : Form
{
    private readonly TextBox pathBox = new();
    private readonly Button fileButton = new();
    private readonly Button folderButton = new();
    private readonly Button scanButton = new();
    private readonly Button decryptButton = new();
    private readonly Button cancelButton = new();
    private readonly ProgressBar progress = new();
    private readonly Label status = new();
    private readonly ListView results = new();
    private bool busy;

    public MainForm()
    {
        Text = "Unlock Portable";
        ClientSize = new Size(900, 640);
        MinimumSize = MaximumSize = Size;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(242, 246, 247);
        Font = new Font("Microsoft YaHei UI", 9F);
        Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);

        var header = new Panel { Dock = DockStyle.Top, Height = 96, BackColor = Color.FromArgb(8, 88, 84) };
        var title = new Label { Text = "Unlock", Font = new Font("Microsoft YaHei UI", 23F, FontStyle.Bold), ForeColor = Color.White, Location = new Point(30, 24), AutoSize = true };
        var mark = new Label { Text = "U", Font = new Font("Segoe UI", 15F, FontStyle.Bold), ForeColor = Color.White, TextAlign = ContentAlignment.MiddleCenter, BackColor = Color.FromArgb(8, 127, 120), Location = new Point(840, 27), Size = new Size(34, 34) };
        header.Controls.AddRange([title, mark]);
        Controls.Add(header);

        var pathPanel = new Panel { BackColor = Color.White, Location = new Point(26, 116), Size = new Size(848, 94) };
        var pathLabel = new Label { Text = "目標路徑", Location = new Point(18, 12), AutoSize = true, Font = new Font(Font, FontStyle.Bold), ForeColor = Color.FromArgb(42, 64, 71) };
        pathBox.SetBounds(18, 42, 665, 32);
        pathBox.ReadOnly = true;
        pathBox.BackColor = Color.White;
        fileButton.Text = "选择文件"; fileButton.SetBounds(700, 15, 130, 30);
        fileButton.FlatStyle = FlatStyle.Flat; fileButton.FlatAppearance.BorderColor = Color.FromArgb(202, 218, 216);
        fileButton.BackColor = Color.FromArgb(248, 251, 250); fileButton.ForeColor = Color.FromArgb(8, 104, 99);
        folderButton.Text = "选择文件夹"; folderButton.SetBounds(700, 51, 130, 30);
        folderButton.FlatStyle = FlatStyle.Flat; folderButton.FlatAppearance.BorderColor = Color.FromArgb(202, 218, 216);
        folderButton.BackColor = Color.FromArgb(248, 251, 250); folderButton.ForeColor = Color.FromArgb(8, 104, 99);
        fileButton.Click += (_, _) => ChooseFile();
        folderButton.Click += (_, _) => ChooseFolder();
        pathPanel.Controls.AddRange([pathLabel, pathBox, fileButton, folderButton]);
        Controls.Add(pathPanel);

        scanButton.Text = "仅扫描"; scanButton.SetBounds(28, 226, 118, 38);
        scanButton.FlatStyle = FlatStyle.Flat; scanButton.FlatAppearance.BorderColor = Color.FromArgb(202, 218, 216);
        scanButton.BackColor = Color.White; scanButton.ForeColor = Color.FromArgb(55, 79, 85);
        decryptButton.Text = "扫描并解密"; decryptButton.SetBounds(158, 226, 148, 38);
        decryptButton.BackColor = Color.FromArgb(8, 127, 120); decryptButton.ForeColor = Color.White; decryptButton.FlatStyle = FlatStyle.Flat; decryptButton.FlatAppearance.BorderSize = 0;
        cancelButton.Text = "取消"; cancelButton.SetBounds(318, 226, 94, 38); cancelButton.Enabled = false;
        cancelButton.FlatStyle = FlatStyle.Flat; cancelButton.FlatAppearance.BorderColor = Color.FromArgb(225, 231, 232);
        scanButton.Click += async (_, _) => await RunWork(false);
        decryptButton.Click += async (_, _) => await RunWork(true);
        cancelButton.Click += (_, _) => cancellationSource.Cancel();
        Controls.AddRange([scanButton, decryptButton, cancelButton]);

        var resultsLabel = new Label { Text = "处理结果", Location = new Point(29, 284), AutoSize = true, Font = new Font(Font, FontStyle.Bold), ForeColor = Color.FromArgb(42, 64, 71) };
        results.SetBounds(26, 310, 848, 248); results.View = View.Details; results.FullRowSelect = true; results.GridLines = false;
        results.BorderStyle = BorderStyle.None; results.BackColor = Color.White; results.ForeColor = Color.FromArgb(44, 63, 69);
        results.HideSelection = false; results.HeaderStyle = ColumnHeaderStyle.Nonclickable;
        results.Columns.Add("文件", 430); results.Columns.Add("状态", 120); results.Columns.Add("信息", 290);
        var resultPanel = new Panel { BackColor = Color.White, Location = new Point(26, 306), Size = new Size(848, 252) };
        results.Location = new Point(1, 1); results.Size = new Size(846, 250);
        resultPanel.Controls.Add(results);
        var footer = new Panel { Location = new Point(26, 574), Size = new Size(848, 42), BackColor = Color.Transparent };
        status.SetBounds(0, 0, 840, 20); status.ForeColor = Color.FromArgb(76, 98, 108); status.Text = "选择文件或文件夹开始。";
        progress.SetBounds(0, 25, 848, 10); progress.Style = ProgressBarStyle.Continuous;
        footer.Controls.AddRange([status, progress]);
        Controls.AddRange([resultsLabel, resultPanel, footer]);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (busy)
        {
            e.Cancel = true;
            cancellationSource.Cancel();
            status.Text = "正在取消；当前文件完成后即可关闭窗口。";
            return;
        }
        base.OnFormClosing(e);
    }

    private void ChooseFile()
    {
        using var dialog = new OpenFileDialog { CheckFileExists = true, Multiselect = false, Title = "选择要扫描或解密的文件" };
        if (dialog.ShowDialog(this) == DialogResult.OK) pathBox.Text = dialog.FileName;
    }

    private void ChooseFolder()
    {
        using var dialog = new FolderBrowserDialog { Description = "选择要递归扫描的文件夹", UseDescriptionForTitle = true, ShowNewFolderButton = false };
        if (dialog.ShowDialog(this) == DialogResult.OK) pathBox.Text = dialog.SelectedPath;
    }

    private async Task RunWork(bool decrypt)
    {
        string root = pathBox.Text;
        if (string.IsNullOrWhiteSpace(root) || (!File.Exists(root) && !Directory.Exists(root)))
        {
            MessageBox.Show(this, "请选择有效的文件或文件夹。", "Unlock", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        if (decrypt && MessageBox.Show(this, "检测到支持的加密文件后，将在验证解密结果后原位替换原文件。重要文件请先备份。继续吗？", "确认原位解密", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;

        busy = true;
        SetControls(false); results.Items.Clear(); progress.Value = 0;
        var tokenSource = new CancellationTokenSource();
        SetCancellation(tokenSource);
        try
        {
            var paths = await Task.Run(() => CollectFiles(root, tokenSource.Token), tokenSource.Token);
            if (paths.Count == 0) { status.Text = "没有找到可扫描的文件。"; return; }
            var matches = new List<string>();
            int scanned = 0;
            foreach (string file in paths)
            {
                tokenSource.Token.ThrowIfCancellationRequested();
                HeaderInfo header;
                try { header = await Task.Run(() => CryptoEngine.InspectReadable(file), tokenSource.Token); }
                catch (Exception ex) { header = new HeaderInfo("Error", ex.GetBaseException().Message, 0); }
                scanned++;
                if (header.Kind == "Supported") matches.Add(file);
                else if (header.Kind is "Invalid" or "Unsupported" or "Error") AddResult(file, "未处理", header.Reason);
                if (scanned % 8 == 0 || scanned == paths.Count)
                {
                    progress.Value = Math.Clamp((int)(100.0 * scanned / paths.Count), 0, 100);
                status.Text = $"扫描中：{scanned:N0}/{paths.Count:N0} · 发现加密文件 {matches.Count:N0}";
                    await Task.Yield();
                }
            }
            if (!decrypt)
            {
                foreach (string file in matches) AddResult(file, "已加密", "支持解密");
                status.Text = $"扫描完成：检查 {scanned:N0} 个 · 发现加密文件 {matches.Count:N0} 个。";
                return;
            }
            if (matches.Count == 0) { status.Text = "扫描完成：没有发现支持的加密文件。"; return; }

            int done = 0, succeeded = 0, failed = 0;
            foreach (string file in matches)
            {
                tokenSource.Token.ThrowIfCancellationRequested();
                try
                {
                    await Task.Run(() => CryptoEngine.DecryptInPlace(file, (current, total) => { }), tokenSource.Token);
                    AddResult(file, "已解密", "已验证并原位替换"); succeeded++;
                }
                catch (Exception ex) { AddResult(file, "失败", ex.GetBaseException().Message); failed++; }
                done++;
                progress.Value = Math.Clamp((int)(100.0 * done / matches.Count), 0, 100);
                status.Text = $"解密中：{done:N0}/{matches.Count:N0} · 成功 {succeeded:N0} · 失败 {failed:N0}";
                await Task.Yield();
            }
            status.Text = $"处理完成：解密 {succeeded:N0} 个 · 失败 {failed:N0} 个。";
        }
        catch (OperationCanceledException) { status.Text = "已取消。正在处理的文件不会在校验成功前替换。"; }
        catch (Exception ex) { status.Text = "处理失败：" + ex.GetBaseException().Message; }
        finally { tokenSource.Dispose(); busy = false; SetControls(true); }
    }

    private CancellationTokenSource cancellationSource = new();
    private void SetCancellation(CancellationTokenSource source)
    {
        cancellationSource.Dispose(); cancellationSource = source;
    }

    private void SetControls(bool enabled)
    {
        fileButton.Enabled = folderButton.Enabled = scanButton.Enabled = decryptButton.Enabled = enabled;
        cancelButton.Enabled = !enabled;
    }

    private List<string> CollectFiles(string root, CancellationToken token)
    {
        if (File.Exists(root)) return [root];
        var files = new List<string>(); var pending = new Stack<string>(); pending.Push(root);
        var tempPattern = new Regex("^unlock_[0-9a-f]{32}_.+\\.tmp$", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        while (pending.Count > 0)
        {
            token.ThrowIfCancellationRequested(); string directory = pending.Pop();
            try
            {
                foreach (string entry in Directory.EnumerateFileSystemEntries(directory))
                {
                    token.ThrowIfCancellationRequested();
                    try
                    {
                        var attributes = File.GetAttributes(entry);
                        if ((attributes & FileAttributes.ReparsePoint) != 0) continue;
                        if ((attributes & FileAttributes.Directory) != 0) pending.Push(entry);
                        else if (!tempPattern.IsMatch(Path.GetFileName(entry))) files.Add(entry);
                    }
                    catch (UnauthorizedAccessException) { AddResult(entry, "跳过", "无读取权限"); }
                }
            }
            catch (UnauthorizedAccessException) { AddResult(directory, "跳过", "无目录访问权限"); }
        }
        return files;
    }

    private void AddResult(string path, string state, string info)
    {
        if (InvokeRequired) { BeginInvoke(() => AddResult(path, state, info)); return; }
        var item = new ListViewItem(path); item.SubItems.Add(state); item.SubItems.Add(info); results.Items.Add(item);
    }

}

internal sealed record HeaderInfo(string Kind, string Reason, long FileBytes);

internal static class CryptoEngine
{
    private const int HeaderSize = 4096;
    private const int Period = 512;

    public static HeaderInfo Inspect(string filename)
    {
        try
        {
            using var stream = new FileStream(filename, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            byte[] header = new byte[512]; long length = stream.Length;
            int count = ReadUpTo(stream, header, 26);
            if (count < 2 || (header[0] & 0xf0) != 0x80 || header[1] != 0x7d) return new("Plain", "未发现加密头", length);
            if (count < 26 || length < HeaderSize) return new("Invalid", "加密头不完整", length);
            if (header[0] != 0x89 || header[2] != 0x1c) return new("Unsupported", $"不支持的版本/模式 0x{header[0]:X2}/0x{header[2]:X2}", length);
            stream.Position = 0;
            count = ReadUpTo(stream, header, 512);
            if (count != 512 || HeaderCrc(header) != header[46]) return new("Invalid", "加密头 CRC 校验失败", length);
            return new("Supported", "版本 9 / 已验证 RC4 格式", length);
        }
        catch (Exception ex) { return new("Error", ex.GetBaseException().Message, 0); }
    }

    public static HeaderInfo InspectReadable(string path)
    {
        if (!Path.GetExtension(path).Equals(".ps1", StringComparison.OrdinalIgnoreCase)) return Inspect(path);
        string temporary = Path.Combine(Path.GetDirectoryName(path)!, Path.GetFileNameWithoutExtension(path) + "." + Guid.NewGuid().ToString("N")[..8] + ".txt");
        File.Move(path, temporary);
        try { return Inspect(temporary); }
        finally
        {
            try { File.Move(temporary, path); }
            catch (Exception ex) { throw new IOException($"无法自动恢复 .ps1 文件名。临时文件位置：{temporary}", ex); }
        }
    }

    public static void DecryptInPlace(string source, Action<long, long>? progress)
    {
        source = Path.GetFullPath(source);
        if ((File.GetAttributes(source) & FileAttributes.ReparsePoint) != 0) throw new IOException("不处理符号链接或重解析点");
        string originalName = Path.GetFileName(source), directory = Path.GetDirectoryName(source)!;
        string readPath = source, renamedPath = "";
        bool ps1 = Path.GetExtension(source).Equals(".ps1", StringComparison.OrdinalIgnoreCase);
        if (ps1)
        {
            renamedPath = Path.Combine(directory, Path.GetFileNameWithoutExtension(source) + "." + Guid.NewGuid().ToString("N")[..8] + ".txt");
            File.Move(source, renamedPath); readPath = renamedPath;
        }
        try { DecryptPath(readPath, readPath, progress); }
        finally
        {
            if (ps1 && File.Exists(renamedPath))
            {
                string restorePath = File.Exists(source) ? Path.Combine(directory, Path.GetFileNameWithoutExtension(source) + ".restored-" + Guid.NewGuid().ToString("N")[..8] + ".ps1") : source;
                File.Move(renamedPath, restorePath);
            }
        }
    }

    private static void DecryptPath(string readableSource, string originalPath, Action<long, long>? progress)
    {
        string temp = Path.Combine(Path.GetDirectoryName(originalPath)!, "unlock_" + Guid.NewGuid().ToString("N") + "_" + Path.GetFileName(originalPath) + ".tmp");
        byte[]? key = null; bool committed = false; long plainBytes = 0, originalLength; string digest; DateTime writeTime = File.GetLastWriteTimeUtc(readableSource);
        try
        {
            using (var input = new FileStream(readableSource, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                originalLength = input.Length; byte[] header = new byte[512]; int read = ReadUpTo(input, header, header.Length);
                if (read != 512 || Inspect(readableSource).Kind != "Supported") throw new InvalidDataException("文件头不支持或已损坏");
                key = KeyStream(header); long expected = originalLength - HeaderSize; input.Position = HeaderSize;
                using var sha = SHA256.Create();
                using (var output = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    byte[] buffer = new byte[1024 * 1024]; int n; progress?.Invoke(0, expected);
                    while ((n = input.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        for (int i = 0; i < n; i++) buffer[i] ^= key[(int)((plainBytes + i) & 511)];
                        sha.TransformBlock(buffer, 0, n, buffer, 0); output.Write(buffer, 0, n); plainBytes += n;
                        progress?.Invoke(plainBytes, expected);
                    }
                    sha.TransformFinalBlock([], 0, 0); digest = Convert.ToHexString(sha.Hash!).ToLowerInvariant(); output.Flush(true);
                    if (plainBytes != expected) throw new IOException("读取期间原文件长度发生变化");
                }
            }
            using (var check = File.OpenRead(temp))
            using (var sha = SHA256.Create())
                if (check.Length != plainBytes || Convert.ToHexString(sha.ComputeHash(check)).ToLowerInvariant() != digest) throw new IOException("临时解密结果校验失败");
            if (new FileInfo(readableSource).Length != originalLength || File.GetLastWriteTimeUtc(readableSource) != writeTime) throw new IOException("替换前源文件已发生变化");
            var attrs = File.GetAttributes(readableSource); bool readOnly = (attrs & FileAttributes.ReadOnly) != 0;
            if (readOnly) File.SetAttributes(readableSource, attrs & ~FileAttributes.ReadOnly);
            try { File.Replace(temp, originalPath, null); }
            finally { if (readOnly && File.Exists(originalPath)) File.SetAttributes(originalPath, attrs); }
            committed = true;
        }
        finally
        {
            if (key is not null) CryptographicOperations.ZeroMemory(key);
            if (!committed && File.Exists(temp)) try { File.Delete(temp); } catch { }
        }
    }

    private static int ReadUpTo(Stream stream, byte[] data, int count)
    {
        int total = 0; while (total < count) { int n = stream.Read(data, total, count - total); if (n == 0) break; total += n; } return total;
    }

    private static byte CrcStep(byte state, byte value)
    {
        int next = state ^ value; for (int i = 0; i < 8; i++) next = (next >> 1) ^ ((next & 1) != 0 ? 0xe0 : 0); return (byte)next;
    }

    private static byte HeaderCrc(byte[] header)
    {
        byte state = 255; for (int i = 8; i < 12; i++) state = CrcStep(state, header[i]);
        for (int i = 28; i < 512; i++) if (i != 46) state = CrcStep(state, header[i]); return (byte)(255 - state);
    }

    private static byte[] Slice(byte[] data, int offset, int count) => data.AsSpan(offset, count).ToArray();

    private static byte[] Rc4(byte[] key, byte[] input)
    {
        byte[] state = new byte[256]; for (int i = 0; i < 256; i++) state[i] = (byte)i; int j = 0;
        for (int i = 0; i < 256; i++) { j = (j + state[i] + key[i % key.Length]) & 255; (state[i], state[j]) = (state[j], state[i]); }
        byte[] output = new byte[input.Length]; int x = 0; j = 0;
        for (int n = 0; n < input.Length; n++) { x = (x + 1) & 255; j = (j + state[x]) & 255; (state[x], state[j]) = (state[j], state[x]); output[n] = (byte)(input[n] ^ state[(state[x] + state[j]) & 255]); }
        CryptographicOperations.ZeroMemory(state); return output;
    }

    private static byte[] KeyStream(byte[] header)
    {
        byte[] parameter = Slice(header, 8, 4), check = Rc4(parameter, Slice(header, 12, 8));
        byte[] selected = [check[6], check[0], check[5]], repeated = new byte[16];
        for (int i = 0; i < 16; i++) repeated[i] = parameter[i % 4];
        byte[] stage = Rc4(selected, repeated); Buffer.BlockCopy(selected, 0, stage, 0, 3); byte[] key = Rc4(parameter, stage); byte[] result = Rc4(key, new byte[Period]);
        CryptographicOperations.ZeroMemory(check); CryptographicOperations.ZeroMemory(selected); CryptographicOperations.ZeroMemory(stage); CryptographicOperations.ZeroMemory(key); return result;
    }
}

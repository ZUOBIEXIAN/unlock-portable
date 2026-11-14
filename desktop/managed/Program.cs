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
        Application.Run(new TrayApplicationContext());
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
    private bool allowClose;
    private readonly Func<bool, Task> workRequested;
    private readonly Action cancelRequested;
    public event Action? CloseRequested;
    public event Action? SettingsRequested;

    public MainForm(Func<bool, Task> workRequested, Action cancelRequested)
    {
        this.workRequested = workRequested;
        this.cancelRequested = cancelRequested;
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
        var settings = new Button { Text = "⚙", Font = new Font("Segoe UI Symbol", 15F), ForeColor = Color.White, BackColor = Color.FromArgb(8, 88, 84), FlatStyle = FlatStyle.Flat, Location = new Point(790, 25), Size = new Size(38, 38), TabStop = false };
        settings.FlatAppearance.BorderSize = 0;
        settings.Click += (_, _) => SettingsRequested?.Invoke();
        var mark = new Label { Text = "U", Font = new Font("Segoe UI", 15F, FontStyle.Bold), ForeColor = Color.White, TextAlign = ContentAlignment.MiddleCenter, BackColor = Color.FromArgb(8, 127, 120), Location = new Point(840, 27), Size = new Size(34, 34) };
        header.Controls.AddRange([title, settings, mark]);
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
        scanButton.Click += async (_, _) => await this.workRequested(false);
        decryptButton.Click += async (_, _) => await this.workRequested(true);
        cancelButton.Click += (_, _) => this.cancelRequested();
        Controls.AddRange([scanButton, decryptButton, cancelButton]);

        results.SetBounds(28, 282, 844, 294);
        results.View = View.Details;
        results.FullRowSelect = true;
        results.GridLines = true;
        results.Columns.Add("文件", 420);
        results.Columns.Add("状态", 110);
        results.Columns.Add("信息", 290);
        Controls.Add(results);

        var footer = new Panel { Location = new Point(26, 590), Size = new Size(848, 42), BackColor = Color.Transparent };
        status.SetBounds(0, 0, 840, 20); status.ForeColor = Color.FromArgb(76, 98, 108); status.Text = "选择文件或文件夹开始。";
        progress.SetBounds(0, 25, 848, 10); progress.Style = ProgressBarStyle.Continuous;
        footer.Controls.AddRange([status, progress]);
        Controls.Add(footer);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!allowClose)
        {
            e.Cancel = true;
            CloseRequested?.Invoke();
            return;
        }
        base.OnFormClosing(e);
    }

    public void ApplyTaskState(bool active, int value, string message, bool indeterminate)
    {
        status.Text = message;
        fileButton.Enabled = folderButton.Enabled = scanButton.Enabled = decryptButton.Enabled = !active;
        cancelButton.Enabled = active;
        progress.Style = indeterminate ? ProgressBarStyle.Marquee : ProgressBarStyle.Continuous;
        progress.MarqueeAnimationSpeed = indeterminate ? 24 : 0;
        if (!indeterminate) progress.Value = Math.Clamp(value, 0, 100);
    }

    public string SelectedPath => pathBox.Text;

    public void ClearResults() => results.Items.Clear();

    public void AddResult(string path, string state, string detail)
    {
        var item = new ListViewItem(path);
        item.SubItems.Add(state);
        item.SubItems.Add(detail);
        results.Items.Add(item);
        item.EnsureVisible();
    }

    public void Shutdown()
    {
        allowClose = true;
        Close();
    }

    private void ChooseFile()
    {
        using var dialog = new OpenFileDialog { CheckFileExists = true, Multiselect = false, Title = "选择要扫描或解密的文件" };
        if (dialog.ShowDialog(this) == DialogResult.OK) { pathBox.Text = dialog.FileName; PathChanged?.Invoke(pathBox.Text); }
    }

    private void ChooseFolder()
    {
        using var dialog = new FolderBrowserDialog { Description = "选择要递归扫描的文件夹", UseDescriptionForTitle = true, ShowNewFolderButton = false };
        if (dialog.ShowDialog(this) == DialogResult.OK) { pathBox.Text = dialog.SelectedPath; PathChanged?.Invoke(pathBox.Text); }
    }

    public event Action<string>? PathChanged;

}

internal sealed record HeaderInfo(string Kind, string Reason, long FileBytes);

internal sealed class TrayApplicationContext : ApplicationContext
{
    private enum CloseBehavior { Ask = 0, Tray = 1, Exit = 2 }
    private readonly NotifyIcon trayIcon;
    private readonly TrayProgressForm progressForm = new();
    private readonly ToolStripMenuItem cancelItem = new("取消当前任务");
    private readonly ToolStripMenuItem showProgressItem = new("显示任务进度");
    private CancellationTokenSource cancellation = new();
    private readonly MainForm mainForm;
    private bool busy;
    private bool exitRequested;
    private int currentProgress;
    private string currentStatus = "空闲。";
    private bool indeterminate;
    private CloseBehavior closeBehavior;
    private readonly string settingsPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "UnlockPortable", "managed-settings.txt");

    public TrayApplicationContext()
    {
        var menu = new ContextMenuStrip();
        var chooseFile = new ToolStripMenuItem("选择文件");
        chooseFile.DropDownItems.Add(new ToolStripMenuItem("仅扫描", null, async (_, _) => await ChooseAndRun(false, false)));
        chooseFile.DropDownItems.Add(new ToolStripMenuItem("扫描并解密…", null, async (_, _) => await ChooseAndRun(false, true)));
        var chooseFolder = new ToolStripMenuItem("选择文件夹");
        chooseFolder.DropDownItems.Add(new ToolStripMenuItem("仅扫描", null, async (_, _) => await ChooseAndRun(true, false)));
        chooseFolder.DropDownItems.Add(new ToolStripMenuItem("扫描并解密…", null, async (_, _) => await ChooseAndRun(true, true)));
        showProgressItem.Click += (_, _) => progressForm.ShowProgress();
        cancelItem.Click += (_, _) => cancellation.Cancel();
        var openPanel = new ToolStripMenuItem("打开操作面板", null, (_, _) => ShowMainForm());
        var exit = new ToolStripMenuItem("退出", null, (_, _) => RequestExit());
        menu.Items.AddRange([openPanel, showProgressItem, new ToolStripSeparator(), chooseFile, chooseFolder, new ToolStripSeparator(), cancelItem, exit]);

        trayIcon = new NotifyIcon
        {
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application,
            Text = "Unlock Portable 托盘版",
            ContextMenuStrip = menu,
            Visible = true
        };
        mainForm = new MainForm(RunFromPanel, () => cancellation.Cancel());
        LoadCloseBehavior();
        mainForm.CloseRequested += HandleMainClose;
        mainForm.SettingsRequested += ShowSettings;
        mainForm.PathChanged += path => { if (!busy) PublishState(currentProgress, path, false); };
        progressForm.CancelRequested += () => cancellation.Cancel();
        progressForm.StateChanged += UpdateMenu;
        UpdateMenu();
        SyncTaskState();
        ShowMainForm();
    }

    private void LoadCloseBehavior()
    {
        if (!int.TryParse(File.Exists(settingsPath) ? File.ReadAllText(settingsPath) : null, out int value) || value is < 1 or > 2)
            closeBehavior = CloseBehavior.Ask;
        else closeBehavior = (CloseBehavior)value;
    }

    private void SaveCloseBehavior()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(settingsPath)!);
        File.WriteAllText(settingsPath, ((int)closeBehavior).ToString());
    }

    private void HandleMainClose()
    {
        if (closeBehavior == CloseBehavior.Ask)
        {
            var choice = MessageBox.Show(mainForm, "是：关闭窗口后保留在系统托盘。\n否：退出程序。\n取消：继续使用。", "关闭方式", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
            if (choice == DialogResult.Cancel) return;
            closeBehavior = choice == DialogResult.Yes ? CloseBehavior.Tray : CloseBehavior.Exit;
            SaveCloseBehavior();
        }
        if (closeBehavior == CloseBehavior.Tray) mainForm.Hide();
        else RequestExit();
    }

    private void ShowSettings()
    {
        using var dialog = new Form { Text = "设置", ClientSize = new Size(360, 190), FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent, MaximizeBox = false, MinimizeBox = false, ShowInTaskbar = false, Font = mainForm.Font };
        var label = new Label { Text = "点击右上角 X 时", Location = new Point(20, 18), AutoSize = true };
        var tray = new RadioButton { Text = "隐藏到系统托盘", Location = new Point(24, 52), AutoSize = true, Checked = closeBehavior != CloseBehavior.Exit };
        var exit = new RadioButton { Text = "直接退出程序", Location = new Point(24, 82), AutoSize = true, Checked = closeBehavior == CloseBehavior.Exit };
        var save = new Button { Text = "保存", DialogResult = DialogResult.OK, Location = new Point(176, 135), Size = new Size(76, 30) };
        var cancel = new Button { Text = "取消", DialogResult = DialogResult.Cancel, Location = new Point(264, 135), Size = new Size(76, 30) };
        dialog.Controls.AddRange([label, tray, exit, save, cancel]); dialog.AcceptButton = save; dialog.CancelButton = cancel;
        if (dialog.ShowDialog(mainForm) == DialogResult.OK)
        {
            closeBehavior = tray.Checked ? CloseBehavior.Tray : CloseBehavior.Exit;
            SaveCloseBehavior();
        }
    }

    private void UpdateMenu()
    {
        cancelItem.Enabled = busy;
        showProgressItem.Enabled = progressForm.HasProgress;
    }

    private void ShowMainForm()
    {
        if (mainForm.IsDisposed) return;
        mainForm.Show();
        mainForm.WindowState = FormWindowState.Normal;
        mainForm.Activate();
        SyncTaskState();
    }

    private Task RunFromPanel(bool decrypt)
    {
        string root = mainForm.SelectedPath;
        if (string.IsNullOrWhiteSpace(root) || (!File.Exists(root) && !Directory.Exists(root)))
        {
            MessageBox.Show(mainForm, "请选择有效的文件或文件夹。", "Unlock", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return Task.CompletedTask;
        }
        return ConfirmAndRun(root, decrypt);
    }

    private void PublishState(int value, string message, bool busyState, bool isIndeterminate = false)
    {
        currentProgress = Math.Clamp(value, 0, 100);
        currentStatus = message;
        busy = busyState;
        indeterminate = isIndeterminate;
        if (isIndeterminate) progressForm.SetIndeterminate(message);
        else progressForm.SetProgress(currentProgress, message);
        if (!mainForm.IsDisposed) mainForm.ApplyTaskState(busyState, currentProgress, message, isIndeterminate);
        UpdateMenu();
    }

    private void SyncTaskState()
    {
        if (!mainForm.IsDisposed) mainForm.ApplyTaskState(busy, currentProgress, currentStatus, indeterminate);
        if (progressForm.TaskActive)
        {
            if (indeterminate) progressForm.SetIndeterminate(currentStatus);
            else progressForm.SetProgress(currentProgress, currentStatus);
        }
    }

    private void RequestExit()
    {
        if (busy)
        {
            exitRequested = true;
            cancellation.Cancel();
            progressForm.SetStatus("正在取消，当前文件完成安全收尾后退出。");
            return;
        }
        ExitThread();
    }

    private async Task ChooseAndRun(bool folder, bool decrypt)
    {
        if (busy) return;
        string? root;
        if (folder)
        {
            using var dialog = new FolderBrowserDialog { Description = "选择要扫描的文件夹", UseDescriptionForTitle = true, ShowNewFolderButton = false };
            root = dialog.ShowDialog() == DialogResult.OK ? dialog.SelectedPath : null;
        }
        else
        {
            using var dialog = new OpenFileDialog { CheckFileExists = true, Multiselect = false, Title = "选择要扫描或解密的文件" };
            root = dialog.ShowDialog() == DialogResult.OK ? dialog.FileName : null;
        }
        if (root is null) return;
        await ConfirmAndRun(root, decrypt);
    }

    private async Task ConfirmAndRun(string root, bool decrypt)
    {
        if (busy) return;
        await RunWork(root, decrypt);
    }

    private async Task RunWork(string root, bool decrypt)
    {
        if (decrypt && MessageBox.Show(mainForm.Visible ? mainForm : null, "检测到支持的加密文件后，将在验证解密结果后原位替换原文件。重要文件请先备份。继续吗？", "确认原位解密", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
        busy = true;
        cancellation.Dispose();
        cancellation = new CancellationTokenSource();
        progressForm.BeginTask(decrypt ? "正在扫描并解密" : "正在扫描", false);
        mainForm.ClearResults();
        bool showTrayProgress = !mainForm.Visible;
        if (showTrayProgress) progressForm.ShowProgress();
        else progressForm.HideProgress();
        PublishState(0, decrypt ? "正在扫描并解密…" : "正在扫描…", true, true);
        string result = "任务已完成。";
        try
        {
            var paths = await Task.Run(() => CollectFiles(root, cancellation.Token,
                (count, current) => BeginInvokeOnUi(() => PublishState(currentProgress, $"正在枚举文件：{count:N0} · {current}", true, true))), cancellation.Token);
            if (paths.Count == 0)
            {
                result = "没有找到可扫描的文件。";
                PublishState(100, result, true);
                return;
            }

            var matches = new List<string>();
            int scanned = 0;
            foreach (string file in paths)
            {
                cancellation.Token.ThrowIfCancellationRequested();
                HeaderInfo header;
                try { header = await Task.Run(() => CryptoEngine.InspectReadable(file), cancellation.Token); }
                catch (Exception ex) { header = new HeaderInfo("Error", ex.GetBaseException().Message, 0); }
                scanned++;
                if (header.Kind == "Supported") matches.Add(file);
                int scanPercent = Math.Clamp((int)(100.0 * scanned / paths.Count), 0, 100);
                int displayed = decrypt ? scanPercent / 2 : scanPercent;
                PublishState(displayed, $"扫描中：{scanned:N0}/{paths.Count:N0} · 发现加密文件 {matches.Count:N0}", true);
                if (scanned % 8 == 0 || scanned == paths.Count) await Task.Yield();
            }

            if (!decrypt)
            {
                result = $"扫描完成：检查 {scanned:N0} 个 · 发现加密文件 {matches.Count:N0} 个。";
                PublishState(100, result, true);
                return;
            }
            if (matches.Count == 0)
            {
                result = "扫描完成：没有发现支持的加密文件。";
                PublishState(100, result, true);
                return;
            }

            int done = 0, succeeded = 0, failed = 0;
            foreach (string file in matches)
            {
                cancellation.Token.ThrowIfCancellationRequested();
                bool decrypted = false;
                try
                {
                    int completedBefore = done;
                    await Task.Run(() => CryptoEngine.DecryptInPlace(file, (current, total) =>
                    {
                        int filePercent = total <= 0 ? 100 : Math.Clamp((int)(100.0 * current / total), 0, 100);
                        int overall = Math.Clamp(50 + (int)(50.0 * (completedBefore + filePercent / 100.0) / matches.Count), 50, 100);
                        BeginInvokeOnUi(() => PublishState(overall, $"解密中：{completedBefore + 1:N0}/{matches.Count:N0} · {filePercent}%", true));
                    }), cancellation.Token);
                    succeeded++;
                    decrypted = true;
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    failed++;
                    mainForm.AddResult(file, "失败", ex.GetBaseException().Message);
                }
                if (decrypted)
                    mainForm.AddResult(file, "已解密", "已验证并原位替换");
                done++;
                int overallProgress = Math.Clamp(50 + (int)(50.0 * done / matches.Count), 0, 100);
                PublishState(overallProgress, $"解密中：{done:N0}/{matches.Count:N0} · 成功 {succeeded:N0} · 失败 {failed:N0}", true);
            }
            result = $"处理完成：解密 {succeeded:N0} 个 · 失败 {failed:N0} 个。";
            PublishState(100, result, true);
        }
        catch (OperationCanceledException) { result = "已取消。正在处理的文件不会在校验成功前替换。"; }
        catch (Exception ex) { result = "处理失败：" + ex.GetBaseException().Message; }
        finally
        {
            busy = false;
            if (exitRequested)
            {
                progressForm.Shutdown();
                ExitThread();
            }
            else
            {
                PublishState(currentProgress, result, false);
                progressForm.Complete(result, showTrayProgress && progressForm.Visible);
            }
        }
    }

    private static List<string> CollectFiles(string root, CancellationToken token, Action<int, string>? report)
    {
        if (File.Exists(root)) return [root];
        var files = new List<string>();
        var pending = new Stack<string>();
        var tempPattern = new Regex("^unlock_[0-9a-f]{32}_.+\\.tmp$", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        pending.Push(root);
        int discovered = 0;
        while (pending.Count > 0)
        {
            token.ThrowIfCancellationRequested();
            string directory = pending.Pop();
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
                        else if (!tempPattern.IsMatch(Path.GetFileName(entry)))
                        {
                            files.Add(entry);
                            if (++discovered % 32 == 0) report?.Invoke(discovered, directory);
                        }
                    }
                    catch (UnauthorizedAccessException) { }
                }
            }
            catch (UnauthorizedAccessException) { }
        }
        report?.Invoke(discovered, "文件枚举完成");
        return files;
    }

    private void BeginInvokeOnUi(Action action)
    {
        if (progressForm.IsDisposed) return;
        if (progressForm.InvokeRequired) progressForm.BeginInvoke(action);
        else action();
    }

    protected override void ExitThreadCore()
    {
        cancellation.Cancel();
        trayIcon.Visible = false;
        trayIcon.Dispose();
        progressForm.Shutdown();
        mainForm.Shutdown();
        cancellation.Dispose();
        base.ExitThreadCore();
    }
}
internal sealed class TrayProgressForm : Form
{
    private readonly Label title = new();
    private readonly Label details = new();
    private readonly ProgressBar bar = new();
    private readonly Button cancel = new();
    private readonly System.Windows.Forms.Timer closeTimer = new() { Interval = 8000 };
    private bool closing;

    public bool TaskActive { get; private set; }
    public bool HasProgress { get; private set; }
    public event Action? CancelRequested;
    public event Action? StateChanged;
    public int CurrentValue { get; private set; }
    public string CurrentMessage => details.Text;

    public TrayProgressForm()
    {
        Text = "Unlock 任务进度";
        ClientSize = new Size(360, 112);
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        BackColor = Color.White;
        Font = new Font("Microsoft YaHei UI", 9F);
        title.SetBounds(16, 12, 320, 22);
        title.Font = new Font(Font, FontStyle.Bold);
        details.SetBounds(16, 38, 320, 20);
        details.ForeColor = Color.FromArgb(76, 98, 108);
        bar.SetBounds(16, 65, 240, 16);
        cancel.Text = "取消";
        cancel.SetBounds(270, 59, 74, 28);
        cancel.Click += (_, _) => CancelRequested?.Invoke();
        Controls.AddRange([title, details, bar, cancel]);
        closeTimer.Tick += (_, _) =>
        {
            closeTimer.Stop();
            Hide();
            HasProgress = false;
            StateChanged?.Invoke();
        };
        FormClosing += (_, e) =>
        {
            if (closing) return;
            e.Cancel = true;
            Hide();
        };
    }

    public void BeginTask(string caption, bool showWindow)
    {
        closeTimer.Stop();
        TaskActive = true;
        HasProgress = true;
        title.Text = caption;
        details.Text = "正在准备任务…";
        bar.Style = ProgressBarStyle.Marquee;
        bar.MarqueeAnimationSpeed = 24;
        cancel.Enabled = true;
        if (showWindow)
        {
            PositionNearTray();
            Show();
            Activate();
        }
        StateChanged?.Invoke();
    }

    public void SetIndeterminate(string message)
    {
        if (!TaskActive) return;
        CurrentValue = bar.Value;
        details.Text = message;
        bar.Style = ProgressBarStyle.Marquee;
    }

    public void SetProgress(int value, string message)
    {
        if (!TaskActive) return;
        CurrentValue = Math.Clamp(value, 0, 100);
        details.Text = message;
        bar.Style = ProgressBarStyle.Continuous;
        bar.MarqueeAnimationSpeed = 0;
        bar.Value = CurrentValue;
    }

    public void SetStatus(string message) => details.Text = message;

    public void HideProgress() => Hide();

    public void Complete(string message, bool showResult)
    {
        TaskActive = false;
        if (!HasProgress) return;
        title.Text = "任务完成";
        details.Text = message;
        bar.Style = ProgressBarStyle.Continuous;
        bar.MarqueeAnimationSpeed = 0;
        bar.Value = 100;
        cancel.Enabled = false;
        StateChanged?.Invoke();
        if (showResult && !Visible) ShowProgress();
        else if (!Visible)
        {
            HasProgress = false;
            StateChanged?.Invoke();
            return;
        }
        closeTimer.Stop();
        closeTimer.Start();
        StateChanged?.Invoke();
    }

    public void ShowProgress()
    {
        if (!Visible)
        {
            PositionNearTray();
            Show();
        }
        Activate();
    }

    public void Shutdown()
    {
        closing = true;
        Close();
    }

    private void PositionNearTray()
    {
        var area = Screen.PrimaryScreen?.WorkingArea ?? Screen.GetWorkingArea(Cursor.Position);
        Location = new Point(Math.Max(area.Left, area.Right - Width - 12), Math.Max(area.Top, area.Bottom - Height - 12));
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) closeTimer.Dispose();
        base.Dispose(disposing);
    }
}
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

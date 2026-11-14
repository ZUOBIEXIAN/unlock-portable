Unlock Portable 桌面版

managed\  .NET 10 版，约 49 MiB
  构建：进入 managed，运行 .\build.ps1
  EXE：managed\release\UnlockPortable.exe

native\  原生 Win32 版，无 .NET 依赖，约 316 KiB
  构建：进入 native，运行 .\build.ps1
  EXE：native\release\UnlockPortable-Native.exe

两版启动时打开面板。设置按钮可选择点 X 时隐藏到托盘或退出；首次关闭会询问。托盘“退出”始终直接退出。设置保存在 %APPDATA%\UnlockPortable。

文件结果显示在面板中。面板任务使用面板进度条；托盘任务显示右下角进度窗，完成 8 秒后关闭。

自测：<EXE> --self-test <加密文件> <对应明文>

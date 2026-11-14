Unlock Portable Native

Native 版

构建：运行 .\build.ps1
发布：release\UnlockPortable-Native.exe
自测：release\UnlockPortable-Native.exe --self-test <加密文件> <对应明文>

启动打开面板。设置按钮配置点 X 时隐藏到托盘或退出；首次关闭会询问。托盘“退出”始终直接退出。
面板任务使用面板进度条；托盘任务显示右下角进度窗，完成 8 秒后关闭。
图标嵌入 EXE，用于托盘和窗口标题栏。设置保存在 %APPDATA%\UnlockPortable。

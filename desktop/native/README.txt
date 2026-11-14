Unlock Portable Native

This is a separate native Win32 build. The managed build is in ..\managed\release\UnlockPortable.exe.

Build with PowerShell:
  .\build.ps1

The resulting executable is written to:
  .\release\UnlockPortable-Native.exe

It uses Windows system APIs and BCrypt SHA-256, with the MinGW runtime statically linked.
The self-test accepts the same encrypted input and expected plaintext paths as the managed build:
  UnlockPortable-Native.exe --self-test <encrypted-file> <expected-plaintext>

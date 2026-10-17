@echo off
rem ===========================================================================
rem  PhiraiAd -> HarmonyOS arm64 交叉编译脚本（产出 libphira.so）
rem
rem  用法（任意位置执行均可）：
rem     scripts\build-libphira.cmd [phiraiad 路径]
rem
rem  默认目录布局（均可用参数 / 环境变量覆盖）：
rem     <workspace>\phiraiad      phiraiad 仓库        （参数1 或 PHIRAAD_HOME）
rem     <workspace>\tools         llvm-mingw 等宿主工具（TOOLS_HOME）
rem     C:\Program Files\Huawei\DevEco Studio\sdk  OHOS NDK（DEVECO_SDK_HOME）
rem
rem  产物：
rem     <phiraiad>\target\aarch64-unknown-linux-ohos\release\libphira.so
rem    并自动拷贝到本仓库 entry\libs\arm64-v8a\
rem ===========================================================================
setlocal enabledelayedexpansion

rem ---- 路径解析 ----
set "SCRIPT_DIR=%~dp0"
set "REPO_DIR=%SCRIPT_DIR%.."
set "PHIRAAD_HOME=%~1"
if "%PHIRAAD_HOME%"=="" set "PHIRAAD_HOME=%REPO_DIR%\..\phiraiad"
if "%TOOLS_HOME%"=="" set "TOOLS_HOME=%REPO_DIR%\..\tools"
if "%DEVECO_SDK_HOME%"=="" set "DEVECO_SDK_HOME=C:\Program Files\Huawei\DevEco Studio\sdk"

if not exist "%PHIRAAD_HOME%\phira\Cargo.toml" (
  echo [FAILED] 找不到 phiraiad: %PHIRAAD_HOME%
  echo           用法: build-libphira.cmd ^<phiraiad 路径^>
  exit /b 1
)
if not exist "%DEVECO_SDK_HOME%\default\openharmony" (
  echo [FAILED] 找不到 OHOS NDK: %DEVECO_SDK_HOME%
  echo           请设置 DEVECO_SDK_HOME 指向 DevEco Studio 的 sdk 目录
  exit /b 1
)

rem ---- 一律转 8.3 短路径，避免空格被 clang 拆散 ----
for %%I in ("%DEVECO_SDK_HOME%\default\openharmony") do set "OH=%%~sI"
for %%I in ("%PHIRAAD_HOME%") do set "PHIRAAD=%%~sI"

rem ---- 宿主侧链接器：本机无 MSVC / Windows SDK 时，用 GNU 宿主工具链 ----
rem     + LLVM-MinGW 完成宿主侧链接，OHOS NDK clang 完成目标侧链接 ----
set "LLVM_MINGW=%TOOLS_HOME%\llvm-mingw-20261006-ucrt-x86_64\bin"
set "SHIMS=%TOOLS_HOME%\shims"
if exist "%SHIMS%\ninja.exe" set "PATH=%SHIMS%;%LLVM_MINGW%;%PATH%"

set "HMS=%OH%/hms/native/sysroot/usr/lib/aarch64-linux-ohos"
set "AVC_LIBS=%TOOLS_HOME%\prpr-avc-libs"

set "OHOS_NDK_HOME=%OH%"
set "CMAKE=%OH%/native/build-tools/cmake/bin/cmake.exe"
set "CMAKE_TOOLCHAIN_FILE_aarch64-unknown-linux-ohos=%OH%/native/build/cmake/ohos.toolchain.cmake"
set "CMAKE_GENERATOR=Ninja"
set "CMAKE_MAKE_PROGRAM=%OH%/native/build-tools/cmake/bin/ninja.exe"

rem ---- 目标侧 C/C++ 编译与归档工具 ----
set "CC_aarch64_unknown_linux_ohos=%OH%/native/llvm/bin/clang.exe"
set "CXX_aarch64_unknown_linux_ohos=%OH%/native/llvm/bin/clang++.exe"
set "AR_aarch64_unknown_linux_ohos=%OH%/native/llvm/bin/llvm-ar.exe"
set "CFLAGS_aarch64_unknown_linux_ohos=--target=aarch64-linux-ohos --sysroot=%OH%/native/sysroot -D__MUSL__"
set "CXXFLAGS_aarch64_unknown_linux_ohos=--target=aarch64-linux-ohos --sysroot=%OH%/native/sysroot -D__MUSL__"

rem prpr-avc 构建期需要预编译 FFmpeg；Rust 的 ureq+rustls 不信任本机代理证书，
rem 故可手动下载后指过去，绕开联网下载。留空则走 build.rs 自动下载。
if exist "%AVC_LIBS%" set "PRPR_AVC_LIBS=%AVC_LIBS%"

set "TC=nightly-2026-09-14-x86_64-pc-windows-gnu"

echo [1/3] 交叉编译 libphira.so (aarch64-unknown-linux-ohos, release)...
cd /d "%PHIRAAD%\phira"
cargo +%TC% build --target aarch64-unknown-linux-ohos --release
if errorlevel 1 (
  echo [FAILED] 编译失败，详见上方输出
  exit /b 1
)

echo [2/3] 拷贝到 phira-ohos/entry/libs/arm64-v8a/ ...
set "OUT=%REPO_DIR%\entry\libs\arm64-v8a"
if not exist "%OUT%" mkdir "%OUT%"
copy /y "%PHIRAAD%\target\aarch64-unknown-linux-ohos\release\libphira.so" "%OUT%\libphira.so" >nul
if errorlevel 1 (
  echo [FAILED] 拷贝失败
  exit /b 1
)

echo [3/3] 完成。接下来用 DevEco Studio 打开 phira-ohos 并配置自动签名后运行。
dir "%OUT%\libphira.so"

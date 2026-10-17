# Phira OHOS

[TeamFlos/phira-ohos](https://github.com/TeamFlos/phira-ohos) 的移植分支：HarmonyOS 上的 Phira 音游客户端（ArkTS 外壳 + phiraiad Rust 引擎，产物为未签名 debug HAP）。

## What's changed

- **在线谱面下载**：导入入口新增"本地文件 / 在线下载"二选一对话框（`ChartDownloadPanel`、`ChartDownloader`、`ChartSource`）。曲目清单来自 Phigros 官谱资源站 `7aGiven/Phigros_Resource`（info / chart / music / illustration 四个分支），默认按 jsdelivr → gcore → ghfast → ghproxy → raw 的顺序自动回退，也可在面板里钉死某一个源（ghproxy 等，选择持久化，指定源优先、失败仍回退）；谱面 JSON、音频 ogg、曲绘 png 三路并行下载，下载完成的资源由 `PezPacker` 打包为 `.pez`，走与本地导入完全相同的 `setChosenFile` + `markAutoImport` 通道进入原生侧。
- **修复下载导入失败（os error 2）**：`@ohos.zlib` 的 `compressFiles` 会在 `.pez` 真正落盘之前就 resolve Promise，原生侧紧接着 `File::open` 报 ENOENT（已用 hilog 记录时间戳证实：Promise resolve 与原生打开之间只差约 15ms，文件尚未写完）。改为纯 ArkTS 手写的 ZIP 打包器 `PezPacker.ets`（STORE 存储 + CRC-32 校验，同步写盘并自校验字节数），摆脱 zlib 的 Promise 时序问题。
- **小窗 / 分屏适配**：新增 `WindowModeManager`，按当前窗口形态切换沉浸式与窗口化，窗口尺寸变化时持续跟随（悬浮窗、分屏来回切换均自动生效）；`module.json5` 声明 `supportWindowMode: ['fullscreen', 'split', 'floating']` 与 `preferMultiWindowOrientation: 'landscape'`。
- **游戏模式**：新增 `GameModeManager`，订阅原生 `interceptor_state` 信号（等价于"正在游玩"），游玩期间保持屏幕常亮等行为。
- **修复 build-profile 的 SDK 版本写反**：原文件 `targetSdkVersion` / `compatibleSdkVersion` 写反（21 > 20），hvigor 会直接拒绝构建，已交换并加注释。
- **修复噪域（Noise）谱面无法播放**：带噪域的谱面一进游戏就报 `Shader compile error: 'recorderTint' : undeclared identifier`。根因在 `prpr/src/noise_area/render.rs`：它用字面量 `"void main()\n{"` 往 Unity 反编译出的着色器里注入 `recorderTint` 声明，而 Windows 检出（`core.autocrlf`）把 `.glsl` 变成了 CRLF，`replacen` 静默失配——声明没插进去，使用处却照旧引用，于是编译失败（Linux CI 是 LF，所以这个 bug 只在本地 Windows 构建里出现）。现在 `canvas_shader` / `recorder_shader` / `active_variant` 入口先把行尾归一化成 LF 再做字符串注入，顺带修掉低画质变体里同因的 `find().unwrap()` panic；`.gitattributes` 把 `shaders/**` 钉成 `eol=lf`，并补了一条 CRLF 回归测试。引擎侧改动放在 `233laoliu/PhiraiAd`（上游 `Adai-add/PhiraiAd` @ `a60b49a` 的 fork，只多这一个提交）。
- **CI 构建**：新增 `.github/workflows/build.yml`，在 GitHub Actions 上自动完成 Rust 交叉编译 `libphira.so`（aarch64-unknown-linux-ohos）+ HAP 打包全流程，产物直接在 workflow run 的 Artifacts 中下载。

## Thanks

- [TeamFlos/phira](https://github.com/TeamFlos/phira) — 上游 Phira 音游本体
- [TeamFlos/phira-ohos](https://github.com/TeamFlos/phira-ohos) — 本分支所基于的 OHOS 外壳
- [Adai-add/PhiraiAd](https://github.com/Adai-add/PhiraiAd) — phiraiad Rust 引擎分支
- [TeamFlos/prpr-avc-ffmpeg](https://github.com/TeamFlos/prpr-avc-ffmpeg) — prpr-avc 使用的预编译 FFmpeg 静态库（构建时自动下载）
- [7aGiven/Phigros_Resource](https://github.com/7aGiven/Phigros_Resource) — 在线下载的曲目数据源
- [harmonyos-dev/hos-sdk](https://github.com/harmonyos-dev/hos-sdk) — CI 环境使用的 HarmonyOS SDK 镜像

## How to build

分两步：先交叉编译 Rust 引擎得到 `libphira.so`，再用 hvigor 打 HAP。

### 1. 构建 libphira.so

```bash
# 需要 Rust nightly-2026-09-14 与 OHOS NDK（DevEco Studio 自带：
# <DevEco>/sdk/default/openharmony/native）
# 用 fork 而不是上游：它多一个"着色器行尾归一化"提交，修掉 Windows 下
# 噪域着色器编译失败（见 What's changed）。
git clone https://github.com/233laoliu/PhiraiAd.git phiraiad
cd phiraiad/phira
cargo +nightly-2026-09-14 build --target aarch64-unknown-linux-ohos --release
cp target/aarch64-unknown-linux-ohos/release/libphira.so ../../phira-ohos/entry/libs/arm64-v8a/
```

FFmpeg 静态库由 prpr-avc 的 build.rs 自动从 TeamFlos/prpr-avc-ffmpeg 的 releases 下载，无需手动准备。Windows 下可直接用仓库内的 `scripts/build-libphira.cmd`，它会自动配好 NDK clang、cmake toolchain 与短路径处理。

### 2. 构建 HAP

```bash
cd phira-ohos
cp build-profile-nosigncfg.json5 build-profile.json5   # 仓库内为无签名模板
hvigorw assembleHap -p product=default -p buildMode=debug --no-daemon
```

Linux/macOS 用 `./hvigorw`，Windows 用 `hvigorw.bat`；需要设置 `DEVECO_SDK_HOME` 指向 DevEco Studio 的 `sdk` 目录。产物位于 `entry/build/default/outputs/default/`，是未签名 debug HAP，可用 `hdc install` 直接装机调试。

### 3. 或者让 CI 代劳

push 代码即触发 GitHub Actions 自动跑完上述全流程，HAP 在对应 workflow run 的 Artifacts 里下载。

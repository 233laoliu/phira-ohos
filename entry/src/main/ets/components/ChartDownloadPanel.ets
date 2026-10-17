import { hilog } from "@kit.PerformanceAnalysisKit";
import { BusinessError } from "@kit.BasicServicesKit";
import fs from "@ohos.file.fs";
import { ChartDownloader, DownloadProgress } from "../utils/ChartDownloader";
import { ChartEntry, ChartSource, DIFFICULTY_NAMES, MIRRORS, MIRROR_LABELS } from "../utils/ChartSource";

const DOMAIN = 0x0000;
const TAG = "PhiraChartPanel";
const MAX_VISIBLE: number = 120;

interface MirrorOption {
  key: string;
  label: string;
}

/**
 * 谱面下载面板。
 *
 * 入口挂在原生发起的"导入文件"请求上：游戏点导入时，ArkTS 侧给出
 * 「本地文件 / 在线下载」两种选择，选在线下载就展开这个面板，
 * 下载完成后走和本地导入完全相同的通道（setChosenFile + markAutoImport）。
 */
@Component
export struct ChartDownloadPanel {
  @State entries: ChartEntry[] = [];
  @State loading: boolean = true;
  @State loadError: string = "";
  @State keyword: string = "";
  @State mirror: string = "";
  @State stage: string = "";
  @State busy: boolean = false;
  @State directUrl: string = "";
  workDir: string = "";
  onImported: (path: string) => void = (): void => {};
  onClose: () => void = (): void => {};

  aboutToAppear(): void {
    this.loadMirrorPref();
    this.loadCatalog();
  }

  /**
   * 读取上次钉死的下载源（workDir/mirror.cfg），避免每次进面板都要重选。
   * 文件不存在或内容非法时保持"自动"。
   */
  private loadMirrorPref(): void {
    try {
      const cfg = `${this.workDir}/mirror.cfg`;
      if (!fs.accessSync(cfg)) {
        return;
      }
      const file = fs.openSync(cfg, fs.OpenMode.READ_ONLY);
      try {
        const buffer = new ArrayBuffer(32);
        const read = fs.readSync(file.fd, buffer);
        const view = new Uint8Array(buffer);
        let name = "";
        for (let i = 0; i < read; i++) {
          name += String.fromCharCode(view[i]);
        }
        if (MIRRORS.includes(name)) {
          this.mirror = name;
          ChartSource.setPreferredMirror(name);
          hilog.info(DOMAIN, TAG, "Preferred mirror restored: %{public}s", name);
        }
      } finally {
        fs.closeSync(file);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, "Failed to read mirror pref. Cause: %{public}s", JSON.stringify(err));
    }
  }

  /**
   * 钉死下载源：写进 mirror.cfg 持久化，之后目录与谱面下载都优先走它。
   * "自动"（空串）时写空文件，读取时自然回落到默认顺序。
   */
  private selectMirror(key: string): void {
    this.mirror = key;
    ChartSource.setPreferredMirror(key);
    try {
      const cfg = `${this.workDir}/mirror.cfg`;
      if (fs.accessSync(cfg)) {
        fs.unlinkSync(cfg);
      }
      const file = fs.openSync(cfg, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, key);
      } finally {
        fs.closeSync(file);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, "Failed to persist mirror pref. Cause: %{public}s", JSON.stringify(err));
    }
  }

  private mirrorOptions(): MirrorOption[] {
    const options: MirrorOption[] = [{ key: "", label: "自动" }];
    for (const mirror of MIRRORS) {
      options.push({ key: mirror, label: MIRROR_LABELS.get(mirror) ?? mirror });
    }
    return options;
  }

  private async loadCatalog(): Promise<void> {
    this.loading = true;
    this.loadError = "";
    try {
      const list = await ChartSource.loadCatalog();
      this.entries = list;
    } catch (err) {
      this.loadError = (err as BusinessError).message ?? JSON.stringify(err);
      hilog.error(DOMAIN, TAG, "Failed to load chart catalog. Cause: %{public}s", this.loadError);
    } finally {
      this.loading = false;
    }
  }

  private filtered(): ChartEntry[] {
    const kw = this.keyword.trim().toLowerCase();
    const result: ChartEntry[] = [];
    for (const entry of this.entries) {
      if (kw !== "") {
        const haystack = `${entry.name} ${entry.nameCn} ${entry.composer} ${entry.id}`.toLowerCase();
        if (!haystack.includes(kw)) {
          continue;
        }
      }
      result.push(entry);
      if (result.length >= MAX_VISIBLE) {
        break;
      }
    }
    return result;
  }

  private async startDownload(entry: ChartEntry, difficultyIndex: number): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.stage = "准备中";
    try {
      const path = await ChartDownloader.download(
        entry,
        difficultyIndex,
        this.workDir,
        (progress: DownloadProgress) => {
          this.stage = progress.stage;
        },
      );
      this.onImported(path);
    } catch (err) {
      const message = (err as BusinessError).message ?? JSON.stringify(err);
      hilog.error(DOMAIN, TAG, "Chart download failed. Cause: %{public}s", message);
      this.showToast(`下载失败：${message}`);
    } finally {
      this.busy = false;
      this.stage = "";
    }
  }

  private async startDirect(): Promise<void> {
    const url = this.directUrl.trim();
    if (url === "" || this.busy) {
      return;
    }
    this.busy = true;
    this.stage = "准备中";
    try {
      const name = url.substring(url.lastIndexOf("/") + 1).replace(".pez", "");
      const path = await ChartDownloader.downloadPez(url, this.workDir, name, (p: DownloadProgress) => {
        this.stage = p.stage;
      });
      this.onImported(path);
      this.directUrl = "";
    } catch (err) {
      const message = (err as BusinessError).message ?? JSON.stringify(err);
      this.showToast(`下载失败：${message}`);
    } finally {
      this.busy = false;
      this.stage = "";
    }
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
    } catch (err) {
      hilog.error(DOMAIN, TAG, "Failed to show toast. Cause: %{public}s", JSON.stringify(err));
    }
  }

  @Builder
  DifficultyChip(entry: ChartEntry, index: number) {
    Text(`${DIFFICULTY_NAMES[index]} ${entry.levels[index]}`)
      .fontSize(12)
      .fontColor("#FFFFFF")
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .borderRadius(10)
      .backgroundColor("#2A2F45")
      .onClick(() => {
        this.startDownload(entry, index);
      });
  }

  build() {
    Column() {
      Row() {
        Text("在线谱面").fontSize(20).fontWeight(FontWeight.Bold).fontColor("#FFFFFF").layoutWeight(1);
        Text("关闭")
          .fontSize(14)
          .fontColor("#8FA0C0")
          .padding({ left: 12, right: 8, top: 6, bottom: 6 })
          .onClick(() => {
            this.onClose();
          });
      }
      .width("100%")
      .padding({ left: 16, right: 8, top: 12, bottom: 8 })

      TextInput({ placeholder: "搜索曲名 / 作曲", text: this.keyword })
        .width("100%")
        .height(40)
        .fontSize(14)
        .backgroundColor("#1B1E2C")
        .placeholderColor("#6B7590")
        .fontColor("#FFFFFF")
        .borderRadius(10)
        .onChange((value: string) => {
          this.keyword = value;
        })

      // 下载源选择：钉死的源优先尝试，失败自动回退其余源；选择写入 mirror.cfg 持久化。
      Flex({ wrap: FlexWrap.Wrap }) {
        Text("下载源")
          .fontSize(11)
          .fontColor("#6B7590")
          .margin({ right: 8, top: 5 });
        ForEach(this.mirrorOptions(), (option: MirrorOption) => {
          Text(option.label)
            .fontSize(11)
            .fontColor(option.key === this.mirror ? "#0F1119" : "#8FA0C0")
            .backgroundColor(option.key === this.mirror ? "#0A59F7" : "#1B1E2C")
            .borderRadius(8)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .margin({ right: 6, top: 2 })
            .onClick(() => {
              this.selectMirror(option.key);
            })
        }, (option: MirrorOption) => option.key)
      }
      .width("100%")
      .margin({ top: 6 })

      Row() {
        TextInput({ placeholder: "或直接粘贴 .pez 下载链接", text: this.directUrl })
          .layoutWeight(1)
          .height(36)
          .fontSize(12)
          .backgroundColor("#1B1E2C")
          .placeholderColor("#6B7590")
          .fontColor("#FFFFFF")
          .borderRadius(8)
          .onChange((value: string) => {
            this.directUrl = value;
          })
        Text("下载")
          .fontSize(13)
          .fontColor("#0A59F7")
          .padding({ left: 12, right: 6 })
          .onClick(() => {
            this.startDirect();
          })
      }
      .width("100%")
      .margin({ top: 8 })

      if (this.loading) {
        Column() {
          LoadingProgress().width(36).height(36).color("#8FA0C0");
          Text("正在获取曲目列表…").fontSize(13).fontColor("#8FA0C0").margin({ top: 10 });
        }
        .layoutWeight(1)
        .width("100%")
        .justifyContent(FlexAlign.Center)
      } else if (this.loadError !== "") {
        Column() {
          Text(`曲目列表获取失败：${this.loadError}`)
            .fontSize(13)
            .fontColor("#E06C75")
            .textAlign(TextAlign.Center)
          Text("重试")
            .fontSize(13)
            .fontColor("#0A59F7")
            .margin({ top: 12 })
            .onClick(() => {
              this.loadCatalog();
            })
        }
        .layoutWeight(1)
        .width("100%")
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.filtered(), (entry: ChartEntry) => {
            ListItem() {
              Column() {
                Text(entry.nameCn !== "" ? `${entry.name}（${entry.nameCn}）` : entry.name)
                  .fontSize(15)
                  .fontColor("#FFFFFF")
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(entry.composer)
                  .fontSize(12)
                  .fontColor("#8FA0C0")
                  .maxLines(1)
                  .margin({ top: 2 })
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(entry.levels, (_level: string, index: number) => {
                    this.DifficultyChip(entry, index);
                  }, (_level: string, index: number) => `${entry.id}-${index}`);
                }
                .margin({ top: 8 })
              }
              .width("100%")
              .padding({ left: 4, right: 4, top: 10, bottom: 10 })
              .alignItems(HorizontalAlign.Start)
            }
          }, (entry: ChartEntry) => entry.id)
        }
        .layoutWeight(1)
        .width("100%")
        .divider({ strokeWidth: 1, color: "#242838" })
        .margin({ top: 8 })
      }

      if (this.busy) {
        Row() {
          LoadingProgress().width(24).height(24).color("#8FA0C0");
          Text(this.stage).fontSize(13).fontColor("#8FA0C0").margin({ left: 10 });
        }
        .width("100%")
        .padding({ top: 10, bottom: 10 })
        .justifyContent(FlexAlign.Center)
      }
    }
    .width("100%")
    .height("100%")
    .padding({ left: 16, right: 16, bottom: 16 })
    .backgroundColor("#0F1119")
  }
}

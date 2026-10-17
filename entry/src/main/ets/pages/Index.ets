import { InputDialog } from "../components/InputDialog";
import { ChartDownloadPanel } from "../components/ChartDownloadPanel";
import {
  callFilePickerAndProcess,
  callFilePickerSaveFile,
  exportCrashLog,
  getSystemInfo,
  startBrowsableAbility,
} from "../utils/AbilityUtils";
import { XComponentHolder } from "../utils/XComponentHolder";
import { GameModeManager } from "../utils/GameModeManager";
import fs from "@ohos.file.fs";
import { common } from "@kit.AbilityKit";
import { InputBoxRequest, InputBoxResponse } from "libphira.so";
import { mediaquery } from "@kit.ArkUI";
import { BusinessError } from "@kit.BasicServicesKit";

interface ShowInputWindowCommand {
  action: "show_input_window";
  isPassword: boolean;
}
interface OpenUrlCommand {
  action: "openurl";
  payload: string;
}
interface ShowMessageCommand {
  action: "show_message";
  message: string;
  title: string;
}
interface ChooseFileCommand {
  action: "chooseFile";
  isPhoto: boolean;
}
interface RequestExportCommand {
  action: "request_export";
  filename: string;
}
interface InterceptorStateCommand {
  action: "interceptor_state";
  state: boolean;
}

type ArkTSCommand =
  | ShowInputWindowCommand
  | OpenUrlCommand
  | ShowMessageCommand
  | ChooseFileCommand
  | RequestExportCommand
  | InterceptorStateCommand;

interface XComponentAttrs {
  id: string;
  type: number;
  libraryname: string;
}

@Entry
@Component
struct Index {
  xComponentAttrs: XComponentAttrs = {
    id: "xcomponentId",
    type: XComponentType.SURFACE,
    libraryname: "phira",
  };
  @State interceptorState: boolean = false;
  @State showInput: boolean = false;
  @State context: common.UIAbilityContext =
    this.getUIContext().getHostContext()! as common.UIAbilityContext;
  @StorageLink("pendingImportFile") @Watch("onPendingImportChange") pendingImportFile: string = "";
  @StorageLink("pendingCrashLog") @Watch("onCrashLogChange") pendingCrashLog: string = "";
  @State currentRequest: InputBoxRequest | null = null;
  private inputDialogController: CustomDialogController | null = null;
  @State isPhone: boolean = true;
  @State showDownloadPanel: boolean = false;
  @State chartWorkDir: string = "";
  private listener = this.getUIContext().getMediaQuery().matchMediaSync("(max-width: 600vp)");

  aboutToAppear(): void {
    PersistentStorage.persistProp("isFirstLaunch", true);
    console.log("system info:" + getSystemInfo());
    this.listener.on("change", (mediaQueryResult: mediaquery.MediaQueryResult) => {
      this.isPhone = mediaQueryResult.matches;
    });
    this.prepareChartWorkDir();
    GameModeManager.prepare(this.context).catch((err: BusinessError) => {
      console.error("Failed to prepare game mode: " + JSON.stringify(err));
    });
    this.showCrashDialog();
  }

  /** 谱面下载暂存目录，缓存目录下建一个子目录便于清理。 */
  private prepareChartWorkDir(): void {
    try {
      const dir = `${this.context.cacheDir}/chart_download`;
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      this.chartWorkDir = dir;
    } catch (err) {
      console.error("Failed to prepare chart work dir: " + JSON.stringify(err));
    }
  }

  aboutToDisappear(): void {
    this.listener.off("change");
    XComponentHolder.clear();
  }

  onCrashLogChange(): void {
    this.showCrashDialog();
  }

  onPendingImportChange(): void {
    if (this.pendingImportFile) {
      this.processPendingImport();
    }
  }

  onBackPress(): boolean {
    if (this.showDownloadPanel) {
      this.showDownloadPanel = false;
      return true;
    }
    return this.interceptorState;
  }

  private showCrashDialog(): void {
    if (!this.pendingCrashLog) {
      return;
    }
    const prompt = this.getUIContext().getPromptAction();
    prompt
      .showDialog({
        title: $r("app.string.crash_dialog_title"),
        message: $r("app.string.crash_dialog_message"),
        buttons: [
          { text: $r("app.string.crash_dialog_button_export"), color: "#0A59F7", primary: true },
          { text: $r("app.string.crash_dialog_button_close"), color: "#666666" },
        ],
      })
      .then((result) => {
        const currentLog = this.pendingCrashLog;
        AppStorage.set("pendingCrashLog", "");
        if (result.index !== 0 || !currentLog) {
          return;
        }
        exportCrashLog(currentLog).then((ok) => {
          try {
            prompt.showToast({
              message: ok
                ? $r("app.string.crash_toast_export_success")
                : $r("app.string.crash_toast_export_failed"),
              duration: ok ? 1500 : 2000,
            });
          } catch (err) {
            console.error("Failed to show toast: " + JSON.stringify(err));
          }
        });
      })
      .catch((error: BusinessError) => {
        console.error("Failed to show crash dialog: " + JSON.stringify(error));
      });
  }

  showInputDialog(request: InputBoxRequest): void {
    this.currentRequest = request;
    const respond = (text?: string): void => {
      const response: InputBoxResponse = {
        callback: request.callback,
        text: text,
      };
      XComponentHolder.ifPresent((context: ESObject): void => {
        context.onInputboxResponse(response);
      });
      this.inputDialogController = null;
    };
    this.inputDialogController = new CustomDialogController({
      builder: InputDialog({
        title: request.title,
        prompt: request.prompt,
        defaultValue: request.defaultValue,
        mode: request.mode,
        okLabel: request.okLabel,
        cancelLabel: request.cancelLabel,
        onConfirm: (text: string) => respond(text),
        onCancel: () => respond(),
      }),
      autoCancel: false,
      alignment: DialogAlignment.Center,
      customStyle: true,
    });
    this.inputDialogController.open();
  }

  private handleNativeCommand(context: ESObject, arg: string): void {
    try {
      const command = JSON.parse(arg) as ArkTSCommand;
      if (!command || typeof command.action !== "string") {
        return;
      }
      switch (command.action) {
        case "interceptor_state":
          // 原生引擎只在 GameScene 的 enter / resume 置 true，pause 与退出置 false，
          // 因此这个信号等价于"正在游玩"，用来驱动游戏模式。
          this.interceptorState = command.state;
          GameModeManager.setGameplayActive(command.state);
          break;
        case "openurl":
          if (command.payload) {
            startBrowsableAbility(this.context, command.payload);
          }
          break;
        case "chooseFile":
          this.showImportSourceDialog(context, command.isPhoto);
          break;
        case "request_export":
          if (command.filename) {
            callFilePickerSaveFile(command.filename).then((result) => {
              if (result) {
                context.processExportFdOhos(result.fd);
              } else {
                console.log("request_export: user cancelled or error occurred");
              }
            });
          }
          break;
        default:
          break;
      }
    } catch (error) {
      console.error("Failed to parse argument as JSON. Raw argument: ", arg, "Error: ", error);
    }
  }

  private processPendingImport(): void {
    const pendingFile = AppStorage.get<string>("pendingImportFile");
    if (!pendingFile) {
      return;
    }
    XComponentHolder.ifPresent((context: ESObject): void => {
      console.info("Processing pending import file: " + pendingFile);
      context.setChosenFile(pendingFile);
      context.markAutoImport();
      AppStorage.set("pendingImportFile", "");
    });
  }

  /** 导入入口：本地文件与在线下载二选一。 */
  private showImportSourceDialog(context: ESObject, isPhoto: boolean): void {
    const prompt = this.getUIContext().getPromptAction();
    prompt
      .showDialog({
        title: "导入谱面",
        message: "选择导入方式",
        buttons: [
          { text: "本地文件", color: "#0A59F7", primary: true },
          { text: "在线下载", color: "#666666" },
          { text: "取消", color: "#999999" },
        ],
      })
      .then((result) => {
        if (result.index === 0) {
          callFilePickerAndProcess(context, this.context, isPhoto);
          return;
        }
        if (result.index === 1 && this.chartWorkDir !== "") {
          this.showDownloadPanel = true;
        }
      })
      .catch((error: BusinessError) => {
        console.error("Failed to show import source dialog: " + JSON.stringify(error));
      });
  }

  /** 下载完成后走和本地导入完全相同的通道。 */
  private importDownloadedChart(path: string): void {
    XComponentHolder.ifPresent((context: ESObject): void => {
      console.info("Importing downloaded chart: " + path);
      // 原生侧拿到路径后会直接 File::open，文件不存在只会弹一句"导入失败"，
      // 这里先挡一道，给个看得懂的提示。
      if (!fs.accessSync(path)) {
        console.error("Chart file missing before import: " + path);
        this.getUIContext().getPromptAction().showToast({
          message: "谱面文件缺失，无法导入",
          duration: 2500,
        });
        return;
      }
      context.setChosenFile(path);
      context.markAutoImport();
    });
    this.showDownloadPanel = false;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      XComponent(this.xComponentAttrs)
        .onLoad((xComponentContext) => {
          const context: ESObject = xComponentContext;
          XComponentHolder.set(context);
          context.registerInputboxCallback((request: InputBoxRequest) => {
            context.setInterceptorState(false);
            this.showInputDialog(request);
          });
          context.registerArktsCallback((arg: string) => this.handleNativeCommand(context, arg));
          this.processPendingImport();
        })
        .focusable(true)
        .defaultFocus(true)
        .constraintSize({ maxWidth: "100%", maxHeight: "100%" })

      if (this.showDownloadPanel) {
        ChartDownloadPanel({
          workDir: this.chartWorkDir,
          onImported: (path: string) => {
            this.importDownloadedChart(path);
          },
          onClose: () => {
            this.showDownloadPanel = false;
          },
        })
      }
    }.height("100%");
  }
}

import { bundleManager, common } from "@kit.AbilityKit";
import { BusinessError } from "@kit.BasicServicesKit";
import { gamePerformance } from "@kit.GameServiceKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { window } from "@kit.ArkUI";

const DOMAIN = 0x0000;
const TAG = "PhiraGameMode";

/**
 * Game Service Kit 预定义场景号：
 * 0 场景结束 / 1 游戏启动 / 4 主界面 / 7 对局中。
 */
const SCENE_SCENE_END: number = 0;
const SCENE_IN_GAME: number = 7;

/**
 * 游戏模式。
 *
 * 两部分内容：
 * 1. 把当前场景上报给系统（Game Service Kit 游戏场景感知）。系统拿到"对局中"这个
 *    信号后会按游戏负载做差异化的资源调度与温控策略，这正是鸿蒙侧"游戏模式"的入口。
 * 2. 窗口层面的对局保障：常亮、沉浸式布局。
 *
 * 对局状态由原生引擎通过 interceptor_state 上报：prpr 的 GameScene::enter / resume
 * 置 true，pause / 退出置 false，因此它是精确的"正在游玩"信号。
 */
export class GameModeManager {
  private static win: window.Window | undefined = undefined;
  private static ready: boolean = false;
  private static initializing: boolean = false;
  private static inGame: boolean = false;
  private static subscribed: boolean = false;

  static attachWindow(win: window.Window): void {
    GameModeManager.win = win;
    if (GameModeManager.inGame) {
      GameModeManager.ensureScreenOn();
    }
  }

  /**
   * 初始化游戏场景感知。init 需要联网鉴权，未签名调试包上大概率失败，
   * 失败不影响游戏本体，下次进入对局时会重试。
   */
  static async prepare(context: common.UIAbilityContext): Promise<void> {
    if (GameModeManager.ready || GameModeManager.initializing) {
      return;
    }
    GameModeManager.initializing = true;
    try {
      const bundleName = context.abilityInfo.bundleName;
      let appVersion = "0.0.0";
      try {
        const bundleInfo = bundleManager.getBundleInfoForSelfSync(
          bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION,
        );
        appVersion = bundleInfo.versionName;
      } catch (err) {
        hilog.warn(DOMAIN, TAG, "Failed to read app version. Cause: %{public}s", JSON.stringify(err));
      }
      const packageInfo: gamePerformance.GamePackageInfo = {
        messageType: 0,
        bundleName: bundleName,
        appVersion: appVersion,
        engineType: 200,
        gameType: 200,
        vulkanSupported: false,
      };
      await gamePerformance.init(packageInfo);
      GameModeManager.ready = true;
      hilog.info(DOMAIN, TAG, "Game performance service initialized");
    } catch (err) {
      hilog.warn(
        DOMAIN,
        TAG,
        "Game performance service unavailable. Cause: %{public}s",
        JSON.stringify(err),
      );
    } finally {
      GameModeManager.initializing = false;
    }
  }

  static setGameplayActive(active: boolean): void {
    if (active === GameModeManager.inGame) {
      return;
    }
    GameModeManager.inGame = active;
    if (active) {
      GameModeManager.enterGameplay();
    } else {
      GameModeManager.exitGameplay();
    }
  }

  static isGameplayActive(): boolean {
    return GameModeManager.inGame;
  }

  private static enterGameplay(): void {
    hilog.info(DOMAIN, TAG, "Game mode engaged");
    GameModeManager.ensureScreenOn();
    GameModeManager.subscribeDeviceState();
    if (!GameModeManager.ready) {
      // init 可能在启动时尚未就绪，进入对局时补一次。
      return;
    }
    const scene: gamePerformance.GameSceneInfo = {
      messageType: 2,
      sceneID: SCENE_IN_GAME,
      description: "gameplay",
      importanceLevel: 5,
      recommendedFps: 120,
      maxFps: 120,
      keyThread: "render",
      sceneFrequency: 1,
    };
    GameModeManager.report(scene);
  }

  private static exitGameplay(): void {
    hilog.info(DOMAIN, TAG, "Game mode released");
    if (!GameModeManager.ready) {
      return;
    }
    const scene: gamePerformance.GameSceneInfo = {
      messageType: 2,
      sceneID: SCENE_SCENE_END,
      description: "gameplay ended",
      importanceLevel: 1,
    };
    GameModeManager.report(scene);
  }

  /** 订阅设备发热 / GPU 状态，供后续扩展（如高温时降低特效）使用。 */
  private static subscribeDeviceState(): void {
    if (GameModeManager.subscribed || !GameModeManager.ready) {
      return;
    }
    GameModeManager.subscribed = true;
    try {
      gamePerformance.on(
        "deviceStateChanged",
        (info: gamePerformance.DeviceInfo) => {
          hilog.info(
            DOMAIN,
            TAG,
            "Device state changed, temperature level: %{public}d",
            info.tempLevel,
          );
          AppStorage.setOrCreate("deviceTempLevel", info.tempLevel);
        },
        [gamePerformance.DeviceInfoType.THERMAL, gamePerformance.DeviceInfoType.GPU],
      );
    } catch (err) {
      GameModeManager.subscribed = false;
      hilog.warn(
        DOMAIN,
        TAG,
        "Failed to subscribe device state. Cause: %{public}s",
        JSON.stringify(err),
      );
    }
  }

  private static ensureScreenOn(): void {
    const win = GameModeManager.win;
    if (win === undefined) {
      return;
    }
    win.setWindowKeepScreenOn(true).catch((err: BusinessError) => {
      hilog.error(
        DOMAIN,
        TAG,
        "Failed to keep screen on. Cause: %{public}s",
        JSON.stringify(err),
      );
    });
  }

  private static report(scene: gamePerformance.GameSceneInfo): void {
    gamePerformance
      .updateGameInfo(scene)
      .catch((err: BusinessError) => {
        hilog.warn(
          DOMAIN,
          TAG,
          "Failed to report game scene. Cause: %{public}s",
          JSON.stringify(err),
        );
      });
  }
}

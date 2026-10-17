import { window } from "@kit.ArkUI";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { BusinessError } from "@kit.BasicServicesKit";

const DOMAIN = 0x0000;
const TAG = "PhiraWindowMode";

/**
 * 小窗模式 / 智慧多窗适配。
 *
 * Phira 主体是一块全屏 XComponent，ArkTS 壳层默认走沉浸式（状态栏 + 导航栏隐藏、
 * 布局延伸到屏幕边缘）。进入悬浮窗或分屏后，窗口不再铺满屏幕，继续维持沉浸式会把
 * 内容顶到圆角和系统栏下面，因此需要在窗口尺寸变化时来回切换这两种形态。
 *
 * 应用是否允许进入悬浮窗由 module.json5 的 supportWindowMode 决定，
 * preferMultiWindowOrientation 决定悬浮窗是横屏还是竖屏（横屏游戏配 landscape）。
 */
export class WindowModeManager {
  private static win: window.Window | undefined = undefined;
  private static immersiveApplied: boolean | undefined = undefined;

  static bind(win: window.Window): void {
    WindowModeManager.win = win;
    try {
      win.on("windowSizeChange", () => {
        WindowModeManager.apply();
      });
    } catch (err) {
      hilog.error(
        DOMAIN,
        TAG,
        "Failed to watch window size change. Cause: %{public}s",
        JSON.stringify(err),
      );
    }
    // 启动时直接进入沉浸式，与改造前的行为保持一致。
    // 不能依赖 isFullScreen 判断：onWindowStageCreate 阶段窗口尚未完成布局，
    // 该属性会返回 false（实测 MatePad Air 上就是这样），据此切到窗口化会
    // 把布局顶变形，XComponent 拿不到正常的绘制区域。
    WindowModeManager.immersiveApplied = true;
    WindowModeManager.applyInternal(win, true);
  }

  static unbind(win: window.Window): void {
    try {
      win.off("windowSizeChange");
    } catch (err) {
      hilog.error(
        DOMAIN,
        TAG,
        "Failed to unwatch window size change. Cause: %{public}s",
        JSON.stringify(err),
      );
    }
    WindowModeManager.win = undefined;
    WindowModeManager.immersiveApplied = undefined;
  }

  /** 当前是否处于悬浮窗 / 分屏这类非全屏形态。 */
  static isWindowed(): boolean {
    const win = WindowModeManager.win;
    if (win === undefined) {
      return false;
    }
    try {
      return !win.getWindowProperties().isFullScreen;
    } catch (err) {
      return false;
    }
  }

  static apply(): void {
    const win = WindowModeManager.win;
    if (win === undefined) {
      return;
    }
    let immersive = true;
    try {
      immersive = win.getWindowProperties().isFullScreen;
    } catch (err) {
      hilog.error(
        DOMAIN,
        TAG,
        "Failed to read window properties. Cause: %{public}s",
        JSON.stringify(err),
      );
      return;
    }
    if (WindowModeManager.immersiveApplied === immersive) {
      return;
    }
    WindowModeManager.immersiveApplied = immersive;
    WindowModeManager.applyInternal(win, immersive);
  }

  private static applyInternal(win: window.Window, immersive: boolean): void {
    hilog.info(DOMAIN, TAG, "Applying window mode, immersive: %{public}s", String(immersive));
    // 悬浮窗 / 分屏下系统栏归属于屏幕而非当前窗口，失败是正常的，吞掉即可。
    const bars: Array<"status" | "navigation"> = immersive ? [] : ["status", "navigation"];
    const tasks: Array<Promise<void>> = [
      win.setWindowLayoutFullScreen(immersive).then(
        () => {},
        (err: BusinessError) => {
          hilog.error(
            DOMAIN,
            TAG,
            "Failed to set layout full screen. Cause: %{public}s",
            JSON.stringify(err),
          );
        },
      ),
      win.setWindowSystemBarEnable(bars).then(
        () => {},
        (err: BusinessError) => {
          hilog.info(
            DOMAIN,
            TAG,
            "System bar toggle ignored in current window mode. Cause: %{public}s",
            JSON.stringify(err),
          );
        },
      ),
    ];
    try {
      // setWindowDecorVisible 是同步接口，非全屏时显示标题栏便于拖拽悬浮窗。
      win.setWindowDecorVisible(!immersive);
    } catch (err) {
      hilog.info(
        DOMAIN,
        TAG,
        "Window decor toggle ignored in current window mode. Cause: %{public}s",
        JSON.stringify(err),
      );
    }
    Promise.all(tasks).catch(() => {
      // 各任务内部已处理错误，这里仅避免未处理的 Promise 拒绝。
    });
  }
}

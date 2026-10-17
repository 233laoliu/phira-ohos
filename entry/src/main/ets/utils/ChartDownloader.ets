import { BusinessError } from "@kit.BasicServicesKit";
import fs from "@ohos.file.fs";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { ChartEntry, ChartSource, DIFFICULTY_NAMES, HttpFile, MIRRORS } from "./ChartSource";
import { PezPacker } from "./PezPacker";

const DOMAIN = 0x0000;
const TAG = "PhiraChartDownloader";

const BRANCH_MUSIC: string = "music";
const BRANCH_ILLUST: string = "illustration";

export interface DownloadProgress {
  stage: string;
  done: boolean;
  error?: string;
}

/**
 * 谱面下载与打包。
 *
 * 下载站（swordalt/phigros-chart-downloader）做的事情是把官谱资源打成一个 Phira 能
 * 直接导入的 .pez。这里在 ArkTS 侧复刻同一条链路：
 *
 *   谱面 json（PGR 官谱格式，prpr 原生支持解析）+ 音频 + 曲绘 + info.yml  ->  zip  ->  .pez
 *
 * .pez 本质就是 zip，Phira 导入时解压到谱面目录并读取 info.yml；
 * 音频与曲绘拿不到时仍然会生成谱面，只是没有音乐和背景。
 */
export class ChartDownloader {
  /**
   * 下载指定曲目的指定难度，返回可供 Phira 导入的 .pez 路径。
   */
  static async download(
    entry: ChartEntry,
    difficultyIndex: number,
    workDir: string,
    onProgress: (progress: DownloadProgress) => void,
  ): Promise<string> {
    const diff = DIFFICULTY_NAMES[difficultyIndex];
    const staging = `${workDir}/${ChartDownloader.sanitize(entry.id)}-${diff}`;
    ChartDownloader.removeDir(staging);
    fs.mkdirSync(staging, true);

    onProgress({ stage: `下载谱面 ${diff}`, done: false });
    const chartText = await ChartDownloader.fetchText(
      ChartSource.chartPath(entry, difficultyIndex),
      "chart",
    );
    const chartPath = `${staging}/chart.json`;
    ChartDownloader.writeText(chartPath, chartText);

    let musicPath = "";
    try {
      onProgress({ stage: "下载音乐", done: false });
      const bytes = await ChartDownloader.fetchBytes(ChartSource.musicPath(entry), BRANCH_MUSIC);
      musicPath = `${staging}/music.ogg`;
      ChartDownloader.writeBytes(musicPath, bytes);
    } catch (err) {
      hilog.warn(
        DOMAIN,
        TAG,
        "Music download failed for %{public}s. Cause: %{public}s",
        entry.id,
        JSON.stringify(err),
      );
    }

    let illustrationPath = "";
    try {
      onProgress({ stage: "下载曲绘", done: false });
      const bytes = await ChartDownloader.fetchBytes(
        ChartSource.illustrationPath(entry),
        BRANCH_ILLUST,
      );
      illustrationPath = `${staging}/illustration.png`;
      ChartDownloader.writeBytes(illustrationPath, bytes);
    } catch (err) {
      hilog.warn(
        DOMAIN,
        TAG,
        "Illustration download failed for %{public}s. Cause: %{public}s",
        entry.id,
        JSON.stringify(err),
      );
    }

    onProgress({ stage: "写入谱面信息", done: false });
    const infoPath = `${staging}/info.yml`;
    ChartDownloader.writeText(
      infoPath,
      ChartDownloader.buildInfo(entry, difficultyIndex, musicPath !== "", illustrationPath !== ""),
    );

    onProgress({ stage: "打包 .pez", done: false });
    const inputs: string[] = [chartPath, infoPath];
    if (musicPath !== "") {
      inputs.push(musicPath);
    }
    if (illustrationPath !== "") {
      inputs.push(illustrationPath);
    }
    const pezPath = `${workDir}/${ChartDownloader.sanitize(entry.id)}-${diff}.pez`;
    if (fs.accessSync(pezPath)) {
      fs.unlinkSync(pezPath);
    }
    // 不用 zlib.compressFiles：它的 Promise 会早于文件落盘 resolve，原生侧紧跟着
    // open 会 ENOENT（导入失败: No such file or directory）。自己写 zip 同步落盘。
    PezPacker.pack(inputs, pezPath);

    onProgress({ stage: "下载完成", done: true });
    return pezPath;
  }

  /**
   * 直接下载一个现成的 .pez（例如修正版官谱 swordalt/phigros-patched-charts）。
   */
  static async downloadPez(
    url: string,
    workDir: string,
    fileName: string,
    onProgress: (progress: DownloadProgress) => void,
  ): Promise<string> {
    onProgress({ stage: "下载谱面包", done: false });
    const bytes = await HttpFile.get(url, true) as ArrayBuffer;
    const pezPath = `${workDir}/${ChartDownloader.sanitize(fileName)}.pez`;
    if (fs.accessSync(pezPath)) {
      fs.unlinkSync(pezPath);
    }
    ChartDownloader.writeBytes(pezPath, bytes);
    onProgress({ stage: "下载完成", done: true });
    return pezPath;
  }

  static buildInfo(entry: ChartEntry, difficultyIndex: number, hasMusic: boolean, hasIllu: boolean): string {
    const level = entry.levels[difficultyIndex] ?? "0";
    const diff = DIFFICULTY_NAMES[difficultyIndex];
    const charter = entry.charters[difficultyIndex] ?? "";
    const lines: string[] = [
      `name: ${ChartDownloader.quote(entry.name)}`,
      `difficulty: ${level}`,
      `level: ${ChartDownloader.quote(`${diff} Lv.${level}`)}`,
      `charter: ${ChartDownloader.quote(charter === "" ? "Phigros 官方" : charter)}`,
      `composer: ${ChartDownloader.quote(entry.composer)}`,
      `illustrator: ${ChartDownloader.quote(entry.illustrator === "" ? "Phigros 官方" : entry.illustrator)}`,
      `chart: chart.json`,
      `format: pgr`,
      `music: ${hasMusic ? "music.ogg" : "song.mp3"}`,
      `illustration: ${hasIllu ? "illustration.png" : "background.png"}`,
    ];
    return lines.join("\n") + "\n";
  }

  private static async fetchText(path: string, branch: string): Promise<string> {
    return await ChartSource.fetchTextAnyMirror(branch, path);
  }

  private static async fetchBytes(path: string, branch: string): Promise<ArrayBuffer> {
    let lastError = "";
    for (const mirror of MIRRORS) {
      const url = ChartSource.url(mirror, branch, path);
      try {
        return await HttpFile.get(url, true) as ArrayBuffer;
      } catch (err) {
        lastError = (err as BusinessError).message ?? JSON.stringify(err);
      }
    }
    throw new Error(lastError);
  }

  private static writeText(path: string, text: string): void {
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
  }

  private static writeBytes(path: string, bytes: ArrayBuffer): void {
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, bytes);
    } finally {
      fs.closeSync(file);
    }
  }

  private static removeDir(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.rmdirSync(path);
      }
    } catch (err) {
      hilog.info(DOMAIN, TAG, "Skip removing dir %{public}s", path);
    }
  }

  private static sanitize(name: string): string {
    // 曲名里可能有日韩字符与符号，文件名只保留安全字符。
    let out = "";
    for (let i = 0; i < name.length; i++) {
      const ch = name[i];
      out += /[A-Za-z0-9._-]/.test(ch) ? ch : "_";
    }
    return out.length === 0 ? "chart" : out;
  }

  private static quote(value: string): string {
    return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
  }
}

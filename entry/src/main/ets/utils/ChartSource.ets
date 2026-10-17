import { http } from "@kit.NetworkKit";
import { BusinessError } from "@kit.BasicServicesKit";
import { hilog } from "@kit.PerformanceAnalysisKit";

const DOMAIN = 0x0000;
const TAG = "PhiraChartSource";

/**
 * Phigros 官谱资源站的数据布局（与 swordalt/phigros-chart-downloader 使用的源一致）：
 *
 *   仓库：7aGiven/Phigros_Resource
 *   分支：info（曲目元数据）/ chart（谱面）/ music（音频）/ illustration（曲绘）
 *   info 分支的 info.tsv       -> 曲目名、作曲、难度作者、画师
 *   info 分支的 difficulty.tsv -> 各难度定数
 *   chart 分支的 <id>.0/       -> EZ.json / HD.json / IN.json / AT.json
 *
 * 曲目 id 形如 "Glaciaxion.SunsetRay"，即 "曲名.作曲"。
 */
const REPO_OWNER: string = "7aGiven";
const REPO_NAME: string = "Phigros_Resource";
const BRANCH_INFO: string = "info";
const BRANCH_CHART: string = "chart";
const BRANCH_MUSIC: string = "music";
const BRANCH_ILLUSTRATION: string = "illustration";

export const DIFFICULTY_NAMES: string[] = ["EZ", "HD", "IN", "AT"];

/** 镜像源，越靠前优先级越高，失败时依次回退。 */
export const MIRRORS: string[] = ["raw", "jsdelivr", "jsdelivr-gcore", "ghfast", "ghproxy"];

export interface ChartEntry {
  id: string;
  /** 曲名 */
  name: string;
  /** 中文曲名（可能为空） */
  nameCn: string;
  composer: string;
  /** 各难度定数，顺序 EZ / HD / IN / AT */
  levels: string[];
  /** 谱师，顺序 EZ / HD / IN */
  charters: string[];
  illustrator: string;
}

export class ChartSource {
  /** 拼接某个镜像下指定分支文件的下载地址。 */
  static url(mirror: string, branch: string, path: string): string {
    const base = `${REPO_OWNER}/${REPO_NAME}`;
    switch (mirror) {
      case "jsdelivr":
        return `https://cdn.jsdelivr.net/gh/${base}@${branch}/${path}`;
      case "jsdelivr-gcore":
        return `https://gcore.jsdelivr.net/gh/${base}@${branch}/${path}`;
      case "ghfast":
        return `https://ghfast.top/https://raw.githubusercontent.com/${base}/${branch}/${path}`;
      case "ghproxy":
        return `https://ghproxy.net/https://raw.githubusercontent.com/${base}/${branch}/${path}`;
      default:
        return `https://raw.githubusercontent.com/${base}/${branch}/${path}`;
    }
  }

  static chartPath(entry: ChartEntry, difficultyIndex: number): string {
    return `${entry.id}.0/${DIFFICULTY_NAMES[difficultyIndex]}.json`;
  }

  static musicPath(entry: ChartEntry): string {
    return `${entry.id}.ogg`;
  }

  static illustrationPath(entry: ChartEntry): string {
    return `${entry.id}.png`;
  }

  static chartUrl(entry: ChartEntry, difficultyIndex: number, mirror: string): string {
    return ChartSource.url(mirror, BRANCH_CHART, ChartSource.chartPath(entry, difficultyIndex));
  }

  static musicUrl(entry: ChartEntry, mirror: string): string {
    return ChartSource.url(mirror, BRANCH_MUSIC, ChartSource.musicPath(entry));
  }

  static illustrationUrl(entry: ChartEntry, mirror: string): string {
    return ChartSource.url(mirror, BRANCH_ILLUSTRATION, ChartSource.illustrationPath(entry));
  }

  /**
   * 拉取曲目清单。两条 tsv 都按"任一镜像成功即止"的策略获取，
   * 未配置 token 时完全依赖镜像直连，不需要访问 GitHub API，也就没有限流问题。
   */
  static async loadCatalog(): Promise<ChartEntry[]> {
    const difficulty = await ChartSource.fetchTextAnyMirror(BRANCH_INFO, "difficulty.tsv");
    const info = await ChartSource.fetchTextAnyMirror(BRANCH_INFO, "info.tsv");
    return ChartSource.parseCatalog(difficulty, info);
  }

  static parseCatalog(difficultyTsv: string, infoTsv: string): ChartEntry[] {
    const levelsMap = new Map<string, string[]>();
    for (const line of ChartSource.lines(difficultyTsv)) {
      const cols = line.split("\t");
      if (cols.length < 2) {
        continue;
      }
      levelsMap.set(cols[0], cols.slice(1));
    }

    const entries: ChartEntry[] = [];
    for (const line of ChartSource.lines(infoTsv)) {
      const cols = line.split("\t");
      if (cols.length < 2) {
        continue;
      }
      const id = cols[0];
      const levels = levelsMap.get(id) ?? [];
      if (levels.length === 0) {
        continue;
      }
      entries.push({
        id: id,
        name: cols[1] ?? id,
        nameCn: cols[3] ?? "",
        composer: cols[2] ?? "",
        levels: levels,
        charters: [cols[4] ?? "", cols[5] ?? "", cols[6] ?? ""],
        illustrator: cols[7] ?? "",
      });
    }
    entries.sort((a: ChartEntry, b: ChartEntry) => {
      return a.name.localeCompare(b.name);
    });
    return entries;
  }

  private static lines(text: string): string[] {
    return text
      .split("\n")
      .map((it: string) => it.trim())
      .filter((it: string) => it.length > 0);
  }

  /** 依次尝试各镜像，返回首个成功拿到的文本内容。 */
  static async fetchTextAnyMirror(branch: string, path: string): Promise<string> {
    let lastError = "";
    for (const mirror of MIRRORS) {
      const url = ChartSource.url(mirror, branch, path);
      try {
        return await HttpFile.get(url, false) as string;
      } catch (err) {
        lastError = (err as BusinessError).message ?? JSON.stringify(err);
        hilog.warn(DOMAIN, TAG, "Fetch %{public}s via %{public}s failed", path, mirror);
      }
    }
    throw new Error(`无法获取 ${path}：${lastError}`);
  }
}

/** 极薄的 HTTP 封装：文本或二进制下载。 */
export class HttpFile {
  static async get(url: string, asBytes: boolean): Promise<string | ArrayBuffer> {
    const req = http.createHttp();
    try {
      const res = await req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: asBytes ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 120000,
      });
      if (res.responseCode !== 200) {
        throw new Error(`HTTP ${res.responseCode}`);
      }
      return asBytes ? (res.result as ArrayBuffer) : (res.result as string);
    } finally {
      req.destroy();
    }
  }
}

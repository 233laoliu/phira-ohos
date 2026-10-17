import fs from "@ohos.file.fs";
import { hilog } from "@kit.PerformanceAnalysisKit";

const DOMAIN = 0x0000;
const TAG = "PhiraPezPacker";

const LOCAL_HEADER_SIG: number = 0x04034b50;
const CENTRAL_DIR_SIG: number = 0x02014b50;
const EOCD_SIG: number = 0x06054b50;
const VERSION: number = 20;
const METHOD_STORE: number = 0;
const DOS_DATE: number = 0x5821; // 2024-01-01

/**
 * 纯 ArkTS 的 .pez（zip）打包器，STORE 方式，entry 名统一取 basename。
 *
 * 为什么不直接用 @ohos.zlib 的 compressFiles：
 * 实测 HarmonyOS 6.1.0.135 上 compressFiles 的 Promise 在参数 unwrap 后约 0.5ms
 * 就 resolve（设备 hilog 时间戳实锤），此时 zip 还没落盘，原生侧紧接着
 * File::open 直接 ENOENT，导入报"导入失败: No such file or directory"。
 * 自己写 zip 还顺带保证 entry 布局——prpr 的 unzip_into 要求 info.yml 等
 * 文件位于 zip 根级，compressFiles 对文件输入生成的 entry 名行为没有文档保证。
 */
export class PezPacker {
  private static crcTable: Uint32Array | null = null;

  /**
   * 把 files 打包成 outPath（.pez）。返回写出的字节数；写完后自校验，不一致则抛错。
   */
  static pack(files: string[], outPath: string): number {
    const names: Uint8Array[] = [];
    const datas: Uint8Array[] = [];
    const crcs: number[] = [];
    for (const file of files) {
      // basename：同时兼容 "/" 与 "\"，避免路径分隔符差异把整条路径塞进 entry 名。
      const slash = Math.max(file.lastIndexOf("/"), file.lastIndexOf("\\"));
      const name = slash >= 0 ? file.substring(slash + 1) : file;
      const size = fs.statSync(file).size;
      const data = new Uint8Array(size);
      if (size > 0) {
        const reader = fs.openSync(file, fs.OpenMode.READ_ONLY);
        try {
          fs.readSync(reader.fd, data.buffer);
        } finally {
          fs.closeSync(reader.fd);
        }
      }
      names.push(PezPacker.utf8(name));
      datas.push(data);
      crcs.push(PezPacker.crc32(data));
    }

    const count = names.length;
    let localSize = 0;
    let centralSize = 0;
    let dataSize = 0;
    for (let i = 0; i < count; i++) {
      localSize += 30 + names[i].length;
      centralSize += 46 + names[i].length;
      dataSize += datas[i].length;
    }
    const total = localSize + dataSize + centralSize + 22;

    const buffer = new ArrayBuffer(total);
    const view = new DataView(buffer);
    const bytes = new Uint8Array(buffer);
    const offsets: number[] = [];
    let off = 0;
    for (let i = 0; i < count; i++) {
      offsets.push(off);
      view.setUint32(off, LOCAL_HEADER_SIG, true);
      off += 4;
      view.setUint16(off, VERSION, true);
      off += 2;
      view.setUint16(off, 0, true); // flags
      off += 2;
      view.setUint16(off, METHOD_STORE, true);
      off += 2;
      view.setUint16(off, 0, true); // mod time
      off += 2;
      view.setUint16(off, DOS_DATE, true);
      off += 2;
      view.setUint32(off, crcs[i], true);
      off += 4;
      view.setUint32(off, datas[i].length, true); // compressed size
      off += 4;
      view.setUint32(off, datas[i].length, true); // uncompressed size
      off += 4;
      view.setUint16(off, names[i].length, true);
      off += 2;
      view.setUint16(off, 0, true); // extra len
      off += 2;
      bytes.set(names[i], off);
      off += names[i].length;
      bytes.set(datas[i], off);
      off += datas[i].length;
    }

    const cdOffset = off;
    for (let i = 0; i < count; i++) {
      view.setUint32(off, CENTRAL_DIR_SIG, true);
      off += 4;
      view.setUint16(off, VERSION, true); // version made by
      off += 2;
      view.setUint16(off, VERSION, true); // version needed
      off += 2;
      view.setUint16(off, 0, true); // flags
      off += 2;
      view.setUint16(off, METHOD_STORE, true);
      off += 2;
      view.setUint16(off, 0, true); // mod time
      off += 2;
      view.setUint16(off, DOS_DATE, true);
      off += 2;
      view.setUint32(off, crcs[i], true);
      off += 4;
      view.setUint32(off, datas[i].length, true);
      off += 4;
      view.setUint32(off, datas[i].length, true);
      off += 4;
      view.setUint16(off, names[i].length, true);
      off += 2;
      view.setUint16(off, 0, true); // extra len
      off += 2;
      view.setUint16(off, 0, true); // comment len
      off += 2;
      view.setUint16(off, 0, true); // disk number start
      off += 2;
      view.setUint16(off, 0, true); // internal attrs
      off += 2;
      view.setUint32(off, 0, true); // external attrs
      off += 4;
      view.setUint32(off, offsets[i], true); // local header offset
      off += 4;
      bytes.set(names[i], off);
      off += names[i].length;
    }

    view.setUint32(off, EOCD_SIG, true);
    off += 4;
    view.setUint16(off, 0, true); // disk number
    off += 2;
    view.setUint16(off, 0, true); // disk with central dir
    off += 2;
    view.setUint16(off, count, true); // entries on this disk
    off += 2;
    view.setUint16(off, count, true); // total entries
    off += 2;
    view.setUint32(off, centralSize, true);
    off += 4;
    view.setUint32(off, cdOffset, true);
    off += 4;
    view.setUint16(off, 0, true); // comment len
    off += 2;

    const writer = fs.openSync(outPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(writer.fd, buffer);
    } finally {
      fs.closeSync(writer.fd);
    }

    const written = fs.statSync(outPath).size;
    if (written !== total) {
      throw new Error(`pez size mismatch: expect ${total}, got ${written}`);
    }
    hilog.info(DOMAIN, TAG, "packed %{public}s: %{public}d bytes, %{public}d entries", outPath, total, count);
    return total;
  }

  private static crc32(bytes: Uint8Array): number {
    if (PezPacker.crcTable === null) {
      const table = new Uint32Array(256);
      for (let i = 0; i < 256; i++) {
        let c = i;
        for (let k = 0; k < 8; k++) {
          c = (c & 1) === 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
        }
        table[i] = c;
      }
      PezPacker.crcTable = table;
    }
    const table = PezPacker.crcTable;
    let crc = 0xffffffff;
    for (let i = 0; i < bytes.length; i++) {
      crc = table[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
    }
    return (crc ^ 0xffffffff) >>> 0;
  }

  private static utf8(value: string): Uint8Array {
    const out: number[] = [];
    for (let i = 0; i < value.length; i++) {
      let c = value.charCodeAt(i);
      if (c < 0x80) {
        out.push(c);
      } else if (c < 0x800) {
        out.push(0xc0 | (c >> 6));
        out.push(0x80 | (c & 0x3f));
      } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < value.length) {
        const c2 = value.charCodeAt(i + 1);
        if (c2 >= 0xdc00 && c2 <= 0xdfff) {
          c = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00);
          i++;
          out.push(0xf0 | (c >> 18));
          out.push(0x80 | ((c >> 12) & 0x3f));
          out.push(0x80 | ((c >> 6) & 0x3f));
          out.push(0x80 | (c & 0x3f));
        } else {
          out.push(0x3f);
        }
      } else {
        out.push(0xe0 | (c >> 12));
        out.push(0x80 | ((c >> 6) & 0x3f));
        out.push(0x80 | (c & 0x3f));
      }
    }
    return new Uint8Array(out);
  }
}

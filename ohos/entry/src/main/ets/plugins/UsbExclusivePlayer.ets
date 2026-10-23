import {
  BinaryMessenger,
  Log,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { usbManager } from '@kit.BasicServicesKit';

const TAG = 'UsbExclusivePlayer';
const CHANNEL = 'xianyu/usb_exclusive';

// —— 等时节奏参数 ——
// 全速（FS）设备：1 传输 = 1 ms = 1 个等时包（44.1k 用 176/177B 交替凑整）；
// 高速（HS）设备：1 传输 = 8 个微帧（125µs），整包均分（44.1k 有 ~0.2%
// 欠速，v1 已知限制）。在途窗口保持 WINDOW_MS 毫秒，欠载数据补零维持
// 设备时钟（对齐 Rust OHAudio 写回调补零语义）。
const WINDOW_MS = 32;
// 本地 PCM 队列容量（毫秒）。Dart 侧每 8ms 推一次 ring 数据（推模型，
// 免 ArkTS→Dart 回调式 invokeMethod）；队列满时 Dart 侧数据滞留 ring
// 自然背压，不会丢样。
const QUEUE_MS = 96;
// 反馈（feedback）IN 读取周期：每 200 个 OUT 包（≈200ms）读一次 10.10
// 格式频率，按比值微调每包字节数（±5% 箝位）。
const FEEDBACK_PERIOD = 200;
// 连续失败次数达到该值判定设备丢失（拔出/挂起）。
const MAX_FAIL_STREAK = 8;

// UAC（USB Audio Class 1）AudioStreaming 交替设置：
// 系统对象（claim/setInterface 用）+ 从原始配置描述符解析出的格式表。
interface UacAlt {
  iface: usbManager.USBInterface;
  ifaceNum: number;
  alt: number;
  outEp: usbManager.USBEndpoint; // 等时 OUT 端点
  feedbackEp: usbManager.USBEndpoint | null; // 等时 IN 端点（反馈，可选）
  rates: number[]; // continuous=false: 离散频率表；true: [lo, hi] 连续范围
  continuous: boolean;
  channels: number;
  subframeBytes: number;
  bitRes: number;
  maxPacket: number;
}

// FORMAT_TYPE_I（CS_INTERFACE subtype=2, bFormatType=1）解析结果，
// 稍后与系统 USBInterface 对象按 (ifaceNum, alt) 关联。
interface UacFormat {
  ifaceNum: number;
  alt: number;
  channels: number;
  subframeBytes: number;
  bitRes: number;
  rates: number[];
  continuous: boolean;
}

interface StartOk {
  deviceName: string;
  sampleRate: number;
  channels: number;
}

/**
 * 鸿蒙 USB 独占输出（椒盐式路线：应用自当 UAC 主机）。
 *
 * 分工：
 * · Rust（ohos_audio.rs）：解码 → DSP 全链 → 环形缓冲（S16LE 交错 PCM），
 *   经 FFI（xianyu_ohos_usb_ring_read/level/format_json）暴露给 Dart。
 * · Dart（usb_exclusive_service.dart）：控制面（本通道 start/stop）+
 *   数据面（每 8ms 从 ring 拉 FFI 再经 `push` 推给本类）。
 * · 本类（ArkTS）：枚举设备 → requestRight 系统授权弹窗 → connectDevice →
 *   解析 UAC 描述符选 alt setting → claimInterface(force) → setInterface →
 *   usbSubmitTransfer 等时循环直写 DAC → feedback EP 调速 → 热拔出上报。
 *
 * 暂停/seek 不需要通知本类：Rust 侧停产后 ring 干涸，`push` 推不出数据，
 * 等时包补零输出静音，位置自然冻结；恢复后数据续上（≈队列时延内衔接）。
 */
export class UsbExclusivePlayer {
  private channel: MethodChannel;
  private pipe: usbManager.USBDevicePipe | null = null;
  private claimedIface: usbManager.USBInterface | null = null;
  private selected: UacAlt | null = null;
  private running: boolean = false;

  // —— 本地 PCM 环形队列 ——
  private buffer: Uint8Array = new Uint8Array(0);
  private bufCap: number = 0;
  private readPos: number = 0;
  private writePos: number = 0;
  private buffered: number = 0;

  // —— 等时状态 ——
  private frameBytes: number = 0; // 每毫秒字节数（标称，float）
  private packetsPerTransfer: number = 1; // FS=1（1ms/包）；HS=8（微帧/包）
  private inFlight: number = 0;
  private pending: usbManager.UsbDataTransferParams[] = [];
  private failStreak: number = 0;
  private fracAcc: number = 0;

  // —— feedback ——
  private nominalRate: number = 0;
  private rateRatio: number = 1.0;
  private hasFeedback: boolean = false;
  private fbInFlight: boolean = false;
  private outCount: number = 0;

  constructor(messenger: BinaryMessenger) {
    this.channel = new MethodChannel(messenger, CHANNEL);
    const handler: MethodCallHandler = {
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        this.onCall(call, result);
      },
    };
    this.channel.setMethodCallHandler(handler);
  }

  static attach(messenger: BinaryMessenger): void {
    new UsbExclusivePlayer(messenger);
  }

  private onCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'start':
        this.handleStart(call, result);
        break;
      case 'stop':
        this.handleStop(result);
        break;
      case 'push':
        this.handlePush(call, result);
        break;
      default:
        result.notImplemented();
    }
  }

  // =========================================================================
  // 控制面
  // =========================================================================

  private async handleStart(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      const sampleRate: number = call.argument('sampleRate') as number;
      const channels: number = call.argument('channels') as number;
      const bytesPerSample: number = call.argument('bytesPerSample') as number;
      if (this.running) {
        // 幂等：已在跑则视为成功（Dart 侧 start 前总是先 stop）
        result.success(null);
        return;
      }
      // 1. 枚举并挑 UAC 设备
      const devices: usbManager.USBDevice[] = usbManager.getDevices();
      let dev: usbManager.USBDevice | null = null;
      for (const d of devices) {
        const hasUac: boolean = d.configs.some((c: usbManager.USBConfiguration): boolean =>
          c.interfaces.some((it: usbManager.USBInterface): boolean =>
            it.clazz === 1 && it.subClass === 2));
        if (hasUac) {
          dev = d;
          break;
        }
      }
      if (dev == null) {
        throw new Error('未发现 USB 音频 (UAC) 设备');
      }
      // 2. 设备访问授权（系统弹窗；已授权则直接过）
      if (!usbManager.hasRight(dev.name)) {
        const granted: boolean = await usbManager.requestRight(dev.name);
        if (!granted) {
          throw new Error('用户拒绝 USB 设备授权');
        }
      }
      // 3. 建立数据通道
      const pipe: usbManager.USBDevicePipe = usbManager.connectDevice(dev);
      this.pipe = pipe;
      // 4. 解析配置描述符 → 选 alt setting（S16/bps 匹配 + 采样率 + 声道数）
      const raw: ArrayBuffer = usbManager.getRawDescriptor(pipe);
      const formats: UacFormat[] = UsbExclusivePlayer.parseFormats(new Uint8Array(raw));
      const alts: UacAlt[] = this.joinAlts(dev, formats);
      const sel: UacAlt | null = this.chooseAlt(alts, sampleRate, channels, bytesPerSample);
      if (sel == null) {
        throw new Error(
          `DAC 无 ${sampleRate}Hz/${channels}ch/${bytesPerSample * 8}bit 交替设置（v1 仅支持 S16）`);
      }
      // 5. claim（force 允许抢占）→ setInterface 激活 alt setting
      let ret: number = usbManager.claimInterface(pipe, sel.iface, true);
      if (ret !== 0) {
        // 某些设备未激活配置：先 setConfiguration 再试一次
        try {
          usbManager.setConfiguration(pipe, dev.configs[0]);
        } catch (e) {
          Log.w(TAG, `setConfiguration failed: ${(e as BusinessError).message}`);
        }
        ret = usbManager.claimInterface(pipe, sel.iface, true);
      }
      if (ret !== 0) {
        throw new Error(`claimInterface 失败 code=${ret}（接口被内核驱动或他方占用）`);
      }
      this.claimedIface = sel.iface;
      ret = usbManager.setInterface(pipe, sel.iface);
      if (ret !== 0) {
        throw new Error(`setInterface 失败 code=${ret}`);
      }
      // 6. 起等时循环
      this.selected = sel;
      this.nominalRate = sampleRate;
      this.frameBytes = sampleRate * channels * bytesPerSample / 1000;
      this.packetsPerTransfer = sel.maxPacket > 1023 ? 8 : 1;
      this.hasFeedback = sel.feedbackEp != null;
      this.bufCap = Math.ceil(this.frameBytes * QUEUE_MS) + 4096;
      this.buffer = new Uint8Array(this.bufCap);
      this.readPos = 0;
      this.writePos = 0;
      this.buffered = 0;
      this.inFlight = 0;
      this.failStreak = 0;
      this.fracAcc = 0;
      this.rateRatio = 1.0;
      this.outCount = 0;
      this.fbInFlight = false;
      this.running = true;
      // 预填在途窗口（此刻本地队列大概率是空的：头几包补零，push 数据
      // 到达后自然续上；Rust ring 此时已有最多 ~300ms 存货，补零窗口 <16ms）
      for (let k = 0; k < WINDOW_MS; k++) {
        this.submitOut();
      }
      const ok: StartOk = {
        deviceName: dev.productName !== '' ? dev.productName : dev.name,
        sampleRate: sampleRate,
        channels: channels,
      };
      result.success(ok);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Log.w(TAG, `start failed: ${msg}`);
      this.running = false;
      this.cleanup();
      result.error('usb_error', msg, '');
    }
  }

  private handleStop(result: MethodResult): void {
    this.running = false;
    // 取消在途传输（回调回来发现 running=false 自行退出）
    const pend: usbManager.UsbDataTransferParams[] = this.pending;
    this.pending = [];
    for (const p of pend) {
      try {
        usbManager.usbCancelTransfer(p);
      } catch (e) {
        // 已完成/不存在：忽略
      }
    }
    this.cleanup();
    result.success(null);
  }

  private handlePush(call: MethodCall, result: MethodResult): void {
    const pcm: Uint8Array | null = call.argument('pcm') as Uint8Array | null;
    let dropped: number = 0;
    if (pcm != null && pcm.length > 0 && this.running) {
      dropped = this.enqueue(pcm);
    }
    // 满队列丢弃（返回丢弃量便于 Dart 侧诊断；正常应恒为 0）
    result.success(dropped);
  }

  // =========================================================================
  // 等时循环
  // =========================================================================

  private submitOut(): void {
    if (!this.running || this.pipe == null || this.selected == null) {
      return;
    }
    const sel: UacAlt = this.selected as UacAlt;
    const packet: number = this.nextPacketBytes();
    if (packet <= 0) {
      this.deviceLost('packet size computed 0');
      return;
    }
    const buf: Uint8Array = new Uint8Array(packet);
    this.takeBytes(buf);
    const self: UsbExclusivePlayer = this;
    const params: usbManager.UsbDataTransferParams = {
      devPipe: this.pipe as usbManager.USBDevicePipe,
      flags: usbManager.UsbTransferFlags.USB_TRANSFER_SHORT_NOT_OK,
      endpoint: sel.outEp.address,
      type: usbManager.UsbEndpointTransferType.TRANSFER_TYPE_ISOCHRONOUS,
      timeout: 0,
      length: packet,
      callback: (err: BusinessError<void>, res: usbManager.SubmitTransferCallback): void => {
        self.onOutDone(err, res);
      },
      userData: new Uint8Array(0),
      buffer: buf,
      isoPacketCount: this.packetsPerTransfer,
    };
    this.pending.push(params);
    this.inFlight++;
    try {
      usbManager.usbSubmitTransfer(params);
    } catch (e) {
      this.inFlight--;
      const idx: number = this.pending.indexOf(params);
      if (idx >= 0) {
        this.pending.splice(idx, 1);
      }
      this.deviceLost(`submitOut: ${(e as BusinessError).message}`);
    }
  }

  private onOutDone(err: BusinessError<void>, res: usbManager.SubmitTransferCallback): void {
    this.inFlight--;
    if (!this.running) {
      return;
    }
    const completed: boolean = err == null && res != null &&
      res.status === usbManager.UsbTransferStatus.TRANSFER_COMPLETED;
    if (completed) {
      this.failStreak = 0;
    } else {
      this.failStreak++;
      const st: number = res != null ? res.status : -1;
      if (st === usbManager.UsbTransferStatus.TRANSFER_NO_DEVICE ||
        this.failStreak >= MAX_FAIL_STREAK) {
        this.deviceLost(`iso out status=${st} err=${err != null ? err.message : ''}`);
        return;
      }
      // 偶发失败：不重提该包，等下一次窗口内自然恢复
      if (this.inFlight < WINDOW_MS) {
        this.submitOut();
      }
      return;
    }
    this.outCount++;
    if (this.hasFeedback && !this.fbInFlight && this.outCount >= FEEDBACK_PERIOD) {
      this.outCount = 0;
      this.fbInFlight = true;
      this.submitFeedback();
    }
    this.submitOut();
  }

  private submitFeedback(): void {
    if (!this.running || this.pipe == null || this.selected == null) {
      this.fbInFlight = false;
      return;
    }
    const sel: UacAlt = this.selected as UacAlt;
    if (sel.feedbackEp == null) {
      this.fbInFlight = false;
      return;
    }
    const fb: usbManager.USBEndpoint = sel.feedbackEp as usbManager.USBEndpoint;
    const size: number = fb.maxPacketSize > 0 ? fb.maxPacketSize : 3;
    const buf: Uint8Array = new Uint8Array(size);
    const self: UsbExclusivePlayer = this;
    const params: usbManager.UsbDataTransferParams = {
      devPipe: this.pipe as usbManager.USBDevicePipe,
      flags: usbManager.UsbTransferFlags.USB_TRANSFER_SHORT_NOT_OK,
      endpoint: fb.address,
      type: usbManager.UsbEndpointTransferType.TRANSFER_TYPE_ISOCHRONOUS,
      timeout: 0,
      length: size,
      callback: (err: BusinessError<void>, res: usbManager.SubmitTransferCallback): void => {
        self.onFeedbackDone(err, res, buf);
      },
      userData: new Uint8Array(0),
      buffer: buf,
      isoPacketCount: 1,
    };
    try {
      usbManager.usbSubmitTransfer(params);
    } catch (e) {
      // 反馈仅用于调速，失败不影响出声
      this.fbInFlight = false;
    }
  }

  private onFeedbackDone(err: BusinessError<void>, res: usbManager.SubmitTransferCallback,
    buf: Uint8Array): void {
    this.fbInFlight = false;
    if (!this.running || err != null || res == null) {
      return;
    }
    const descs: Array<Readonly<usbManager.UsbIsoPacketDescriptor>> = res.isoPacketDescs;
    if (descs == null || descs.length === 0 || descs[0].status !==
      usbManager.UsbTransferStatus.TRANSFER_COMPLETED || descs[0].actualLength < 3) {
      return;
    }
    // UAC1 全速：10.10（3B）= 每帧(1ms)采样数 Q10.10；高速：16.16（4B）
    // = 每微帧(125µs)采样数 Q16.16。
    let freq: number = 0;
    if (buf.length >= 4) {
      const raw16: number = (buf[0] | (buf[1] << 8) | (buf[2] << 16) | (buf[3] << 24)) >>> 0;
      freq = (raw16 / 65536) * 8000;
    } else {
      const raw10: number = (buf[0] | (buf[1] << 8) | (buf[2] << 16)) >>> 0;
      freq = (raw10 / 1024) * 1000;
    }
    if (freq <= 0 || this.nominalRate <= 0) {
      return;
    }
    const ratio: number = freq / this.nominalRate;
    if (ratio > 0.95 && ratio < 1.05) {
      this.rateRatio = ratio;
    }
  }

  private nextPacketBytes(): number {
    const base: number = this.frameBytes * this.rateRatio;
    if (base <= 0) {
      return 0;
    }
    if (this.packetsPerTransfer > 1) {
      // HS：整包均分微帧（44.1k 略欠速，已知限制）
      const per: number = Math.max(1, Math.round(base / this.packetsPerTransfer));
      return per * this.packetsPerTransfer;
    }
    // FS：分数累进凑整（44.1k → 176/177B 交替）
    this.fracAcc += base;
    let whole: number = Math.floor(this.fracAcc);
    if (whole < 1) {
      whole = 1;
    }
    this.fracAcc -= whole;
    return whole;
  }

  private deviceLost(msg: string): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    Log.w(TAG, `device lost: ${msg}`);
    this.cleanup();
    this.channel.invokeMethod('deviceLost', msg);
  }

  private cleanup(): void {
    this.selected = null;
    const pipe: usbManager.USBDevicePipe | null = this.pipe;
    const iface: usbManager.USBInterface | null = this.claimedIface;
    this.claimedIface = null;
    this.buffer = new Uint8Array(0);
    this.bufCap = 0;
    this.readPos = 0;
    this.writePos = 0;
    this.buffered = 0;
    this.pending = [];
    this.inFlight = 0;
    this.rateRatio = 1.0;
    if (pipe == null) {
      return;
    }
    try {
      if (iface != null) {
        usbManager.releaseInterface(pipe, iface);
      }
    } catch (e) {
      Log.w(TAG, `releaseInterface: ${(e as BusinessError).message}`);
    }
    try {
      usbManager.closePipe(pipe);
    } catch (e) {
      Log.w(TAG, `closePipe: ${(e as BusinessError).message}`);
    }
    this.pipe = null;
  }

  // =========================================================================
  // 本地 PCM 队列（环形）
  // =========================================================================

  private enqueue(pcm: Uint8Array): number {
    const free: number = this.bufCap - this.buffered;
    const n: number = Math.min(free, pcm.length);
    for (let i = 0; i < n; i++) {
      this.buffer[this.writePos] = pcm[i];
      this.writePos = (this.writePos + 1) % this.bufCap;
    }
    this.buffered += n;
    return pcm.length - n; // 丢弃量
  }

  private takeBytes(dst: Uint8Array): number {
    const want: number = dst.length;
    let copied: number = 0;
    while (copied < want && this.buffered > 0) {
      const take: number = Math.min(want - copied, this.buffered, this.bufCap - this.readPos);
      dst.set(this.buffer.subarray(this.readPos, this.readPos + take), copied);
      this.readPos = (this.readPos + take) % this.bufCap;
      this.buffered -= take;
      copied += take;
    }
    if (copied < want) {
      dst.fill(0, copied); // 欠载补零，维持设备时钟与时间轴
    }
    return copied;
  }

  // =========================================================================
  // UAC 描述符解析
  // =========================================================================

  // 走原始配置描述符 blob，收集 FORMAT_TYPE_I 格式（键 = 接口号 + 交替设置）。
  // 布局（UAC1）：AS_GENERAL(subtype=1) → FORMAT_TYPE(subtype=2)：
  //   [3]=bFormatType [4]=bNrChannels [5]=bSubframeSize [6]=bBitResolution
  //   [7]=bSamFreqType（0=连续，后跟 lo/hi 两组 3B 端点；n>0=离散 n 组 3B）
  static parseFormats(bytes: Uint8Array): UacFormat[] {
    const out: UacFormat[] = [];
    let curIfaceNum: number = -1;
    let curAlt: number = -1;
    let i: number = 0;
    while (i + 2 <= bytes.length) {
      const len: number = bytes[i];
      if (len < 2 || i + len > bytes.length) {
        break;
      }
      const type: number = bytes[i + 1];
      if (type === 0x04 && len >= 9) {
        // INTERFACE descriptor
        curIfaceNum = bytes[i + 2];
        curAlt = bytes[i + 3];
      } else if (type === 0x24 && len >= 8 && curIfaceNum >= 0) {
        // CS_INTERFACE descriptor
        const subtype: number = bytes[i + 2];
        if (subtype === 0x02 && bytes[i + 3] === 0x01) {
          // FORMAT_TYPE_I（仅认 type I PCM）
          const channels: number = bytes[i + 4];
          const subframe: number = bytes[i + 5];
          const bitRes: number = bytes[i + 6];
          const n: number = bytes[i + 7];
          const rates: number[] = [];
          let continuous: boolean = false;
          if (n === 0) {
            continuous = true;
            const off: number = i + 8;
            if (len >= 14) {
              const lo: number = bytes[off] | (bytes[off + 1] << 8) | (bytes[off + 2] << 16);
              const hi: number =
                bytes[off + 3] | (bytes[off + 4] << 8) | (bytes[off + 5] << 16);
              rates.push(lo, hi);
            }
          } else {
            for (let k: number = 0; k < n; k++) {
              const off: number = i + 8 + k * 3;
              if (off + 2 < i + len) {
                rates.push(bytes[off] | (bytes[off + 1] << 8) | (bytes[off + 2] << 16));
              }
            }
          }
          const f: UacFormat = {
            ifaceNum: curIfaceNum,
            alt: curAlt,
            channels: channels,
            subframeBytes: subframe,
            bitRes: bitRes,
            rates: rates,
            continuous: continuous,
          };
          out.push(f);
        }
      }
      i += len;
    }
    return out;
  }

  // 系统解析的 AudioStreaming 交替设置 × 格式表 → UacAlt 列表。
  private joinAlts(dev: usbManager.USBDevice, formats: UacFormat[]): UacAlt[] {
    const out: UacAlt[] = [];
    if (dev.configs.length === 0) {
      return out;
    }
    const interfaces: usbManager.USBInterface[] = dev.configs[0].interfaces;
    for (const it of interfaces) {
      if (it.clazz !== 1 || it.subClass !== 2) {
        continue; // 非 AudioStreaming
      }
      let fmt: UacFormat | null = null;
      for (const f of formats) {
        if (f.ifaceNum === it.id && f.alt === it.alternateSetting) {
          fmt = f;
          break;
        }
      }
      if (fmt == null) {
        continue; // 无格式表（AudioControl/零带宽 alt 0 等）
      }
      let outEp: usbManager.USBEndpoint | null = null;
      let feedbackEp: usbManager.USBEndpoint | null = null;
      for (const ep of it.endpoints) {
        const iso: boolean = (ep.attributes & 0x03) === 0x01;
        if (!iso) {
          continue;
        }
        if (ep.direction === usbManager.USBRequestDirection.USB_REQUEST_DIR_TO_DEVICE) {
          if (outEp == null) {
            outEp = ep;
          }
        } else if (feedbackEp == null) {
          feedbackEp = ep; // 等时 IN = implicit feedback
        }
      }
      if (outEp == null) {
        continue; // 无等时 OUT 端点
      }
      const a: UacAlt = {
        iface: it,
        ifaceNum: it.id,
        alt: it.alternateSetting,
        outEp: outEp as usbManager.USBEndpoint,
        feedbackEp: feedbackEp,
        rates: fmt.rates,
        continuous: fmt.continuous,
        channels: fmt.channels,
        subframeBytes: fmt.subframeBytes,
        bitRes: fmt.bitRes,
        maxPacket: (outEp as usbManager.USBEndpoint).maxPacketSize,
      };
      out.push(a);
    }
    return out;
  }

  private rateMatches(sel: UacAlt, rate: number): boolean {
    if (sel.continuous && sel.rates.length >= 2) {
      return rate >= sel.rates[0] && rate <= sel.rates[1];
    }
    return sel.rates.indexOf(rate) >= 0;
  }

  // 选 alt：S16（v1）+ 采样率 + 声道数匹配；同配择 wMaxPacketSize 最小者
  // （省带宽）。FS 还要求每毫秒字节数 ≤ wMaxPacketSize。
  private chooseAlt(alts: UacAlt[], rate: number, channels: number,
    bytesPerSample: number): UacAlt | null {
    let best: UacAlt | null = null;
    for (const a of alts) {
      if (a.subframeBytes !== bytesPerSample || a.bitRes !== bytesPerSample * 8) {
        continue;
      }
      if (a.channels !== channels || !this.rateMatches(a, rate)) {
        continue;
      }
      const perMs: number = rate * channels * bytesPerSample / 1000;
      if (a.maxPacket <= 1023 && perMs > a.maxPacket) {
        continue; // FS 塞不下
      }
      if (best == null || a.maxPacket < (best as UacAlt).maxPacket) {
        best = a;
      }
    }
    return best;
  }
}

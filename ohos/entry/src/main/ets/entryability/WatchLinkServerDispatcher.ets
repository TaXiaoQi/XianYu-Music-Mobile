import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { AsyncCallback, Callback } from '@ohos.base';
import socket from '@ohos.bluetooth.socket';
import connection from '@ohos.bluetooth.connection';
import { BinaryMessenger, MethodCall, MethodChannel, MethodResult } from '@ohos/flutter_ohos';

const kWatchLinkServiceUuid = 'f7a24b6c-9d3e-4f8a-b1c2-2e5d8a7f6b3a';
const kPermissionBluetooth: Permissions = 'ohos.permission.ACCESS_BLUETOOTH';

/**
 * 手表联动 SPP 传输层（ohos 手机端 = 服务端）。
 *
 * 职责边界与安卓 WatchLink.kt 完全一致：只做蓝牙 SPP 字节管道
 * （accept / 读写 / 断连感知），帧编解码、CRC、分片重组、心跳与协议
 * 语义全部在 Dart 侧 lib/src/watch_link/（复用腕上端
 * lib/src/link/protocol.dart 同一实现），通道名同为 'xianyu/watch_link'。
 *
 * 连接模型：单手表场景，accept 循环接受连接后关掉旧连接保最新；
 * stop 时关闭全部套接字，幂等可重启。connect 为反向配对（手机主动
 * 连手表的服务端）——纯血鸿蒙表侧 v1 未起反向服务端，连接会失败并
 * 回 onConnection(false)，Dart 侧按既有失败路径处理。
 *
 * 平台矩阵：@ohos.bluetooth.socket SPP 需 API 10+（手机/平板全域可用），
 * 本工程 compatibleSdkVersion 为 5.1.0(18)。Wear Engine 系列方法为
 * 安卓华为 SDK 专属，ohos 不实现（Dart 侧 catch 后静默）。
 *
 * 与安卓差异（v1，待实机验证）：sppRead 事件无 EOF/错误信号，断连
 * 感知靠写失败静默 + Dart 心跳 10s 判死兜底。
 */
export class WatchLinkServerDispatcher {
  private static channel: MethodChannel | null = null;
  private static context: common.UIAbilityContext | null = null;
  private static running: boolean = false;
  private static accepting: boolean = false;
  private static serverSocket: number = -1;
  private static clientSocket: number = -1;
  private static readCb: Callback<ArrayBuffer> | null = null;
  private static connecting: boolean = false;

  /** 连接代际：adopt/disconnect/stop 各自推进，丢弃旧代读回调。 */
  private static epoch: number = 0;

  /** 注册通道（configureFlutterEngine 时调用一次；重入仅刷新引用）。 */
  static attach(messenger: BinaryMessenger, context: common.UIAbilityContext): void {
    const ch = new MethodChannel(messenger, 'xianyu/watch_link');
    ch.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        WatchLinkServerDispatcher.onMethodCall(call, result);
      }
    });
    WatchLinkServerDispatcher.channel = ch;
    WatchLinkServerDispatcher.context = context;
  }

  private static onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'start':
        WatchLinkServerDispatcher.start();
        result.success(null);
        break;
      case 'stop':
        WatchLinkServerDispatcher.stop();
        result.success(null);
        break;
      case 'disconnect':
        WatchLinkServerDispatcher.disconnect();
        result.success(null);
        break;
      case 'send': {
        const bytes = call.argument('bytes') as Object | null;
        if (bytes instanceof Uint8Array) {
          // sppWrite 同步写完即回包：Dart await 后再发下一帧（天然背压）。
          WatchLinkServerDispatcher.send(bytes);
        }
        result.success(null);
        break;
      }
      case 'pairedDevices':
        result.success(WatchLinkServerDispatcher.pairedDevices());
        break;
      case 'connect': {
        const address = (call.argument('address') ?? '') as string;
        WatchLinkServerDispatcher.connect(address);
        result.success(null);
        break;
      }
      case 'hasPermission':
        result.success(WatchLinkServerDispatcher.hasPermission());
        break;
      case 'requestPermission':
        WatchLinkServerDispatcher.requestPermission();
        result.success(null);
        break;
      default:
        // wearHasEngine/wearAuthorize/wearWake 等：Wear Engine 为安卓华为
        // SDK 专属，ohos 不实现，Dart 侧 catch 后静默。
        result.notImplemented();
        break;
    }
  }

  // ---- 服务端 ----

  /** 启动 accept 服务（幂等；无权限时静默不启动，Dart 前置检查权限）。 */
  private static start(): void {
    if (WatchLinkServerDispatcher.running) {
      return;
    }
    if (!WatchLinkServerDispatcher.hasPermission()) {
      return;
    }
    if (WatchLinkServerDispatcher.context == null) {
      return;
    }
    WatchLinkServerDispatcher.running = true;
    const options: socket.SppOptions = {
      uuid: kWatchLinkServiceUuid,
      secure: true,
      type: socket.SppType.SPP_RFCOMM,
    };
    const cb: AsyncCallback<number> = (err, serverId) => {
      if (!WatchLinkServerDispatcher.running) {
        return;
      }
      if (err || serverId == null || serverId < 0) {
        WatchLinkServerDispatcher.running = false;
        return;
      }
      WatchLinkServerDispatcher.serverSocket = serverId;
      WatchLinkServerDispatcher.acceptNext();
    };
    try {
      socket.sppListen('XianYuWatchLink', options, cb);
    } catch (e) {
      WatchLinkServerDispatcher.running = false;
    }
  }

  /** 停止服务并断开连接（幂等）。 */
  private static stop(): void {
    WatchLinkServerDispatcher.running = false;
    const serverId = WatchLinkServerDispatcher.serverSocket;
    WatchLinkServerDispatcher.serverSocket = -1;
    if (serverId >= 0) {
      try {
        socket.sppCloseServerSocket(serverId);
      } catch (e) {
      }
    }
    WatchLinkServerDispatcher.epoch++;
    WatchLinkServerDispatcher.closeCurrent();
  }

  private static acceptNext(): void {
    if (!WatchLinkServerDispatcher.running) {
      return;
    }
    if (WatchLinkServerDispatcher.accepting) {
      return;
    }
    if (WatchLinkServerDispatcher.serverSocket < 0) {
      return;
    }
    WatchLinkServerDispatcher.accepting = true;
    const cb: AsyncCallback<number> = (err, sockId) => {
      WatchLinkServerDispatcher.accepting = false;
      if (!WatchLinkServerDispatcher.running) {
        // stop 已关服务端：迟到的入站连接直接丢弃。
        if (sockId != null && sockId >= 0) {
          try {
            socket.sppCloseClientSocket(sockId);
          } catch (e) {
          }
        }
        return;
      }
      if (err || sockId == null || sockId < 0) {
        // accept 异常对齐安卓：退出循环（重启靠 Dart 再次 start）。
        return;
      }
      WatchLinkServerDispatcher.adopt(sockId);
      WatchLinkServerDispatcher.acceptNext();
    };
    try {
      socket.sppAccept(WatchLinkServerDispatcher.serverSocket, cb);
    } catch (e) {
      WatchLinkServerDispatcher.accepting = false;
    }
  }

  /** 仅断开当前手表连接：服务端保持 accept，手表可随时重连（幂等）。 */
  private static disconnect(): void {
    WatchLinkServerDispatcher.epoch++;
    WatchLinkServerDispatcher.closeCurrent();
  }

  /** 采纳新连接：关旧保新（最新手表优先），起读事件。 */
  private static adopt(sockId: number): void {
    WatchLinkServerDispatcher.closeCurrent();
    const epoch = ++WatchLinkServerDispatcher.epoch;
    let deviceId = '';
    try {
      deviceId = socket.getDeviceId(sockId);
    } catch (e) {
    }
    let name = 'watch';
    if (deviceId.length > 0) {
      try {
        const n = connection.getRemoteDeviceName(deviceId);
        if (n && n.length > 0) {
          name = n;
        }
      } catch (e) {
      }
    }
    WatchLinkServerDispatcher.clientSocket = sockId;
    const cb: Callback<ArrayBuffer> = (data) => {
      if (epoch !== WatchLinkServerDispatcher.epoch) {
        return;
      }
      if (data && data.byteLength > 0) {
        const ch = WatchLinkServerDispatcher.channel;
        if (ch != null) {
          ch.invokeMethod('onRaw', new Uint8Array(data));
        }
      }
    };
    WatchLinkServerDispatcher.readCb = cb;
    try {
      socket.on('sppRead', sockId, cb);
    } catch (e) {
    }
    WatchLinkServerDispatcher.emitConnection(true, name);
  }

  private static closeCurrent(): void {
    const cb = WatchLinkServerDispatcher.readCb;
    WatchLinkServerDispatcher.readCb = null;
    const sockId = WatchLinkServerDispatcher.clientSocket;
    WatchLinkServerDispatcher.clientSocket = -1;
    if (sockId < 0) {
      return;
    }
    if (cb != null) {
      try {
        socket.off('sppRead', sockId, cb);
      } catch (e) {
      }
    }
    try {
      socket.sppCloseClientSocket(sockId);
    } catch (e) {
    }
  }

  // ---- 反向配对（手机主动连手表）----

  /** 连接指定地址（异步，单飞）。成败与断连均经 onConnection 回传。 */
  private static connect(address: string): void {
    if (address.length === 0) {
      return;
    }
    if (!WatchLinkServerDispatcher.hasPermission()) {
      return;
    }
    if (WatchLinkServerDispatcher.connecting) {
      return;
    }
    WatchLinkServerDispatcher.connecting = true;
    const options: socket.SppOptions = {
      uuid: kWatchLinkServiceUuid,
      secure: true,
      type: socket.SppType.SPP_RFCOMM,
    };
    const cb: AsyncCallback<number> = (err, sockId) => {
      WatchLinkServerDispatcher.connecting = false;
      if (err || sockId == null || sockId < 0) {
        WatchLinkServerDispatcher.emitConnection(false, '');
        return;
      }
      WatchLinkServerDispatcher.adopt(sockId);
    };
    try {
      socket.sppConnect(address, options, cb);
    } catch (e) {
      WatchLinkServerDispatcher.connecting = false;
      WatchLinkServerDispatcher.emitConnection(false, '');
    }
  }

  // ---- 收发 ----

  /** 发送原始字节（帧由 Dart 层编码；写失败静默，断连由 Dart 心跳判死）。 */
  private static send(bytes: Uint8Array): void {
    if (bytes.length === 0) {
      return;
    }
    const sockId = WatchLinkServerDispatcher.clientSocket;
    if (sockId < 0) {
      return;
    }
    // 拷贝一份连续 ArrayBuffer（入参可能是大缓冲上的视图）。
    const ab: ArrayBuffer = new ArrayBuffer(bytes.byteLength);
    new Uint8Array(ab).set(bytes);
    try {
      socket.sppWrite(sockId, ab);
    } catch (e) {
    }
  }

  // ---- 设备与权限 ----

  /** 已配对设备列表 [{address, name}]（无权限/蓝牙关闭返回空）。 */
  private static pairedDevices(): Array<Object> {
    const out: Array<Object> = [];
    try {
      const ids = connection.getPairedDevices();
      for (const id of ids) {
        let name = id;
        try {
          const n = connection.getRemoteDeviceName(id);
          if (n && n.length > 0) {
            name = n;
          }
        } catch (e) {
        }
        const dev = new Map<string, string>();
        dev.set('address', id);
        dev.set('name', name);
        out.push(dev);
      }
    } catch (e) {
    }
    return out;
  }

  static hasPermission(): boolean {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const tokenId = info.appInfo.accessTokenId;
      const status = abilityAccessCtrl.createAtManager()
        .checkAccessTokenSync(tokenId, kPermissionBluetooth);
      return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (e) {
      return false;
    }
  }

  /** 发起 ACCESS_BLUETOOTH 运行时授权，结果经 onPermission 回传 Dart。 */
  private static async requestPermission(): Promise<void> {
    const ctx = WatchLinkServerDispatcher.context;
    if (ctx == null) {
      WatchLinkServerDispatcher.emitPermission(false);
      return;
    }
    try {
      const perms: Array<Permissions> = [kPermissionBluetooth];
      const res = await abilityAccessCtrl.createAtManager()
        .requestPermissionsFromUser(ctx, perms);
      let granted = res.authResults.length > 0;
      for (const r of res.authResults) {
        if (r !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          granted = false;
        }
      }
      WatchLinkServerDispatcher.emitPermission(granted);
    } catch (e) {
      WatchLinkServerDispatcher.emitPermission(false);
    }
  }

  // ---- 回传 ----

  private static emitConnection(connected: boolean, name: string): void {
    const ch = WatchLinkServerDispatcher.channel;
    if (ch == null) {
      return;
    }
    const m = new Map<string, Object>();
    m.set('connected', connected);
    m.set('name', name);
    ch.invokeMethod('onConnection', m);
  }

  private static emitPermission(granted: boolean): void {
    const ch = WatchLinkServerDispatcher.channel;
    if (ch != null) {
      ch.invokeMethod('onPermission', granted);
    }
  }
}

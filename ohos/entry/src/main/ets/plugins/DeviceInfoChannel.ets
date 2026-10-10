import {
  BinaryMessenger,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { deviceInfo } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

/**
 * 设备信息通道（channel: xianyu/device_info），协议对齐 Android 端
 * MainActivity.kt：getDeviceInfo 返回 JSON 字符串（brand/manufacturer/
 * model/market_name/os_version）。反馈后台据此显示「品牌 | 机型」。
 *
 * getInstallerSource（商店渠道判定）与 getStableDeviceId（Widevine 硬件
 * 指纹）为 Android 特有，鸿蒙不实现——Dart 侧 catch 后走 null 兜底，
 * 行为与现状一致。
 */
// ArkTS 禁止无类型对象字面量（arkts-no-untyped-obj-literals），
// JSON 入参必须对应显式声明的 interface。
interface DeviceInfoJson {
  brand: string;
  manufacturer: string;
  model: string;
  market_name: string;
  os_version: string;
}

export class DeviceInfoChannel {
  static attach(messenger: BinaryMessenger, context: common.UIAbilityContext): void {
    const channel = new MethodChannel(messenger, 'xianyu/device_info');
    channel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        switch (call.method) {
          case 'getDeviceInfo':
            result.success(DeviceInfoChannel.json());
            break;
          default:
            result.notImplemented();
        }
      },
    });
  }

  private static json(): string {
    // osFullName 形如 "HarmonyOS 5.1.0"；displayVersion 为系统完整版本号。
    const osFull: string = deviceInfo.osFullName ?? '';
    const osVersion = `${osFull.length > 0 ? osFull : 'HarmonyOS'} (API ${deviceInfo.sdkApiVersion}) · ${deviceInfo.displayVersion}`;
    const info: DeviceInfoJson = {
      brand: deviceInfo.brand,
      manufacturer: deviceInfo.manufacture,
      model: deviceInfo.productModel,
      market_name: deviceInfo.marketName ?? '',
      os_version: osVersion,
    };
    return JSON.stringify(info);
  }
}

/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd.
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

import Log from '@ohos/flutter_ohos/src/main/ets/util/Log';
import { MethodCall } from '@ohos/flutter_ohos';
import { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import Share from './Share';

const TAG = 'MethodCallHandlerImpl';

export default class MethodCallHandlerImpl implements MethodCallHandler {
  private share: Share | null = null;

  constructor(share: Share) {
    this.share = share;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    Log.i(TAG, "onMethodCall step in");
    let method: string = call.method;
    Log.i(TAG, "Received '" + method + "' message.");
    const isWithResult: boolean = call.method.endsWith('WithResult');
    try {
      switch (method) {
        case 'shareUri':
          this.share?.share(call.argument('uri') as string, null, false, result);
          if (!isWithResult) {
            result.success(null);
          }
          break;
        case 'share':
        case 'shareWithResult':
          // 官方 share_plus 10+ Dart 把文件并入 'share' 的 paths/mimeTypes
          // 参数（旧协议才拆 shareFiles）；本插件源自老协议实现，为兼容
          // 13.x 主包按参数路由：带 paths 走文件分享，否则纯文本
          if (call.argument('paths') != null) {
            this.share?.shareFiles(
              call.argument('paths'),
              call.argument('mimeTypes'),
              call.argument('text'),
              call.argument('subject'),
              isWithResult,
              result);
          } else {
            this.share?.share(
              call.argument('text') as string,
              call.argument('subject') as string,
              isWithResult,
              result);
          }
          if (!isWithResult) {
            result.success("dev.fluttercommunity.plus/share/unavailable");
          }
          break;
        case 'shareFiles':
        case 'shareFilesWithResult':
          this.share?.shareFiles(
            call.argument('paths'),
            call.argument('mimeTypes'),
            call.argument('text'),
            call.argument('subject'),
            isWithResult,
            result);
          if (!isWithResult) {
            result.success("dev.fluttercommunity.plus/share/unavailable");
          }
          break;
        default:
          result.notImplemented();
          break;
      }
    } catch (err) {
      Log.e(TAG, 'err:' + JSON.stringify(err));
    }
  }
}

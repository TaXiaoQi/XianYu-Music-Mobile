// 夸克网盘：继承 QuarkUcBase，仅声明品牌与扫码常量。

import 'quark_uc_base.dart';

class QuarkProvider extends QuarkUcBase {
  const QuarkProvider();

  @override
  String get id => 'quark';

  @override
  String get displayName => '夸克网盘';

  @override
  String get apiHost => 'drive-pc.quark.cn';

  @override
  String get webHost => 'pan.quark.cn';

  @override
  String get pr => 'quark';

  @override
  String get uaBrand => 'quark-cloud-drive';

  @override
  String get casHost => 'uop.quark.cn';

  @override
  String get qrContentTemplate =>
      'https://su.quark.cn/4_eMHBJ?token={token}&client_id=532&ssb=weblogin'
      '&uc_param_str=&uc_biz_str=S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1'
      '|OPT:BACK_BTN_STYLE@0';
}

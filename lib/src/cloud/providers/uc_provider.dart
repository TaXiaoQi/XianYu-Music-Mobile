// UC 网盘：继承 QuarkUcBase，仅声明品牌与扫码常量（接口与夸克同构）。

import 'quark_uc_base.dart';

class UcProvider extends QuarkUcBase {
  const UcProvider();

  @override
  String get id => 'uc';

  @override
  String get displayName => 'UC网盘';

  @override
  String get apiHost => 'drive-pc.uc.cn';

  @override
  String get webHost => 'drive.uc.cn';

  @override
  String get pr => 'ucpro';

  @override
  String get uaBrand => 'uc-cloud-drive';

  @override
  String get casHost => 'api.open.uc.cn';

  @override
  String get qrContentTemplate =>
      'https://broccoli.uc.cn/apps/ZY5qIZiK/routes/1hbcQwLhH'
      '?uc_param_str=dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt'
      '&uc_biz_str=S%3Acustom%7CC%3Atitlebar_hover_2'
      '&token={token}&client_id=381&ssb=weblogin';
}

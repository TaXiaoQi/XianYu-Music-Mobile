import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xianyu_music_mobile/src/cloud/providers/http_login_support.dart';

void main() {
  group('parseSpki（天翼 encryptConf.pubKey，base64 X.509 SPKI）', () {
    // encryptConf.do 真实响应样例（1024-bit RSA，e=65537）。
    const b64 =
        'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCZLyV4gHNDUGJMZoOcYauxmNEsKrc0TlLeBEVVIIQNzG4WqjimceOj5R9ETwDeeSN3yejAKLGHgx83lyy2wBjvnbfm/nLObyWwQD/09CmpZdxoFYCH6rdDjRpwZOZ2nXSZpgkZXoOBkfNXNxnN74aXtho2dqBynTw3NFTWyQl8BQIDAQAB';
    const expectN =
        '00992f257880734350624c66839c61abb198d12c2ab7344e52de04455520840dcc6e16aa38a671e3a3e51f444f00de792377c9e8c028b187831f37972cb6c018ef9db7e6fe72ce6f25b0403ff4f429a965dc68158087eab7438d1a7064e6769d7499a609195e838191f3573719cdef8697b61a3676a0729d3c373454d6c9097c05';
    const expectE = '010001';

    test('提取 modulus / exponent', () {
      final (modHex, expHex) = parseSpki(b64);
      // 取证：临时写文件（PowerShell 管道吞测试输出）。
      File(r'C:\Users\小奇\AppData\Local\Temp\m139\spki_actual.txt')
          .writeAsStringSync('mod(len=${modHex.length})=$modHex\nexp=$expHex\n');
      expect(modHex, expectN);
      expect(expHex, expectE);
    });

    test('解析结果可用于 RSA 加密（不抛异常，输出 hex 定长 256）', () {
      final (modHex, expHex) = parseSpki(b64);
      final out = rsaPkcs1Hex('16608240512', modHex, expHex);
      expect(out.length, 256);
      expect(RegExp(r'^[0-9a-f]{256}$').hasMatch(out), isTrue);
    });
  });
}

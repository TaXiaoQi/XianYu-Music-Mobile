// BiliPai 液态玻璃背景着色器。
//
// 与 BiliPai 的 LiquidGlassShader.kt（AGSL）逐行对齐：底栏玻璃 = 轻模糊
// （BiliPai 中档 backdropBlurRadius 仅 4px，由 Dart 侧 compose 的 outer 真高
// 斯承担）+ **边缘 24px 边带内的 SDF 透镜折射**（circleMap 圆弧衰减、SDF
// 外向梯度、向内采样——BiliPai 传负 refractionAmount，边缘往里压）+
// 半透明底色 + 饱和度增益。没有全表面波浪（BiliPai 的
// contentDistortion 默认关闭）、没有 rim/meniscus 高光、shell 无色差
// （"Miuix keeps the shell achromatic"）。
//
// 通过 BackdropFilterLayer + ImageFilter.shader 绑定：着色器第一个 sampler2D
// （uImage）由引擎绑定到该玻璃表面下方的实时背景；FlutterFragCoord() 为
// 屏幕空间物理像素、Y 向下。
//
// 注意：ImageFilter.shader 要求第一个 uniform 为 vec2（uSize，宿主/引擎设为
// 背景纹理物理尺寸），且至少一个 sampler2D 作为输入。

#include <flutter/runtime_effect.glsl>

precision highp float;

// 槽 0-1：uSize —— 背景纹理物理尺寸（全屏），ImageFilter.shader 要求首 uniform 为 vec2。
uniform vec2 uSize;
// 槽 2：槽位保留（BiliPai 的滚动耦合波浪默认关闭，不参与渲染）。
uniform float uScrollOffset;
// 槽 3：折射强度 —— 透镜边缘最大位移（物理像素，Dart 侧已乘 dpr）
//（low 8 / medium 18 / high 24 逻辑像素，对齐 BiliPai refractionAmount 24dp）。
uniform float uRefract;
// 槽 4：色差强度 —— BiliPai shell 无色差（achromatic），运行时恒为 0。
uniform float uChroma;
// 槽 5：槽位保留（主体模糊由 compose outer 真高斯承担）。
uniform float uBlurSigma;
// 槽 6-9：预乘半透明底色（BiliPai surfaceAlpha 0.40 + 白 overlay 的等效物）。
uniform vec4 uBackgroundColor;
// 槽 10：槽位保留（BiliPai 无 rim 高光）。
uniform float uSpecular;
// 槽 11：圆角半径（物理像素，胶囊取短边一半）。
uniform float uRadius;
// 槽 12-13：玻璃表面左上角在屏幕空间的物理像素位置。
uniform vec2 uGlassOrigin;
// 槽 14-15：玻璃表面物理像素尺寸。
uniform vec2 uGlassSize;
// 槽 16：边带厚度（物理像素；BiliPai refractionHeight 中档 24px）。
uniform float uEdgeAmount;
// 槽 17：饱和度增益（BiliPai 中档 1.5）。
uniform float uSaturation;
// 槽 18：径向深度效应（BiliPai/Halcyon 水滴 depthEffect=true）：把径向
// 方向掺进 SDF 梯度，让中心内容也参与「鼓起」折射——水滴压到内容上
// 立刻有放大镜观感（无此项时，向内采样存在 ~A/2 的跳过区，内容要没入
// 近半半径才出现在边带里）。
uniform float uDepthEffect;

// 引擎绑定的实时背景（采样器 0）。
uniform sampler2D uImage;

out vec4 fragColor;

vec2 texel() {
  return 1.0 / max(uSize, vec2(1.0));
}

vec3 tapRGB(vec2 screenPos) {
  return texture(uImage, clamp(screenPos * texel(), 0.0, 1.0)).rgb;
}

void main() {
  vec2 p = FlutterFragCoord().xy;

  // 玻璃局部坐标（中心为原点）——BiliPai 的 p = fragCoord - center 语义。
  vec2 c = p - (uGlassOrigin + uGlassSize * 0.5);

  // 圆角矩形 SDF（BiliPai 同款；size 取半尺寸，q = |p| - (half - r)）。
  vec2 half2size = uGlassSize * 0.5;
  vec2 q = abs(c) - max(half2size - vec2(uRadius), vec2(0.0));
  float sd = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - uRadius;

  // —— 边缘透镜折射（BiliPai Lens.kt 原版公式逐行对齐）——
  // 剖面 = circleMap(1 - depth/H) = 1 - sqrt(1 - x²)：位移在贴边处最大、
  // 向内沿圆弧快速衰减（半带处仅 ~13%、内界斜率为 0 平滑归零）。这是
  // BiliPai「只有贴边一圈在弯」观感的来源；不能换成 edge² 二次衰减
  //（中带位移偏大，会「还没靠近就开始折射」）。
  vec2 uv = p;
  if (sd < 0.0 && uEdgeAmount > 0.0 && uRefract > 0.0) {
    float depth = -sd;
    if (depth < uEdgeAmount) {
      float x = 1.0 - depth / uEdgeAmount;
      float d = (1.0 - sqrt(max(0.0, 1.0 - x * x))) * uRefract;
      if (d > 0.001) {
        // SDF 外向梯度（BiliPai gradSdRoundedRect 原版）：直边区垂直于最近
        // 边、圆角区沿角心径向。不能用 normalize(c / size)——长条胶囊上
        // 方向会斜掉，折射位置/大小对不上、相邻内容被横向串色。
        float gradRadius = min(uRadius * 1.5, min(half2size.x, half2size.y));
        vec2 cornerCoord = abs(c) - max(half2size - vec2(gradRadius), vec2(0.0));
        vec2 direction;
        if (cornerCoord.x >= 0.0 || cornerCoord.y >= 0.0) {
          direction = sign(c) * normalize(max(cornerCoord, vec2(0.0)));
        } else {
          float gradX = step(cornerCoord.y, cornerCoord.x);
          direction = sign(c) * vec2(gradX, 1.0 - gradX);
        }
        // depthEffect（Halcyon Lens.kt：grad = normalize(gradSd +
        // depthEffect·normalize(centeredCoord))）：掺入径向分量，中心内容
        // 也被弯折，水滴「鼓包/放大镜」观感的来源。c 在中心为 0 向量，
        // GLSL normalize(0) 未定义，用长度下限兜底。
        direction = normalize(
          direction + uDepthEffect * (c / max(length(c), 1e-3)));
        // BiliPai 传负 refractionAmount（Lens.kt：-scaledRefractionAmount），
        // 即 refractedCoord = coord − d·grad：向内采样，边缘显示往里更深处
        // 的内容（往里压的透镜观感）；往外采样方向就反了。
        uv -= direction * d;
      }
    }
  }

  // 采样点只 clamp 到屏幕内：向内折射采样的是玻璃下方的内容，正常不会
  // 越界；clamp 只做屏幕边界兜底。
  vec2 minUV = vec2(0.0);
  vec2 maxUV = max(uSize - vec2(1.0), vec2(1.0));
  vec3 sampled = tapRGB(clamp(uv, minUV, maxUV));

  // 亚像素色差微颤（BiliPai shell 恒为 0，保留参数位）。
  if (uChroma > 0.001) {
    float ab = uChroma * 0.35;
    vec2 abDir = vec2(ab * 4.0, ab * 1.5);
    sampled.r = tapRGB(clamp(uv + abDir, minUV, maxUV)).r;
    sampled.b = tapRGB(clamp(uv - abDir, minUV, maxUV)).b;
  }

  // 饱和度增益：透过玻璃的色彩更鲜艳水润（BiliPai 中档 1.5，Haze 材质等效）。
  float luma = dot(sampled, vec3(0.2126, 0.7152, 0.0722));
  sampled = mix(vec3(luma), sampled, uSaturation);

  // 与半透明底色混合保证可读性（BiliPai 同款：sampled*(1-a) + bg）。
  vec3 result = sampled * (1.0 - uBackgroundColor.a) + uBackgroundColor.rgb;

  // 槽位保留：Impeller 会剔除未引用的 uniform，导致后续槽位整体错位；
  // 显式乘 0 占位（uScrollOffset/uBlurSigma/uSpecular 本配方不参与渲染）。
  result += vec3((uScrollOffset + uBlurSigma + uSpecular) * 0.0);

  // 抖动（dither）：每物理像素 ±1/255 随机偏移，打破 8-bit 量化的色阶断层。
  // 静态噪声，肉眼只会觉得渐变更顺滑。
  result += (fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453) - 0.5) * (2.0 / 255.0);

  fragColor = vec4(result, 1.0);
}

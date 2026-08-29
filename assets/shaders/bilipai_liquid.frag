// BiliPai 液态玻璃背景着色器。
//
// 用于迷你播放条与悬浮底栏。渲染管线：本 shader 作为 compose 的 inner 先跑，
// 对「原始清晰背景」做「边缘窄带内的环形涟漪 + 二次曲线透镜折射（弯折位移）
// + 饱和度增益 + 半透明底色混合」；随后引擎的 outer 真高斯（ImageFilter.blur）
// 整体糊上去——模糊不撤销位移，边缘拉弯的内容糊后仍可见，中心则是纯净高斯。
// shader 内不承担模糊（uBlurSigma 恒为 0，单点采样）。
//
// 通过 BackdropFilterLayer + ImageFilter.shader 绑定：着色器第一个 sampler2D
// （uImage）由引擎绑定到该玻璃表面下方的实时背景；FlutterFragCoord() 为
// 屏幕空间物理像素、Y 向下。
//
// 坐标系约定（与 liquid_glass_widgets 的 liquid_glass_final_render.frag 一致）：
//   FlutterFragCoord() 是屏幕空间物理像素；uSize == 全屏物理像素尺寸；
//   uGlassOrigin / uGlassSize 为玻璃表面在屏幕空间的物理像素位置/尺寸，
//   用于把片段坐标换算到玻璃局部空间，精确计算到玻璃胶囊边缘的距离（SDF）。
//
// 注意：ImageFilter.shader 要求第一个 uniform 为 vec2（uSize，宿主/引擎设为
// 背景纹理物理尺寸），且至少一个 sampler2D 作为输入。Flutter 3.46+ 已在顶点
// 阶段统一 GLES 纹理为 top-down，采样无需再手动翻转 Y。

#include <flutter/runtime_effect.glsl>

precision highp float;

// 槽 0-1：uSize —— 背景纹理物理尺寸（全屏），ImageFilter.shader 要求首 uniform 为 vec2。
uniform vec2 uSize;
// 槽 2：全局滚动偏移，驱动波浪相位。
uniform float uScrollOffset;
// 槽 3：折射强度（波浪位移幅度，0=无波浪）。
uniform float uRefract;
// 槽 4：色差强度（RGB 通道分离幅度）。
uniform float uChroma;
// 槽 5：shader 内微模糊 sigma（当前恒为 0，单点采样——主体模糊由 Dart 侧
// compose 的 outer 真高斯承担，shader 不做模糊以免出位移重影）。
uniform float uBlurSigma;
// 槽 6-9：预乘半透明底色（保证可读性，BiliPai 同款混合）。
uniform vec4 uBackgroundColor;
// 槽 10：表面流动高光强度（滚动时在玻璃上扫过的反光带）。
uniform float uSpecular;
// 槽 11：胶囊圆角半径（物理像素），用于圆角矩形 SDF 计算真实边缘距离。
uniform float uRadius;
// 槽 12-13：玻璃表面左上角在屏幕空间的物理像素位置。
uniform vec2 uGlassOrigin;
// 槽 14-15：玻璃表面物理像素尺寸。
uniform vec2 uGlassSize;
// 槽 16：边缘透镜折射幅度（物理像素）——BiliPai 同款二次曲线边带折射的
// 最大位移量，内容在玻璃边界被外向拉出弯折，静止也可见。
uniform float uEdgeAmount;
// 槽 17：饱和度增益（BiliPai balanced 档 1.5，水晶透亮感的核心来源）。
uniform float uSaturation;

// 引擎绑定的实时背景（采样器 0）。
uniform sampler2D uImage;

out vec4 fragColor;

vec4 tap(vec2 uv) {
  return texture(uImage, clamp(uv, 0.0, 1.0));
}

// 稳定 hash（大坐标下不丢精度），用于每像素旋转模糊采样环。
float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

// 13-tap 双环泊松模糊核 + 每像素随机旋转。
// 只承担 σ1.5 级微模糊（平滑引擎双线性采样与轻微放大噪点）；每像素旋转
// 把离散 tap 能量抖成均匀颗粒，任何 sigma 下都不出现结构性位移副本。
vec4 blurAt(vec2 pos, vec2 texel) {
  float s = max(uBlurSigma, 0.0);
  if (s < 0.5) {
    return tap(pos * texel);
  }
  vec2 c = pos * texel;
  float ang = hash12(pos) * 6.2831853;
  float ca = cos(ang);
  float sa = sin(ang);
  mat2 rot = mat2(ca, -sa, sa, ca);
  vec2 step1 = rot * (s * texel);
  vec2 step2 = rot * (s * 2.0 * texel);
  vec2 stepD = rot * (s * 1.414 * texel);
  vec4 outColor = tap(c) * 0.16;
  outColor += tap(c + vec2(step1.x, 0.0)) * 0.09;
  outColor += tap(c - vec2(step1.x, 0.0)) * 0.09;
  outColor += tap(c + vec2(0.0, step1.y)) * 0.09;
  outColor += tap(c - vec2(0.0, step1.y)) * 0.09;
  outColor += tap(c + vec2(stepD.x, stepD.y)) * 0.075;
  outColor += tap(c - vec2(stepD.x, stepD.y)) * 0.075;
  outColor += tap(c + vec2(stepD.x, -stepD.y)) * 0.075;
  outColor += tap(c - vec2(stepD.x, -stepD.y)) * 0.075;
  outColor += tap(c + vec2(step2.x, 0.0)) * 0.045;
  outColor += tap(c - vec2(step2.x, 0.0)) * 0.045;
  outColor += tap(c + vec2(0.0, step2.y)) * 0.045;
  outColor += tap(c - vec2(0.0, step2.y)) * 0.045;
  return outColor;
}

// 圆角矩形 SDF：p 到胶囊边缘的有符号距离（内部为负，含圆角端）。
float rrectSDF(vec2 p, vec2 size, float r) {
  vec2 q = abs(p - size * 0.5) - (size * 0.5 - r);
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 texel = 1.0 / max(uSize, vec2(1.0));

  // 玻璃局部坐标（物理像素，0,0 = 胶囊左上角）。
  vec2 g = p - uGlassOrigin;

  // 到胶囊边缘的真实距离（0=边缘，向内部增大，含圆角端）。
  float dEdge = -rrectSDF(g, uGlassSize, uRadius);

  // —— 边缘窄带：固定厚度边带内二次衰减 ——
  // 小表面（迷你条 58px）上 0.30 倍边带会侵入中部造成「糊+清晰」混合重影，
  // 收窄到 0.20 倍（8-22px），中部主体保持均匀磨砂。
  float band = clamp(uGlassSize.y * 0.20, 8.0, 22.0);
  float edgeB = clamp((band - dEdge) / band, 0.0, 1.0);
  float edgeB2 = edgeB * edgeB;

  vec2 pc = (g - uGlassSize * 0.5) / max(uGlassSize, vec2(1.0));
  vec2 dirOut = pc / max(length(pc), 1e-4); // 中心退化为零向量，防 NaN。

  // —— 液态感 1：边缘涟漪（以边缘为波源的环形波，沿法线推进）——
  // 波长 ~14px（2π/0.45），边带内能看到 1-2 道波峰；双频叠加让波形不呆板，
  // 滚动时波纹从边缘向内滚动。作用对象是模糊后背景，梯度柔和，位移幅度
  // 加大到 ~5px 才有可见的液面涌动感。edgeB² 门控：中部纹丝不动。
  float t = uScrollOffset * 0.008;
  float ripple = sin(dEdge * 0.45 - t * 2.4) * 0.62 + sin(dEdge * 0.95 + t * 1.6) * 0.38;
  vec2 wave = dirOut * ripple * uRefract * 34.0 * edgeB2;

  // —— 液态感 2：边缘透镜折射——
  // 沿外向法线向外偏移采样：边界处位移最大、向内快速收敛，玻璃边界内容
  // 被「拉出弯折」，呈现凸透镜观感；静止也可见。
  vec2 edgeRefract = dirOut * edgeB2 * uEdgeAmount;

  vec2 offset = wave + edgeRefract;

  // —— 主体模糊来自 Dart 侧 compose 的 inner 真高斯（ImageFilter.blur），
  // shader 采到的已是模糊后背景；这里只做 σ1.5 微模糊平滑引擎的双线性采样。
  // tap 核在 σ6 逻辑（物理 18px）下必然产生离散位移副本（实测重影），
  // 所以 shader 绝不承担大 sigma 模糊。
  vec2 gOff = p + offset;
  vec4 sampled = blurAt(gOff, texel);
  // 色差（当前全档归零，参数位保留）：R 前移、B 后移，作用于模糊后背景。
  if (uChroma > 0.001) {
    vec2 ab = vec2(uChroma * 4.5, uChroma * 1.6);
    sampled.r = tap(gOff + ab).r;
    sampled.b = tap(gOff - ab).b;
  }

  // 饱和度增益（BiliPai 同款 1.5）：水晶透亮感的核心来源，让透过玻璃的
  // 背景色彩鲜艳水润；在底色混合前施加，避免冲淡 tint 本身。
  float luma = dot(sampled.rgb, vec3(0.2126, 0.7152, 0.0722));
  sampled.rgb = mix(vec3(luma), sampled.rgb, uSaturation);

  // 与半透明底色混合保证可读性（BiliPai 同款：sampled*(1-a) + bg）。
  vec4 result = sampled * (1.0 - uBackgroundColor.a) + uBackgroundColor;

  // —— 玻璃自发光：克制、非图案化。液态感来自折射位移 + 边缘光 ——
  // 背景细节量：以当前采样点与 ~2.5px 外一点的差值衡量背景是否有内容。
  // 纯色/空白背景为 0 → 抑制边缘光与液面高光，避免「没内容时边被刷白」；
  // 有内容（列表/壁纸/渐变）时 > 0 → 液态边缘光正常显现。
  vec2 probe = gOff * texel;
  vec4 sharp = tap(probe);
  vec4 far = tap(probe + vec2(2.5, 0.0) * texel);
  float detail = abs(sharp.r - far.r) + abs(sharp.g - far.g) + abs(sharp.b - far.b);
  float detailI = clamp(detail * 5.0, 0.0, 1.0);

  // 内圈柔光（rim）：贴近胶囊边缘的细亮带，给玻璃「厚透镜」边界；仅背景
  // 有内容细节时显现（纯色背景下不把边刷白）。
  result.rgb += exp(-dEdge / max(uGlassSize.y * 0.03, 1.0)) * uSpecular * 0.7 * detailI;
  // 顶部液面高光（meniscus）：一条柔和亮线，液体感的关键（玻璃局部上边缘）；
  // 保留微弱底值以维持液体体积感，空白背景下不会形成白色亮带。
  result.rgb += exp(-g.y / max(uGlassSize.y * 0.18, 1.0)) * 0.12 * (0.35 + 0.65 * detailI);
  // 底部轻微压暗（液体聚集，玻璃局部下边缘）。
  result.rgb -= exp(-(uGlassSize.y - g.y) / max(uGlassSize.y * 0.14, 1.0)) * 0.10;

  fragColor = result;
}

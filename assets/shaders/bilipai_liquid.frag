// BiliPai 液态玻璃背景着色器（移植自 jay3-yy/BiliPai FullBarLiquidGlassModifier）。
//
// 用于迷你播放条与悬浮底栏：对实时背景做「滚动驱动的波浪扭曲 + RGB 色差 +
// 轻量高斯模糊 + 半透明底色混合」，呈现 BiliPai 的液态玻璃流动感。
//
// 通过 BackdropFilterLayer + ImageFilter.shader 绑定：着色器第一个 sampler2D
// （uImage）由引擎绑定到该玻璃表面下方的实时背景；FlutterFragCoord() 为
// 物理像素、Y 向下。
//
// 坐标系约定（与 liquid_glass_widgets 的 liquid_glass_final_render.frag 一致）：
//   FlutterFragCoord() 是屏幕空间物理像素；uSize == 全屏物理像素尺寸；
//   screenUV = fragCoord / uSize 采样背景的屏幕位置。
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
// 槽 5：轻量模糊 sigma（物理像素）。
uniform float uBlurSigma;
// 槽 6-9：预乘半透明底色（保证可读性，BiliPai 同款混合）。
uniform vec4 uBackgroundColor;
// 槽 10：表面流动高光强度（滚动时在玻璃上扫过的反光带）。
uniform float uSpecular;

// 引擎绑定的实时背景（采样器 0）。
uniform sampler2D uImage;

out vec4 fragColor;

vec4 tap(vec2 uv) {
  return texture(uImage, clamp(uv, 0.0, 1.0));
}

// 以物理像素 pos 为中心做 5-tap 十字轻量高斯模糊（中心 0.4 + 四邻 0.15）。
// sigma < 0.5 时退化为单点采样（零模糊开销）。
vec4 blurAt(vec2 pos, vec2 texel) {
  float s = max(uBlurSigma, 0.0);
  if (s < 0.5) {
    return tap(pos * texel);
  }
  vec2 step = s * texel;
  vec2 c = pos * texel;
  vec4 outColor = tap(c) * 0.4;
  outColor += tap(c + vec2(step.x, 0.0)) * 0.15;
  outColor += tap(c - vec2(step.x, 0.0)) * 0.15;
  outColor += tap(c + vec2(0.0, step.y)) * 0.15;
  outColor += tap(c - vec2(0.0, step.y)) * 0.15;
  return outColor;
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 texel = 1.0 / max(uSize, vec2(1.0));

  // BiliPai 滚动波浪扭曲：沿滚动方向传播的连贯波（纵向主波 + 低幅横向扰动），
  // 滚动时内容在玻璃下「流动」，静止时保留一层静谧的液面涟漪。
  float scrollProgress = uScrollOffset * 0.008;
  float mainWave = sin(p.y * 0.018 - scrollProgress);
  float sideWave = sin(p.x * 0.006 + scrollProgress * 0.4);
  float wave = mainWave + sideWave * 0.35;
  // 位移：纵向为主（与滚动同向），横向轻微，幅度随 uRefract 缩放。
  vec2 offset = vec2(wave * 0.5, wave) * uRefract * 40.0;

  // RGB 色差：R 前移、B 后移，形成玻璃透镜边缘的可见分光（不过度，避免噪点感）。
  vec2 ab = vec2(uChroma * 4.5, uChroma * 1.6);
  vec2 rOff = p + offset + ab;
  vec2 gOff = p + offset;
  vec2 bOff = p + offset - ab;

  float r = blurAt(rOff, texel).r;
  vec4 gs = blurAt(gOff, texel);
  float b = blurAt(bOff, texel).b;
  vec4 sampled = vec4(r, gs.g, b, gs.a);

  // 与半透明底色混合保证可读性（BiliPai 同款：sampled*(1-a) + bg）。
  vec4 result = sampled * (1.0 - uBackgroundColor.a) + uBackgroundColor;

  // —— 玻璃自发光 / 自阴影：不依赖背景内容，纯色白底上也有液面观感 ——
  float dTop = p.y;
  float dBottom = uSize.y - p.y;
  float dEnd = min(p.x, uSize.x - p.x);
  float dEdge = min(min(dTop, dBottom), dEnd);

  // 液面阴影涟漪：随主波起伏的柔和明暗，白底上也能看到「涟漪在流动」。
  result.rgb -= mainWave * 0.04;
  // 边缘柔和阴影（向内渐深）：赋予玻璃厚度与曲率，浅色背景上勾勒出胶囊轮廓。
  float edgeShade = 0.10 * pow(clamp(1.0 - dEdge / (uSize.y * 0.22), 0.0, 1.0), 2.0);
  result.rgb -= edgeShade;
  // 顶部液面高光（meniscus）：柔和提亮，给玻璃体积感。
  result.rgb += exp(-dTop * 3.0 / uSize.y) * 0.10;
  // 滚动流动高光带：随波浪相位在表面扫过（有内容背景时最明显）。
  float spec = pow(0.5 + 0.5 * sin(scrollProgress * 1.1 + (p.x + p.y) * 0.012), 6.0);
  result.rgb += spec * uSpecular;

  fragColor = result;
}

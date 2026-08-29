// 滚动驱动的液态波浪扭曲着色器。
//
// 参考 BiliPai (jay3-yy/BiliPai) 的 FullBarLiquidGlassModifier 思路：
// 滚动偏移作为正弦波相位，滚动时背景波纹流动，静止时保留静态纹理。
// 仅对传入的玻璃区域（底栏/迷你播放条所在矩形）施加扭曲，其余原样采样，
// 由玻璃表面的 BackdropFilter 再模糊扭曲后的背景，形成"模糊 + 液态波浪"。
//
// 坐标系：FlutterFragCoord() 为物理像素、Y 向下；纹理 uv 与之一致（Flutter 3.46+
// 已统一 GLES/Metal/Vulkan 为 top-down），无需手动翻转 Y。

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform sampler2D uImage;   // 背景纹理（AnimatedSampler 捕获的内容）
uniform vec2 uSize;         // 逻辑像素尺寸
uniform vec2 uResolution;   // 物理像素尺寸
uniform float uScrollOffset;// 全局滚动偏移
uniform vec4 uRect0;        // 玻璃区域（物理像素 x0,y0,x1,y1），未启用则 z<=0
uniform vec4 uRect1;
uniform vec4 uRect2;
uniform float uRefract;     // 折射强度
uniform float uChroma;      // 色差强度

out vec4 fragColor;

// 玻璃区域掩码：矩形内 1，边缘外 16px 平滑过渡到 0（r=0 表示该区域未启用）。
float rectMask(vec2 p, vec4 r) {
  if (r.z <= 0.0) return 0.0;
  float dx = max(r.x - p.x, p.x - r.z);
  float dy = max(r.y - p.y, p.y - r.w);
  float d = max(dx, dy);
  return 1.0 - smoothstep(0.0, 16.0, max(d, 0.0));
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 uv = p / max(uResolution, vec2(1.0));

  float glass =
      max(max(rectMask(p, uRect0), rectMask(p, uRect1)), rectMask(p, uRect2));

  vec4 base = texture(uImage, uv);

  // 滚动驱动的波浪扭曲（参考 BiliPai FullBarLiquidGlassModifier）。
  float scroll = uScrollOffset * 0.008;
  float waveX = sin(uv.x * 28.0 + scroll) * 0.6;
  float waveY = cos(uv.y * 20.0 + scroll * 0.5) * 0.8;
  float wave = waveX * waveY + sin(scroll * 0.3) * 0.4;
  vec2 offset = vec2(wave * 0.4, wave * 1.2) * uRefract * 50.0;
  vec2 o = offset / uResolution;

  // 向玻璃中心外辐射的 RGB 通道分离（色差）。
  vec2 dir = uv - vec2(0.5);
  dir /= max(length(dir), 0.0001);
  vec2 ch = dir * uChroma / uResolution;

  vec4 waved;
  waved.r = texture(uImage, uv + o + ch * 2.0).r;
  waved.g = texture(uImage, uv + o).g;
  waved.b = texture(uImage, uv + o - ch * 2.0).b;
  waved.a = base.a;

  fragColor = mix(base, waved, glass);
}

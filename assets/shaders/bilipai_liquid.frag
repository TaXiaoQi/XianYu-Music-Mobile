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
// 槽 18：径向深度效应（水滴专用，玻璃壳恒为 0）：两个作用——
// ① 把径向方向掺进边带 SDF 梯度，让中心内容也参与「鼓起」折射——
//    水滴压到内容上立刻有放大镜观感（无此项时，向内采样存在 ~A/2 的
//    跳过区，内容要没入近半半径才出现在边带里）；
// ② >0 时启用全表面凸透镜放大：采样坐标往圆心收，水滴内部整个背景
//    被放大（B 站水滴「折射整个背景」的放大镜观感来源）。
uniform float uDepthEffect;
// 槽 19：uTime —— 持续涟漪时间（秒）。给采样点加低频正弦微位移，让玻璃
// 自身始终带轻微液态流动（静止/拖拽/滚动皆可见），不是单纯停在模糊上。
uniform float uTime;
// 槽 20：连续曲率（squircle）指数，与 Dart appSquirclePath 同源：
// 胶囊/圆形传 2.0 退化为精确圆，非胶囊恒 2.2（标定见 squircle.dart）
uniform float uSquircleN;
// 槽 21-22：水滴透镜圆心（屏幕物理像素；底栏玻璃专用，其余玻璃实例恒 0）。
uniform vec2 uDropletCenter;
// 槽 23：水滴透镜半径（物理像素；<=0 透镜关闭，圆外像素完全不变）。
uniform float uDropletRadius;
// 槽 24：水滴全表面放大深度（0..1，随按压 mf 渐强）。
uniform float uDropletDepth;
// 槽 25：水滴边带厚度（物理像素，BiliPai LiquidIndicator 10/56·d）。
uniform float uDropletBand;
// 槽 26：水滴边带折射量（物理像素，BiliPai 14/56·d）。
uniform float uDropletRefract;
// 槽 27：水滴色差强度（用户档位 dropletChroma）。
uniform float uDropletChroma;
// 槽 28：栏内容纹理开关（1=采样器 1 已绑定 tabRow 捕获图）。
uniform float uIconOn;
// 槽 29-30：栏内容纹理左上角（屏幕物理像素，与 uGlassOrigin 同一坐标系）。
uniform vec2 uIconOrigin;
// 槽 31-32：栏内容纹理尺寸（物理像素；捕获 pixelRatio 与 viewDpr 一致）。
uniform vec2 uIconSize;
// 槽 33：水滴色散外溢带（物理像素，BiliPai chromaticEdgeBand 同构）=
// 水滴当前半径 - 栏轨半高（水滴超出栏缘的溢出量；未溢出为 0=无色散）。
// 色散权重按「到水滴上/下缘的纵向距离 < 外溢带」smoothstep 衰减——彩虹
// 只出现在水滴上下缘外溢出栏面的月牙带（BiliPai dock 指示器同构），
// 替代通用透镜的鞍形权重（鞍形在上下弧 dc.x·dc.y≈0 处恒为零，水滴的
// 彩虹弧会被完全杀掉）。
uniform float uDropletGapBand;
// 槽 34：水滴胶囊横向半长（物理像素；<= 纵向半径时退化为圆）。
// BiliPai LiquidIndicator 是贴合栏轨的 stadium：横向绽放全量、纵向贴近
// 栏高，比正圆更契合底栏。
uniform float uDropletHalfW;

// 引擎绑定的实时背景（采样器 0）。
uniform sampler2D uImage;
// 栏内容捕获图（采样器 1，Dart 侧 setImageSampler(1) 绑定）：tabRow
//（图标+文字）的 RepaintBoundary toImage 产物。BiliPai combinedBackdrop
//（materialBackdrop + tabsBackdrop）的 Flutter 等价物——嵌套 backdrop
// 采不到栏面玻璃与图标，透镜要折射「整个底部栏」必须显式喂纹理。
uniform sampler2D uIconTex;

out vec4 fragColor;

vec2 texel() {
  return 1.0 / max(uSize, vec2(1.0));
}

vec3 tapRGB(vec2 screenPos) {
  return texture(uImage, clamp(screenPos * texel(), 0.0, 1.0)).rgb;
}

// 玻璃面采样：blur 后的 backdrop → 饱和度增益 → 混半透明底色。
// 水滴透镜折射的就是这个面（BiliPai lens() 采样 dock 玻璃面同构）——
// 弯进圆内的是含模糊与白雾的栏面，不是原始页面内容。
vec3 glassFace(vec2 uv) {
  vec2 mn = vec2(0.0);
  vec2 mx = max(uSize - vec2(1.0), vec2(1.0));
  vec3 s = tapRGB(clamp(uv, mn, mx));
  float luma = dot(s, vec3(0.2126, 0.7152, 0.0722));
  s = mix(vec3(luma), s, uSaturation);
  return s * (1.0 - uBackgroundColor.a) + uBackgroundColor.rgb;
}

// 水滴透镜的组合采样面 = 玻璃面 + 栏内容（图标/文字）。
// toImage 产物为预乘 alpha：out = bg*(1-a) + premul.rgb。图标不经
// 饱和度/tint（BiliPai tabsBackdrop 回放同构：捕获是原始图标色）。
vec3 dropletFace(vec2 uv) {
  vec3 s = glassFace(uv);
  if (uIconOn > 0.5) {
    vec2 icUv = (uv - uIconOrigin) / max(uIconSize, vec2(1.0));
    vec4 ic = texture(uIconTex, clamp(icUv, vec2(0.0), vec2(1.0)));
    s = s * (1.0 - ic.a) + ic.rgb;
  }
  return s;
}

void main() {
  vec2 p = FlutterFragCoord().xy;

  // 玻璃局部坐标（中心为原点）——BiliPai 的 p = fragCoord - center 语义。
  vec2 c = p - (uGlassOrigin + uGlassSize * 0.5);

  // 连续曲率（superellipse）SDF：零线与 Dart squircle 裁剪路径精确重合
  //（0.88 只缩放梯度≈带厚，不移动边界）。曾用圆角矩形 SDF——角部弧线
  // 与 squircle 裁剪边错开数像素，深色下折射带在角部读成第二道「方角」
  vec2 half2size = uGlassSize * 0.5;
  vec2 q = abs(c) - max(half2size - vec2(uRadius), vec2(0.0));
  vec2 qq = max(q, vec2(0.0));
  float corner =
      pow(pow(qq.x, uSquircleN) + pow(qq.y, uSquircleN), 1.0 / uSquircleN) -
      uRadius;
  float sd = corner * 0.88 + min(max(q.x, q.y), 0.0);

  // —— 边缘透镜折射（BiliPai Lens.kt 原版公式逐行对齐）——
  // 剖面 = circleMap(1 - depth/H) = 1 - sqrt(1 - x²)：位移在贴边处最大、
  // 向内沿圆弧快速衰减（半带处仅 ~13%、内界斜率为 0 平滑归零）。这是
  // BiliPai「只有贴边一圈在弯」观感的来源；不能换成 edge² 二次衰减
  //（中带位移偏大，会「还没靠近就开始折射」）。
  vec2 uv = p;

  // —— 全表面凸透镜放大（先做，边带折射在最终屏幕空间全强度作用）——
  // depthEffect>0 的水滴：采样坐标往圆心收，内部整个背景被放大（B 站
  // 水滴「折射整个背景」的观感来源）；玻璃壳 depthEffect=0 不受影响。
  // 系数 0.40：depthEffect=1 时 mix 0.40（缘部采样收到 0.6r，约放大
  // 1.67 倍，「整个圆内都在折射」的透镜感更强）；上限 0.5 防过度畸变
  if (uDepthEffect > 0.0 && sd < 0.0) {
    vec2 centerUV = uGlassOrigin + uGlassSize * 0.5;
    uv = mix(uv, centerUV, min(uDepthEffect * 0.40, 0.5));
  }

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

  // 持续涟漪已移除（BiliPai 透镜是静态的，无时间驱动波）：此前的 uTime
  // 行进波会把按住/拖动时折叠进边带的内容（图标/文字）撕成随时间晃动的
  // 碎片，且与静止冻结抓屏（blit 无动画）互相矛盾。
  // 槽 19 uTime 保留占位（Impeller 剔除未引用 uniform 会导致槽位错位）。
  uv -= vec2(0.0, uTime * 0.0);

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

  // —— 水滴透镜（BiliPai LiquidLens 同构，底栏玻璃专用）——
  // 胶囊区域内像素改为采样「放大+边带弯折后的组合面」（dropletFace =
  // 玻璃面 + 栏内容图标）：折射覆盖整个底部栏（BiliPai combinedBackdrop
  // 同构）。区域外像素完全不变。
  if (uDropletRadius > 0.5) {
    vec2 dc = p - uDropletCenter;
    // 胶囊 SDF（BiliPai 指示器 stadium 同构）：横向半长
    // max(uDropletHalfW, r)、纵向半径 r，两端相切圆心距 halfW-r；
    // halfW <= r 退化为圆（sd = length(dc) - r）
    float halfW = max(uDropletHalfW, uDropletRadius);
    float coreX = max(abs(dc.x) - (halfW - uDropletRadius), 0.0);
    float coreLen = max(length(vec2(coreX, dc.y)), 1e-3);
    float sd = coreLen - uDropletRadius;
    if (sd < 0.0) {
      vec2 duv = p;
      // 全表面放大：采样坐标往水滴中心收（0.40 系数与壳层 depthEffect
      // 同源），depth=1 时缘部采样收到 0.6r，约放大 1.67 倍
      if (uDropletDepth > 0.0) {
        duv = mix(p, uDropletCenter, min(uDropletDepth * 0.40, 0.5));
      }
      // 边带折射：贴边 band 宽内沿 SDF 外向梯度向内采样，剖面 circleMap
      //（1 - sqrt(1-x²)），与壳层边带同一公式——位移贴边最大、向内
      // 沿弧快速衰减。dsh 同时驱动光谱色散幅度（BiliPai：
      // dispersedCoord = d·grad·intensity，色散随折射深度走）
      float dsh = 0.0;
      vec2 bendDir = vec2(0.0);
      float fromEdge = -sd;
      if (uDropletBand > 0.0 && uDropletRefract > 0.0 &&
          fromEdge < uDropletBand) {
        float x = 1.0 - fromEdge / uDropletBand;
        dsh = (1.0 - sqrt(max(0.0, 1.0 - x * x))) * uDropletRefract;
        if (dsh > 0.001) {
          // 胶囊 SDF 外向梯度（BiliPai gradSdRoundedRect 同构）：圆端区
          // 沿端心径向，直边区垂直于边
          bendDir = (coreX > 0.0)
              ? vec2(sign(dc.x) * coreX, dc.y) / coreLen
              : vec2(0.0, sign(dc.y));
          duv -= bendDir * dsh;
        }
      }
      // 光谱色散（BiliPai dock 指示器 chromaticEdgeBand 同构）：沿折射方向
      // 按 7 谱档位（红→紫，±1/±⅔/±⅓）各采一次再按通道权重叠加。权重 =
      // 1 - smoothstep(gapBand-1, gapBand, 纵向缘距)：彩虹只集中在水滴
      // 上下缘超出栏面的月牙带（BiliPai 水滴顶部/底部彩虹弧的来源），
      // 栏内区域无色散保持白玻璃面纯净。gapBand<=0（未溢出栏轨）无色散
      vec3 droplet;
      if (uDropletChroma > 0.001 && dsh > 0.001 && uDropletGapBand > 0.5) {
        vec2 dir = (coreX > 0.0)
            ? vec2(sign(dc.x) * coreX, dc.y) / coreLen
            : vec2(0.0, sign(dc.y));
        float edgeDist = uDropletRadius - abs(dc.y);
        float dispW =
            1.0 - smoothstep(uDropletGapBand - 1.0, uDropletGapBand, edgeDist);
        vec2 off = dir * (dsh * uDropletChroma * dispW);
        vec3 red = dropletFace(duv + off);
        vec3 orange = dropletFace(duv + off * (2.0 / 3.0));
        vec3 yellow = dropletFace(duv + off * (1.0 / 3.0));
        vec3 green = dropletFace(duv);
        vec3 cyan = dropletFace(duv - off * (1.0 / 3.0));
        vec3 blue = dropletFace(duv - off * (2.0 / 3.0));
        vec3 purple = dropletFace(duv - off);
        droplet = vec3(
          (red.r + orange.r + yellow.r) / 3.5 + purple.r / 7.0,
          orange.g / 7.0 + (yellow.g + green.g + cyan.g) / 3.5,
          (cyan.b + blue.b + purple.b) / 3.0
        );
      } else {
        droplet = dropletFace(duv);
      }
      result = droplet;
    }
  }

  // 槽位保留：Impeller 会剔除未引用的 uniform，导致后续槽位整体错位；
  // 显式乘 0 占位（uScrollOffset/uBlurSigma/uSpecular 本配方不参与渲染）。
  result += vec3((uScrollOffset + uBlurSigma + uSpecular) * 0.0);

  // 抖动（dither）：每物理像素 ±1/255 随机偏移，打破 8-bit 量化的色阶断层。
  // 静态噪声，肉眼只会觉得渐变更顺滑。
  result += (fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453) - 0.5) * (2.0 / 255.0);

  fragColor = vec4(result, 1.0);
}

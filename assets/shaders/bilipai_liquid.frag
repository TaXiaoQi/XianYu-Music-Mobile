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

// ── Metal buffer 上限修复（iOS 不显示水滴/巨卡的根因）──────────────────
// Flutter 把每个非 sampler uniform 转成一个 Metal buffer：本 shader 原本
// 33 个散装 uniform，槽位落到 buffer(32) > Metal fragment 上限 30，
// Impeller 编译失败并每帧重试刷错（水滴不渲染 + 巨卡，iOS 27.2 模拟器
// 实录）。Android GL/Vulkan 无此上限所以一直正常。
// 修法：按 float 槽位顺序打包成 vec4（1×vec2 + 10×vec4 + 1×float = 12 个
// uniform），Dart 侧 setFloat 的槽位序号 0-42 逐位不变，shader 语义不变。
// 注意：ImageFilter.shader 要求第一个 uniform 必须是 vec2 uSize，故槽 0-1
// 保持独立 vec2 不并入打包。

// 槽 0-1：uSize —— 背景纹理物理尺寸（全屏），ImageFilter.shader 要求首 uniform 为 vec2。
uniform vec2 uSize;
// 槽 2-5：x=uScrollOffset（槽位保留，滚动耦合波浪默认关闭）、y=uRefract
//（透镜边缘最大位移，物理像素，Dart 侧已乘 dpr）、z=uChroma（色差强度，
// BiliPai shell 无色差恒 0）、w=uBlurSigma（槽位保留，主体模糊由 compose
// outer 真高斯承担）。
uniform vec4 uP0;
// 槽 6-9：预乘半透明底色（BiliPai surfaceAlpha 0.40 + 白 overlay 的等效物）。
uniform vec4 uBackgroundColor;
// 槽 10-13：x=uSpecular（槽位保留，BiliPai 无 rim 高光）、y=uRadius
//（圆角半径，物理像素，胶囊取短边一半）、zw=uGlassOrigin（玻璃表面左上
// 角屏幕物理像素）。
uniform vec4 uP2;
// 槽 14-17：xy=uGlassSize（玻璃表面物理像素尺寸）、z=uEdgeAmount（边带
// 厚度物理像素，BiliPai refractionHeight 中档 24px）、w=uSaturation
//（饱和度增益，BiliPai 中档 1.5）。
uniform vec4 uP3;
// 槽 18-21：x=uDepthEffect（径向深度效应，水滴专用，见原注释）、
// y=uTime（持续涟漪时间占位，槽位保留防剔除错位）、z=uSquircleN（连续
// 曲率指数，胶囊/圆形 2.0、非胶囊 2.2）、w=uDropletCenter.x。
uniform vec4 uP4;
// 槽 22-25：x=uDropletCenter.y（水滴透镜圆心，屏幕物理像素，与 uP4.w 成
// 对）、y=uDropletRadius（<=0 透镜关闭）、z=uDropletDepth（0..1 按压
// 放大深度）、w=uDropletBand（边带厚度，BiliPai LiquidIndicator 10/56·d）。
uniform vec4 uP5;
// 槽 26-29：x=uDropletRefract（边带折射量 14/56·d）、y=uDropletChroma
//（色差强度）、z=uIconOn（1=采样器 1 已绑定 tabRow 捕获图）、
// w=uIconOrigin.x。
uniform vec4 uP6;
// 槽 30-33：x=uIconOrigin.y、yz=uIconSize（栏内容纹理尺寸，物理像素）、
// w=uDropletGapBand（色散外溢带，水滴超出栏缘的溢出量，0=无色散）。
uniform vec4 uP7;
// 槽 34-37：x=uDropletHalfW（胶囊横向半长，<=纵向半径退化圆）、
// y=uDropletTintInvert（tint 动态反色开关）、z=uDropletBarTop（栏顶全局
// y，物理 px）、w=uPageOn（1=采样器 2 已绑定页面捕获图）。
uniform vec4 uP8;
// 槽 38-41：xy=uPageOrigin（页面纹理左上角）、zw=uPageSize（页面纹理
// 尺寸，物理像素）。
uniform vec4 uP9;
// 槽 42：栏底全局 y（物理 px）：与 uDropletBarTop 成对——独立透镜的
//「完整区域画面」归属判据（barC 落在栏上下缘之间=栏面，缘外=缩栏露出
// 的上下原始内容）
uniform float uDropletBarBottom;

// 各槽位语义详注（原 33 散装声明版，解包见 main() 开头）：
//   槽 2  uScrollOffset   槽位保留（滚动耦合波浪默认关闭）
//   槽 3  uRefract        折射强度（物理像素，Dart 已乘 dpr）
//   槽 4  uChroma         色差强度（shell 无色差恒 0）
//   槽 5  uBlurSigma      槽位保留（主体模糊由 compose outer 承担）
//   槽 10 uSpecular       槽位保留（BiliPai 无 rim 高光）
//   槽 16 uEdgeAmount     边带厚度（BiliPai refractionHeight 24px）
//   槽 17 uSaturation     饱和度增益（BiliPai 中档 1.5）
//   槽 18 uDepthEffect    径向深度效应（水滴专用）：①掺径向进边带 SDF
//                         梯度让中心内容参与「鼓起」折射；②>0 启用全
//                         表面凸透镜放大（B 站水滴放大镜观感来源）
//   槽 19 uTime           持续涟漪占位（Impeller 剔除未引用 uniform
//                         会导致槽位错位）
//   槽 20 uSquircleN      squircle 指数（胶囊 2.0 / 非胶囊 2.2）
//   槽 21-22 uDropletCenter 水滴透镜圆心（屏幕物理像素）
//   槽 23 uDropletRadius  透镜半径（<=0 透镜关闭）
//   槽 24 uDropletDepth   按压放大深度（0..1）
//   槽 25 uDropletBand    边带厚度（LiquidIndicator 10/56·d）
//   槽 26 uDropletRefract 边带折射量（14/56·d）
//   槽 27 uDropletChroma  水滴色差强度
//   槽 28 uIconOn         栏内容纹理开关
//   槽 33 uDropletGapBand 色散外溢带（彩虹只画上下缘外溢月牙带）
//   槽 34 uDropletHalfW   胶囊横向半长（<=纵向半径退化圆）
//   槽 35 uDropletTintInvert tint 动态反色开关（亮背景黑 10%/暗背景白 10%）
//   槽 36 uDropletBarTop  栏顶全局 y（物理 px）
//   槽 37 uPageOn         页面纹理开关

// 引擎绑定的实时背景（采样器 0）。
uniform sampler2D uImage;
// 栏内容捕获图（采样器 1，Dart 侧 setImageSampler(1) 绑定）：tabRow
//（图标+文字）的 RepaintBoundary toImage 产物。BiliPai combinedBackdrop
//（materialBackdrop + tabsBackdrop）的 Flutter 等价物——嵌套 backdrop
// 采不到栏面玻璃与图标，透镜要折射「整个底部栏」必须显式喂纹理。
uniform sampler2D uIconTex;
// app 内容捕获图（采样器 2，Dart 侧 setImageSampler(2) 绑定）：页面层
// RepaintBoundary 的 toImageSync 产物（背景色+页面原始内容，不含任何
// 玻璃模糊/栏面 chrome）。BiliPai materialBackdrop 等价物——按压透镜
// 直接折射原始页面内容，不再折射毛玻璃合成结果
uniform sampler2D uPageTex;

out vec4 fragColor;

// ── 打包 uniform 的解包目标（文件级全局变量，供下方辅助函数引用）──────
// 命名沿用原散装 uniform（原 uniform 已打包为 uP0-uP9，见上）；GLSL ES
// 全局初始化器必须是常量表达式，故在 main() 开头统一赋值（所有调用点
// 均在赋值之后），函数体零改动。
float uScrollOffset; float uRefract;      float uChroma;       float uBlurSigma;
float uSpecular;     float uRadius;       vec2  uGlassOrigin;
vec2  uGlassSize;    float uEdgeAmount;   float uSaturation;
float uDepthEffect;  float uTime;         float uSquircleN;    vec2  uDropletCenter;
float uDropletRadius;     float uDropletDepth;   float uDropletBand;
float uDropletRefract;    float uDropletChroma;  float uIconOn;
vec2  uIconOrigin;        vec2  uIconSize;       float uDropletGapBand;
float uDropletHalfW;      float uDropletTintInvert;
float uDropletBarTop;     float uPageOn;
vec2  uPageOrigin;        vec2  uPageSize;

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
  if (uDropletTintInvert > 0.5) {
    // 动态反色 tint：取水滴圆心处（模糊后）折射内容亮度决定黑白。
    // 区域级单点取样——整颗水滴统一黑白，避免逐像素反色在黑白交界的
    // 内容上碎成花斑；smoothstep 窄带过渡防滚动经过明暗阈值时 tint 跳变。
    // 黑 10%/白 10% 与 BiliPai Shadow/Highlight 空闲水滴面完全一致。
    // 按压淡出（BiliPai drawHomeIndicatorSurface 同构）：tint alpha 随
    // 按压进度（dropletDepth，树内按压路径为 depthEffect）线性退场，
    // 全按压只剩 3% 黑——透镜变近全透明，depthEffect 放大 + 边带色散
    // 直接折射出内容彩色光（「按住放大的彩色水滴」），不再被反色罩盖住
    float pressed = clamp(max(uDropletDepth, uDepthEffect), 0.0, 1.0);
    vec3 cs = tapRGB(clamp(uDropletCenter, mn, mx));
    float cl = dot(cs, vec3(0.2126, 0.7152, 0.0722));
    vec3 tint = mix(vec3(1.0), vec3(0.0), smoothstep(0.45, 0.55, cl));
    float ta = 0.10 * (1.0 - pressed);
    return s * (1.0 - ta - 0.03 * pressed) + tint * ta;
  }
  return s * (1.0 - uBackgroundColor.a) + uBackgroundColor.rgb;
}

// 水滴透镜的玻璃面采样（blur 后的 backdrop，不含图标）。图标由
// compositeIcon 单独锐利合成——图标若随折射坐标一起弯折/色散偏移，
// 会读成「图标被折歪」，故前景与折射面分离（BiliPai 前景不被透镜
// 弯曲同构）。
// toImage 产物为预乘 alpha：out = bg*(1-a) + premul.rgb。
vec3 compositeIcon(vec3 face, vec2 uv) {
  if (uIconOn > 0.5) {
    vec2 icUv = (uv - uIconOrigin) / max(uIconSize, vec2(1.0));
    // 矩形外不采样：clamp 到边缘会把捕获纹理边缘色（上缘红徽标、
    // 下缘红文字）拉成水滴上下缘的红色月牙弧
    if (icUv.x >= 0.0 && icUv.x <= 1.0 && icUv.y >= 0.0 && icUv.y <= 1.0) {
      vec4 ic = texture(uIconTex, icUv);
      face = face * (1.0 - ic.a) + ic.rgb;
    }
  }
  return face;
}

// 页面原始内容采样（toImageSync 产物为预乘 alpha；捕获层含背景色填充，
// 边界内 alpha=1）。矩形外返回透明黑——水滴永不越出页面矩形，纯兜底
vec3 tapPage(vec2 screenPos) {
  vec2 uv = (screenPos - uPageOrigin) / max(uPageSize, vec2(1.0));
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
    return vec3(0.0);
  }
  return texture(uPageTex, uv).rgb;
}

// 水滴透镜单点采样：透镜采样「虚拟合成栈」（BiliPai combinedBackdrop
// 同构——materialBackdrop + tabsBackdrop 叠在一起被折射）。
//
// —— 独立透镜透「整个区域的完整画面」（用户定稿模型）——镜心 1:1 不
// 放大（BiliPai 实机：中心内容原样），「底栏被缩小」完全由边带折射完成
//（采样向外弯折，见水滴分支 pc 注释）：栏缘上下的原始内容被压缩进镜缘
// 边带、栏缘线向镜心弯折。按压态（用户对比图定稿）：栏带内全强度采
// uImage 真实栏面（玻璃霜+图标+文字已烘焙，随径向场放大弯折进镜内
// ——BiliPai 镜内白栏面+放大弯折图标+彩虹缘同构），栏带外采原始页面
// 内容；静息 pc=p、透镜全落栏内 = 已确认静息观感逐字节一致。
// 注意：图标不在此合成——色散会对本函数连调 7 次（7 个色散偏移坐
// 标），带内合成会让外溢带内的图标被叠 7 次 = 七彩鬼影（真机截图
// 屋顶橙弧/底部红绿条）；图标由调用方在色散混合完成后一次性合成
vec3 lensTap(vec2 pageC, float rawMix) {
  if (rawMix > 0.0) {
    // 按压面 = 静态玻璃面（glassFace：磨砂+饱和度+tint 反色）经折射场
    // 采样。用户定稿（2026-11-26）：按压放大水滴必须有静态水滴的玻璃
    // 质感——此前直采 uImage 原始场景被否决（纯透镜）。
    // 按压态霜化：glassFace 的 tint 只有 10%，鼓出栏缘的部分透出未霜化
    // 的原始页面内容，读作「纯透镜」与静态磨砂质感脱节——镜面内容先经
    // 9 点小半径模糊再过玻璃 tint（B 站实机：镜面奶白磨砂、放大图标仍
    // 清晰可辨）。半径随 rawMix 渐入；静息 rawMix=0 走下方单点 glassFace
    // 逐字节不变
    float frostR = rawMix * 6.0;
    vec3 face = glassFace(pageC) * 0.25;
    face += glassFace(pageC + vec2(frostR, 0.0)) * 0.125;
    face += glassFace(pageC - vec2(frostR, 0.0)) * 0.125;
    face += glassFace(pageC + vec2(0.0, frostR)) * 0.125;
    face += glassFace(pageC - vec2(0.0, frostR)) * 0.125;
    face += glassFace(pageC + vec2(frostR, frostR) * 0.7071) * 0.0625;
    face += glassFace(pageC - vec2(frostR, frostR) * 0.7071) * 0.0625;
    face += glassFace(pageC + vec2(frostR, -frostR) * 0.7071) * 0.0625;
    face += glassFace(pageC - vec2(frostR, -frostR) * 0.7071) * 0.0625;
    // 采样器 2 与栏带 uniforms 引用保留（Impeller 剔除未引用
    // uniform/sampler 会让槽位/绑定错位）：结果恒等 face，但权重依赖
    // uPageOn/uDropletBarTop/uDropletBarBottom，防常量折叠被 DCE
    float band =
        smoothstep(uDropletBarTop - 1.5, uDropletBarTop + 1.5, pageC.y) *
        (1.0 - smoothstep(uDropletBarBottom - 1.5, uDropletBarBottom + 1.5,
                          pageC.y));
    return mix(tapPage(pageC), face, 1.0 - band * min(uPageOn, 0.0));
  }
  // 静息（rawMix=0）：玻璃面（已确认静息观感逐字节一致）
  return glassFace(pageC);
}

void main() {
  // ── unpack：打包 uniform 解回原散装语义（赋值给文件级全局，函数体零改动）──
  uScrollOffset = uP0.x;        // 槽 2
  uRefract      = uP0.y;        // 槽 3
  uChroma       = uP0.z;        // 槽 4
  uBlurSigma    = uP0.w;        // 槽 5
  uSpecular     = uP2.x;        // 槽 10
  uRadius       = uP2.y;        // 槽 11
  uGlassOrigin  = uP2.zw;       // 槽 12-13
  uGlassSize    = uP3.xy;       // 槽 14-15
  uEdgeAmount   = uP3.z;        // 槽 16
  uSaturation   = uP3.w;        // 槽 17
  uDepthEffect  = uP4.x;        // 槽 18
  uTime         = uP4.y;        // 槽 19
  uSquircleN    = uP4.z;        // 槽 20
  uDropletCenter = vec2(uP4.w, uP5.x); // 槽 21-22
  uDropletRadius     = uP5.y;   // 槽 23
  uDropletDepth      = uP5.z;   // 槽 24
  uDropletBand       = uP5.w;   // 槽 25
  uDropletRefract    = uP6.x;   // 槽 26
  uDropletChroma     = uP6.y;   // 槽 27
  uIconOn            = uP6.z;   // 槽 28
  uIconOrigin        = vec2(uP6.w, uP7.x); // 槽 29-30
  uIconSize          = uP7.yz;  // 槽 31-32
  uDropletGapBand    = uP7.w;   // 槽 33
  uDropletHalfW      = uP8.x;   // 槽 34
  uDropletTintInvert = uP8.y;   // 槽 35
  uDropletBarTop     = uP8.z;   // 槽 36
  uPageOn            = uP8.w;   // 槽 37
  uPageOrigin        = uP9.xy;  // 槽 38-39
  uPageSize          = uP9.zw;  // 槽 40-41
  // uDropletBarBottom 为独立 float uniform（槽 42），无需解包

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

  // —— 水滴透镜（BiliPai LiquidLens ROUNDED_RECT_REFRACTION_
  // WITH_DISPERSION 严格同构，底栏玻璃专用）——折射只作用于贴边
  // band 宽的边缘带：内部 -sd >= band 区域 1:1 原样采样，零放大
  // （BiliPai 无全表面放大，depthEffect 只拧位移方向）。位移方向 =
  // 外法向 + depthEffect×径向，采样坐标 + d·grad 向外偏——边缘带把
  // 水滴外的底栏/页面内容吸进来压缩显示（「底栏被水滴缩小」的来源）。
  // 区域外像素完全不变
  if (uDropletRadius > 0.5) {
    vec2 dc = p - uDropletCenter;
    // 胶囊 SDF（BiliPai 指示器 stadium 同构）：横向半长
    // max(uDropletHalfW, r)、纵向半径 r，两端相切圆心距 halfW-r；
    // halfW <= r 退化为圆（sd = length(dc) - r）
    float halfW = max(uDropletHalfW, uDropletRadius);
    float coreX = max(abs(dc.x) - (halfW - uDropletRadius), 0.0);
    float coreLen = max(length(vec2(coreX, dc.y)), 1e-3);
    float sd = coreLen - uDropletRadius;
    // 按压进度（BiliPai progress）：水滴/外投影两分支共用，声明在外层
    float pressedSh = clamp(max(uDropletDepth, uDepthEffect), 0.0, 1.0);
    // 整矩形走透镜分支：rect 与 SDF 几何失配的兜底条带（按压 swell 期间
    // rect 与 lensR 不同步的边缘区）旧结构回落壳层玻璃路径——backdrop
    // 含真实栏面图标文字，与放大捕获图标叠成双影（用户截图否决）。失配
    // 区 fromEdge=0 零折射，但仍走透镜面采样保持观感一致
    float fromEdge = max(-sd, 0.0);
    // 折射剖面半径：静息=贴边带（原 band 行为不变）；按压收缩到 35%
    // 半径的镜缘环带——此前按压展开到全半径，且 Dart 侧 band 随按压
    // 同步膨胀到 ~0.94R（实测 band=138.9 vs r=148.4），外推场铺满整镜
    // 把镜心放大逐环抵消（真机观察「图标内容没有变化」的根因）。
    // BiliPai 实机 = 镜心放大 + 镜缘压缩两个独立场：外推只作用于镜缘
    // 环带，镜心保持纯凸透镜放大
    float profR = mix(uDropletBand, uDropletRadius * 0.35, pressedSh);
    float dsh = 0.0;
    vec2 grad = vec2(0.0);
    if (sd < 0.0 && uDropletRefract > 0.0 && profR > 0.0 &&
        fromEdge < profR) {
        float x = 1.0 - fromEdge / profR;
        dsh = (1.0 - sqrt(max(0.0, 1.0 - x * x))) * uDropletRefract;
        if (dsh > 0.001) {
          // 位移方向（BiliPai grad = normalize(gradSd + depthEffect·
          // normalize(dc)) 同构）：胶囊 SDF 外向梯度（圆端沿端心径向、
          // 直边区垂直于边）+ 按压时往径向拧
          vec2 eg = (coreX > 0.0)
              ? vec2(sign(dc.x) * coreX, dc.y) / coreLen
              : vec2(0.0, sign(dc.y));
          grad = normalize(eg + uDropletDepth * normalize(dc));
        }
      }
      // 镜心 1:1（dsh(镜心)=0）+ 镜缘压缩放大：径向场 pc = p - dsh·grad
      //（grad 外向）采样向镜心收——BiliPai circleMap 原版观感。静息与
      // 按压同一方向同一公式，区别只在 profR（band→全半径）与捕获纹理
      // 分支（rawMix）
      // 光谱色散（BiliPai dispersedCoord = d·grad·intensity 同构）：
      // 偏移幅度正比折射位移 d、方向全径向。
      // 掩膜（BiliPai 实机按压截图定稿 2026-11）：彩虹缘布满透镜边缘
      // 一圈——贴边最强、向内 35% 半径衰减；uRoll... 静息 gapBand=0
      // 时恒 0（无色散），按压随外溢量 smoothstep 渐入
      float dispW = (1.0 - smoothstep(0.0, uDropletRadius * 0.35, -sd)) *
          smoothstep(0.0, 8.0, uDropletGapBand);
      vec3 droplet;
      // —— 真实合成面透镜（BiliPai combinedBackdrop 同构）——按压态由
      // lensTap 采样实时 backdrop：uImage = 页面+栏面+实图标的完整场景
      //（实图标随液态关孔保留在 backdrop 里）。rawMix 随按压 0→0.3 渐入，
      // 与玻璃面交叉淡化。此前 rawMix 以 uPageOn 为门：页面捕获失败/未
      // 捕获（部分机型 toImageSync 静默失败）恒走玻璃面分支——弯折场
      // 作用在低对比霜化面上不可读 + 捕获图标 1:1 不弯 = 「纯透镜带
      // 模糊」（真机截图确认）。现按压折射不再依赖捕获纹理
      float rawMix = smoothstep(0.0, 0.3, pressedSh);
      // 按压径向场（BiliPai 实机按压截图定稿 2026-11 重构）——两段叠加：
      // ① 全表面凸透镜放大：采样坐标向镜心收（0.35·pressedSh），镜心
      //    内容放大 ~1.54×（参考图：图标/徽标在镜内明显放大）；
      // ② 边带外推（折射缩小）：dsh·grad 向外，镜缘采样越过透镜边界
      //    （full press 时 refract 79.6 > mag·R ≈ 52），把栏缘/邻位
      //    内容吸入压缩进镜缘一圈（参考图：「我的」文字在镜缘弯折、
      //    dock 呈被水滴缩小观感）。
      // 方向分流保留：静息向内（旧观感，负号经 (1-2·dirMix) 在按压翻转为
      // 向外）、0.3 渐变窗口与 rawMix 同步防跳变
      float dirMix = smoothstep(0.0, 0.3, pressedSh);
      float mag = pressedSh * 0.35;
      vec2 pc = mix(p, uDropletCenter, mag) -
          dsh * grad * (1.0 - 2.0 * dirMix);
      if (dsh > 0.001 && uDropletChroma > 0.001 && dispW > 0.0) {
        // 色散全径向（BiliPai dispersedCoord = d·grad·intensity 原版）：
        // 只取 grad.x 时水滴顶部 grad.x≈0，鼓出月牙永远无彩虹（用户
        // 截图否决「外面的部分要加彩色」）。改径向后栏内白面均匀无
        // 色散可读、图标在色散之后合成不参与偏移——旧「竖向彩虹条拉
        // 歪图标红」的前提（色散作用于彩色内容糊团+图标）已不存在，
        // 彩虹集中在有内容梯度的月牙带（BiliPai dock 指示器上下缘
        // chromaticEdgeBand 同构）
        // 色散偏移跟随折射位移场（p - pc = 当前位移矢量 = 径向 dsh·grad）
        vec2 off = (p - pc) * (uDropletChroma * dispW);
        vec3 red = lensTap(pc + off, rawMix);
        vec3 orange = lensTap(pc + off * (2.0 / 3.0), rawMix);
        vec3 yellow = lensTap(pc + off * (1.0 / 3.0), rawMix);
        vec3 green = lensTap(pc, rawMix);
        vec3 cyan = lensTap(pc - off * (1.0 / 3.0), rawMix);
        vec3 blue = lensTap(pc - off * (2.0 / 3.0), rawMix);
        vec3 purple = lensTap(pc - off, rawMix);
        droplet = vec3(
          (red.r + orange.r + yellow.r) / 3.5 + purple.r / 7.0,
          orange.g / 7.0 + (yellow.g + green.g + cyan.g) / 3.5,
          (cyan.b + blue.b + purple.b) / 3.0
        );
      } else {
        droplet = lensTap(pc, rawMix);
      }
      // 图标合成（一次性，色散混合完成后）：静息 1:1 原位合成捕获图标
      //（crisp，用户确认的静息样式，此时孔开、实图标已让位）；按压
      //（rawMix>0）时跳过——uImage 实时场景已含实图标/文字（液态关孔，
      // 所有设备一致，不再依赖页面捕获成功与否；随栏按压压扁动画实时
      // 变化），再叠静息位置捕获的图标 = 双影错位；且 uImage 图标经 7
      // 次色散采样自带彩虹缘（BiliPai 实机按压同构）
      if (rawMix <= 0.0) {
        vec2 iconC = pressedSh < 0.001 ? p : pc;
        result = compositeIcon(droplet, iconC);
      }
      // 边缘高光（BiliPai 实机按压同构：顶缘亮带 ~8px 且明显）：贴边
      // 6px 亮环，玻璃胶囊厚度感。仅按压态生效——静息多出一圈亮环被
      // 读成第二个圆（用户截图否决「现在这是什么东西」），静息样式
      // 保持无 rim 的已确认观感
      float rimW = 1.0 - smoothstep(0.0, 6.0, fromEdge);
      result = mix(result, vec3(1.0),
          rimW * 0.55 * smoothstep(0.0, 0.3, pressedSh));
  } // uDropletRadius > 0.5（水滴实例：整矩形透镜分支）

  // 槽位保留：Impeller 会剔除未引用的 uniform，导致后续槽位整体错位；
  // 显式乘 0 占位（uScrollOffset/uBlurSigma/uSpecular 本配方不参与渲染）。
  result += vec3((uScrollOffset + uBlurSigma + uSpecular) * 0.0);

  // 抖动（dither）：每物理像素 ±1/255 随机偏移，打破 8-bit 量化的色阶断层。
  // 静态噪声，肉眼只会觉得渐变更顺滑。
  result += (fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453) - 0.5) * (2.0 / 255.0);

  fragColor = vec4(result, 1.0);
}

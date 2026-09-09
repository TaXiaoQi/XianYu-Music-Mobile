# 弦予音乐 Rust 核心（动态 framework）CocoaPods 集成。
#
# 职责对齐 Android 侧 gradle rustHook（scripts/gradle-rust-hook.ps1）：
# 编译前先跑 scripts/ios-rust-hook.sh 按当前 SDK（PLATFORM_NAME）增量产出
# xianyu_core.framework，再 vendored 引入并嵌入 Runner。
#
# 为什么是动态 framework：flutter_rust_bridge 2.12 在 iOS 侧加载
# $stem.framework/$stem（loader/_io.dart），没有静态符号分支，详见脚本头注释。
Pod::Spec.new do |s|
  s.name             = 'xianyu_core'
  s.version          = '0.1.0'
  s.summary          = '弦予音乐移动端 Rust 核心（flutter_rust_bridge 动态框架）'
  s.description      = 'Prebuilt dynamic framework of the Rust core, built by scripts/ios-rust-hook.sh.'
  s.homepage         = 'https://xymusic.cc'
  s.license          = { :type => 'AGPL-3.0-only' }
  s.authors          = { 'lyc' => 'lyc@xymusic.cc' }
  s.source           = { :path => '.' }

  s.ios.deployment_target = '13.0'
  s.swift_version    = '5.0'

  s.vendored_frameworks = 'Frameworks/xianyu_core.framework'

  # 编译前钩子：$PODS_ROOT = ios/Pods，向上一级即项目根的 scripts/。
  s.script_phases = [
    {
      :name => 'Build Rust Core',
      :script => '"$PODS_ROOT/../scripts/ios-rust-hook.sh"',
      :execution_position => :before_compile,
    }
  ]
end

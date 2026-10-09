/// 窗口材质（背景效果）模式。
///
/// 前四种走 Win32 系统级效果，[simulated] 完全由 Flutter 自绘；
/// 之所以保留自绘模式，是因为系统效果在三种情况下会失效：
/// 远程桌面 / 虚拟机里 DWM 合成被关掉、Win10 早期版本没有 Mica、
/// 以及用户就是想要一个不透明的窗口。这时必须有一个"体面的退路"，
/// 而不是露出一片黑或者干脆闪退。
enum ZhyWindowMaterial {
  acrylic(
    label: '亚克力',
    description: 'Win10/11 系统级毛玻璃，模糊强度随系统设置，透明度可调',
    usesSystemEffect: true,
    minWindows11: false,
  ),
  mica(
    label: 'Mica',
    description: 'Win11 22H2+ 桌面材质，以系统壁纸为底，最省电、最"原生"',
    usesSystemEffect: true,
    minWindows11: true,
  ),
  micaAlt(
    label: 'Mica Alt',
    description: 'Win11 标签式 Mica，层与层之间的层次感更明显',
    usesSystemEffect: true,
    minWindows11: true,
  ),
  blur(
    label: '高斯模糊',
    description: 'Win10 时代的 Aero 模糊，只有模糊没有磨砂颗粒',
    usesSystemEffect: true,
    minWindows11: false,
  ),
  simulated(
    label: '模拟磨砂',
    description: '不用系统效果，用封面渐变 + 实时模糊 + 噪点自绘，跨版本稳定',
    usesSystemEffect: false,
    minWindows11: false,
  ),
  solid(
    label: '实色',
    description: '完全不透明，性能最好，也不受系统合成开关影响',
    usesSystemEffect: false,
    minWindows11: false,
  );

  const ZhyWindowMaterial({
    required this.label,
    required this.description,
    required this.usesSystemEffect,
    required this.minWindows11,
  });

  final String label;
  final String description;

  /// 是否需要把 Flutter 渲染面设为透明、把背景交给 DWM。
  final bool usesSystemEffect;

  /// 是否要求 Windows 11（build >= 22000）。
  final bool minWindows11;

  /// 是否需要绘制「模拟磨砂」背景（自绘渐变 + 模糊 + 噪点）。
  bool get isSimulated => this == ZhyWindowMaterial.simulated;

  /// 窗口是否完全不透明。
  bool get isOpaque => this == ZhyWindowMaterial.solid;

  static ZhyWindowMaterial fromName(String? name) {
    if (name == null) return ZhyWindowMaterial.acrylic;
    for (final ZhyWindowMaterial m in values) {
      if (m.name == name) return m;
    }
    return ZhyWindowMaterial.acrylic;
  }
}

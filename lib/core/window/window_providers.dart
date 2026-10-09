import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/theme_providers.dart';
import '../theme/theme_settings.dart';
import '../theme/window_material.dart';
import 'window_effects.dart';

/// 最近一次**真正应用下去**的窗口材质。
///
/// 界面（设置页）需要知道"用户选了 Mica，但系统不支持、实际用的是亚克力"
/// 这种降级事实，否则用户只会以为开关坏了。
class AppliedBackdropNotifier extends Notifier<AppliedBackdrop?> {
  @override
  AppliedBackdrop? build() => null;

  void update(AppliedBackdrop value) => state = value;
}

final NotifierProvider<AppliedBackdropNotifier, AppliedBackdrop?>
appliedBackdropProvider =
    NotifierProvider<AppliedBackdropNotifier, AppliedBackdrop?>(
      AppliedBackdropNotifier.new,
    );

/// 当前系统的窗口材质能力（版本号、是否支持 Mica 等）。
final Provider<WindowsBackdropSupport> windowsBackdropSupportProvider =
    Provider<WindowsBackdropSupport>((Ref ref) => WindowEffects.support);

/// 把主题设置单向同步到 Win32 窗口效果。
///
/// 为什么用「帧后回调 + 变更签名比较」而不是 `ref.listen`：
/// 窗口外观既取决于设置（材质、透明度），也取决于**运行时的主题亮度**
/// （深浅色由 MaterialApp 按系统决定），而后者只能从 `Theme.of(context)`
/// 拿到。放在 widget 里比较签名，两边都能覆盖到，而且重复设置同一组值
/// 时不会白白调一次 DWM。
class WindowEffectSync extends ConsumerStatefulWidget {
  const WindowEffectSync({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<WindowEffectSync> createState() => _WindowEffectSyncState();
}

class _WindowEffectSyncState extends ConsumerState<WindowEffectSync> {
  _EffectSignature? _last;

  @override
  Widget build(BuildContext context) {
    final ZhyThemeSettings settings = ref.watch(themeSettingsProvider);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    final _EffectSignature signature = _EffectSignature(
      material: settings.material,
      dark: theme.brightness == Brightness.dark,
      opacity: settings.windowOpacity,
      tint: scheme.surface,
    );

    if (signature != _last) {
      _last = signature;
      final ZhyThemeSettings captured = settings;
      final bool dark = signature.dark;
      final Color tint = signature.tint;
      // 放到帧后：DWM 调用会立即改变窗口外观，如果在 build 过程中执行，
      // 本帧的合成结果和窗口实际状态会不一致，肉眼能看到一下闪动。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final AppliedBackdrop applied = WindowEffects.applyMaterial(
          captured.material,
          tintArgb: tint,
          opacity: captured.windowOpacity,
          dark: dark,
        );
        ref.read(appliedBackdropProvider.notifier).update(applied);
      });
    }

    return widget.child;
  }
}

/// 只比较会影响窗口外观的字段。
@immutable
class _EffectSignature {
  const _EffectSignature({
    required this.material,
    required this.dark,
    required this.opacity,
    required this.tint,
  });

  final ZhyWindowMaterial material;
  final bool dark;
  final double opacity;
  final Color tint;

  @override
  bool operator ==(Object other) =>
      other is _EffectSignature &&
      other.material == material &&
      other.dark == dark &&
      other.opacity == opacity &&
      other.tint == tint;

  @override
  int get hashCode => Object.hash(material, dark, opacity, tint);
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/theme_providers.dart';
import '../core/ui/window_backdrop.dart';
import '../core/window/window_providers.dart';
import '../features/player/player_controller.dart';
import '../features/shell/app_shell.dart';

/// 应用根组件。
class ZhuoYueApp extends ConsumerWidget {
  const ZhuoYueApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData lightTheme = ref.watch(lightThemeProvider);
    final ThemeData darkTheme = ref.watch(darkThemeProvider);
    final ThemeMode themeMode = ref.watch(themeModeProvider);

    // 当前封面直接驱动背景与莫奈取色，所以在这里读一次就够了，
    // 内部会自行处理封面字节的加载与缓存。
    final String? coverUrl = ref.watch(currentCoverUrlProvider);

    return MaterialApp(
      title: '卓越播放器',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      // builder 处在 Theme 之内、Navigator 之外：
      // 窗口材质同步需要 Theme 的亮度，背景层需要盖住所有页面与弹窗。
      builder: (BuildContext context, Widget? child) {
        return WindowEffectSync(
          child: WindowBackdrop(
            coverUrl: coverUrl,
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      home: const AppShell(),
    );
  }
}

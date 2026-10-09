import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/window_bootstrap.dart';
import 'core/download/download_manager.dart';
import 'core/storage/preferences.dart';
import 'core/theme/font_loader.dart';
import 'features/downloads/downloads_page.dart';
import 'features/onboarding/onboarding_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 先读设置再建窗口：主题必须在第一帧就是正确的配色，
  // 否则用户会看到一次"默认紫 → 自己的主题"的闪烁
  // （走系统材质时尤其明显，因为窗口背景是透明的）。
  final SharedPreferences preferences = await SharedPreferences.getInstance();

  // 自定义字体必须在 runApp 之前注册完：FontLoader 是异步的，
  // 放在第一帧之后就一定会先闪一下系统字体再换成用户的字体。
  await ZhyFontLoader.restoreFromPreferences(preferences);

  await bootstrapWindow();

  runApp(
    ProviderScope(
      // 不写显式类型参数：Riverpod 3 的 Override 类型没有从
      // flutter_riverpod 导出，交给类型推断即可。
      overrides: [
        // 同步注入，让主题相关的 Provider 能在 build 里直接同步读盘。
        sharedPreferencesProvider.overrideWithValue(preferences),
        // 下载管理器需要 SharedPreferences 与运行期生命周期，在这里装配。
        // 构造时它会自己把 dispose 挂到 ref.onDispose 上。
        downloadQueueProvider.overrideWith((Ref ref) => DownloadManager(ref)),
      ],
      child: const OnboardingGate(
        // 首次运行的门槛：本机没走过引导就先显示引导页，完成或跳过后
        // 才挂上应用外壳。门槛放在这里是因为它必须在第一帧就决定，
        // 而引导页自己要写"已走过"这个标记（见 onboarding_page.dart）。
        child: ZhuoYueApp(),
      ),
    ),
  );
}

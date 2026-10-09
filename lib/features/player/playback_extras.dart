import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_tokens.dart';
import '../../data/models/audio_quality.dart';
import '../../data/models/media_source.dart';
import '../../data/repositories/music_repository.dart';
import '../../data/repositories/source_registry.dart';

/// 均衡器预设。频段增益单位是 dB。
///
/// **这些数字目前不会改变声音**，原因见 [showEqualizerDialog] 顶部的说明 ——
/// 之所以还是把预设写全，是因为一旦换上支持音频图的后端（media_kit / mpv），
/// 这些曲线就能直接用，不需要重新设计一遍。
class EqualizerPreset {
  const EqualizerPreset(this.name, this.gains);

  final String name;

  /// 从低频到高频的增益（dB），对应 [_kBandLabels] 的 10 个频段。
  final List<double> gains;
}

const List<String> _kBandLabels = <String>[
  '31',
  '62',
  '125',
  '250',
  '500',
  '1k',
  '2k',
  '4k',
  '8k',
  '16k',
];

const List<EqualizerPreset> kEqualizerPresets = <EqualizerPreset>[
  EqualizerPreset('原声', <double>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  EqualizerPreset('流行', <double>[-1, 0, 2, 4, 4, 2, 0, -1, -1, -1]),
  EqualizerPreset('摇滚', <double>[5, 4, 2, -1, -2, -1, 2, 4, 5, 5]),
  EqualizerPreset('古典', <double>[4, 3, 2, 1, -1, -1, 0, 2, 3, 4]),
  EqualizerPreset('人声', <double>[-3, -2, 0, 3, 5, 5, 4, 2, 0, -1]),
  EqualizerPreset('低音增强', <double>[7, 6, 4, 2, 0, 0, 0, 0, 0, 0]),
  EqualizerPreset('高音增强', <double>[0, 0, 0, 0, 0, 1, 3, 5, 6, 7]),
  EqualizerPreset('深夜', <double>[-4, -3, -1, 1, 3, 3, 2, 0, -1, -2]),
];

/// 打开均衡器面板。
///
/// ## 为什么这里必须写清楚"暂时不生效"
///
/// Windows 上音频由 `just_audio_windows`（C++/WinRT + Media Foundation）播放，
/// 它**没有暴露任何音频效果接口**：`just_audio` 的 `AndroidEqualizer`
/// 是 Android 专属（走 `AudioEffect`），`AudioPipeline` 同样只对 Android 可用。
///
/// 也就是说：现在做一个"能拖动、看起来在工作"的均衡器，全部是假的。
/// 与其骗人，不如把曲线和预设真实地存下来、并如实标注"当前后端不生效" ——
/// 换到支持音频图的后端（media_kit / mpv，带 `af=equalizer`）就能直接用上。
Future<void> showEqualizerDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => const _EqualizerDialog(),
  );
}

/// 面板内容区宽度（不含 [AlertDialog] 自己的内边距）。
///
/// 十个频段横排，每列平分到 560 / 10 = 56 逻辑像素 —— 刚好放得下
/// 34 宽的推子和 `+12.0` 这样的数值。窗口更窄时 AlertDialog 会把可用宽度
/// 压下来，列宽由 `Expanded` 跟着缩，所以面板只会变窄，不会溢出。
const double _kPanelWidth = 560;

/// 单个推子的横向占位（把横向 Slider 转 90° 之后剩下的"宽"）。
const double _kFaderWidth = 34;

/// 推子的可见长度（旋转后的"高"）。
///
/// 用固定值而不是跟着窗口拉伸，是因为十个推子必须**等长**：
/// 「0 dB 在同一条水平线上」这句话只有在每列行程一致时才成立 ——
/// 只要有一列比别人短，数值相同看起来也是歪的。
///
/// 取 140 而不是更长：面板总高还要塞得进应用允许的最小窗口（900x560，
/// 见 `kMinimumWindowSize`）—— 再长就要靠滚动才能看到频率标签，
/// 而标签恰恰是推子面板最不能少的东西。
const double _kFaderHeight = 140;

/// dB 数值行 / 频率标签行的固定高度。
///
/// 三行（数值 / 推子 / 标签）各自高度写死，是为了让基准线的位置可以被精确
/// 算出来：文本行高一旦随字体浮动，整排推子的起止位置就会跟着错开。
const double _kValueRowHeight = 18;
const double _kLabelRowHeight = 16;

/// 数值行与推子行、推子行与标签行之间的间距。
const double _kRowGap = 6;

/// 把 dB 增益格式化成一列对齐的文本：固定一位小数、始终带正负号。
///
/// 走 `abs()` 再补符号而不是 `toStringAsFixed` 直接拼：`-0.0` 会被
/// `toStringAsFixed` 打印成 `-0.0`，和前面的 `+` 拼起来就成了 `+-0.0`。
String _formatGain(double gain) {
  final String sign = gain < 0 ? '-' : '+';
  return '$sign${gain.abs().toStringAsFixed(1)}';
}

class _EqualizerDialog extends StatefulWidget {
  const _EqualizerDialog();

  @override
  State<_EqualizerDialog> createState() => _EqualizerDialogState();
}

class _EqualizerDialogState extends State<_EqualizerDialog> {
  EqualizerPreset _preset = kEqualizerPresets.first;
  late List<double> _gains = _gainsOf(_preset);

  @override
  void initState() {
    super.initState();
    // 开发期把**全部**预设都校验一遍，而不是只校验当前选中的那个：
    // 只在被点到时才断言的话，一个写错的预设可能很久都没人发现。
    assert(() {
      for (final EqualizerPreset preset in kEqualizerPresets) {
        assert(
          preset.gains.length == _kBandLabels.length,
          '预设「${preset.name}」有 ${preset.gains.length} 个增益，'
          '与 ${_kBandLabels.length} 个频段对不上',
        );
      }
      return true;
    }());
  }

  /// 把预设增益对齐到频段数量。
  ///
  /// 预设与 [_kBandLabels] 数量不一致时（有人加了频段却忘了补预设），
  /// 直接按下标取 `preset.gains[i]` 会 RangeError 崩掉整个面板；
  /// 这里按频段数量补齐 / 截断，缺的档位按 0 dB（不动）处理 ——
  /// 界面上平掉一段，总好过窗口根本弹不出来。
  List<double> _gainsOf(EqualizerPreset preset) {
    return <double>[
      for (int i = 0; i < _kBandLabels.length; i++)
        i < preset.gains.length ? preset.gains[i] : 0,
    ];
  }

  void _applyPreset(EqualizerPreset preset) {
    setState(() {
      _preset = preset;
      _gains = _gainsOf(preset);
    });
  }

  void _setGain(int index, double value) {
    setState(() {
      _gains[index] = value;
      // 手动调过就不再声称还是某个预设。
      _preset = kEqualizerPresets.first;
    });
  }

  /// 十段竖推子。
  ///
  /// 拆成「数值行 / 推子行 / 标签行」三行（而不是每个频段一个 Column），
  /// 三行用的是**同一套 `Expanded` 列宽**，所以数值、推子、标签天然对齐；
  /// 而推子行的高度恒等于 [_kFaderHeight]，0 dB 参考线和底部基线
  /// 就能落在确定的坐标上，不用去猜文本行高。
  Widget _faderBank(ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // ---- ① 每个推子上方的当前 dB 值 ----
        Row(
          children: <Widget>[
            for (int i = 0; i < _kBandLabels.length; i++)
              Expanded(
                child: SizedBox(
                  height: _kValueRowHeight,
                  child: Center(
                    child: FittedBox(
                      // 列被挤窄时缩放而不是换行或溢出：数值是这里可读性最高的
                      // 信息，宁可小一点，也不能让它把列撑破。
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _formatGain(_gains[i]),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurface,
                          // 等宽数字：不然 1 和 8 宽度不同，上下两列的数值看着不在一条线上。
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: _kRowGap),
        // ---- ② 推子本体（叠两条参考线） ----
        Stack(
          children: <Widget>[
            // 0 dB 参考线：十列共用一条，谁不在线上、谁被拖过头，一眼可见。
            // 画在推子**下层**（Stack 里靠前的先绘制），免得盖住推子。
            Positioned(
              left: 0,
              right: 0,
              top: _kFaderHeight / 2 - 0.5,
              child: IgnorePointer(
                child: Container(
                  height: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
            ),
            // 底部基线：推子行程的下沿。
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  height: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.8),
                ),
              ),
            ),
            Row(
              children: <Widget>[
                for (int i = 0; i < _kBandLabels.length; i++)
                  Expanded(
                    child: Center(
                      child: SizedBox(
                        width: _kFaderWidth,
                        height: _kFaderHeight,
                        child: RotatedBox(
                          // 顺时针 270°：把横向 Slider 立起来，并且让**最小值在底、
                          // 最大值在顶** —— 往上推才是增益，符合调音台的直觉。
                          // 用旋转而不是自绘：Slider 的拖动、键盘、无障碍语义全都还在，
                          // 自绘一个垂直版本等于把它们重写一遍。
                          quarterTurns: 3,
                          child: Slider(
                            value: _gains[i].clamp(-12, 12),
                            min: -12,
                            max: 12,
                            // 48 级 = 0.5 dB 一格，和数值显示的一位小数对得上。
                            divisions: 48,
                            onChanged: (double value) => _setGain(i, value),
                            // 读屏软件念的是"哪个频段、多少 dB"，而不是一个裸数字。
                            semanticFormatterCallback: (double value) =>
                                '${_kBandLabels[i]}Hz ${_formatGain(value)}dB',
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: _kRowGap),
        // ---- ③ 每个推子下方的频率标签 ----
        Row(
          children: <Widget>[
            for (int i = 0; i < _kBandLabels.length; i++)
              Expanded(
                child: SizedBox(
                  height: _kLabelRowHeight,
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '${_kBandLabels[i]}Hz',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ZhyTokens tokens = context.tokens;

    return AlertDialog(
      // 十段推子 + 预设 + 说明在竖向是"能排下但不算矮"的高度。
      // 交给 AlertDialog 自己滚动，窗口一矮就滚动而不是顶出一堆黄黑条纹。
      scrollable: true,
      title: Row(
        children: <Widget>[
          const Icon(Icons.graphic_eq_rounded, size: 18),
          const SizedBox(width: 8),
          const Text('均衡器'),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(tokens.pillRadius),
            ),
            child: Text(
              '当前后端不生效',
              style: TextStyle(
                fontSize: 10.5,
                color: scheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: _kPanelWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 说明放在最上面而不是折叠起来：用户点进来就是为了确认它有没有用。
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.tertiaryContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(tokens.cardRadius),
              ),
              child: Text(
                'Windows 的播放后端（just_audio_windows / Media Foundation）'
                '没有暴露音频效果接口，所以这里的曲线**不会改变声音**。\n'
                '预设与增益会保存下来，等换上支持音频图的后端（media_kit + mpv）即可直接生效。',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: scheme.onTertiaryContainer,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '预设',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final EqualizerPreset preset in kEqualizerPresets)
                  ChoiceChip(
                    label: Text(preset.name),
                    selected: _preset == preset,
                    onSelected: (_) => _applyPreset(preset),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            // 标题与右侧提示同一行：推子是竖的，"往上推"这件事必须写出来，
            // 否则第一次见到竖推子的人会以为下面那端才是增益。
            Row(
              children: <Widget>[
                Text(
                  '频段增益（dB）',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '向上为增益 · -12 ~ +12 dB · 步进 0.5',
                    textAlign: TextAlign.right,
                    // 窗口很窄时省略号收尾，绝不允许这一行顶出横向溢出。
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _faderBank(scheme),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => _applyPreset(kEqualizerPresets.first),
          child: const Text('复位'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 播放条上的音质按钮：显示**实际**拿到的档位，点开可改偏好。
///
/// 放在左侧曲目信息里而不是右侧按钮堆里：右侧已经有音量、均衡器、队列、
/// 全屏四个控件，再塞一个会把音量条挤没；而"音质"本来就是
/// "这首歌的信息"的一部分，和艺人名排在一起最自然。
class PlaybackQualityChip extends ConsumerWidget {
  const PlaybackQualityChip({
    super.key,
    required this.source,
    required this.actualLabel,
    required this.onChanged,
  });

  final MediaSource source;

  /// 实际拿到的音质（来自 `ResolvedStream.qualityLabel`）。
  final String? actualLabel;

  /// 改完音质后刷新当前曲目。
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ZhyTokens tokens = context.tokens;
    final MusicRepository? repository = repositoryForWidget(ref, source);
    if (repository == null) return const SizedBox.shrink();

    final String preferred = repository.preferredQualityId;
    final String label = actualLabel ?? repository.effectiveQuality.label;

    return PopupMenuButton<String>(
      tooltip: '音质：${repository.effectiveQuality.label}（点开修改）',
      initialValue: preferred,
      onSelected: (String value) async {
        await repository.setPreferredQuality(value);
        await onChanged();
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: kAutoQualityId,
          child: Row(
            children: <Widget>[
              Icon(
                preferred == kAutoQualityId
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 15,
              ),
              const SizedBox(width: 8),
              Text('自动（${repository.effectiveQuality.label}）'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        for (final AudioQuality quality in repository.audioQualities)
          PopupMenuItem<String>(
            value: quality.id,
            child: Row(
              children: <Widget>[
                Icon(
                  preferred == quality.id
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 15,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(quality.label)),
                if (quality.description != null)
                  Text(
                    quality.description!,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(tokens.pillRadius),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              label,
              style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
            ),
            Icon(
              Icons.arrow_drop_down_rounded,
              size: 14,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

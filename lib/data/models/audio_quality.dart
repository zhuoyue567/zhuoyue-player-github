import 'package:flutter/foundation.dart';

/// 音质档位。
///
/// 刻意做成"音源各自声明一组档位"而不是一个全局枚举：网易云与哔哩的
/// 音质体系完全对不上（前者是 128k→320k→无损→Hi-Res→母带，
/// 后者是 64k→132k→192k + 杜比全景声 + Hi-Res 无损），
/// 用一套枚举硬套只会到处写 if。
@immutable
class AudioQuality {
  const AudioQuality({
    required this.id,
    required this.label,
    this.description,
    this.requiredVipLevel = 0,
  });

  /// 传给音源接口的值（网易云是 `level`，哔哩是内部标识）。
  final String id;

  /// 界面展示名。
  final String label;

  final String? description;

  /// 需要的会员等级：0 = 不需要会员，1 = 普通会员，2 = 高级会员。
  ///
  /// 只用于「自动」档位挑最高可用，以及界面上标注"需要会员"。
  /// 真正的授权判定永远以服务端返回为准 —— 这里只是**选择依据**，
  /// 不是权限判定（服务端给你降级，我们就用它给的结果）。
  final int requiredVipLevel;

  bool requiresVip(int vipLevel) => requiredVipLevel > vipLevel;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is AudioQuality && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'AudioQuality($id, $label)';
}

/// 「自动」档位的标识。
///
/// 用它而不是 `null` 表示自动，是为了让持久化与界面选择都统一成
/// "一个字符串 id"，少一层 nullable 分支。
const String kAutoQualityId = 'auto';

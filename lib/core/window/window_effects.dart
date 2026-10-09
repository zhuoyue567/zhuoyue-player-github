import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';

import '../theme/window_material.dart';

// ---------------------------------------------------------------------------
// Win32 结构体
// ---------------------------------------------------------------------------

/// `ACCENT_POLICY`（undocumented，随 `SetWindowCompositionAttribute` 使用）。
final class _AccentPolicy extends Struct {
  @Uint32()
  external int accentState;

  @Uint32()
  external int accentFlags;

  /// 颜色是 **ABGR** 排列的 `0xAABBGGRR`，不是常见的 ARGB —— 传错会得到
  /// 红蓝互换的诡异底色，这是踩过的坑里最容易忽略的一个。
  @Uint32()
  external int gradientColor;

  @Uint32()
  external int animationId;
}

/// `WINDOWCOMPOSITIONATTRIBDATA`。
///
/// 布局在 x64 上是 `{int(4) + pad(4) + ptr(8) + size_t(8)} = 24` 字节，
/// Dart FFI 会按平台 ABI 自动补对齐，不需要手写 padding。
final class _WinCompAttrData extends Struct {
  @Uint32()
  external int attrib;

  external Pointer<Void> pvData;

  @IntPtr()
  external int cbData;
}

/// `MARGINS`，配合 `DwmExtendFrameIntoClientArea` 使用。
final class _Margins extends Struct {
  @Int32()
  external int cxLeftWidth;

  @Int32()
  external int cxRightWidth;

  @Int32()
  external int cyTopHeight;

  @Int32()
  external int cyBottomHeight;
}

/// `OSVERSIONINFOEXW`，用 `RtlGetVersion` 填充。
///
/// 之所以不用 `GetVersionEx`：那个 API 在 Win8.1 之后会被应用兼容性清单
/// 劫持，永远返回 6.2，探测 Windows 11 会直接失效。`RtlGetVersion` 是
/// 内核导出、不受清单影响，也是目前公认可靠的做法。
final class _OsVersionInfoExW extends Struct {
  @Uint32()
  external int dwOSVersionInfoSize;

  @Uint32()
  external int dwMajorVersion;

  @Uint32()
  external int dwMinorVersion;

  @Uint32()
  external int dwBuildNumber;

  @Uint32()
  external int dwPlatformId;

  @Array(128)
  external Array<Uint16> szCSDVersion;

  @Uint16()
  external int wServicePackMajor;

  @Uint16()
  external int wServicePackMinor;

  @Uint16()
  external int wSuiteMask;

  @Uint8()
  external int wProductType;

  @Uint8()
  external int wReserved;
}

// ---------------------------------------------------------------------------
// 函数签名
// ---------------------------------------------------------------------------

typedef _FindWindowExWNative = IntPtr Function(
  IntPtr hwndParent,
  IntPtr hwndChildAfter,
  Pointer<Utf16> className,
  Pointer<Utf16> windowName,
);
typedef _FindWindowExWDart = int Function(
  int hwndParent,
  int hwndChildAfter,
  Pointer<Utf16> className,
  Pointer<Utf16> windowName,
);

typedef _GetWindowThreadProcessIdNative = Uint32 Function(
  IntPtr hwnd,
  Pointer<Uint32> pid,
);
typedef _GetWindowThreadProcessIdDart = int Function(
  int hwnd,
  Pointer<Uint32> pid,
);

typedef _GetCurrentProcessIdNative = Uint32 Function();
typedef _GetCurrentProcessIdDart = int Function();

typedef _SetWindowCompositionAttributeNative = Int32 Function(
  IntPtr hwnd,
  Pointer<_WinCompAttrData> data,
);
typedef _SetWindowCompositionAttributeDart = int Function(
  int hwnd,
  Pointer<_WinCompAttrData> data,
);

typedef _DwmSetWindowAttributeNative = Int32 Function(
  IntPtr hwnd,
  Uint32 attribute,
  Pointer<Void> value,
  Uint32 size,
);
typedef _DwmSetWindowAttributeDart = int Function(
  int hwnd,
  int attribute,
  Pointer<Void> value,
  int size,
);

typedef _DwmExtendFrameIntoClientAreaNative = Int32 Function(
  IntPtr hwnd,
  Pointer<_Margins> margins,
);
typedef _DwmExtendFrameIntoClientAreaDart = int Function(
  int hwnd,
  Pointer<_Margins> margins,
);

typedef _RtlGetVersionNative = Int32 Function(Pointer<_OsVersionInfoExW> info);
typedef _RtlGetVersionDart = int Function(Pointer<_OsVersionInfoExW> info);

// ---------------------------------------------------------------------------
// 能力探测
// ---------------------------------------------------------------------------

/// 当前系统的窗口材质能力。
@immutable
class WindowsBackdropSupport {
  const WindowsBackdropSupport({
    required this.buildNumber,
    required this.majorVersion,
    required this.minorVersion,
  });

  final int buildNumber;
  final int majorVersion;
  final int minorVersion;

  /// Windows 11 起始 build。
  bool get isWindows11 => buildNumber >= 22000;

  /// Mica / Mica Alt 需要 Win11 21H2（22000）及以上。
  bool get supportsMica => buildNumber >= 22000;

  /// `DWMWA_SYSTEMBACKDROP_TYPE` 这个属性本身要到 Win11 22H2（22621）才有；
  /// 更早的版本只能用 `DWMWA_MICA_EFFECT`（build 22000~22620 的实验性属性）。
  bool get supportsBackdropType => buildNumber >= 22621;

  /// `ACCENT_ENABLE_ACRYLICBLURBEHIND` 从 Win10 1803（17134）开始可用。
  bool get supportsAcrylic => buildNumber >= 17134;

  /// 老式 Aero 模糊，Vista 起就有。
  bool get supportsBlur => true;

  String get label => isWindows11
      ? 'Windows 11 (build $buildNumber)'
      : 'Windows 10 (build $buildNumber)';
}

// ---------------------------------------------------------------------------
// 窗口效果
// ---------------------------------------------------------------------------

/// 真正应用之后的结果。
///
/// 之所以要回传「实际应用了什么」而不是闷头设置：用户选了 Mica 但系统是
/// Win10 时，应用只能退化成亚克力。这个差异必须能在设置页说明白，
/// 否则用户只会觉得"这个材质开关是坏的"。
@immutable
class AppliedBackdrop {
  const AppliedBackdrop({
    required this.requested,
    required this.applied,
    this.note,
  });

  final ZhyWindowMaterial requested;

  /// 实际生效的材质；完全不支持系统效果时为 null。
  final ZhyWindowMaterial? applied;

  /// 给用户看的说明（降级原因等）。
  final String? note;

  /// 是否发生了降级。
  bool get isFallback => applied != requested;

  /// 系统效果是否真的生效了。
  bool get isSystemEffect => applied?.usesSystemEffect ?? false;
}

/// Windows 窗口材质（Mica / 亚克力 / 高斯模糊）实现。
///
/// **为什么不直接用 `flutter_acrylic`**：它最后一次发版是 2024 年 6 月，
/// 且把 `win32` 锁在 5.x；本项目需要 `win32` 6.x。更要紧的是它没有覆盖
/// `DWMWA_SYSTEMBACKDROP_TYPE` 这条 Win11 22H2+ 的正路，也没有能力探测。
/// 自己用 `dart:ffi` 直接调 Win32 反而代码更少、行为更可控，
/// 而且完全不需要编译期插件（纯 Dart，改完直接热重载）。
class WindowEffects {
  WindowEffects._();

  static const String _windowClassName = 'FLUTTER_RUNNER_WIN32_WINDOW';

  // ---- DWMWINDOWATTRIBUTE ----
  static const int _dwmwaUseImmersiveDarkMode = 20;
  static const int _dwmwaWindowCornerPreference = 33;
  static const int _dwmwaBorderColor = 34;
  static const int _dwmwaCaptionColor = 35;
  static const int _dwmwaTextColor = 36;
  static const int _dwmwaSystemBackdropType = 38;

  /// build 22000 ~ 22620 上 Mica 只能靠这个未公开属性开启。
  static const int _dwmwaMicaEffect = 1029;

  /// `DWMWA_COLOR_NONE`：让系统自己决定边框颜色。
  static const int _dwmColorNone = 0xFFFFFFFE;

  // ---- DWM_SYSTEMBACKDROP_TYPE ----
  static const int _dwmsbtNone = 1;
  static const int _dwmsbtMainWindow = 2; // Mica
  static const int _dwmsbtTransientWindow = 3; // Acrylic
  static const int _dwmsbtTabbedWindow = 4; // Mica Alt

  // ---- WINDOWCOMPOSITIONATTRIB ----
  static const int _wcaAccentPolicy = 19;

  // ---- ACCENT_STATE ----
  static const int _accentDisabled = 0;
  static const int _accentEnableBlurBehind = 3;
  static const int _accentEnableAcrylicBlurBehind = 4;

  /// 让强调色铺满四个边框，否则系统模糊只作用于一条细边。
  static const int _accentFlagDrawAllBorders = 0x20 | 0x40 | 0x80 | 0x100;

  static DynamicLibrary? _user32;
  static DynamicLibrary? _dwmapi;
  static DynamicLibrary? _ntdll;
  static DynamicLibrary? _kernel32;

  static _FindWindowExWDart? _findWindowEx;
  static _GetWindowThreadProcessIdDart? _getWindowThreadProcessId;
  static _GetCurrentProcessIdDart? _getCurrentProcessId;
  static _SetWindowCompositionAttributeDart? _setWindowCompositionAttribute;
  static _DwmSetWindowAttributeDart? _dwmSetWindowAttribute;
  static _DwmExtendFrameIntoClientAreaDart? _dwmExtendFrameIntoClientArea;
  static _RtlGetVersionDart? _rtlGetVersion;

  static bool _bindingsReady = false;
  static bool _bindingsFailed = false;

  static WindowsBackdropSupport? _support;
  static int? _cachedHandle;

  /// 当前平台是否支持（仅 Windows）。
  static bool get isSupported => Platform.isWindows;

  /// 系统能力探测结果。绑定失败时返回一个保守的兜底值。
  static WindowsBackdropSupport get support {
    WindowsBackdropSupport? cached = _support;
    if (cached != null) return cached;
    cached = _probeVersion();
    _support = cached;
    return cached;
  }

  /// 查找属于**本进程**的主窗口句柄；找不到返回 0。
  ///
  /// 这里刻意不用 `FindWindowW(类名, null)`：窗口类名是编译期固定的，
  /// 用户同时开两个实例时它会返回**另一个实例**的窗口，于是"设置亚克力"
  /// 结果作用到了别的窗口上。改成枚举同类的窗口再按进程号过滤才是正确的。
  static int windowHandle() {
    final int? cached = _cachedHandle;
    if (cached != null && cached != 0) return cached;
    if (!_ensureBindings()) return 0;

    final _FindWindowExWDart? findWindowEx = _findWindowEx;
    final _GetWindowThreadProcessIdDart? getWindowThreadProcessId =
        _getWindowThreadProcessId;
    final _GetCurrentProcessIdDart? getCurrentProcessId = _getCurrentProcessId;
    if (findWindowEx == null ||
        getWindowThreadProcessId == null ||
        getCurrentProcessId == null) {
      return 0;
    }

    final int pid = getCurrentProcessId();
    final Pointer<Utf16> className = _windowClassName.toNativeUtf16();
    final Pointer<Uint32> pidOut = calloc<Uint32>();
    try {
      int handle = 0;
      // FindWindowEx 的第二个参数传上一个兄弟窗口即可实现枚举。
      while (true) {
        handle = findWindowEx(0, handle, className, nullptr);
        if (handle == 0) return 0;
        getWindowThreadProcessId(handle, pidOut);
        if (pidOut.value == pid) {
          _cachedHandle = handle;
          return handle;
        }
      }
    } finally {
      calloc.free(className);
      calloc.free(pidOut);
    }
  }

  /// 应用窗口材质。
  ///
  /// [tintArgb] 是强调色/染色层颜色，仅在走 `SetWindowCompositionAttribute`
  /// 的路径上使用；[opacity] 决定染色层的不透明度（0~1）。
  static AppliedBackdrop applyMaterial(
    ZhyWindowMaterial material, {
    required Color tintArgb,
    double opacity = 0.78,
    bool dark = true,
  }) {
    if (!isSupported) {
      return AppliedBackdrop(
        requested: material,
        applied: null,
        note: '当前平台不是 Windows，已退回 Flutter 自绘背景',
      );
    }

    final int hwnd = windowHandle();
    if (hwnd == 0) {
      return AppliedBackdrop(
        requested: material,
        applied: null,
        note: '尚未取得窗口句柄（窗口可能还没创建完成）',
      );
    }

    // 这三项与材质无关，任何模式下都顺手设好：
    // 标题栏深色、圆角、细边框。
    setImmersiveDarkMode(dark);
    setRoundedCorners(true);
    setBorderColor(null);

    final WindowsBackdropSupport caps = support;

    switch (material) {
      case ZhyWindowMaterial.mica:
      case ZhyWindowMaterial.micaAlt:
        final int backdrop = material == ZhyWindowMaterial.mica
            ? _dwmsbtMainWindow
            : _dwmsbtTabbedWindow;
        if (caps.supportsBackdropType) {
          _clearAccent(hwnd);
          _extendFrameIntoClientArea(hwnd);
          if (_setBackdropType(hwnd, backdrop)) {
            return AppliedBackdrop(requested: material, applied: material);
          }
        } else if (material == ZhyWindowMaterial.mica && caps.supportsMica) {
          // 22000~22620：只有未公开的 DWMWA_MICA_EFFECT 可用。
          _clearAccent(hwnd);
          _extendFrameIntoClientArea(hwnd);
          if (_setIntAttribute(hwnd, _dwmwaMicaEffect, 1)) {
            return AppliedBackdrop(
              requested: material,
              applied: material,
              note: 'Windows build ${caps.buildNumber} 使用实验性 Mica 属性开启',
            );
          }
        }
        // 系统不支持 Mica：退到亚克力，并明确告知。
        final AppliedBackdrop fallback = _applyAccentPath(
          hwnd,
          caps,
          ZhyWindowMaterial.acrylic,
          tintArgb,
          opacity,
          requested: material,
        );
        return AppliedBackdrop(
          requested: material,
          applied: fallback.applied,
          note:
              '当前系统（${caps.label}）不支持 ${material.label}，已改用'
              '${fallback.applied?.label ?? "Flutter 自绘背景"}',
        );

      case ZhyWindowMaterial.acrylic:
        return _applyAccentPath(
          hwnd,
          caps,
          material,
          tintArgb,
          opacity,
          requested: material,
        );

      case ZhyWindowMaterial.blur:
        return _applyAccentPath(
          hwnd,
          caps,
          material,
          tintArgb,
          opacity,
          requested: material,
        );

      case ZhyWindowMaterial.solid:
      case ZhyWindowMaterial.simulated:
        _setBackdropType(hwnd, _dwmsbtNone);
        _setIntAttribute(hwnd, _dwmwaMicaEffect, 0);
        _clearAccent(hwnd);
        return AppliedBackdrop(requested: material, applied: material);
    }
  }

  static AppliedBackdrop _applyAccentPath(
    int hwnd,
    WindowsBackdropSupport caps,
    ZhyWindowMaterial material,
    Color tintArgb,
    double opacity, {
    required ZhyWindowMaterial requested,
  }) {
    // Win11 22H2+ 走正规的 backdrop 属性，比未公开的 accent policy 稳，
    // 也能正确响应系统的"透明效果"开关。
    if (material == ZhyWindowMaterial.acrylic && caps.supportsBackdropType) {
      _clearAccent(hwnd);
      _extendFrameIntoClientArea(hwnd);
      if (_setBackdropType(hwnd, _dwmsbtTransientWindow)) {
        return AppliedBackdrop(requested: requested, applied: material);
      }
    }

    _setBackdropType(hwnd, _dwmsbtNone);
    _extendFrameIntoClientArea(hwnd);

    final int state = material == ZhyWindowMaterial.acrylic
        ? _accentEnableAcrylicBlurBehind
        : _accentEnableBlurBehind;
    if (!caps.supportsAcrylic && material == ZhyWindowMaterial.acrylic) {
      // Win10 1803 以下没有亚克力，只有老式模糊。
      if (_setAccent(hwnd, _accentEnableBlurBehind, tintArgb, opacity)) {
        return AppliedBackdrop(
          requested: requested,
          applied: ZhyWindowMaterial.blur,
          note: '当前系统（${caps.label}）不支持亚克力，已退回高斯模糊',
        );
      }
      return AppliedBackdrop(
        requested: requested,
        applied: null,
        note: '当前系统（${caps.label}）不支持任何系统级模糊效果',
      );
    }

    if (_setAccent(hwnd, state, tintArgb, opacity)) {
      return AppliedBackdrop(requested: requested, applied: material);
    }
    return AppliedBackdrop(
      requested: requested,
      applied: null,
      note: '设置窗口模糊失败（可能被系统"透明效果"开关或远程桌面禁用）',
    );
  }

  /// 标题栏深色模式。
  static bool setImmersiveDarkMode(bool dark) {
    final int hwnd = windowHandle();
    if (hwnd == 0) return false;
    return _setIntAttribute(hwnd, _dwmwaUseImmersiveDarkMode, dark ? 1 : 0);
  }

  /// 是否使用系统圆角。无边框窗口需要自己画圆角时传 false。
  static bool setRoundedCorners(bool rounded) {
    final int hwnd = windowHandle();
    if (hwnd == 0) return false;
    // DWMWCP_ROUND = 2, DWMWCP_DONOTROUND = 1
    return _setIntAttribute(
      hwnd,
      _dwmwaWindowCornerPreference,
      rounded ? 2 : 1,
    );
  }

  /// 窗口边框颜色。传 null 交回系统决定。
  static bool setBorderColor(Color? color) {
    final int hwnd = windowHandle();
    if (hwnd == 0) return false;
    // 边框色是 COLORREF（0x00BBGGRR），不是 ABGR 也不是 ARGB。
    final int value = color == null
        ? _dwmColorNone
        : (color.b * 255).round() |
              (((color.g * 255).round()) << 8) |
              (((color.r * 255).round()) << 16);
    return _setIntAttribute(hwnd, _dwmwaBorderColor, value);
  }

  /// 标题栏底色。传 null 交回系统决定。
  static bool setCaptionColor(Color? color) {
    final int hwnd = windowHandle();
    if (hwnd == 0) return false;
    final int value = color == null
        ? _dwmColorNone
        : (color.b * 255).round() |
              (((color.g * 255).round()) << 8) |
              (((color.r * 255).round()) << 16);
    return _setIntAttribute(hwnd, _dwmwaCaptionColor, value);
  }

  /// 标题栏文字颜色。
  static bool setTextColor(Color? color) {
    final int hwnd = windowHandle();
    if (hwnd == 0) return false;
    final int value = color == null
        ? _dwmColorNone
        : (color.b * 255).round() |
              (((color.g * 255).round()) << 8) |
              (((color.r * 255).round()) << 16);
    return _setIntAttribute(hwnd, _dwmwaTextColor, value);
  }

  /// 窗口句柄失效时清掉缓存（例如窗口被重建）。
  static void invalidateHandleCache() => _cachedHandle = null;

  // -------------------------------------------------------------------------
  // 内部实现
  // -------------------------------------------------------------------------

  static bool _setIntAttribute(int hwnd, int attribute, int value) {
    final _DwmSetWindowAttributeDart? fn = _dwmSetWindowAttribute;
    if (fn == null) return false;
    final Pointer<Int32> buffer = calloc<Int32>();
    try {
      buffer.value = value;
      final int hr = fn(hwnd, attribute, buffer.cast<Void>(), sizeOf<Int32>());
      if (hr != 0) {
        debugPrint(
          '[window] DwmSetWindowAttribute($attribute) 返回 HRESULT '
          '0x${hr.toRadixString(16)}',
        );
        return false;
      }
      return true;
    } finally {
      calloc.free(buffer);
    }
  }

  static bool _setBackdropType(int hwnd, int type) =>
      _setIntAttribute(hwnd, _dwmwaSystemBackdropType, type);

  static bool _setAccent(
    int hwnd,
    int accentState,
    Color tint,
    double opacity,
  ) {
    final _SetWindowCompositionAttributeDart? fn =
        _setWindowCompositionAttribute;
    if (fn == null) return false;

    final Pointer<_AccentPolicy> policy = calloc<_AccentPolicy>();
    final Pointer<_WinCompAttrData> data = calloc<_WinCompAttrData>();
    try {
      final int alpha = (opacity.clamp(0.0, 1.0) * 255).round();
      final int r = (tint.r * 255).round();
      final int g = (tint.g * 255).round();
      final int b = (tint.b * 255).round();

      policy.ref
        ..accentState = accentState
        ..accentFlags = _accentFlagDrawAllBorders
        // ABGR：0xAABBGGRR
        ..gradientColor = (alpha << 24) | (b << 16) | (g << 8) | r
        ..animationId = 0;

      data.ref
        ..attrib = _wcaAccentPolicy
        ..pvData = policy.cast<Void>()
        ..cbData = sizeOf<_AccentPolicy>();

      return fn(hwnd, data) != 0;
    } finally {
      calloc.free(policy);
      calloc.free(data);
    }
  }

  static void _clearAccent(int hwnd) {
    final _SetWindowCompositionAttributeDart? fn =
        _setWindowCompositionAttribute;
    if (fn == null) return;
    final Pointer<_AccentPolicy> policy = calloc<_AccentPolicy>();
    final Pointer<_WinCompAttrData> data = calloc<_WinCompAttrData>();
    try {
      policy.ref
        ..accentState = _accentDisabled
        ..accentFlags = 0
        ..gradientColor = 0
        ..animationId = 0;
      data.ref
        ..attrib = _wcaAccentPolicy
        ..pvData = policy.cast<Void>()
        ..cbData = sizeOf<_AccentPolicy>();
      fn(hwnd, data);
    } finally {
      calloc.free(policy);
      calloc.free(data);
    }
  }

  /// 把 DWM 边框扩展到整个客户区。
  ///
  /// Mica / 亚克力要覆盖 Flutter 绘制的区域，就必须让 DWM 认为
  /// "整个客户区都属于边框"。这是 Mica 生效的常见前提之一。
  static void _extendFrameIntoClientArea(int hwnd) {
    final _DwmExtendFrameIntoClientAreaDart? fn = _dwmExtendFrameIntoClientArea;
    if (fn == null) return;
    final Pointer<_Margins> margins = calloc<_Margins>();
    try {
      margins.ref
        ..cxLeftWidth = -1
        ..cxRightWidth = -1
        ..cyTopHeight = -1
        ..cyBottomHeight = -1;
      fn(hwnd, margins);
    } finally {
      calloc.free(margins);
    }
  }

  static bool _ensureBindings() {
    if (_bindingsReady) return true;
    if (_bindingsFailed) return false;
    if (!isSupported) {
      _bindingsFailed = true;
      return false;
    }

    try {
      _user32 = DynamicLibrary.open('user32.dll');
      _dwmapi = DynamicLibrary.open('dwmapi.dll');
      _ntdll = DynamicLibrary.open('ntdll.dll');
      _kernel32 = DynamicLibrary.open('kernel32.dll');

      _findWindowEx = _user32!
          .lookupFunction<_FindWindowExWNative, _FindWindowExWDart>(
            'FindWindowExW',
          );
      _getWindowThreadProcessId = _user32!
          .lookupFunction<
            _GetWindowThreadProcessIdNative,
            _GetWindowThreadProcessIdDart
          >('GetWindowThreadProcessId');

      // GetCurrentProcessId 在 **kernel32** 里，不是 user32。
      // 一开始写错成 user32，结果是整层绑定一起失败、窗口句柄永远是 0，
      // 表现为"亚克力设置完全没反应"。用一个测试把真实版本号断言出来才抓到。
      _getCurrentProcessId = _kernel32!
          .lookupFunction<_GetCurrentProcessIdNative, _GetCurrentProcessIdDart>(
            'GetCurrentProcessId',
          );

      // SetWindowCompositionAttribute 没有公开的头文件声明，只能按名字取；
      // 取不到也不能崩，只是亚克力不可用而已。
      try {
        _setWindowCompositionAttribute = _user32!
            .lookupFunction<
              _SetWindowCompositionAttributeNative,
              _SetWindowCompositionAttributeDart
            >('SetWindowCompositionAttribute');
      } on ArgumentError {
        debugPrint('[window] 未找到 SetWindowCompositionAttribute，亚克力将退回 Mica/自绘');
      }

      _dwmSetWindowAttribute = _dwmapi!
          .lookupFunction<
            _DwmSetWindowAttributeNative,
            _DwmSetWindowAttributeDart
          >('DwmSetWindowAttribute');
      _dwmExtendFrameIntoClientArea = _dwmapi!
          .lookupFunction<
            _DwmExtendFrameIntoClientAreaNative,
            _DwmExtendFrameIntoClientAreaDart
          >('DwmExtendFrameIntoClientArea');
      _rtlGetVersion = _ntdll!
          .lookupFunction<_RtlGetVersionNative, _RtlGetVersionDart>(
            'RtlGetVersion',
          );

      _bindingsReady = true;
      return true;
    } on Object catch (error) {
      debugPrint('[window] Win32 绑定失败，窗口材质功能停用: $error');
      _bindingsFailed = true;
      return false;
    }
  }

  static WindowsBackdropSupport _probeVersion() {
    if (!isSupported || !_ensureBindings()) {
      return const WindowsBackdropSupport(
        buildNumber: 0,
        majorVersion: 0,
        minorVersion: 0,
      );
    }
    final _RtlGetVersionDart? fn = _rtlGetVersion;
    if (fn == null) {
      return const WindowsBackdropSupport(
        buildNumber: 0,
        majorVersion: 0,
        minorVersion: 0,
      );
    }

    final Pointer<_OsVersionInfoExW> info = calloc<_OsVersionInfoExW>();
    try {
      info.ref.dwOSVersionInfoSize = sizeOf<_OsVersionInfoExW>();
      final int status = fn(info);
      if (status != 0) {
        return const WindowsBackdropSupport(
          buildNumber: 0,
          majorVersion: 0,
          minorVersion: 0,
        );
      }
      return WindowsBackdropSupport(
        buildNumber: info.ref.dwBuildNumber,
        majorVersion: info.ref.dwMajorVersion,
        minorVersion: info.ref.dwMinorVersion,
      );
    } finally {
      calloc.free(info);
    }
  }
}

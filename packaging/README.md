# 打包与安装包

这个目录里只有"怎么把应用发出去"的东西，没有应用代码。

```powershell
# 一条命令产出安装包（会先做 release 构建）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-installer.ps1

# 只调安装脚本、不重新构建（改 .iss 时用这个，几秒钟就能看到结果）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-installer.ps1 -SkipBuild -Configuration Debug
```

| 路径 | 是什么 | 进仓库吗 |
| --- | --- | --- |
| `zhuoyue-player.iss` | Inno Setup 脚本（安装界面、页面、写配置） | ✅ 进 |
| `languages\ChineseSimplified.isl` | 安装向导的简体中文文案（Inno 官方仓库里那份） | ✅ 进 |
| `staging\` | 从 `build\...\runner\<配置>` 拷贝出来的"即将打包的内容" | ❌ 构建产物 |
| `dist\` | 编译出来的 `*-setup.exe` | ❌ 构建产物 |

## 三个刻意的取舍

**1. 按用户安装，不要管理员权限**（`PrivilegesRequired=lowest`）
装到 `%LOCALAPPDATA%\Programs`。这样不弹 UAC，而且"安装完就能勾开机自启动"是天然成立的
—— 开机自启动写的是 `HKCU` 的 `Run` 项，按用户安装与它匹配。想装到 `Program Files`
的用户仍然可以自己改路径（那时会要管理员，写入启动项的位置也随之变成同一个 HKCU 项）。

**2. 不含 Node 运行时**（那 121MB 由应用首次启动时自己下载）
所以安装包很小，但**首次启动必须联网**。这不是偷懒：把 121MB 的 Node 与
`node_modules` 塞进安装包会让包体大三倍，而绝大多数用户只需要一次下载。

**3. 不含内置字体 `zhuzi.ttf`**
它的再分发许可未经核实，作者按"自用字体"处理：**随源码仓库分发，不随安装包分发**。
`scripts/build-installer.ps1` 会在暂存阶段把它删掉，**并且**从 `FontManifest.json`
（以及 `AssetManifest.json`，如果列了它）里摘掉对应条目 —— 只删文件是不够的，
清单里还列着它的话，引擎会去找一个不存在的资源。脚本最后会**校验**暂存目录里确实
没有字体残留，缺文件就中止构建。

应用侧的代价：字体缺失时 `ThemeData.fontFamily` 指向的家族不存在，Flutter 会回退到
系统字体，不会崩，但观感会变。这是刻意接受的结果。

## 安装时选的两个路径怎么传给应用

安装器把结果写成 **`%APPDATA%\com.zhuoyue\zhuoyue_player\installer.json`**：

**格式示例**（下面的路径只是举例，不是默认值）：

```json
{
  "schema": 1,
  "appVersion": "0.1.0",
  "installDir": "D:\\Apps\\ZhuoYue Player",
  "cacheDir": "D:\\ZhuoYue\\cache",
  "downloadDir": "D:\\Music",
  "installedAt": "2026-10-09 00:15:17"
}
```

安装器**实际的默认值**（以 `zhuoyue-player.iss` 为准）：

| 字段 | 默认值 |
| --- | --- |
| `installDir` | `{autopf}\ZhuoYue Player` —— 按用户安装时即 `%LOCALAPPDATA%\Programs\ZhuoYue Player` |
| `cacheDir` | `%APPDATA%\ZhuoYue Player\cache` |
| `downloadDir` | `%USERPROFILE%\Documents\ZhuoYue Player\Music` |

三个都能在安装向导里改。

- 用**文件**而不是注册表：应用本来就在这个目录下存 `shared_preferences`（同一个
  `path_provider` 的 application support 目录），读到之后可以自己决定何时采纳、
  何时忽略；卸载也不会留下注册表垃圾。
- `schema` 是给未来的：字段要变时靠它做兼容，而不是靠猜。
- 应用侧读取后应当**记住"已采纳"**，这样用户在设置里改过的路径不会被安装器的旧值盖回去。

## 首次启动会做什么

1. 应用发现自己没有可用的 Node 运行时（`runtime/` 里要有 `node/` 与 `netease-api/`）；
2. 引导页里联网下载并解压到应用数据目录；
3. 之后正常启动。

如果下载失败，应用会给出可操作的提示（重试 / 手动指定运行时目录），**不会**再像开发期
那样让用户去跑 `scripts/fetch-runtime.ps1` —— 那是开发者脚本，安装后的用户没有仓库。

## 已知的粗糙处（都如实记着）

- 安装向导的中文文案来自 Inno 官方仓库的 `ChineseSimplified.isl`（标注 6.5.0+），
  与当前 6.7.3 之间若有新增文案，会显示英文原文 —— 编译时 ISCC 会给出提示。
- 安装器的自定义页面（缓存目录 / 下载目录）在**静默安装**（`/SILENT`）时会用默认值，
  这是 Inno 的固有行为：自定义页面的输入没有命令行参数可以替代。
- 「立即运行」与「开机自启动」是完成页上的两个勾选框（走 `[Run]` + `Flags: postinstall`）。
  静默安装会跳过它们（`skipifsilent`）。
- 应用图标用的是 `windows\runner\resources\app_icon.ico`；exe 的版本信息来自
  `windows\runner\Runner.rc`，与 `pubspec.yaml` 的版本号是两处，发版时要一起改。

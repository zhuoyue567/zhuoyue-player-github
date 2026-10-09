# 接口集成

两类后端，两套完全不同的接入方式：

| | 网易云音乐 | Bilibili |
| --- | --- | --- |
| 调用方 | 内嵌 Node 服务 `NeteaseCloudMusicApi` 4.32.0（子进程） | Dart 直连（`dio`） |
| 基址 | `http://127.0.0.1:<动态端口>`（由 launcher 决定） | `https://api.bilibili.com` / `https://passport.bilibili.com` |
| 成功标志 | `code == 200` | `code == 0` |
| 鉴权 | `cookie` 参数，Cookie 由 Dart 侧持有并逐请求下发 | Cookie（`SESSDATA` 等）由 Dart 侧持有，请求头携带 |
| 特殊头 | 无 | **必需** `Referer: https://www.bilibili.com` + 浏览器 `User-Agent` |
| 登录 | 二维码 / 手机号 | 二维码（web 端 qrcode） |

---

## §1 网易云

### 1.1 内嵌运行时

由 `scripts/fetch-runtime.ps1` 准备，产物全部在 `runtime/`（已 gitignore），构建时 CMake 复制到 exe 同级：

```
runtime/
├─ node/                         # nodejs.org 便携版 win-x64（SHA256 校验）
│  ├─ node.exe                   # ~80 MB
│  └─ npm.cmd
└─ netease-api/
   ├─ package.json               # 只声明 NeteaseCloudMusicApi@4.32.0
   ├─ node_modules/              # 从 registry.npmmirror.com 安装
   └─ launcher.js                # 启动器：选端口 → 起服务 → 探测 → 打印就绪行
```

进程环境与启动参数：

| 项 | 值 | 说明 |
| --- | --- | --- |
| 可执行文件 | `<runtime>/node/node.exe` | 调试时从仓库根 `runtime/`，安装后从 exe 同级 `runtime/` |
| 参数 | `launcher.js` | 入口即启动器，不直接 require API |
| 工作目录 | `<runtime>/netease-api/` | 保证 `require('NeteaseCloudMusicApi')` 能解析 |
| `ZHUOYUE_HOST` | `127.0.0.1` | 仅 loopback，不监听外部网卡 |
| `PORT` | 由 launcher 写入（`listen(0)` 取得） | 环境变量与 `serveNcmApi({port})` 同时给，兼容不同版本读取来源 |
| `checkVersion: false` | 传给 `serveNcmApi` | 关闭启动时的版本检查（会访问 GitHub，本机不可达） |
| stdout | 逐行读取，**只认** `ZHUOYUE_API_READY <port>` | 唯一就绪信号，避免端口就绪与 HTTP 可响应之间的竞态 |
| stderr | 落盘到日志目录并在「诊断」里可看 | launcher 的错误码：2=加载 API 失败、3=版本不兼容、4=启动抛错、5=60s 未就绪、1=其他 |
| stdin | 不使用 | 退出走信号/强杀，不做 stdin 协议 |

就绪握手（Dart 侧）：

```dart
// 逐行读 stdout，超时 60s
await for (final line in process.stdout.transform(utf8.decoder).transform(const LineSplitter())) {
  final m = RegExp(r'^ZHUOYUE_API_READY (\d+)$').firstMatch(line.trim());
  if (m != null) {
    _baseUrl = Uri.parse('http://127.0.0.1:${m.group(1)}');
    _ready.complete(_baseUrl);
    return;
  }
}
```

生命周期细节（惰性启动、健康探测、优雅退出、端口冲突处理）见 [architecture.md](architecture.md#内嵌-node-服务生命周期)。

### 1.2 Cookie 归属

**Cookie 的唯一所有者是 Dart 侧**（`data/netease/netease_cookie_store.dart`）：

- 登录成功后，从接口响应里取出 cookie 字符串（形如 `MUSIC_U=...; __csrf=...`），整体写入 `shared_preferences` 的 `netease.cookie`。
- 每个请求都把 cookie 作为**查询参数/表单字段** `cookie` 传给内嵌服务（不依赖 Node 侧的会话状态），因此：
  - App 重启后登录态自动恢复，不需要重新登录；
  - 重装/重启 Node 进程不会丢登录态；
  - 切换账号只是替换这个字符串，无需清 Node 缓存。
- 退出登录：调 `/logout` 后立即清空本地字符串与内存中的用户信息，再刷新 UI。
- 服务启动时不带任何 cookie，避免把用户凭证明文写进进程环境。

### 1.3 接口清单

方法列中 `GET` 表示只读查询，`POST` 用于提交（登录、点赞）；NeteaseCloudMusicApi 对多数接口同时接受两者，项目内统一按本表执行。所有请求都经 `NeteaseClient`（dio），统一带 `cookie`（未登录时不带）与 `timestamp`（防缓存）。

| 路径 | 方法 | 用途 | 备注 |
| --- | --- | --- | --- |
| `/login/qr/key` | GET | 获取二维码 key（unicode） | 第一步 |
| `/login/qr/create` | GET | 用 key 生成二维码图片（base64） | 参数 `qrimg=true` 直接拿图片 |
| `/login/qr/check` | GET | 轮询扫码状态 | `800` 过期 / `801` 待扫 / `802` 待确认 / `803` 成功（成功时响应带 cookie） |
| `/login/status` | GET | 查询当前登录状态 | 传 `cookie` |
| `/login/cellphone` | POST | 手机号 + 密码/验证码登录 | 参数 `phone`、`password` 或 `captcha` |
| `/logout` | POST | 退出登录 | 之后清本地 cookie |
| `/user/account` | GET | 当前账号信息（uid、vipType 等） | 用于顶部头像与会员标识 |
| `/user/playlist` | GET | 用户歌单（含「我喜欢的音乐」） | 参数 `uid` |
| `/playlist/detail` | GET | 歌单详情（含前若干首曲目） | 参数 `id` |
| `/playlist/track/all` | GET | 歌单全量曲目（分页） | 参数 `id`、`limit`、`offset` |
| `/song/url/v1` | GET | **获取播放地址（核心）** | 参数 `id`、`level`（`standard`/`higher`/`exhigh`/`lossless`）；响应 `data[0].url` 可能为 `null` |
| `/song/detail` | GET | 歌曲详情（名称、歌手、专辑、封面、时长） | 参数 `ids`（逗号分隔），批量用 |
| `/search` | GET | 综合搜索 | 参数 `keywords`、`type`（1=单曲，1000=歌单）、`limit`、`offset` |
| `/search/default` | GET | 默认搜索关键词 | 用于搜索框占位提示 |
| `/top/playlist` | GET | 排行榜/分类歌单 | 参数 `cat`、`limit`、`order` |
| `/personalized` | GET | 推荐歌单列表 | 发现页主要数据源 |
| `/recommend/songs` | GET | 每日推荐歌曲（需登录） | 未登录返回空，需提示 |
| `/likelist` | GET | 「喜欢的音乐」id 列表 | 参数 `uid`；用于给列表打红心态 |
| `/song/like` | POST | 红心/取消红心 | 参数 `id`、`like=true|false` |
| `/album` | GET | 专辑详情与曲目 | 参数 `id` |
| `/artist/top/song` | GET | 歌手热门 50 首 | 参数 `id` |
| `/lyric` | GET | 歌词（含翻译） | 参数 `id`；`lrc.lyric` / `tlyric.lyric` |
| `/song/download` | — | 下载地址 | **「待验证」**：4.32.0 未必暴露该路径，实际可能是 `/song/download/url/v1`；实现前先用 `/song/url/v1` 的响应体 + `dio.download` 落地，确认后再决定是否单独用下载接口 |

「待验证」表示文档不臆测其行为：实现时以本机 `runtime` 里该版本的实际路由表和一次真实请求为准，验证结果回填到本表。

### 1.4 响应信封与错误处理

统一信封：`{ "code": <int>, "status"?: ..., ...payload }`，**`code == 200` 视为成功**，其余按错误处理。`code == 200` 不等于业务可用，需再看 payload。

| 情况 | 判定 | UI 行为 |
| --- | --- | --- |
| 成功 | HTTP 200 且 `code == 200` | 正常渲染 |
| 未登录 | `code == 301`（需登录） | 跳登录页；不弹「网络错误」 |
| 需要付费/无版权 | `song/url/v1` 的 `data[0].url == null`；或列表层 `noCopyrightRcmd` 把它标成不可播（`Song.playable == false`，`unplayableReason` = 「该歌曲暂无版权，已下架」） | 曲目行置灰并给出原因；**播放时按队列切歌**（沿用户的行进方向继续找下一首能播的），封面 / 标题 / 歌词跟着切过去。判据是类型化信号（`playable` / `MusicApiException.unplayable`），**不去匹配错误文案** |
| 网络/地址类暂时失败 | 连接失败、403 地址过期 | **不**切歌：停在原地，播放条常驻显示原因 + 重试。换一首歌并不会让网络恢复，反而会把用户真正想听的那首跳过去 |
| 频率限制 | `code == 406`/`429` 或 HTTP 429 | 拦截器退避重试一次，仍失败则提示稍后再试 |
| 参数错误 | `code == 400` | 记录日志（含路径与参数），提示「请求参数异常」，视为客户端 bug |
| 服务未就绪 | 连接被拒（Node 未起/已崩） | 触发一次惰性重启；仍失败则展示「内嵌服务未启动，请查看日志」 |
| 网络不可达 | dio `DioException` | 统一文案「网络连接失败」+ 重试按钮 |
| 未知 code | 其他 | 记录 `code` 与响应体前 512 字符到日志，提示「接口返回异常（code=...）」 |

实现约定：DTO 解析对字段缺失一律宽容（可空 + 默认值），单个字段异常不能让整页崩；所有响应体在 `debug` 下截断落日志。

---

## §2 Bilibili

Bilibili 由 Dart 直连（`data/bilibili/`），**不经 Node**。除播放地址本身外，所有请求必须带：

| 头 | 值 | 原因 |
| --- | --- | --- |
| `Referer` | `https://www.bilibili.com` | 缺失会被防盗链拒绝（播放地址直接返回 403） |
| `User-Agent` | 桌面版浏览器 UA 字符串 | 默认的 `Dio/5.x` 会被识别为脚本请求 |
| `Cookie` | `SESSDATA=...; bili_jct=...; DedeUserID=...`（登录后） | 私有收藏夹与 `nav` 的登录态 |
| `Origin` | `https://www.bilibili.com`（POST/部分接口） | 与 Referer 一致的来源校验 |

**关键点**：`Referer` 与 `User-Agent` 不只在 API 请求上要带，**拉取音频流本身的 GET 也必须带**，否则 403。因此播放不走 `AudioEngine` 的裸 URL —— URL 与头一起交给 `AudioEngine`（`just_audio` 支持传 headers），并在重解析后更新头。

### 2.1 鉴权

二维码登录（`data/bilibili/bilibili_auth.dart`）：

```
1) GET  passport-login/web/qrcode/generate
        → { code:0, data:{ url, qrcode_key } }   // url 编成二维码展示
2) 轮询 GET passport-login/web/qrcode/poll?qrcode_key=<key>   （建议 2s 间隔）
        → data.code: 86101 未扫 / 86090 已扫待确认 / 86038 已过期 / 0 登录成功
3) code == 0 时，响应头 Set-Cookie 携带 SESSDATA、bili_jct、DedeUserID（以及用于续期的 ac_time_value）
        → 解析并持久化到 shared_preferences: bili.cookie
4) 登录态检查：GET x/web-interface/nav → data.isLogin / mid / uname / face
```

| 凭据 | 作用 | 失效表现与处理 |
| --- | --- | --- |
| `SESSDATA` | 主会话凭据（必需） | 失效 → `nav.isLogin == false` 或接口 `code == -101`；提示重新扫码 |
| `bili_jct` | CSRF token（写操作必需） | 缺失时写操作被拒；仅读接口可不用 |
| `DedeUserID` | 用户 mid | 用于取自己的收藏夹（`up_mid`） |
| `ac_time_value` | 用于 Cookie 刷新 | 见下 |

**刷新**：web 端刷新流程是 `passport-login/web/cookie/refresh`（需 `bili_jct` + `ac_time_value`，成功后需再调 `cookie/confirm/refresh` 确认）——该流程的**具体参数与返回值「待验证」**，实现时以真机抓包为准。v1 的兜底策略：不做自动刷新，检测到失效即提示重新扫码，并把刷新列为后续增强。

浏览他人**公开**收藏夹不需要登录（`up_mid` 填目标用户 mid 即可）；**私有**收藏夹必须有有效 `SESSDATA`。

#### 登录态为什么会"自己掉线"（实测结论）

同一台机器上出现「网易云还登录着、哔哩却变成未登录」是**正常现象，不是 bug**：

| | 网易云 | 哔哩哔哩 |
| --- | --- | --- |
| 凭据 | `MUSIC_U` | `SESSDATA` |
| 有效期的量级 | 数月 | 数天到数十天（且随登录方式不同而变） |
| 能否自动续期 | 一般不需要 | **本客户端做不到** |

原因有两层：

1. `SESSDATA` 本身的生命周期就短得多。
2. 哔哩的续期接口 `/x/passport-login/web/cookie/refresh` 需要 cookie 里的
   `ac_time_value`，而**扫码登录（`passport-login/web/qrcode/poll` →
   `crossDomain` 回跳）这条路径只给出 `SESSDATA` / `bili_jct` / `DedeUserID` /
   `DedeUserID__ckMd5` / `sid`，不含 `ac_time_value`**。
   实测本机保存下来的 cookie 正是这 5 个字段，所以拿不到续期资格。

因此策略是「**如实检测、明确告知、引导重登**」，而不是假装已登录：

- 每次启动 `refreshAccount()` 会打一次 `nav`；`code == -101` 或
  `data.isLogin != true` 时立即 `clearSession()`，同时删掉本地缓存的 profile
  （避免界面继续显示一个已经无效的昵称头像）。
- 从"已登录"变成"未登录"且原因是凭据失效时，主界面弹一条带
  **「重新登录」** 动作的提示；主动退出不会触发它。
- 设置页的账户分区在哔哩未登录时会直接写明上述原因。

> 如果将来要支持自动续期，需要改成**网页版扫码**流程以拿到 `ac_time_value`，
> 属于后续增强（见 [roadmap.md](roadmap.md)）。

### 2.2 接口清单

成功统一为 `{ "code": 0, "message": "...", "ttl": 1, "data": {...} }`。常用错误码：`-101` 未登录、`-403` 权限不足（私有内容）、`-404` 无此资源、`-412` 被风控（请求过于频繁，需退避）。注意这与网易云的 `200` 语义不同，两套客户端各自封装，不共用判定。

| 路径 | 方法 | 用途 | 关键参数 |
| --- | --- | --- | --- |
| `x/web-interface/nav` | GET | 登录态检查 | 无；响应含 `wbi_img`（WBI 签名用） |
| `passport-login/web/qrcode/generate` | GET | 生成登录二维码 | 无 |
| `passport-login/web/qrcode/poll` | GET | 轮询扫码结果 | `qrcode_key` |
| `x/v3/fav/folder/created/list-all` | GET | 收藏夹列表（全部） | `up_mid`（自己或他人 mid，需带 `web_location` 兜底参数） |
| `x/v3/fav/resource/list` | GET | 收藏夹内资源列表（分页） | `media_id`、`pn`、`ps`（**≤40，实测 41 即报错**）、`keyword`、`order=mtime`、`platform=web` |
| `x/player/playurl` | GET | 取视频的 DASH 播放信息 | `bvid`（或 `avid`）、`cid`、`fnval=16`、`fnver=0`、`fourk=1` |
| `audio/music-service-c/url` | GET | 音频区（au）条目的音频地址 | `songid`、`quality`、`privilege`、`mid`、`platform` —— 具体取值与返回结构**「待验证」**（音频区接口变动较频繁） |
| `passport-login/web/cookie/refresh` | POST | Cookie 续期（后续增强） | **「待验证」** |

补充：`x/v3/fav/resource/list` 的分页信息在 `data.has_more` / `data.media_count`；返回条目中 `type` 字段区分视频（2）与音频（12），`bvid`/`id` 为来源 id 的依据；失效条目会出现在 `data.invalid`（提示用户但不播放）。

> ⚠️ **`ps` 的硬上限是 40，而且报错信息完全没有指向性。**
> 实测边界非常干脆：`ps=40` 正常返回，`ps=41` 立刻变成 `code=-400, message="请求错误"`。
> 由于 `MusicRepository.collectionTracks` 的 `limit` 默认值是 50，如果不在 repository 里夹紧，
> **用默认参数调这个接口必挂** —— 而"请求错误"这个文案极容易被误判成 cookie 失效或参数拼错。
> 现在实现对 `ps` 做了 `clamp(1, 40)`，并把上限守在唯一的读取出口 `_fetchTracks` 上，
> 调用方传什么都不会踩到。
>
> 教训：**"实测通过"必须覆盖默认参数**。这个 bug 之所以漏到运行时，是因为验证时用的是
> `ps=20`（文档里的推荐值），而接口层的默认值是 50 —— 两者都没错，组合起来才炸。

### 2.3 DASH 音轨选择

`x/player/playurl` 带 `fnval=16` 时返回 `data.dash`，音频在 `data.dash.audio[]`（另有 `dolby`、`flac` 等扩展字段）。选择策略：

```
1) 若 data.dash.audio 为空 → 退回归接口（fnval=0 的 durl）不适用音频，直接报错提示
2) 候选音轨按 (是否 Hi-Res/Dolby) → bandwidth 降序 排列
3) 若用户设置了码率上限，过滤掉超限项；否则取带宽最高的一条
4) 从选中项取 baseUrl（新字段）或 base_url（旧字段），失败时按 backupUrl/backup_url 依次重试
```

| 音轨 id（常见值） | 大致码率 | 备注 |
| --- | --- | --- |
| 30216 | ~64 kbps | 低清 |
| 30232 | ~132 kbps | 默认 |
| 30280 | ~192 kbps | 常见最高 |
| 30250 / 30251 | 杜比 / Hi-Res | 需会员权益，可能返回空 |

id 与码率的对应关系可能随平台调整，**以响应里的 `bandwidth` 与 `codecs` 为准**（上表仅作调试参考，标注为「待验证」）。

### 2.4 播放地址时效与重解析

- DASH 的 `baseUrl` 是**带签名的临时地址**（通常数十分钟级有效），存下来等以后再播必然 403/404。
- 因此 `Song` 里**不持久化**播放地址，只存 `sourceId`（`bvid`/`au id`）+ `cid`；每次真正播放前解析一次，播放地址只放内存。
- 播放中报错（`AudioEngine` 抛平台错误、HTTP 403/404）时：重解析**一次** → 用新 URL 从头播放（seek 到原位置）；再失败则跳到下一首并提示。
- 队列里已解析过的地址标记解析时间，超过 20 分钟主动刷新，避免长时间暂停后播放失败。

### 2.5 WBI 签名

部分接口（尤其 `nav` 的扩展字段、部分查询类接口）要求 `w_rid` + `wts`（WBI 签名）：取 `nav` 返回的 `wbi_img.img_url`/`sub_url` 文件名拼接成 key，对参数排序 + 混淆表重排后做 MD5。**本项目列为「后续按需接入」**：v1 只用本表里已确认可用的接口路径，遇到 `-403`/签名校验失败再按需实现，不提前引入这套易变的逻辑。

---

## 合规说明

- 两套接口都是**非官方、未公开、随时可能变更**的接口；本项目不保证其可用性与稳定性，也不提供任何形式的服务承诺。
- **必须限速**：所有请求经统一拦截器，单域名并发不超过 2、连续请求间隔不少于 300ms，遇到 `-412`/`429`/`406` 指数退避；禁止批量遍历、并发爬取收藏夹或歌单。
- **不得用于绕过付费与版权限制**：不实现任何破解、去广告、绕过会员权益或伪造权益参数（如伪造 `privilege`、`vipType`）的逻辑。
- **无法播放的付费/版权受限内容必须明确提示用户**：`song/url/v1` 的 `url == null`、Bilibili 音轨为空或返回 `-403` 等情况，UI 直接说明「该内容需要会员/无版权/已下架，无法播放」，不得静默失败、不得伪造播放状态。
  - 但"明确提示"与"接下来做什么"是两件事：**这首歌根本放不了**（版权下架 / 需要购买）时，继续停在它上面没有意义，播放器会**按队列切歌**（方向跟随用户的行进方向），并把封面 / 标题 / 歌词一起切过去 —— 绝不允许出现"声音还在放上一首、界面却显示这首下架歌"。整队都不可播时停下并说明。
  - **暂时性失败不切歌**（网络连接失败、403 地址过期）：换一首歌并不会让网络恢复，停在原地给出原因与「重试」才是对的。这两类的判据是**类型化信号**（`Song.playable` / `MusicApiException.unplayable`），不是匹配错误文案。
- 登录凭据（Cookie）只保存在本机 `shared_preferences`，不上传任何服务器；日志默认脱敏（不打印 `SESSDATA`、`MUSIC_U`、`__csrf`）。
- 请通过官方渠道支持创作者与平台：在官方客户端开通会员、购买数字专辑。

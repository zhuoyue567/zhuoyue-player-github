; 卓越播放器（ZhuoYue Player）Windows 安装脚本 —— Inno Setup 6
;
; 设计取舍（每一条都有理由，改动前请先读）：
;
; 1. **按用户安装（PrivilegesRequired=lowest）**：不需要管理员权限，不弹 UAC，
;    装到 %LOCALAPPDATA%\Programs。这也是"安装完就能勾开机自启动"的前提 ——
;    开机自启动写的是 HKCU 的 Run 项，按用户安装与它天然匹配。
;
; 2. **不打包 Node 运行时**（那 121MB 由应用首次启动时自己下载）。所以安装包
;    很小，但**首次启动必须联网**。应用找不到运行时会给出可操作的提示。
;
; 3. **不打包内置字体** zhuzi.ttf：它的再分发许可未经核实，作者按"自用字体"
;    处理（随源码仓库分发、不随安装包分发）。缺字体时应用会回退系统字体，
;    不会崩 —— 但观感会变，这是刻意接受的代价。
;
; 4. **缓存目录与下载目录在安装时选**，并把结果写成
;    `%APPDATA%\com.zhuoyue\zhuoyue_player\installer.json`，由应用首次启动时
;    读取并落进自己的设置。用文件而不是注册表：应用本来就在这个目录下存
;    shared_preferences，读到之后可以直接删掉/忽略，卸载也不会留注册表垃圾。
;
; 5. **「立即运行」与「开机自启动」都放在完成页上**（Inno 的 `[Run]` +
;    `Flags: postinstall` 会在完成页生成勾选框）。开机自启动用 `reg.exe add`
;    写 HKCU 的 Run 项 —— 这样它也能出现在完成页，而不必挤到前面的"附加任务"页。

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef SourceDir
  #define SourceDir "staging"
#endif

#define AppName "卓越播放器"
#define AppNameEn "ZhuoYue Player"
#define AppExe "zhuoyue_player.exe"
#define AppPublisher "ZhuoYue Player Contributors"
#define AppSupportDir "{userappdata}\com.zhuoyue\zhuoyue_player"
#define RunKey "Software\Microsoft\Windows\CurrentVersion\Run"
#define RunValue "ZhuoYuePlayer"

[Setup]
; AppId 一旦发布就不能再改：它决定了"这是同一个应用"，改了会变成并存的两份。
AppId={{7C1F2E90-5B3A-4C6D-9E21-8A4B6D3F1C57}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppNameEn}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=zhuoyue-player-{#AppVersion}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#AppExe}
SetupIconFile=..\windows\runner\resources\app_icon.ico
LicenseFile=..\LICENSE
; 卸载时不要删用户数据（缓存/下载目录、账号凭据都在用户自己的目录里）。
; 卸载留"用户目录里的东西"是刻意的：重装后不该丢掉登录态。

[Languages]
; 简体中文在 Inno 官方仓库里是 `Files/Languages/ChineseSimplified.isl`。
; 只提供中文：我们的自定义页面文案全是中文，混着英文向导反而更乱。
Name: "chinese"; MessagesFile: "languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务："; Flags: checkedonce

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
; 完成页上的两个勾选框 —— 用户明确要求在"安装完成后"提供这两个选项。
Filename: "{app}\{#AppExe}"; Description: "立即运行 {#AppName}"; Flags: nowait postinstall skipifsilent
Filename: "{sys}\reg.exe"; Parameters: "add ""HKCU\{#RunKey}"" /v {#RunValue} /t REG_SZ /d """"{app}\{#AppExe}"""" /f"; Description: "开机自启动（写入当前用户的启动项，可随时在应用设置里关掉）"; Flags: postinstall runhidden skipifsilent

[UninstallRun]
; 卸载时把自己写进去的启动项删掉，别留垃圾。
Filename: "{sys}\reg.exe"; Parameters: "delete ""HKCU\{#RunKey}"" /v {#RunValue} /f"; Flags: runhidden; RunOnceId: "RemoveAutostart"

[Code]
var
  CacheDirPage: TInputDirWizardPage;
  DownloadDirPage: TInputDirWizardPage;

function JsonEscape(const S: String): String;
begin
  Result := S;
  StringChangeEx(Result, '\', '\\', True);
  StringChangeEx(Result, '"', '\"', True);
end;

function InstallerJsonPath: String;
begin
  Result := ExpandConstant('{#AppSupportDir}\installer.json');
end;

procedure InitializeWizard;
begin
  // 插在"选择安装位置"之后，问两个路径。默认值放在用户目录里，
  // 这样按用户安装时一定可写（放到 Program Files 旁边反而会因权限失败）。
  CacheDirPage := CreateInputDirPage(
    wpSelectDir,
    '缓存目录',
    '音乐缓存放在哪里？',
    '封面、歌词与歌单缓存都会写进这个目录，它可能长得比较大，建议放在空间充裕的盘。' + #13#10 +
    '以后可以在「设置 → 存储路径」里修改，或直接搬走这个目录（应用会重建）。',
    False,
    '');
  CacheDirPage.Add('缓存目录：');
  CacheDirPage.Values[0] := ExpandConstant('{userappdata}\{#AppNameEn}\cache');

  DownloadDirPage := CreateInputDirPage(
    CacheDirPage.ID,
    '下载目录',
    '下载的音乐放在哪里？',
    '从应用里下载的歌曲文件会保存到这个目录。以后可以在「设置 → 存储路径」里修改。',
    False,
    '');
  DownloadDirPage.Add('下载目录：');
  DownloadDirPage.Values[0] := ExpandConstant('{userdocs}\{#AppNameEn}\Music');
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CacheDirPage <> nil) and (CurPageID = CacheDirPage.ID) then
  begin
    if Trim(CacheDirPage.Values[0]) = '' then
    begin
      MsgBox('请选择缓存目录。', mbError, MB_OK);
      Result := False;
    end;
  end
  else if (DownloadDirPage <> nil) and (CurPageID = DownloadDirPage.ID) then
  begin
    if Trim(DownloadDirPage.Values[0]) = '' then
    begin
      MsgBox('请选择下载目录。', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Json: String;
  SupportDir: String;
  CacheDir: String;
  DownloadDir: String;
begin
  if CurStep <> ssPostInstall then
    Exit;

  CacheDir := CacheDirPage.Values[0];
  DownloadDir := DownloadDirPage.Values[0];

  // 安装时就把目录建出来：一是让用户马上能看到自己选的位置，
  // 二是**顺便验证可写** —— 选了个只读位置的话现在就能发现，而不是等播放时才报错。
  ForceDirectories(CacheDir);
  ForceDirectories(DownloadDir);

  SupportDir := ExpandConstant('{#AppSupportDir}');
  ForceDirectories(SupportDir);

  Json := '{' + #13#10;
  Json := Json + '  "schema": 1,' + #13#10;
  Json := Json + '  "appVersion": "' + '{#AppVersion}' + '",' + #13#10;
  Json := Json + '  "installDir": "' + JsonEscape(ExpandConstant('{app}')) + '",' + #13#10;
  Json := Json + '  "cacheDir": "' + JsonEscape(CacheDir) + '",' + #13#10;
  Json := Json + '  "downloadDir": "' + JsonEscape(DownloadDir) + '",' + #13#10;
  Json := Json + '  "installedAt": "' + GetDateTimeString('yyyy-mm-dd hh:nn:ss', '-', ':') + '"' + #13#10;
  Json := Json + '}' + #13#10;

  if not SaveStringToFile(InstallerJsonPath, Json, False) then
    MsgBox('安装已完成，但没能写入路径配置：' + #13#10 + InstallerJsonPath + #13#10 +
           '应用首次启动时会用默认路径，你可以在「设置 → 存储路径」里手动改。',
           mbInformation, MB_OK);
end;

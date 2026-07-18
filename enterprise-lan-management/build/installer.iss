; 金网通 安装包定义（M1）—— InnoSetup 脚本
; 用法：用 InnoSetup Compiler 打开本文件编译，生成 setup.exe
; 说明：
;   · 打包 scripts/ 目录与说明文档；
;   · 安装后调用 install.ps1 完成部署、快捷方式与卸载项；
;   · 建议先用 sign-scripts.ps1 对 scripts/*.ps1 签名，再用 InnoSetup 对 setup.exe 签名（Authenticode）。

#define MyAppName "金网通 企业局域网互联互通"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "厦门金奕鸣科技有限公司"
#define MyAppURL "https://www.jinyiming.com"
#define MySrcDir "..\scripts"

[Setup]
AppId={{A1B2C3D4-E5F6-7890-ABCD-1234567890AB}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
DefaultDirName={autopf}\JinNetConnect
DefaultGroupName={#MyAppName}
OutputDir=output
OutputBaseFilename=JinNetConnect-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64
WizardStyle=modern
SetupIconFile=
UninstallDisplayName={#MyAppName}

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Default.isl"

[Files]
; 复制脚本集与配置模板
Source: "{#MySrcDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; 说明文档（仓库根，可选）
Source: "..\README-使用说明.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\商业授权与上线说明.md"; DestDir: "{app}"; Flags: ignoreversion

[Run]
; 安装末尾调用 PowerShell 引导器完成注册与快捷方式
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install.ps1"" -Destination ""{app}"""; StatusMsg: "正在完成部署..."

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
; 可选：安装前校验 PowerShell 版本（最低 5.1）
function InitializeSetup(): Boolean;
var
  psVer: string;
begin
  Result := True;
  try
    psVer := GetEnv('PSModulePath');
    if psVer = '' then
    begin
      MsgBox('未检测到 PowerShell，请先安装 PowerShell 5.1+。', mbError, MB_OK);
      Result := False;
    end;
  except
    Result := True;
  end;
end;

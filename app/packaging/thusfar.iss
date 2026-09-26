; Inno Setup script for the Windows installer. Built in CI by apps.yml:
;   iscc /DAppVersion=2.0.0 /DSourceDir=...\Release packaging\thusfar.iss
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6E0B8F2A-3C1D-4B7E-9F2A-7A5D1C4E8B31}
AppName=页读 Thusfar
AppVersion={#AppVersion}
AppPublisher=Thusfar contributors
AppPublisherURL=https://github.com/athemeroy/thusfar
DefaultDirName={localappdata}\Programs\Thusfar
DefaultGroupName=页读
DisableProgramGroupPage=yes
; A per-user install needs no administrator prompt.
PrivilegesRequired=lowest
OutputBaseFilename=Thusfar-{#AppVersion}-windows-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\Thusfar.exe
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\页读"; Filename: "{app}\Thusfar.exe"
Name: "{autodesktop}\页读"; Filename: "{app}\Thusfar.exe"; Tasks: desktopicon

[Registry]
; Offer 页读 under "打开方式" for books, without taking over the default app.
Root: HKCU; Subkey: "Software\Classes\Applications\Thusfar.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "页读"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\Thusfar.exe\shell\open\command"; ValueType: string; ValueData: """{app}\Thusfar.exe"" ""%1"""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\Thusfar.exe\SupportedTypes"; ValueType: string; ValueName: ".txt"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\Thusfar.exe\SupportedTypes"; ValueType: string; ValueName: ".epub"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\.epub\OpenWithList\Thusfar.exe"; ValueType: string; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.txt\OpenWithList\Thusfar.exe"; ValueType: string; ValueData: ""; Flags: uninsdeletekey

[Run]
Filename: "{app}\Thusfar.exe"; Description: "{cm:LaunchProgram,页读}"; Flags: nowait postinstall skipifsilent

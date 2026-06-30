; ponytail: minimal Inno Setup script for PhotoFlow
; Install Inno Setup from https://jrsoftware.org/isdl.php, then run:
;   iscc PhotoFlow_setup.iss

#define MyAppName "PhotoFlow"
#define MyAppVersion "0.1.0"
#define MyAppPublisher "com.example"
#define MyAppURL "https://github.com/example/photos-app"
#define MyBuildDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
OutputDir=.
OutputBaseFilename=PhotoFlow-{#MyAppVersion}-setup
Compression=lzma
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
UninstallDisplayIcon={app}\PhotoFlow.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"

[Files]
Source: "{#MyBuildDir}\PhotoFlow.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#MyBuildDir}\flutter_windows.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#MyBuildDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#MyBuildDir}\photos_core.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\PhotoFlow.exe"; Tasks: ""
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\PhotoFlow.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\PhotoFlow.exe"; Description: "Launch PhotoFlow"; Flags: postinstall nowait skipifsilent

; Installer for the signed release pipeline.
;
; Every branded value arrives through the environment so the workflow can brand
; the installer without editing this file:
;
;   BRAND_APP_NAME        display name, also the install directory name
;   BRAND_VERSION         version without the leading "v"
;   BRAND_PUBLISHER       company shown in the uninstall entry
;   BRAND_PUBLISHER_URL   support and updates URL
;   BRAND_EXE_NAME        executable file name inside the bundle
;   BRAND_SOURCE_DIR      directory holding the signed release bundle
;   BRAND_OUTPUT_DIR      where the installer is written
;   BRAND_OUTPUT_BASENAME installer file name without the extension
;   BRAND_ICON            setup icon (.ico)
;
; Build with: iscc /Qp .github\custom\installer.iss

#define AppName GetEnv("BRAND_APP_NAME")
#define AppVersion GetEnv("BRAND_VERSION")
#define AppPublisher GetEnv("BRAND_PUBLISHER")
#define AppPublisherUrl GetEnv("BRAND_PUBLISHER_URL")
#define ExeName GetEnv("BRAND_EXE_NAME")
#define SourceDir GetEnv("BRAND_SOURCE_DIR")
#define OutputDir GetEnv("BRAND_OUTPUT_DIR")
#define OutputBase GetEnv("BRAND_OUTPUT_BASENAME")
#define IconFile GetEnv("BRAND_ICON")

[Setup]
; Fixed so an upgrade installs over the previous version. Change it only when a
; rebrand must sit next to the old install instead of replacing it.
AppId={{8C7E1B42-6A3D-4E19-9C58-2B7E4D6A1F03}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppPublisherUrl}
AppSupportURL={#AppPublisherUrl}
AppUpdatesURL={#AppPublisherUrl}
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBase}
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\{#ExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "launchAtStartup"; Description: "{cm:AutoStartProgram,{#AppName}}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#ExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#ExeName}"; Tasks: desktopicon
Name: "{userstartup}\{#AppName}"; Filename: "{app}\{#ExeName}"; WorkingDir: "{app}"; Tasks: launchAtStartup

; The app turns the system proxy off on its own exit path, which a forced close
; during setup or uninstall skips; the flag clears whatever is left behind.
[Run]
Filename: "{app}\{#ExeName}"; Parameters: "--clear-stale-proxy"; Flags: runhidden waituntilterminated; StatusMsg: "Cleaning up proxy settings..."
Filename: "{app}\{#ExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: runascurrentuser nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\{#ExeName}"; Parameters: "--clear-stale-proxy"; Flags: runhidden waituntilterminated; RunOnceId: "ClearStaleProxy"

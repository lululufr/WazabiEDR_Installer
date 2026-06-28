; WazabiEDR — Inno Setup script.
;
; Bundles the kernel driver package, the user-mode agent (Windows
; service) and the operator CLI (`wedr-plugin`). Reads optional
; /SERVER= /TOKEN= command line arguments to seed the agent's
; configuration; in interactive mode the wizard prompts for them.
;
; Build (CI):
;   ISCC.exe /DAppVersion=0.1.0 setup.iss
;
; Silent install (typical server-driven one-liner):
;   WazabiEDR_Setup_0.1.0.exe /SILENT /SERVER=http://wazabi.example.com:8080 /TOKEN=<JWT>
;
; Reboot handling: install-driver.ps1 returns 3010 when test signing
; was just enabled or when the previously-loaded driver could not be
; unloaded. Inno Setup interprets 3010 from a [Run] item as
; "restart required" thanks to RestartIfNeededByRun=yes below.

#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif

#define AppNameStr "WazabiEDR"
#define AppId      "{8C9D4A2B-3E1F-4A5C-9D6E-7F8B0C1D2E3F}"

[Setup]
AppId={{#AppId}
AppName={#AppNameStr}
AppVersion={#AppVersion}
AppPublisher=WazabiEDR
DefaultDirName={autopf}\WazabiEDR
DefaultGroupName=WazabiEDR
DisableProgramGroupPage=yes
OutputBaseFilename=WazabiEDR_Setup_{#AppVersion}
OutputDir=out
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
ChangesEnvironment=yes
RestartIfNeededByRun=yes
CloseApplications=no
SetupLogging=yes
; Allow the silent CLI to override the install dir if needed.
UsePreviousAppDir=yes

[Files]
; Agent service binary.
Source: "payload\agent\WazabiEDR_Agent.exe"; \
  DestDir: "{app}\agent"; Flags: ignoreversion

; Operator CLI. {app}\bin is added to the machine PATH (see [Registry]).
Source: "payload\utils\wedr-plugin.exe"; \
  DestDir: "{app}\bin"; Flags: ignoreversion

; Helper scripts kept inside {app} so the uninstaller can call them.
Source: "scripts\install-driver.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "scripts\post-install.ps1";   DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "scripts\install-all.ps1";    DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "scripts\resume-ui.ps1";      DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "scripts\uninstall-pre.ps1";  DestDir: "{app}\scripts"; Flags: ignoreversion

; Driver package. {tmp} + deleteafterinstall: ~MB of binary the
; operator doesn't need to keep around once the driver is loaded.
Source: "payload\driver\*"; DestDir: "{tmp}\driver"; \
  Flags: deleteafterinstall recursesubdirs

[Registry]
; Machine PATH. Check: skip when {app}\bin is already there (idempotent
; on re-install / repair).
Root: HKLM; Subkey: "SYSTEM\CurrentControlSet\Control\Session Manager\Environment"; \
  ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}\bin"; \
  Check: NeedsAddPath(ExpandConstant('{app}\bin'))

[Run]
; Single orchestrator: install-driver then post-install. Le bug
; historique : install-all.ps1 retourne 3010 quand test signing
; doit être activé (reboot required), MAIS Inno Setup avale
; silencieusement ce code et termine setup.exe en exit 0. Le oneliner
; PowerShell ne voit alors pas le besoin de reboot et affiche "Done"
; alors que post-install.ps1 n'a jamais tourné.
; Solution : install-all.ps1 écrit un marker file
; %ProgramData%\WazabiEDR\.reboot-required avant d'exit 3010 ;
; le oneliner check ce marker après setup.exe, indépendamment du code
; renvoyé par Inno.
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\install-all.ps1"" -PackageDir ""{tmp}\driver"" -AgentExe ""{app}\agent\WazabiEDR_Agent.exe"" -Server ""{code:GetServer}"" -Token ""{code:GetToken}"""; \
  StatusMsg: "Installing driver, configuring agent..."; \
  Flags: runhidden waituntilterminated

[UninstallRun]
; Tear down services + driver BEFORE Inno deletes files. RunOnceId so a
; repair pass doesn't double-fire.
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\uninstall-pre.ps1"""; \
  Flags: runhidden waituntilterminated; \
  RunOnceId: "WazabiTearDown"

[Code]
var
  ServerPage: TInputQueryWizardPage;

// ---- /SERVER= / /TOKEN= command-line parameter helpers -------------------
// Inno Setup ParamCount/ParamStr include all switches; we accept the
// Windows-style /NAME=VALUE form (case-insensitive on the name).
function CmdParam(const Name: String; const Default: String): String;
var
  i: Integer;
  prefix, arg: String;
begin
  Result := Default;
  prefix := '/' + Name + '=';
  for i := 0 to ParamCount do
  begin
    arg := ParamStr(i);
    if Length(arg) > Length(prefix) then
      if CompareText(Copy(arg, 1, Length(prefix)), prefix) = 0 then
      begin
        Result := Copy(arg, Length(prefix) + 1, Length(arg));
        Exit;
      end;
  end;
end;

procedure InitializeWizard;
begin
  ServerPage := CreateInputQueryPage(wpWelcome,
    'WazabiEDR server configuration',
    'Enter the URL of the WazabiEDR server and the enrollment token.',
    'These values are written to %ProgramData%\WazabiEDR\agent.json so the agent can auto-enroll on first start.');
  ServerPage.Add('Server URL:', False);
  ServerPage.Add('Enrollment token:', False);
  ServerPage.Values[0] := CmdParam('SERVER', '');
  ServerPage.Values[1] := CmdParam('TOKEN', '');
end;

// Skip the input page entirely if /SERVER= and /TOKEN= were both
// passed -- typical for silent server-driven installs.
function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if PageID = ServerPage.ID then
    if (CmdParam('SERVER', '') <> '') and (CmdParam('TOKEN', '') <> '') then
      Result := True;
end;

function GetServer(Param: String): String;
begin
  if CmdParam('SERVER', '') <> '' then
    Result := CmdParam('SERVER', '')
  else
    Result := ServerPage.Values[0];
end;

function GetToken(Param: String): String;
begin
  if CmdParam('TOKEN', '') <> '' then
    Result := CmdParam('TOKEN', '')
  else
    Result := ServerPage.Values[1];
end;

// ---- PATH manipulation --------------------------------------------------
function NeedsAddPath(Param: String): Boolean;
var
  OrigPath: String;
begin
  if not RegQueryStringValue(HKEY_LOCAL_MACHINE,
    'SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
    'Path', OrigPath) then
  begin
    Result := True;
    Exit;
  end;
  // Look for ;{app}\bin; inside ;PATH; -- the wrap on both sides
  // matches even when {app}\bin is the first or last entry.
  Result := Pos(';' + Uppercase(Param) + ';', ';' + Uppercase(OrigPath) + ';') = 0;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Path, Item: String;
  P: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    if RegQueryStringValue(HKEY_LOCAL_MACHINE,
      'SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
      'Path', Path) then
    begin
      Item := ExpandConstant('{app}\bin');
      P := Pos(';' + Uppercase(Item) + ';', ';' + Uppercase(Path) + ';');
      if P > 0 then
      begin
        // P is the 1-based index in the wrapped string ';PATH;'. The
        // entry we want to remove starts at P (because we prefixed
        // the search with ';') and is Length(Item)+1 chars long
        // (item + the trailing ';'). When the entry is the very
        // first one of PATH, P = 1 and we delete (Item + ';');
        // when last, the trailing ';' we delete is the one we added
        // at wrapping time -- which DOESN'T exist in the real PATH.
        // We compensate by deleting Length(Item) only if it was the
        // first entry; otherwise Length(Item)+1.
        if P = 1 then
          Delete(Path, P, Length(Item) + 1)
        else
          Delete(Path, P - 1, Length(Item) + 1);
        RegWriteStringValue(HKEY_LOCAL_MACHINE,
          'SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
          'Path', Path);
      end;
    end;
  end;
end;

// ---- Silent-mode validation ---------------------------------------------
// Refuse to start a silent install without both /SERVER and /TOKEN.
// The wizard wouldn't get a chance to show its input page, and the
// agent would auto-enroll with empty values -- guaranteed 401.
function InitializeSetup(): Boolean;
begin
  Result := True;
  if WizardSilent() then
  begin
    if (CmdParam('SERVER', '') = '') or (CmdParam('TOKEN', '') = '') then
    begin
      MsgBox('Silent install requires /SERVER=<url> /TOKEN=<enrollment_token>.',
        mbError, MB_OK);
      Result := False;
    end;
  end;
end;

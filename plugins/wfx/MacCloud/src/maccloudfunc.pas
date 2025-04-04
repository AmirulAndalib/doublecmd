{
  Notes:
  1. currently implementing DropBox only
  2. other cloud drivers will be gradually supported
}

unit MacCloudFunc;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  WfxPlugin,
  uMacCloudCore, uMacCloudUtil, uMacCloudOptions,
  uDropBoxClient,
  uMiniUtil;

function FsInitW(PluginNr:integer;pProgressProc:tProgressProcW;pLogProc:tLogProcW;pRequestProc:tRequestProcW):integer; cdecl;
function FsFindFirstW(path:pwidechar;var FindData:tWIN32FINDDATAW):thandle; cdecl;
function FsFindNextW(handle:thandle;var FindData:tWIN32FINDDATAW):bool; cdecl;
function FsFindClose(handle:thandle):integer; cdecl;
function FsGetFileW(RemoteName,LocalName:pwidechar;CopyFlags:integer;RemoteInfo:pRemoteInfo):integer; cdecl;
function FsPutFileW(LocalName,RemoteName:pwidechar;CopyFlags:integer):integer; cdecl;
function FsMkDirW(RemoteDir:pwidechar):bool; cdecl;
function FsDeleteFileW(RemoteName:pwidechar):bool; cdecl;
function FsRemoveDirW(RemoteName:pwidechar):bool; cdecl;
function FsRenMovFileW(OldName,NewName:pwidechar;Move,OverWrite:bool;RemoteInfo:pRemoteInfo):integer; cdecl;
function FsExecuteFileW(MainWin:HWND;RemoteName,Verb:pwidechar):integer; cdecl;
function FsGetBackgroundFlags:integer; cdecl;
procedure FsGetDefRootName(DefRootName:pchar;maxlen:integer); cdecl;

implementation

type

  { TCloudRootListFolder }

  TCloudRootListFolder = class( TCloudListFolder )
  private
    _list: TFPList;
  public
    procedure listFolderBegin(const path: String); override;
    function listFolderGetNextFile: TCloudFile; override;
    procedure listFolderEnd; override;
  end;

function FsInitW(
  PluginNr: Integer;
  pProgressProc: TProgressProcW;
  pLogProc: TLogProcW;
  pRequestProc: TRequestProcW ): Integer; cdecl;
begin
  macCloudPlugin:= TMacCloudPlugin.Create( PluginNr, pProgressProc, pLogProc );
  Result:= 0;
end;

function FsFindFirstW(
  path: pwidechar;
  var FindData: TWIN32FINDDATAW ): THandle; cdecl;
var
  parser: TCloudPathParser;
  listFolder: TCloudListFolder;

  function doFindFirst: THandle;
  var
    utf8Path: String;
    cloudFile: TCloudFile;
  begin
    utf8Path:= TStringUtil.widecharsToString(path);
    parser:= TCloudPathParser.Create( utf8Path );
    if utf8Path = PathDelim then
      listFolder:= TCloudRootListFolder.Create
    else
      listFolder:= parser.driver;
    Result:= THandle( listFolder );
    listFolder.listFolderBegin( parser.driverPath );
    cloudFile:= listFolder.listFolderGetNextFile;
    if cloudFile = nil then
      Exit( wfxInvalidHandle );

    TMacCloudUtil.cloudFileToWinFindData( cloudFile, FindData );
  end;

begin
  try
    try
      Result:= doFindFirst;
    finally
      FreeAndNil( parser );
    end;
  except
    on e: Exception do begin
      TMacCloudUtil.exceptionToResult( e );
      Result:= wfxInvalidHandle;
    end;
  end;

  if (Result=wfxInvalidHandle) and Assigned(listFolder) then
    listFolder.listFolderEnd;
end;

function FsFindNextW(
  handle: THandle;
  var FindData:tWIN32FINDDATAW ): Bool; cdecl;
var
  listFolder: TCloudListFolder;
  cloudFile: TCloudFile;
begin
  try
    listFolder:= TCloudListFolder( handle );
    cloudFile:= listFolder.listFolderGetNextFile;
    if cloudFile = nil then
      Exit( False );

    TMacCloudUtil.cloudFileToWinFindData( cloudFile, FindData );
    Result:= True;
  except
    on e: Exception do begin
      TMacCloudUtil.exceptionToResult( e );
      Result:= False;
    end;
  end;
end;

function FsFindClose( handle: THandle ): Integer; cdecl;
var
  listFolder: TCloudListFolder;
begin
  Result:= 0;
  try
    listFolder:= TCloudListFolder( handle );
    listFolder.listFolderEnd;
  except
    on e: Exception do begin
      TMacCloudUtil.exceptionToResult( e );
    end;
  end;
end;

function FsGetFileW(
  RemoteName: pwidechar;
  LocalName: pwidechar;
  CopyFlags: Integer;
  RemoteInfo: pRemoteInfo ): Integer; cdecl;

var
  parser: TCloudPathParser;
  callback: TCloudProgressCallback;

  function doGetFile: Integer;
  var
    serverPath: String;
    localPath: String;
    totalBytes: Integer;
    li: ULARGE_INTEGER;
    exits: Boolean;
  begin
    parser:= TCloudPathParser.Create( TStringUtil.widecharsToString(RemoteName) );
    serverPath:= parser.driverPath;
    localPath:= TStringUtil.widecharsToString( LocalName );
    li.LowPart:= RemoteInfo^.SizeLow;
    li.HighPart:= RemoteInfo^.SizeHigh;
    totalBytes:= li.QuadPart;
    exits:= TFileUtil.exists( localPath );

    TLogUtil.logInformation(
      'FsGetFileW: remote=' + serverPath + ', local=' + localPath +
      ', CopyFlags=' + IntToStr(CopyFlags) + ', size=' + IntToStr(totalBytes) +
      ', LocalFileExists=' + BoolToStr(exits,True) );

    if (CopyFlags and FS_COPYFLAGS_RESUME <> 0) then
      Exit( FS_FILE_NOTSUPPORTED );
    if exits and (CopyFlags and FS_COPYFLAGS_OVERWRITE = 0) then
      Exit( FS_FILE_EXISTS );

    callback:= TCloudProgressCallback.Create(
      RemoteName,
      LocalName,
      totalBytes );
    callback.progress( 0 );
    parser.driver.download( serverPath, localPath, callback );

    Result:= FS_FILE_OK;
  end;

begin
  try
    try
      Result:= doGetFile;
    finally
      FreeAndNil( parser );
      FreeAndNil( callback );
    end;
  except
    on e: Exception do
      Result:= TMacCloudUtil.exceptionToResult( e );
  end;
end;

function FsPutFileW(
  LocalName: pwidechar;
  RemoteName: pwidechar;
  CopyFlags: Integer ): Integer; cdecl;
const
  FS_EXISTS = FS_COPYFLAGS_EXISTS_SAMECASE or FS_COPYFLAGS_EXISTS_DIFFERENTCASE;
var
  parser: TCloudPathParser;
  callback: TCloudProgressCallback;

  function doPutFile: Integer;
  var
    serverPath: String;
    localPath: String;
    totalBytes: Integer;
    exits: Boolean;
  begin
    parser:= TCloudPathParser.Create( TStringUtil.widecharsToString(RemoteName) );
    serverPath:= parser.driverPath;
    localPath:= TStringUtil.widecharsToString( LocalName );
    totalBytes:= TFileUtil.filesize( localPath );
    exits:= (CopyFlags and FS_EXISTS <> 0);

    TLogUtil.logInformation(
      'FsPutFileW: remote=' + serverPath + ', local=' + localPath +
      ', CopyFlags=' + IntToStr(CopyFlags) + ', size=' + IntToStr(totalBytes) +
      ', RemoteFileExists=' + BoolToStr(exits,True) );

    if (CopyFlags and FS_COPYFLAGS_RESUME <> 0) then
      Exit( FS_FILE_NOTSUPPORTED );
    if exits and (CopyFlags and FS_COPYFLAGS_OVERWRITE = 0) then
      Exit( FS_FILE_EXISTS );

    callback:= TCloudProgressCallback.Create(
      RemoteName,
      LocalName,
      totalBytes );
    callback.progress( 0 );
    parser.driver.upload( serverPath, localPath, callback );

    Result:= FS_FILE_OK;
  end;

begin
  try
    try
      Result:= doPutFile;
    finally
      FreeAndNil( parser );
      FreeAndNil( callback );
    end;
  except
    on e: Exception do
      Result:= TMacCloudUtil.exceptionToResult( e );
  end;
end;

function FsMkDirW( RemoteDir: pwidechar ): Bool; cdecl;
var
  parser: TCloudPathParser;

  procedure doCreateFolder;
  begin
    parser:= TCloudPathParser.Create( TStringUtil.widecharsToString(RemoteDir) );
    parser.driver.createFolder( parser.driverPath );
  end;

begin
  try
    try
      doCreateFolder;
      Result:= True;
    finally
      FreeAndNil( parser );
    end;
  except
    on e: Exception do begin
      TMacCloudUtil.exceptionToResult( e );
      Result:= False;
    end;
  end;
end;

function FsDeleteFileW( RemoteName: pwidechar ): Bool; cdecl;
var
  parser: TCloudPathParser;

  procedure doDelete;
  begin
    parser:= TCloudPathParser.Create( TStringUtil.widecharsToString(RemoteName) );
    parser.driver.delete( parser.driverPath );
  end;

begin
  try
    try
      doDelete;
      Result:= True;
    finally
      FreeAndNil( parser );
    end;
  except
    on e: Exception do begin
      TMacCloudUtil.exceptionToResult( e );
      Result:= False;
    end;
  end;
end;

function FsRemoveDirW( RemoteName: pwidechar ): Bool; cdecl;
begin
  FsDeleteFileW( RemoteName );
end;

function FsRenMovFileW(
  OldName: pwidechar;
  NewName: pwidechar;
  Move, OverWrite: Bool;
  RemoteInfo: pRemoteInfo ): Integer; cdecl;
var
  parserOld: TCloudPathParser;
  parserNew: TCloudPathParser;

  function doCopyOrMove: Integer;
  var
    ret: Boolean;
  begin
    parserOld:= TCloudPathParser.Create( TStringUtil.widecharsToString(OldName) );
    parserNew:= TCloudPathParser.Create( TStringUtil.widecharsToString(NewName) );

    if parserOld.connection <> parserNew.connection then
      raise ENotSupportedException.Create( 'Internal copy/move functions cannot be used between different accounts' );

    ret:= macCloudPlugin.progress( oldName, newName, 0 ) = 0;
    if ret then begin
      parserNew.driver.copyOrMove( parserOld.driverPath, parserNew.driverPath, Move );
      macCloudPlugin.progress( oldName, newName, 100 );
      Result:= FS_FILE_OK;
    end else
      Result:= FS_FILE_USERABORT;
  end;

begin
  try
    try
      Result:= doCopyOrMove;
    finally
      FreeAndNil( parserOld );
      FreeAndNil( parserNew );
    end;
  except
    on e: Exception do
      Result:= TMacCloudUtil.exceptionToResult( e );
  end;
end;

function FsExecuteFileW(
  MainWin: HWND;
  RemoteName: pwidechar;
  Verb: pwidechar ): Integer; cdecl;
var
  utf8Path: String;
  utf8Verb: String;
begin
  Result:= FS_EXEC_OK;
  utf8Path:= TStringUtil.widecharsToString( RemoteName );
  utf8Verb:= TStringUtil.widecharsToString( Verb );

  if utf8Verb = 'open' then begin
    Result:= FS_EXEC_SYMLINK;
  end else if utf8Verb = 'properties' then begin
    TCloudOptionsUtil.show;
  end;

end;

function FsGetBackgroundFlags: Integer; cdecl;
begin
  Result:= BG_DOWNLOAD or BG_UPLOAD{ or BG_ASK_USER};
end;

procedure FsGetDefRootName( DefRootName: pchar; maxlen: Integer ); cdecl;
begin
  strlcopy( DefRootName, 'DropBox', maxlen );
end;

procedure init;
var
  driver: TCloudDriver;
  connection: TCloudConnection;
begin
  dropBoxConfig:= TDropBoxConfig.Create( 'ahj0s9xia6i61gh', 'dc2ea085a05ac273a://dropbox/auth' );
  cloudDriverManager.register( TDropBoxClient );

  driver:= cloudDriverManager.createInstance( 'DropBox' );
  connection:= TCloudConnection.Create( 'rich', driver );
  cloudConnectionManager.add( connection );
end;

{ TCloudRootListFolder }

procedure TCloudRootListFolder.listFolderBegin(const path: String);
var
  cloudFile: TCloudFile;
begin
  _list:= TFPList.Create;
  cloudFile:= TCloudFile.Create;
  cloudFile.name:= '<Add Connections>';
  _list.Add( cloudFile );

  cloudFile:= TCloudFile.Create;
  cloudFile.name:= 'rich';
  _list.Add( cloudFile );
end;

function TCloudRootListFolder.listFolderGetNextFile: TCloudFile;
begin
  if _list.Count > 0 then begin
    Result:= TCloudFile( _list.First );
    _list.Delete( 0 );
  end else begin
    Result:= nil;
  end;
end;

procedure TCloudRootListFolder.listFolderEnd;
begin
  FreeAndNil( _list );
  self.Free;
end;

initialization
  init;

end.

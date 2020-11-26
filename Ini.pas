unit Ini;
{
DESCRIPTION:  Memory cached ini files management
AUTHOR:       Alexander Shostak (aka Berserker aka EtherniDee aka BerSoft)
}

(***)  interface  (***)
uses
  SysUtils, Utils, Log,
  TypeWrappers, AssocArrays, Lists, Files, TextScan, StrLib;

type
  (* IMPORT *)
  TString     = TypeWrappers.TString;
  TAssocArray = AssocArrays.TAssocArray;


procedure ClearIniCache (const FileName: string);
procedure ClearAllIniCache;

function  ReadStrFromIni
(
  const Key:          string;
  const SectionName:  string;
        FilePath:     string;
  out   Res:          string
): boolean;

function  WriteStrToIni (const Key, Value, SectionName: string; FilePath: string): boolean;
function  SaveIni (FilePath: string): boolean;

(***) implementation (***)


var
{O} CachedIniFiles: {O} TAssocArray {OF TAssocArray};


procedure ClearIniCache (const FileName: string);
begin
  CachedIniFiles.DeleteItem(SysUtils.ExpandFileName(FileName));
end;

procedure ClearAllIniCache;
begin
  CachedIniFiles.Clear;
end;

function LoadIni (FilePath: string): boolean;
const
  LINE_END_MARKER     = #10;
  LINE_END_MARKERS    = [#10, #13];
  BLANKS              = [#0..#32];
  DEFAULT_DELIMS      = [';'] + LINE_END_MARKERS;
  SECTION_NAME_DELIMS = [']'] + DEFAULT_DELIMS;
  KEY_DELIMS          = ['='] + DEFAULT_DELIMS;

var
{O} TextScanner:  TextScan.TTextScanner;
{O} Sections:     {O} TAssocArray {OF TAssocArray};
{U} CurrSection:  {O} TAssocArray {OF TString};
    FileContents: string;
    SectionName:  string;
    Key:          string;
    Value:        string;
    c:            char;

 procedure GotoNextLine;
 begin
   TextScanner.FindChar(LINE_END_MARKER);
   TextScanner.GotoNextChar;
 end;
    
begin
  TextScanner :=  TextScan.TTextScanner.Create;
  Sections    :=  nil;
  CurrSection :=  nil;
  // * * * * * //
  FilePath  :=  SysUtils.ExpandFileName(FilePath);
  result    :=  Files.ReadFileContents(FilePath, FileContents);
  
  if result and (Length(FileContents) > 0) then begin
    Sections  :=  AssocArrays.NewStrictAssocArr(TAssocArray);
    TextScanner.Connect(FileContents, LINE_END_MARKER);
    
    while result and (not TextScanner.EndOfText) do begin
      TextScanner.SkipCharset(BLANKS);
      
      if TextScanner.GetCurrChar(c) then begin
        if c = ';' then begin
          GotoNextLine;
        end else begin
          if c = '[' then begin
            TextScanner.GotoNextChar;
            
            result  :=
              TextScanner.ReadTokenTillDelim(SECTION_NAME_DELIMS, SectionName)  and
              TextScanner.GetCurrChar(c)                                        and
              (c = ']');
            
            if result then begin
              SectionName :=  SysUtils.Trim(SectionName);
              GotoNextLine;
              CurrSection :=  Sections[SectionName];
              
              if CurrSection = nil then begin
                CurrSection           :=  AssocArrays.NewStrictAssocArr(TString);
                Sections[SectionName] :=  CurrSection;
              end;
            end;
          end else begin
            TextScanner.ReadTokenTillDelim(KEY_DELIMS, Key);
            result  :=  TextScanner.GetCurrChar(c) and (c = '=');
            
            if result then begin
              Key :=  SysUtils.Trim(Key);
              TextScanner.GotoNextChar;
              
              if not TextScanner.ReadTokenTillDelim(DEFAULT_DELIMS, Value) then begin
                Value :=  '';
              end else begin
                Value :=  Trim(Value);
              end;
              
              if CurrSection = nil then begin
                CurrSection   :=  AssocArrays.NewStrictAssocArr(TString);
                Sections['']  :=  CurrSection;
              end;
              
              CurrSection[Key]  :=  TString.Create(Value);
            end; // .if
          end; // .else
        end; // .else
      end; // .if
    end; // .while
    
    if result then begin
      CachedIniFiles[FilePath]  :=  Sections; Sections  := nil;
    end else begin
      Log.Write
      (
        'Ini',
        'LoadIni',
        StrLib.Concat
        ([
          'The file "', FilePath, '" has invalid format.'#13#10,
          'Scanner stopped at position ', SysUtils.IntToStr(TextScanner.Pos)
        ])
      );
    end; // .else
  end; // .if
  // * * * * * //
  SysUtils.FreeAndNil(TextScanner);
  SysUtils.FreeAndNil(Sections);
end; // .function LoadIni

function SaveIni (FilePath: string): boolean;
var
{O} StrBuilder:   StrLib.TStrBuilder;
{O} SectionNames: Lists.TStringList {OF TAssocArray};
{O} SectionKeys:  Lists.TStringList {OF TString};

{U} CachedIni:    {O} TAssocArray {OF TAssocArray};
{U} Section:      {O} TAssocArray {OF TString};
{U} Value:        TString;
    SectionName:  string;
    Key:          string;
    i:            integer;
    j:            integer;

begin
  StrBuilder    :=  StrLib.TStrBuilder.Create;
  SectionNames  :=  Lists.NewSimpleStrList;
  SectionKeys   :=  Lists.NewSimpleStrList;
  CachedIni     :=  nil;
  Section       :=  nil;
  Value         :=  nil;
  // * * * * * //
  FilePath  :=  SysUtils.ExpandFileName(FilePath);
  CachedIni :=  CachedIniFiles[FilePath];
  
  if CachedIni <> nil then begin
    CachedIni.BeginIterate;
    
    while CachedIni.IterateNext(SectionName, pointer(Section)) do begin
      SectionNames.AddObj(SectionName, Section);
      Section :=  nil;
    end;
    
    CachedIni.EndIterate;
    
    SectionNames.Sorted :=  TRUE;
    
    for i:=0 to SectionNames.Count - 1 do begin
      if SectionNames[i] <> '' then begin
        StrBuilder.Append('[');
        StrBuilder.Append(SectionNames[i]);
        StrBuilder.Append(']'#13#10);
      end;
      
      Section :=  SectionNames.Values[i];
      
      Section.BeginIterate;
      
      while Section.IterateNext(Key, pointer(Value)) do begin
        SectionKeys.AddObj(Key, Value);
        Value :=  nil;
      end;
      
      Section.EndIterate;
      
      SectionKeys.Sorted :=  TRUE;
      
      for j:=0 to SectionKeys.Count - 1 do begin
        StrBuilder.Append(SectionKeys[j]);
        StrBuilder.Append('=');
        StrBuilder.Append(TString(SectionKeys.Values[j]).Value);
        StrBuilder.Append(#13#10);
      end;
      
      SectionKeys.Clear;
      SectionKeys.Sorted :=  FALSE;
    end; // .for
  end; // .if
  
  result  :=  Files.WriteFileContents(StrBuilder.BuildStr, FilePath);
  // * * * * * //
  SysUtils.FreeAndNil(StrBuilder);
  SysUtils.FreeAndNil(SectionNames);
  SysUtils.FreeAndNil(SectionKeys);
end; // .function SaveIni

function ReadStrFromIni
(
  const Key:          string;
  const SectionName:  string;
        FilePath:     string;
  out   Res:          string
): boolean;

var
{U} CachedIni:  {O} TAssocArray {OF TAssocArray};
{U} Section:    {O} TAssocArray {OF TString};
{U} Value:      TString;

begin
  CachedIni :=  nil;
  Section   :=  nil;
  Value     :=  nil;
  // * * * * * //
  FilePath  :=  SysUtils.ExpandFileName(FilePath);
  CachedIni :=  CachedIniFiles[FilePath];
  
  if CachedIni = nil then begin
    LoadIni(FilePath);
    CachedIni :=  CachedIniFiles[FilePath];
  end;
  
  result  :=  CachedIni <> nil;
  
  if result then begin
    Section :=  CachedIni[SectionName];
    result  :=  Section <> nil;
    
    if result then begin
      Value   :=  Section[Key];
      result  :=  Value <> nil;
      
      if result then begin
        Res :=  Value.Value;
      end;
    end;
  end; // .if
end; // .function ReadStrFromIni

function WriteStrToIni (const Key, Value, SectionName: string; FilePath: string): boolean;
var
{U} CachedIni:      {O} TAssocArray {OF TAssocArray};
{U} Section:        {O} TAssocArray {OF TString};
    InvalidCharPos: integer;

begin
  CachedIni :=  nil;
  Section   :=  nil;
  // * * * * * //
  FilePath  :=  SysUtils.ExpandFileName(FilePath);
  CachedIni :=  CachedIniFiles[FilePath];
  
  if CachedIni = nil then begin
    if not LoadIni(FilePath) then begin
      CachedIniFiles[FilePath] := AssocArrays.NewStrictAssocArr(TAssocArray);
    end;

    CachedIni := CachedIniFiles[FilePath];
  end;
  
  result  :=
    not StrLib.FindCharset([';', #10, #13, ']'], SectionName, InvalidCharPos) and
    not StrLib.FindCharset([';', #10, #13, '='], Key, InvalidCharPos)         and
    not StrLib.FindCharset([';', #10, #13], Value, InvalidCharPos)            and
    ((CachedIni <> nil) or (not SysUtils.FileExists(FilePath)));
  
  if result then begin
    if CachedIni = nil then begin
      CachedIni                := AssocArrays.NewStrictAssocArr(TAssocArray);
      CachedIniFiles[FilePath] := CachedIni;
    end;
    
    Section := CachedIni[SectionName];
    
    if Section = nil then begin
      Section                := AssocArrays.NewStrictAssocArr(TString);
      CachedIni[SectionName] := Section;
    end;
    
    Section[Key] := TString.Create(Value);
  end; // .if
end; // .function WriteStrToIni

begin
  CachedIniFiles := AssocArrays.NewStrictAssocArr(TAssocArray);
end.

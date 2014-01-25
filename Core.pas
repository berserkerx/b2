unit Core;
{
DESCRIPTION:  Low-level functions
AUTHOR:       Alexander Shostak (aka Berserker aka EtherniDee aka BerSoft)
}

(***)  interface  (***)
uses
  Windows, Math, Utils, DlgMes, CFiles, Files, hde32,
  PatchApi;

const
  (* Hooks *)
  HOOKTYPE_JUMP   = 0;  // jmp, 5 bytes
  HOOKTYPE_CALL   = 1;  // call, 5 bytes
  
  (*
  Opcode: call.
  Creates a bridge to High-level function "F".
  function F (Context: PHookHandlerArgs): TExecuteDefaultCodeFlag; stdcall;
  if default code should be executed, it can contain any commands except jumps.
  *)
  HOOKTYPE_BRIDGE = 2;
  
  OPCODE_JUMP     = $E9;
  OPCODE_CALL     = $E8;
  OPCODE_RET      = $C3;
  
  EXEC_DEF_CODE   = TRUE;


type
  THookRec = packed record
    Opcode: byte;
    Ofs:    integer;
  end; // .record THookRec
  
  PHookHandlerArgs  = ^THookHandlerArgs;
  THookHandlerArgs  = packed record
    EDI, ESI, EBP, ESP, EBX, EDX, ECX, EAX: integer;
    RetAddr:                                POINTER;
  end; // .record THookHandlerArgs

  PContext = PHookHandlerArgs;
  
  PAPIArg = ^TAPIArg;
  TAPIArg = packed record
    v:  integer;
  end; // .record TAPIArg


function  WriteAtCode (Count: integer; Src, Dst: POINTER): boolean; stdcall;

(* in BRIDGE mode hook functions return address to call original routine *)
function  Hook
(
  HandlerAddr:  POINTER;
  HookType:     integer;
  PatchSize:    integer;
  CodeAddr:     POINTER
): {n} POINTER; stdcall;

function  ApiHook
(
  HandlerAddr:  POINTER;
  HookType:     integer;
  CodeAddr:     POINTER
): {n} POINTER; stdcall;

function  APIArg (Context: PHookHandlerArgs; ArgN: integer): PAPIArg; inline;
function  GetOrigAPIAddr (HookAddr: POINTER): POINTER; stdcall;
function  RecallAPI (Context: PHookHandlerArgs; NumArgs: integer): integer; stdcall;
procedure KillThisProcess; stdcall;
procedure FatalError (const Err: string); stdcall;

// Returns address of assember ret-routine which will clean the arguments and return
function  Ret (NumArgs: integer): POINTER;


var
  (* Patching provider *)
  GlobalPatcher: PatchApi.TPatcher;
  p: PatchApi.TPatcherInstance;


(***) implementation (***)


const
  BRIDGE_DEF_CODE_OFS = 17;


var
{O} Hooker: Files.TFixedBuf;


function WriteAtCode (Count: integer; Src, Dst: POINTER): boolean;
var
  OldPageProtect: integer;

begin
  {!} Assert(Count >= 0);
  {!} Assert(Src <> nil);
  {!} Assert(Dst <> nil);
  result  :=  Windows.VirtualProtect(Dst, Count, Windows.PAGE_EXECUTE_READWRITE	, @OldPageProtect);
  
  if result then begin
    Utils.CopyMem(Count, Src, Dst);
    result  :=  Windows.VirtualProtect(Dst, Count, OldPageProtect, @OldPageProtect);
  end; // .if
end; // .function WriteAtCode

function Hook
(
  HandlerAddr:  POINTER;
  HookType:     integer;
  PatchSize:    integer;
  CodeAddr:     POINTER
): {n} POINTER;

const
  MIN_BRIDGE_SIZE = 25;
  
type
  TBytes  = array of byte;

var
{U} BridgeCode: POINTER;
    HookRec:    THookRec;
    NopCount:   integer;
    NopBuf:     string;
    
 function PreprocessCode (CodeSize: integer; OldCodeAddr, NewCodeAddr: POINTER): TBytes;
 var
   Delta:   integer;
   BufPos:  integer;
   Disasm:  hde32.TDisasm;
 
 begin
  {!} Assert(CodeSize >= sizeof(THookRec));
  {!} Assert(OldCodeAddr <> nil);
  {!} Assert(NewCodeAddr <> nil);
  SetLength(result, CodeSize);
  Utils.CopyMem(CodeSize, OldCodeAddr, @result[0]);
  Delta   :=  integer(NewCodeAddr) - integer(OldCodeAddr);
  BufPos  :=  0;
  
  while BufPos < CodeSize do begin
    hde32.hde32_disasm(Utils.PtrOfs(OldCodeAddr, BufPos), Disasm);
    
    if (Disasm.Len = sizeof(THookRec)) and (Disasm.Opcode in [OPCODE_JUMP, OPCODE_CALL]) then begin
      Dec(PINTEGER(@result[BufPos + 1])^, Delta);
    end; // .if
    
    Inc(BufPos, Disasm.Len);
  end; // .while
 end; // .function PreprocessCode

begin
  {!} Assert(HandlerAddr <> nil);
  {!} Assert(Math.InRange(HookType, HOOKTYPE_JUMP, HOOKTYPE_BRIDGE));
  {!} Assert(PatchSize >= sizeof(THookRec));
  {!} Assert(CodeAddr <> nil);
  BridgeCode  :=  nil;
  // * * * * * //
  result  :=  nil;

  if HookType = HOOKTYPE_JUMP then begin
    HookRec.Opcode  :=  OPCODE_JUMP;
  end // .if
  else begin
    HookRec.Opcode  :=  OPCODE_CALL;
  end; // .else
  
  if HookType = HOOKTYPE_BRIDGE then begin
    GetMem(BridgeCode, MIN_BRIDGE_SIZE + PatchSize);
    Hooker.Open(BridgeCode, MIN_BRIDGE_SIZE + PatchSize, CFiles.MODE_WRITE);
    // PUSHAD
    // PUSH ESP
    // MOV EAX, ????
    Hooker.WriteStr(#$60#$54#$B8);
    Hooker.WriteInt(integer(HandlerAddr));
    // CALL near EAX
    Hooker.WriteStr(#$FF#$D0);
    // TEST EAX, EAX
    // JZ ??
    Hooker.WriteStr(#$85#$C0#$74);
    Hooker.WriteByte(PatchSize + 10);
    // POPAD
    Hooker.WriteByte($61);
    // ADD ESP, 4
    Hooker.WriteStr(#$83#$C4#$04);
    // default CODE
    Hooker.Write
    (
      PatchSize,
      @PreprocessCode(PatchSize, CodeAddr, Utils.PtrOfs(BridgeCode, BRIDGE_DEF_CODE_OFS))[0]
    );
    // PUSH ????
    Hooker.WriteByte($68);
    Hooker.WriteInt(integer(CodeAddr) + sizeof(THookRec));
    // RET
    Hooker.WriteByte($C3);
    // POPAD
    // RET
    Hooker.WriteByte($61);
    Hooker.WriteByte($C3);
    Hooker.Close;
    HandlerAddr :=  BridgeCode;
    
    result  :=  Utils.PtrOfs(BridgeCode, BRIDGE_DEF_CODE_OFS);
  end; // .if
  
  HookRec.Ofs :=  integer(HandlerAddr) - integer(CodeAddr) - sizeof(THookRec);
  {!} Assert(WriteAtCode(sizeof(THookRec), @HookRec, CodeAddr));
  NopCount    :=  PatchSize - sizeof(THookRec);
  
  if NopCount > 0 then begin
    SetLength(NopBuf, NopCount);
    FillChar(NopBuf[1], NopCount, CHR($90));
    {!} Assert(WriteAtCode(NopCount, POINTER(NopBuf), Utils.PtrOfs(CodeAddr, sizeof(THookRec))));
  end; // .if
end; // .function Hook

function CalcHookSize (Code: POINTER): integer;
var
  Disasm: hde32.TDisasm;

begin
  {!} Assert(Code <> nil);
  result  :=  0;
  
  while result < sizeof(THookRec) do begin
    hde32.hde32_disasm(Code, Disasm);
    result  :=  result + Disasm.Len;
    Code    :=  Utils.PtrOfs(Code, Disasm.Len);
  end; // .while
end; // .function CalcHookSize

function ApiHook (HandlerAddr: POINTER; HookType: integer; CodeAddr: POINTER): {n} POINTER;
begin
  result  :=  Hook(HandlerAddr, HookType, CalcHookSize(CodeAddr), CodeAddr);
end; // .function ApiHook

function APIArg (Context: PHookHandlerArgs; ArgN: integer): PAPIArg;
begin
  result :=  Ptr(Context.ESP + (4 + 4 * ArgN));
end; // .function APIArg

function GetOrigAPIAddr (HookAddr: POINTER): POINTER;
begin
  {!} Assert(HookAddr <> nil);
  result  :=  POINTER
  (
    integer(HookAddr)                 +
    sizeof(THookRec)                  +
    PINTEGER(integer(HookAddr) + 1)^  +
    BRIDGE_DEF_CODE_OFS
  );
end; // .function GetOrigAPIAddr

function RecallAPI (Context: PHookHandlerArgs; NumArgs: integer): integer;
var
  APIAddr:  POINTER;
  PtrArgs:  integer;
  APIRes:   integer;
   
begin
  APIAddr :=  GetOrigAPIAddr(Ptr(PINTEGER(Context.ESP)^ - sizeof(THookRec)));
  PtrArgs :=  integer(APIArg(Context, NumArgs));
  
  asm
    MOV ECX, NumArgs
    MOV EDX, PtrArgs
  
  @PUSHARGS:
    PUSH [EDX]
    SUB EDX, 4
    Dec ECX
    JNZ @PUSHARGS
    
    MOV EAX, APIAddr
    CALL EAX
    MOV APIRes, EAX
  end; // .asm
  
  result :=  APIRes;
end; // .function RecallAPI

procedure KillThisProcess; ASSEMBLER;
asm
  xor EAX, EAX
  MOV ESP, EAX
  MOV [EAX], EAX
end; // .procedure KillThisProcess

procedure FatalError (const Err: string);
begin
  DlgMes.MsgError(Err);
  KillThisProcess;
end; // .procedure FatalError

procedure Ret0; ASSEMBLER;
asm
  // RET
end; // .procedure Ret0

procedure Ret4; ASSEMBLER;
asm
  RET 4
end; // .procedure Ret4

procedure Ret8; ASSEMBLER;
asm
  RET 8
end; // .procedure Ret8

procedure Ret12; ASSEMBLER;
asm
  RET 12
end; // .procedure Ret12

procedure Ret16; ASSEMBLER;
asm
  RET 16
end; // .procedure Ret16

procedure Ret20; ASSEMBLER;
asm
  RET 20
end; // .procedure Ret20

procedure Ret24; ASSEMBLER;
asm
  RET 24
end; // .procedure Ret24

procedure Ret28; ASSEMBLER;
asm
  RET 28
end; // .procedure Ret28

procedure Ret32; ASSEMBLER;
asm
  RET 32
end; // .procedure Ret32

function Ret (NumArgs: integer): POINTER;
begin
  case NumArgs of 
    0:  result  :=  @Ret0;
    1:  result  :=  @Ret4;
    2:  result  :=  @Ret8;
    3:  result  :=  @Ret12;
    4:  result  :=  @Ret16;
    5:  result  :=  @Ret20;
    6:  result  :=  @Ret24;
    7:  result  :=  @Ret28;
    8:  result  :=  @Ret32;
  else
    result  :=  nil;
    {!} Assert(FALSE);
  end; // .SWITCH NumArgs
end; // .function Ret

begin
  Hooker        := Files.TFixedBuf.Create;
  GlobalPatcher := PatchApi.GetPatcher;
  p             := GlobalPatcher.CreateInstance('ERA');
end.

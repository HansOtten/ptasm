program ptasm;

{
  V1.1 Last update Hans Otten November 2026

  MIT License

  Copyright (c) 2019, 2026 Hans Otten

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.
}




{ PTASM - a two pass 6502/65C02 cross assembler.

  Source and command line compatible with TASM32 (the Telemark Assembler,
  6502 table), but a single standalone program: the instruction set is
  built in, no TASM65.TAB is needed.  Written in plain (non-object) Pascal
  for Free Pascal, so it runs wherever FPC runs.

  Object output: Intel hex (-g0, default), MOS Technology paper tape
  (-m / -g1) or binary (-b / -g3).  Listing, label table, symbol file and export file as TASM.

  Changes with respect to TASM32:
  - '<' and '>' at the start of an expression select the low and high
    byte (LDA #<TABLE, LDA #>TABLE+1).
  - The MOS paper tape end record holds the record count and checksum
    (;00nnnncccc) instead of only ';00'.
  - A forward referenced operand keeps absolute addressing in pass 2, so
    there is no 'Label value misaligned' phase error for zero page.

  Build:   fpc ptasm.pas                                                }

{$mode fpc}
{$H-}
{$B-}
{$R-}
{$Q-}

uses dos;

const
  Version    = '1.1';
  MaxSym     = 15000;
  SymHashSz  = 4096;
  MaxMac     = 1000;
  MacHashSz  = 256;
  MaxArgs    = 10;
  MaxInc     = 8;
  MaxCond    = 32;
  MaxLineErr = 8;
  MaxExport  = 1000;
  MaxOps     = 110;
  MaxCmdArg  = 64;

  { addressing modes }
  mIMP = 0;  mACC = 1;  mIMM = 2;  mZPG = 3;  mZPX = 4;  mZPY = 5;
  mABS = 6;  mABX = 7;  mABY = 8;  mIND = 9;  mINX = 10; mINY = 11;
  mZPI = 12; mAIX = 13; mREL = 14; mZPR = 15;
  NModes = 16;
  ModeNames = 'IMPACCIMMZPGZPXZPYABSABXABYINDINXINYZPIAIXRELZPR';

type
  Str80 = string[80];

  TSym = record
    name    : Str80;     { key: label, or module:label for local labels }
    value   : longint;
    defined : boolean;   { has a value (from pass 1 or pass 2) }
    def2    : boolean;   { defined in pass 2 }
    isSet   : boolean;   { defined with SET }
    sgm     : char;      { segment for AVSYM }
    next    : longint;   { hash chain }
  end;

  TMac = record
    name  : string[40];
    nargs : longint;     { -1: no argument list }
    args  : array[1..MaxArgs] of string[32];
    body  : string;
    next  : longint;
  end;

  TOp = record
    mn   : string[4];
    code : array[0..NModes-1] of longint;   { -1: mode not available }
    cls  : array[0..NModes-1] of longint;   { instruction class mask }
  end;

var
  { memory image }
  image     : array[0..65535] of byte;
  used      : array[0..65535] of boolean;
  forcedAbs : array[0..65535] of boolean;   { per instruction, from pass 1 }

  { symbols }
  sym     : array[1..MaxSym] of TSym;
  nsym    : longint;
  symHash : array[0..SymHashSz-1] of longint;
  sidx    : array[1..MaxSym] of longint;
  nsidx   : longint;

  { macros }
  mac         : array[1..MaxMac] of TMac;
  nmac        : longint;
  cmdMacCount : longint;
  lastMac     : longint;
  macHash     : array[0..MacHashSz-1] of longint;
  actArg      : array[1..MaxArgs] of string;
  nAct        : longint;

  { instruction set }
  ops  : array[1..MaxOps] of TOp;
  nops : longint;

  { options }
  srcName, objName, lstName, expName, symName : string;
  symNameSet  : boolean;
  objFormat   : longint;    { 0 Intel hex, 1 MOS Technology, 3 binary }
  recLen      : longint;
  fillVal     : longint;
  amask       : longint;
  xmask       : longint;
  xSet        : boolean;
  table65C02  : boolean;
  contiguous  : boolean;
  expandOpt   : boolean;
  hexTable    : boolean;
  ignoreCase  : boolean;
  labelTable  : boolean;
  allLabels   : boolean;
  longLabels  : boolean;
  pageOpt     : boolean;
  pageLen     : longint;
  quiet       : boolean;
  symOpt      : boolean;
  avsym       : boolean;
  timing      : boolean;

  { assembly state }
  pass       : longint;
  pc         : longint;
  instrSeq   : longint;
  instrPC    : longint;
  errCount   : longint;
  warnCount  : longint;
  ended      : boolean;
  moduleName : Str80;
  localChar  : char;
  msFirst    : boolean;
  listOn     : boolean;
  codesOn    : boolean;
  pageOn     : boolean;
  curSeg     : char;
  title      : string;
  exitCode   : longint;

  { include files }
  incFile     : array[0..MaxInc] of text;
  incName     : array[0..MaxInc] of string;
  incLine     : array[0..MaxInc] of longint;
  incCondBase : array[0..MaxInc] of longint;
  incDepth    : longint;

  { conditional assembly }
  condDepth  : longint;
  condActive : array[0..MaxCond] of boolean;
  condParent : array[0..MaxCond] of boolean;
  condTaken  : array[0..MaxCond] of boolean;

  { current source line }
  errFile       : string;
  errLine       : longint;
  lineErr       : array[1..MaxLineErr] of string;
  nLineErr      : longint;
  lineAddr      : longint;
  lineByteStart : longint;
  lineBytes     : longint;
  lineDepth     : longint;
  expandedText  : string;
  wasExpanded   : boolean;

  { expression scanner }
  ex      : string;
  ep      : longint;
  exPC    : longint;
  exUndef : boolean;
  exErr   : boolean;

  { listing }
  lst        : text;
  lstOpen    : boolean;
  pageNo     : longint;
  pageLines  : longint;
  forceEject : boolean;

  { export }
  expKey  : array[1..MaxExport] of Str80;
  expShow : array[1..MaxExport] of Str80;
  nExport : longint;

  { object file }
  objF     : text;
  recCount : longint;

  { command line }
  cmdArg  : array[1..MaxCmdArg] of string;
  nCmdArg : longint;
  fileArg : array[1..5] of string;
  nFiles  : longint;

  { timing }
  t0 : real;

{ ---------------------------------------------------------------------- }
{ small helpers                                                          }
{ ---------------------------------------------------------------------- }

function hexDigit(n: longint): char;
begin
  n := n and 15;
  if n < 10 then hexDigit := chr(48 + n) else hexDigit := chr(55 + n)
end;

function hex2(n: longint): string;
begin
  hex2 := hexDigit(n shr 4) + hexDigit(n)
end;

function hex4(n: longint): string;
begin
  hex4 := hex2(n shr 8) + hex2(n)
end;

function decStr(n: longint): string;
var s: string;
begin
  str(n, s);
  decStr := s
end;

function dec4(n: longint): string;
var s: string;
begin
  str(n, s);
  while length(s) < 4 do s := '0' + s;
  dec4 := s
end;

function upstr(const s: string): string;
var i: longint; r: string;
begin
  r := s;
  for i := 1 to length(r) do r[i] := upcase(r[i]);
  upstr := r
end;

function isSpace(c: char): boolean;
begin
  isSpace := (c = ' ') or (c = #9)
end;

function isDigit(c: char): boolean;
begin
  isDigit := (c >= '0') and (c <= '9')
end;

function isAlpha(c: char): boolean;
begin
  isAlpha := ((c >= 'A') and (c <= 'Z')) or ((c >= 'a') and (c <= 'z'))
end;

function isAlnum(c: char): boolean;
begin
  isAlnum := isAlpha(c) or isDigit(c)
end;

function isHex(c: char): boolean;
begin
  c := upcase(c);
  isHex := isDigit(c) or ((c >= 'A') and (c <= 'F'))
end;

function digitVal(c: char): longint;
begin
  c := upcase(c);
  if isDigit(c) then digitVal := ord(c) - 48
  else if (c >= 'A') and (c <= 'Z') then digitVal := ord(c) - 55
  else digitVal := 99
end;

function isLabelChar(c: char): boolean;
begin
  isLabelChar := isAlnum(c) or (c = '_') or (c = '.')
end;

function labelStart(c: char): boolean;
begin
  labelStart := isAlpha(c) or (c = localChar)
end;

function isIdChar(c: char): boolean;    { macro scanning }
begin
  isIdChar := isAlnum(c) or (c = '_') or (c = '.')
end;

function trimL(const s: string): string;
var i: longint;
begin
  i := 1;
  while (i <= length(s)) and isSpace(s[i]) do inc(i);
  trimL := copy(s, i, 255)
end;

function trimR(const s: string): string;
var n: longint;
begin
  n := length(s);
  while (n > 0) and isSpace(s[n]) do dec(n);
  trimR := copy(s, 1, n)
end;

function trimS(const s: string): string;
begin
  trimS := trimL(trimR(s))
end;

function padTo(const s: string; n: longint): string;
var r: string;
begin
  r := s;
  if length(r) >= n then r := r + ' '
  else while length(r) < n do r := r + ' ';
  padTo := r
end;

function hashStr(const s: string; size: longint): longint;
var i, h: longint;
begin
  h := 0;
  for i := 1 to length(s) do h := (h * 31 + ord(s[i])) mod size;
  hashStr := h
end;

{ index just after a quoted item that starts at s[i] ('"' or '''') }
function skipQuoted(const s: string; i: longint): longint;
var j: longint;
begin
  if s[i] = '"' then
  begin
    j := i + 1;
    while (j <= length(s)) and (s[j] <> '"') do
    begin
      if s[j] = '\' then inc(j);
      inc(j)
    end;
    skipQuoted := j + 1
  end
  else
  begin
    if (i + 2 <= length(s)) and (s[i + 2] = '''') then skipQuoted := i + 3
    else skipQuoted := i + 1
  end
end;

function stripComment(const s: string): string;
var i: longint; found: boolean;
begin
  i := 1; found := false;
  while (i <= length(s)) and not found do
    if s[i] = ';' then found := true
    else if (s[i] = '"') or (s[i] = '''') then i := skipQuoted(s, i)
    else inc(i);
  if found then stripComment := trimR(copy(s, 1, i - 1))
  else stripComment := trimR(s)
end;

{ position of the first comma outside parentheses and quotes, 0 if none }
function findTopComma(const s: string; start: longint): longint;
var i, depth, r: longint;
begin
  i := start; depth := 0; r := 0;
  while (i <= length(s)) and (r = 0) do
    if (s[i] = '"') or (s[i] = '''') then i := skipQuoted(s, i)
    else
    begin
      if s[i] = '(' then inc(depth)
      else if s[i] = ')' then dec(depth)
      else if (s[i] = ',') and (depth = 0) then r := i;
      inc(i)
    end;
  findTopComma := r
end;

{ true if s is completely enclosed in one pair of parentheses }
function isWrapped(const s: string): boolean;
var i, depth: longint; r, done: boolean;
begin
  r := false;
  if (length(s) >= 2) and (s[1] = '(') and (s[length(s)] = ')') then
  begin
    i := 1; depth := 0; done := false;
    while (i <= length(s)) and not done do
      if (s[i] = '"') or (s[i] = '''') then i := skipQuoted(s, i)
      else
      begin
        if s[i] = '(' then inc(depth)
        else if s[i] = ')' then
        begin
          dec(depth);
          if depth = 0 then
          begin
            done := true;
            r := (i = length(s))
          end
        end;
        inc(i)
      end
  end;
  isWrapped := r
end;

function firstWord(const s: string): string;
var i: longint; r: string;
begin
  r := ''; i := 1;
  while (i <= length(s)) and isIdChar(s[i]) do
  begin
    r := r + s[i];
    inc(i)
  end;
  firstWord := r
end;

function openFile(var f: text; const name: string): boolean;
begin
  assign(f, name);
  {$I-} reset(f); {$I+}
  openFile := ioresult = 0
end;

function createFile(var f: text; const name: string): boolean;
begin
  assign(f, name);
  {$I-} rewrite(f); {$I+}
  createFile := ioresult = 0
end;

function fixPath(const s: string): string;
var i: longint; r: string;
begin
  r := s;
  for i := 1 to length(r) do
    if (r[i] = '/') or (r[i] = '\') then r[i] := DirectorySeparator;
  fixPath := r
end;

function dirOf(const s: string): string;
var p: longint;
begin
  p := length(s);
  while (p > 0) and not ((s[p] = '/') or (s[p] = '\') or (s[p] = ':')) do dec(p);
  dirOf := copy(s, 1, p)
end;

function changeExt(const name, ext: string): string;
var p: longint;
begin
  p := length(name);
  while (p > 0) and not ((name[p] = '.') or (name[p] = '/') or
                         (name[p] = '\') or (name[p] = ':')) do dec(p);
  if (p > 0) and (name[p] = '.') then changeExt := copy(name, 1, p - 1) + ext
  else changeExt := name + ext
end;

function nowSeconds: real;
var h, m, s, hs: word;
begin
  GetTime(h, m, s, hs);
  nowSeconds := h * 3600.0 + m * 60.0 + s + hs / 100.0
end;

{ ---------------------------------------------------------------------- }
{ errors                                                                 }
{ ---------------------------------------------------------------------- }

procedure report(const msg, data: string);
var s: string;
begin
  s := errFile + ' line ' + dec4(errLine) + ': ' + msg;
  if data <> '' then s := s + ' ' + data;
  writeln(s);
  if nLineErr < MaxLineErr then
  begin
    inc(nLineErr);
    lineErr[nLineErr] := s
  end
end;

procedure error(const msg, data: string);
begin
  if pass = 2 then
  begin
    inc(errCount);
    report(msg, data)
  end
end;

procedure warning(const msg, data: string);
begin
  if pass = 2 then
  begin
    inc(warnCount);
    report('Warning: ' + msg, data)
  end
end;

procedure fatal(const msg: string; code: longint);
begin
  writeln('ptasm: ', msg);
  halt(code)
end;

{ ---------------------------------------------------------------------- }
{ instruction set                                                        }
{ ---------------------------------------------------------------------- }

function findOp(const mn: string): longint;
var i, r: longint;
begin
  r := 0;
  for i := 1 to nops do
    if ops[i].mn = mn then r := i;
  findOp := r
end;

function modeIndex(const md: string): longint;
var m, r: longint;
begin
  r := -1;
  for m := 0 to NModes - 1 do
    if copy(ModeNames, m * 3 + 1, 3) = md then r := m;
  if r < 0 then fatal('internal error: bad mode ' + md, 4);
  modeIndex := r
end;

{ add opcodes for one mnemonic: spec is a list of MODExx items }
procedure defOp(const mn: string; c: longint; const spec: string);
var i, k, m: longint;
begin
  k := findOp(mn);
  if k = 0 then
  begin
    inc(nops); k := nops;
    ops[k].mn := mn;
    for m := 0 to NModes - 1 do
    begin
      ops[k].code[m] := -1;
      ops[k].cls[m] := 0
    end
  end;
  i := 1;
  while i <= length(spec) do
    if spec[i] = ' ' then inc(i)
    else
    begin
      m := modeIndex(copy(spec, i, 3));
      ops[k].code[m] := digitVal(spec[i + 3]) * 16 + digitVal(spec[i + 4]);
      ops[k].cls[m] := c;
      i := i + 5
    end
end;

procedure initOps;
var b: longint;
begin
  nops := 0;
  { NMOS 6502, class 1 }
  defOp('ADC', 1, 'IMM69 ZPG65 ZPX75 ABS6D ABX7D ABY79 INX61 INY71');
  defOp('AND', 1, 'IMM29 ZPG25 ZPX35 ABS2D ABX3D ABY39 INX21 INY31');
  defOp('ASL', 1, 'ACC0A ZPG06 ZPX16 ABS0E ABX1E');
  defOp('BCC', 1, 'REL90');
  defOp('BCS', 1, 'RELB0');
  defOp('BEQ', 1, 'RELF0');
  defOp('BIT', 1, 'ZPG24 ABS2C');
  defOp('BMI', 1, 'REL30');
  defOp('BNE', 1, 'RELD0');
  defOp('BPL', 1, 'REL10');
  defOp('BRK', 1, 'IMP00');
  defOp('BVC', 1, 'REL50');
  defOp('BVS', 1, 'REL70');
  defOp('CLC', 1, 'IMP18');
  defOp('CLD', 1, 'IMPD8');
  defOp('CLI', 1, 'IMP58');
  defOp('CLV', 1, 'IMPB8');
  defOp('CMP', 1, 'IMMC9 ZPGC5 ZPXD5 ABSCD ABXDD ABYD9 INXC1 INYD1');
  defOp('CPX', 1, 'IMME0 ZPGE4 ABSEC');
  defOp('CPY', 1, 'IMMC0 ZPGC4 ABSCC');
  defOp('DEC', 1, 'ZPGC6 ZPXD6 ABSCE ABXDE');
  defOp('DEX', 1, 'IMPCA');
  defOp('DEY', 1, 'IMP88');
  defOp('EOR', 1, 'IMM49 ZPG45 ZPX55 ABS4D ABX5D ABY59 INX41 INY51');
  defOp('INC', 1, 'ZPGE6 ZPXF6 ABSEE ABXFE');
  defOp('INX', 1, 'IMPE8');
  defOp('INY', 1, 'IMPC8');
  defOp('JMP', 1, 'ABS4C IND6C');
  defOp('JSR', 1, 'ABS20');
  defOp('LDA', 1, 'IMMA9 ZPGA5 ZPXB5 ABSAD ABXBD ABYB9 INXA1 INYB1');
  defOp('LDX', 1, 'IMMA2 ZPGA6 ZPYB6 ABSAE ABYBE');
  defOp('LDY', 1, 'IMMA0 ZPGA4 ZPXB4 ABSAC ABXBC');
  defOp('LSR', 1, 'ACC4A ZPG46 ZPX56 ABS4E ABX5E');
  defOp('NOP', 1, 'IMPEA');
  defOp('ORA', 1, 'IMM09 ZPG05 ZPX15 ABS0D ABX1D ABY19 INX01 INY11');
  defOp('PHA', 1, 'IMP48');
  defOp('PHP', 1, 'IMP08');
  defOp('PLA', 1, 'IMP68');
  defOp('PLP', 1, 'IMP28');
  defOp('ROL', 1, 'ACC2A ZPG26 ZPX36 ABS2E ABX3E');
  defOp('ROR', 1, 'ACC6A ZPG66 ZPX76 ABS6E ABX7E');
  defOp('RTI', 1, 'IMP40');
  defOp('RTS', 1, 'IMP60');
  defOp('SBC', 1, 'IMME9 ZPGE5 ZPXF5 ABSED ABXFD ABYF9 INXE1 INYF1');
  defOp('SEC', 1, 'IMP38');
  defOp('SED', 1, 'IMPF8');
  defOp('SEI', 1, 'IMP78');
  defOp('STA', 1, 'ZPG85 ZPX95 ABS8D ABX9D ABY99 INX81 INY91');
  defOp('STX', 1, 'ZPG86 ZPY96 ABS8E');
  defOp('STY', 1, 'ZPG84 ZPX94 ABS8C');
  defOp('TAX', 1, 'IMPAA');
  defOp('TAY', 1, 'IMPA8');
  defOp('TSX', 1, 'IMPBA');
  defOp('TXA', 1, 'IMP8A');
  defOp('TXS', 1, 'IMP9A');
  defOp('TYA', 1, 'IMP98');
  { 65C02 additions, class 2 }
  defOp('ADC', 2, 'ZPI72');
  defOp('AND', 2, 'ZPI32');
  defOp('BIT', 2, 'IMM89 ZPX34 ABX3C');
  defOp('CMP', 2, 'ZPID2');
  defOp('DEC', 2, 'ACC3A');
  defOp('EOR', 2, 'ZPI52');
  defOp('INC', 2, 'ACC1A');
  defOp('JMP', 2, 'AIX7C');
  defOp('LDA', 2, 'ZPIB2');
  defOp('ORA', 2, 'ZPI12');
  defOp('SBC', 2, 'ZPIF2');
  defOp('STA', 2, 'ZPI92');
  defOp('STZ', 2, 'ZPG64 ZPX74 ABS9C ABX9E');
  defOp('TRB', 2, 'ZPG14 ABS1C');
  defOp('TSB', 2, 'ZPG04 ABS0C');
  { R65C02 and R65C00/21, class 6 }
  defOp('BRA', 6, 'REL80');
  defOp('PHX', 6, 'IMPDA');
  defOp('PHY', 6, 'IMP5A');
  defOp('PLX', 6, 'IMPFA');
  defOp('PLY', 6, 'IMP7A');
  for b := 0 to 7 do
  begin
    defOp('BBR' + chr(48 + b), 6, 'ZPR' + hex2(b * 16 + $0F));
    defOp('BBS' + chr(48 + b), 6, 'ZPR' + hex2(b * 16 + $8F));
    defOp('RMB' + chr(48 + b), 6, 'ZPG' + hex2(b * 16 + $07));
    defOp('SMB' + chr(48 + b), 6, 'ZPG' + hex2(b * 16 + $87))
  end;
  { R65C00/21 only, class 4 }
  defOp('MUL', 4, 'IMP02')
end;

function has(k, m: longint): boolean;
begin
  has := (ops[k].code[m] >= 0) and ((ops[k].cls[m] and xmask) <> 0)
end;

function exists(k, m: longint): boolean;
begin
  exists := ops[k].code[m] >= 0
end;

function anyEnabled(k: longint): boolean;
var m: longint; r: boolean;
begin
  r := false;
  for m := 0 to NModes - 1 do
    if has(k, m) then r := true;
  anyEnabled := r
end;

{ ---------------------------------------------------------------------- }
{ symbol table                                                           }
{ ---------------------------------------------------------------------- }

function makeKey(const name: string): string;
var k: string;
begin
  if (length(name) > 0) and (name[1] = localChar) then k := moduleName + ':' + name
  else k := name;
  if ignoreCase then k := upstr(k);
  makeKey := k
end;

function displayName(const key: string): string;
var p: longint; r: string;
begin
  r := key;
  p := pos(':', r);
  if p = 1 then delete(r, 1, 1)
  else if p > 1 then r[p] := '.';
  displayName := r
end;

function findSym(const key: string): longint;
var k: longint;
begin
  k := symHash[hashStr(key, SymHashSz)];
  while (k <> 0) and (sym[k].name <> key) do k := sym[k].next;
  findSym := k
end;

function addSym(const key: string): longint;
var h: longint;
begin
  if nsym >= MaxSym then fatal('Label table overflow', 2);
  inc(nsym);
  h := hashStr(key, SymHashSz);
  sym[nsym].name := key;
  sym[nsym].value := 0;
  sym[nsym].defined := false;
  sym[nsym].def2 := false;
  sym[nsym].isSet := false;
  sym[nsym].sgm := 'C';
  sym[nsym].next := symHash[h];
  symHash[h] := nsym;
  addSym := nsym
end;

procedure defineLabel(const name: string; value: longint; viaSet: boolean);
var key: string; k: longint;
begin
  if length(name) > 32 then error('Label too long:', '(' + name + ')');
  key := makeKey(name);
  k := findSym(key);
  value := value and $FFFF;
  if viaSet then
  begin
    if k = 0 then k := addSym(key);
    sym[k].value := value;
    sym[k].defined := true;
    sym[k].isSet := true;
    sym[k].sgm := curSeg;
    if pass = 2 then sym[k].def2 := true
  end
  else if k = 0 then
  begin
    k := addSym(key);
    sym[k].value := value;
    sym[k].defined := true;
    sym[k].sgm := curSeg;
    if pass = 2 then sym[k].def2 := true
  end
  else if pass = 1 then
  begin
    { a second definition in pass 1 is reported in pass 2 }
    if not sym[k].defined then
    begin
      sym[k].value := value;
      sym[k].defined := true;
      sym[k].sgm := curSeg
    end
  end
  else if sym[k].def2 then
  begin
    if (amask and 4) <> 0 then error('Duplicate label', '(' + name + ')')
  end
  else
  begin
    if sym[k].defined and (sym[k].value <> value) and not sym[k].isSet then
      error('Label value misaligned', '(' + name + ')');
    sym[k].value := value;
    sym[k].defined := true;
    sym[k].def2 := true;
    sym[k].sgm := curSeg
  end
end;

{ ---------------------------------------------------------------------- }
{ macros (#DEFINE)                                                        }
{ ---------------------------------------------------------------------- }

function findMac(const name: string): longint;
var k: longint;
begin
  k := macHash[hashStr(name, MacHashSz)];
  while (k <> 0) and (mac[k].name <> name) do k := mac[k].next;
  findMac := k
end;

function newMacro(const name: string): longint;
var k, h: longint;
begin
  k := findMac(name);
  if k = 0 then
  begin
    if nmac >= MaxMac then
    begin
      error('Maximum number of macros exceeded', '');
      newMacro := 0;
      exit
    end;
    inc(nmac); k := nmac;
    h := hashStr(name, MacHashSz);
    mac[k].name := name;
    mac[k].next := macHash[h];
    macHash[h] := k
  end;
  mac[k].nargs := -1;
  mac[k].body := '';
  lastMac := k;
  newMacro := k
end;

procedure resetMacros;
var i, h: longint;
begin
  for i := 0 to MacHashSz - 1 do macHash[i] := 0;
  nmac := cmdMacCount;
  for i := 1 to nmac do
  begin
    h := hashStr(mac[i].name, MacHashSz);
    mac[i].next := macHash[h];
    macHash[h] := i
  end;
  lastMac := 0
end;

procedure appendS(var dst: string; const src: string; var ovf: boolean);
begin
  if length(dst) + length(src) > 255 then ovf := true
  else dst := dst + src
end;

procedure doDefine(const rest0: string);
var rest, name, a: string; i, n, k: longint;
    args: array[1..MaxArgs] of string;

  procedure addArg;
  begin
    if n < MaxArgs then
    begin
      inc(n);
      args[n] := trimS(a)
    end
    else error('Maximum number of args exceeded', '');
    a := ''
  end;

begin
  rest := stripComment(trimL(rest0));
  i := 1; name := '';
  while (i <= length(rest)) and isIdChar(rest[i]) do
  begin
    name := name + rest[i];
    inc(i)
  end;
  if name = '' then
  begin
    error('Missing macro name', '');
    exit
  end;
  n := -1;
  if (i <= length(rest)) and (rest[i] = '(') then
  begin
    n := 0; a := ''; inc(i);
    while (i <= length(rest)) and (rest[i] <> ')') do
    begin
      if rest[i] = ',' then addArg
      else a := a + rest[i];
      inc(i)
    end;
    if (n > 0) or (trimS(a) <> '') then addArg;
    if i <= length(rest) then inc(i)
    else error('Missing right parenthesis', '')
  end;
  k := newMacro(name);
  if k = 0 then exit;
  mac[k].nargs := n;
  for i := 1 to n do mac[k].args[i] := args[i];
  mac[k].body := trimS(copy(rest, i, 255))
end;

procedure doDefcont(const rest: string);
var ovf: boolean; b: string;
begin
  if lastMac = 0 then error('DEFCONT without DEFINE', '')
  else
  begin
    ovf := false;
    b := mac[lastMac].body;
    appendS(b, rest, ovf);
    if ovf then error('Macro expansion too long.', '');
    mac[lastMac].body := b
  end
end;

{ command line -dNAME or -dNAME=value }
procedure addCmdMacro(const s: string);
var p, k: longint; name, body: string;
begin
  p := pos('=', s);
  if p > 0 then
  begin
    name := copy(s, 1, p - 1);
    body := copy(s, p + 1, 255)
  end
  else
  begin
    name := s;
    body := ''
  end;
  if name = '' then fatal('Missing macro name after -d', 4);
  k := newMacro(name);
  if k > 0 then mac[k].body := body;
  cmdMacCount := nmac
end;

function substBody(k: longint; var ovf: boolean): string;
var b, r, id: string; i, j, a, found: longint;
begin
  b := mac[k].body; r := ''; i := 1;
  while i <= length(b) do
    if isIdChar(b[i]) then
    begin
      j := i;
      while (j <= length(b)) and isIdChar(b[j]) do inc(j);
      id := copy(b, i, j - i);
      found := 0;
      for a := 1 to mac[k].nargs do
        if mac[k].args[a] = id then found := a;
      if found > 0 then
      begin
        if found <= nAct then appendS(r, actArg[found], ovf)
      end
      else appendS(r, id, ovf);
      i := j
    end
    else
    begin
      appendS(r, b[i], ovf);
      inc(i)
    end;
  substBody := r
end;

function expandOnce(var s: string; var ovf: boolean): boolean;
var r, id, a: string; i, j, q, k, depth: longint; changed, done: boolean;
begin
  r := ''; i := 1; changed := false;
  while i <= length(s) do
  begin
    if s[i] = ';' then
    begin
      appendS(r, copy(s, i, 255), ovf);
      i := length(s) + 1
    end
    else if (s[i] = '"') or (s[i] = '''') then
    begin
      j := skipQuoted(s, i);
      appendS(r, copy(s, i, j - i), ovf);
      i := j
    end
    else if isIdChar(s[i]) then
    begin
      j := i;
      while (j <= length(s)) and isIdChar(s[j]) do inc(j);
      id := copy(s, i, j - i);
      k := 0;
      if isAlpha(id[1]) or (id[1] = '_') then k := findMac(id);
      if k = 0 then
      begin
        appendS(r, id, ovf);
        i := j
      end
      else if mac[k].nargs < 0 then
      begin
        appendS(r, mac[k].body, ovf);
        i := j;
        changed := true
      end
      else if (j <= length(s)) and (s[j] = '(') then
      begin
        nAct := 0; a := ''; depth := 0; q := j + 1; done := false;
        while (q <= length(s)) and not done do
          if (s[q] = '"') or (s[q] = '''') then
          begin
            j := skipQuoted(s, q);
            a := a + copy(s, q, j - q);
            q := j
          end
          else
          begin
            if (s[q] = ')') and (depth = 0) then done := true
            else if (s[q] = ',') and (depth = 0) then
            begin
              if nAct < MaxArgs then
              begin
                inc(nAct);
                actArg[nAct] := trimS(a)
              end;
              a := ''
            end
            else
            begin
              if s[q] = '(' then inc(depth)
              else if s[q] = ')' then dec(depth);
              a := a + s[q]
            end;
            inc(q)
          end;
        if ((nAct > 0) or (trimS(a) <> '')) and (nAct < MaxArgs) then
        begin
          inc(nAct);
          actArg[nAct] := trimS(a)
        end;
        appendS(r, substBody(k, ovf), ovf);
        i := q;
        changed := true
      end
      else
      begin
        appendS(r, id, ovf);
        i := j
      end
    end
    else
    begin
      appendS(r, s[i], ovf);
      inc(i)
    end
  end;
  s := r;
  expandOnce := changed
end;

procedure expandLine(var s: string);
var n: longint; ovf: boolean;
begin
  n := 0; ovf := false;
  while (n < 20) and expandOnce(s, ovf) do inc(n);
  if ovf then error('Macro expansion too long.', '');
  if n >= 20 then error('Macro expansion too deep (recursive macro?)', '')
end;

{ ---------------------------------------------------------------------- }
{ expression evaluator                                                   }
{ 16 bit result, evaluated strictly left to right (no precedence) as     }
{ TASM.  A leading '<' or '>' selects the low or high byte.               }
{ ---------------------------------------------------------------------- }

procedure exError(const m, d: string);
begin
  if not exErr then error(m, d);
  exErr := true
end;

function exCh: char;
begin
  if ep <= length(ex) then exCh := ex[ep] else exCh := #0
end;

procedure exSkip;
begin
  while (ep <= length(ex)) and isSpace(ex[ep]) do inc(ep)
end;

function allDigits(const s: string; base: longint): boolean;
var i: longint; r: boolean;
begin
  r := length(s) > 0;
  for i := 1 to length(s) do
    if digitVal(s[i]) >= base then r := false;
  allDigits := r
end;

function convNum(const s: string; base: longint): longint;
var i, v: longint;
begin
  v := 0;
  for i := 1 to length(s) do v := v * base + digitVal(s[i]);
  convNum := v
end;

function parseNumber: longint;
var s, body: string; last: char; base: longint;
begin
  s := '';
  while isAlnum(exCh) do
  begin
    s := s + ex[ep];
    inc(ep)
  end;
  last := upcase(s[length(s)]);
  body := copy(s, 1, length(s) - 1);
  base := 10;
  if last = 'H' then base := 16
  else if (last = 'B') and allDigits(body, 2) then base := 2
  else if (last = 'D') and allDigits(body, 10) then base := 10
  else if ((last = 'O') or (last = 'Q')) and allDigits(body, 8) then base := 8
  else body := s;
  if not allDigits(body, base) then
  begin
    exError('Invalid number:', '(' + s + ')');
    parseNumber := 0
  end
  else parseNumber := convNum(body, base)
end;

function lookupValue(const name: string): longint;
var k: longint;
begin
  k := findSym(makeKey(name));
  if (k > 0) and sym[k].defined then lookupValue := sym[k].value
  else
  begin
    exUndef := true;
    if pass = 2 then exError('Label not found:', '(' + name + ')');
    lookupValue := 0
  end
end;

function parseLevel: longint; forward;

function parseTerm: longint;
var v: longint; c: char; name: string;
begin
  v := 0;
  exSkip;
  c := exCh;
  if c = '-' then
  begin
    inc(ep);
    v := -parseTerm
  end
  else if c = '+' then
  begin
    inc(ep);
    v := parseTerm
  end
  else if c = '~' then
  begin
    inc(ep);
    v := not parseTerm
  end
  else if c = '(' then
  begin
    inc(ep);
    v := parseLevel;
    exSkip;
    if exCh = ')' then inc(ep)
    else exError('Missing right parenthesis', '')
  end
  else if isDigit(c) then v := parseNumber
  else if c = '$' then
  begin
    inc(ep);
    if isHex(exCh) then
      while isHex(exCh) do
      begin
        v := v * 16 + digitVal(exCh);
        inc(ep)
      end
    else v := exPC
  end
  else if c = '*' then
  begin
    inc(ep);
    v := exPC
  end
  else if (c = '%') and ((ep < length(ex)) and ((ex[ep + 1] = '0') or (ex[ep + 1] = '1'))) then
  begin
    inc(ep);
    while (exCh = '0') or (exCh = '1') do
    begin
      v := v * 2 + ord(exCh) - 48;
      inc(ep)
    end
  end
  else if (c = '@') and ((ep < length(ex)) and (digitVal(ex[ep + 1]) < 8)) then
  begin
    inc(ep);
    while digitVal(exCh) < 8 do
    begin
      v := v * 8 + digitVal(exCh);
      inc(ep)
    end
  end
  else if c = '''' then
  begin
    if ep + 1 <= length(ex) then
    begin
      v := ord(ex[ep + 1]);
      if (ep + 2 <= length(ex)) and (ex[ep + 2] = '''') then ep := ep + 3
      else ep := ep + 2
    end
    else
    begin
      exError('No terminating quote', '');
      inc(ep)
    end
  end
  else if labelStart(c) then
  begin
    name := c;
    inc(ep);
    while isLabelChar(exCh) do
    begin
      name := name + ex[ep];
      inc(ep)
    end;
    v := lookupValue(name)
  end
  else if c = #0 then exError('Value expected at end of expression', '')
  else if c in ['*', '/', '%', '&', '|', '^', '<', '>', '=', '!'] then
    exError('Binary operator where value expected', '')
  else exError('Unknown token:', '(' + c + ')');
  parseTerm := v
end;

{ read a binary operator, 0 if none }
function readOp: longint;
var c, d: char; r: longint;
begin
  c := exCh;
  if ep < length(ex) then d := ex[ep + 1] else d := #0;
  r := 0;
  if (c = '<') and (d = '<') then r := 6
  else if (c = '>') and (d = '>') then r := 7
  else if (c = '=') and (d = '=') then r := 8
  else if (c = '!') and (d = '=') then r := 9
  else if (c = '<') and (d = '=') then r := 12
  else if (c = '>') and (d = '=') then r := 13;
  if r <> 0 then ep := ep + 2
  else
  begin
    case c of
      '+': r := 1;
      '-': r := 2;
      '*': r := 3;
      '/': r := 4;
      '%': r := 5;
      '=': r := 8;
      '<': r := 10;
      '>': r := 11;
      '&': r := 14;
      '|': r := 15;
      '^': r := 16;
    end;
    if r <> 0 then inc(ep)
  end;
  readOp := r
end;

function applyOp(op, a, b: longint): longint;
var r: longint;
begin
  r := 0;
  case op of
    1: r := a + b;
    2: r := a - b;
    3: r := a * b;
    4: if b = 0 then exError('Division by zero', '') else r := a div b;
    5: if b = 0 then exError('Division by zero', '') else r := a mod b;
    6: r := a shl b;
    7: r := a shr b;
    8: r := ord(a = b);
    9: r := ord(a <> b);
    10: r := ord(a < b);
    11: r := ord(a > b);
    12: r := ord(a <= b);
    13: r := ord(a >= b);
    14: r := a and b;
    15: r := a or b;
    16: r := a xor b;
  end;
  applyOp := r
end;

function parseLevel: longint;
var v, w, op: longint; sel: char; done: boolean;
begin
  exSkip;
  sel := ' ';
  if (exCh = '<') or (exCh = '>') then
  begin
    sel := exCh;
    inc(ep)
  end;
  v := parseTerm;
  done := false;
  repeat
    exSkip;
    if (exCh = #0) or (exCh = ')') or exErr then done := true
    else
    begin
      op := readOp;
      if op = 0 then
      begin
        exError('Unknown token:', '(' + copy(ex, ep, 255) + ')');
        done := true
      end
      else
      begin
        w := parseTerm;
        v := applyOp(op, v, w)
      end
    end
  until done;
  if sel = '<' then v := v and $FF
  else if sel = '>' then v := (v shr 8) and $FF;
  parseLevel := v
end;

{ evaluate s; returns true when there was no error and no undefined label }
function evalExpr(const s: string; var v: longint): boolean;
begin
  ex := s; ep := 1; exUndef := false; exErr := false;
  exSkip;
  if ep > length(ex) then
  begin
    exError('Missing expression', '');
    v := 0
  end
  else
  begin
    v := parseLevel;
    exSkip;
    if (not exErr) and (ep <= length(ex)) then
      exError('Unknown token:', '(' + copy(ex, ep, 255) + ')')
  end;
  evalExpr := not exErr and not exUndef
end;

{ ---------------------------------------------------------------------- }
{ code generation                                                        }
{ ---------------------------------------------------------------------- }

procedure emit(b: longint);
begin
  if pass = 2 then
  begin
    if lineBytes = 0 then lineByteStart := pc;
    image[pc] := b and $FF;
    used[pc] := true
  end;
  inc(lineBytes);
  pc := (pc + 1) and $FFFF
end;

procedure emitWord(v: longint);          { instruction operand: low first }
begin
  emit(v);
  emit(v shr 8)
end;

procedure byteCheck(v: longint);         { 8 bit data, -a2 checks MS byte }
begin
  if ((amask and 2) <> 0) and ((v and $FF00) <> 0) then
    error('Unused data in MS byte of argument.', '')
end;

procedure zpCheck(v: longint);           { operand must be a zero page address }
begin
  if (v and $FFFF) > 255 then error('Range of argument exceeded.', '')
end;

procedure relByte(t, len: longint);
var d: longint;
begin
  d := (t and $FFFF) - ((instrPC + len) and $FFFF);
  if (d < -128) or (d > 127) then error('Range of relative branch exceeded.', '');
  emit(d)
end;

procedure modeError(k, m: longint; const s: string);
begin
  if exists(k, m) then
    error('Addressing mode needs 65C02 instructions (-x3):', '(' + s + ')')
  else error('Unrecognized argument:', '(' + s + ')')
end;

{ plain, ,X or ,Y operand: choose between zero page and absolute }
procedure addrMode(k: longint; const e: string; zpm, absm: longint);
var v: longint; ok, forced, useZp: boolean;
begin
  ok := evalExpr(e, v);
  if (zpm = mZPG) and exists(k, mREL) then
  begin
    emit(ops[k].code[mREL]);
    relByte(v, 2);
    exit
  end;
  if not (has(k, zpm) or has(k, absm)) then
  begin
    if exists(k, zpm) then modeError(k, zpm, e) else modeError(k, absm, e);
    exit
  end;
  if instrSeq <= 65535 then
  begin
    if pass = 1 then forcedAbs[instrSeq] := not ok;
    forced := forcedAbs[instrSeq]
  end
  else forced := not ok;
  useZp := has(k, zpm) and
           ((not has(k, absm)) or ((not forced) and ((v and $FFFF) < 256)));
  if useZp then
  begin
    emit(ops[k].code[zpm]);
    zpCheck(v);
    emit(v)
  end
  else
  begin
    emit(ops[k].code[absm]);
    emitWord(v)
  end
end;

procedure doInstruction(const mn, operand: string);
var k, c: longint; s, u, a, b, inner: string; v, v2: longint; ok: boolean;
begin
  k := findOp(mn);
  if k = 0 then
  begin
    error('Unrecognized instruction:', '(' + mn + ')');
    exit
  end;
  if not anyEnabled(k) then
  begin
    error('Instruction needs 65C02 instructions (-x3):', '(' + mn + ')');
    exit
  end;
  instrPC := pc;
  inc(instrSeq);
  s := operand;
  u := upstr(s);
  if s = '' then
  begin
    if has(k, mIMP) then emit(ops[k].code[mIMP])
    else if has(k, mACC) then emit(ops[k].code[mACC])
    else error('Missing operand', '')
  end
  else if (u = 'A') and exists(k, mACC) then
  begin
    if has(k, mACC) then emit(ops[k].code[mACC]) else modeError(k, mACC, s)
  end
  else if s[1] = '#' then
  begin
    if not has(k, mIMM) then modeError(k, mIMM, s)
    else
    begin
      ok := evalExpr(copy(s, 2, 255), v);
      emit(ops[k].code[mIMM]);
      byteCheck(v);
      emit(v)
    end
  end
  else if exists(k, mZPR) then
  begin
    c := findTopComma(s, 1);
    if c = 0 then error('Unrecognized argument:', '(' + s + ')')
    else
    begin
      ok := evalExpr(copy(s, 1, c - 1), v);
      emit(ops[k].code[mZPR]);
      zpCheck(v);
      emit(v);
      ok := evalExpr(copy(s, c + 1, 255), v2);
      relByte(v2, 3)
    end
  end
  else
  begin
    c := findTopComma(s, 1);
    if c > 0 then
    begin
      a := trimS(copy(s, 1, c - 1));
      b := upstr(trimS(copy(s, c + 1, 255)));
      if b = 'X' then addrMode(k, a, mZPX, mABX)
      else if b = 'Y' then
      begin
        if isWrapped(a) and has(k, mINY) then
        begin
          ok := evalExpr(copy(a, 2, length(a) - 2), v);
          emit(ops[k].code[mINY]);
          zpCheck(v);
          emit(v)
        end
        else addrMode(k, a, mZPY, mABY)
      end
      else error('Unrecognized argument:', '(' + s + ')')
    end
    else if isWrapped(s) then
    begin
      inner := copy(s, 2, length(s) - 2);
      c := findTopComma(inner, 1);
      if c > 0 then
      begin
        a := copy(inner, 1, c - 1);
        b := upstr(trimS(copy(inner, c + 1, 255)));
        if b <> 'X' then error('Unrecognized argument:', '(' + s + ')')
        else if has(k, mINX) then
        begin
          ok := evalExpr(a, v);
          emit(ops[k].code[mINX]);
          zpCheck(v);
          emit(v)
        end
        else if has(k, mAIX) then
        begin
          ok := evalExpr(a, v);
          emit(ops[k].code[mAIX]);
          emitWord(v)
        end
        else if exists(k, mAIX) then modeError(k, mAIX, s)
        else modeError(k, mINX, s)
      end
      else if has(k, mIND) then
      begin
        ok := evalExpr(inner, v);
        emit(ops[k].code[mIND]);
        emitWord(v)
      end
      else if has(k, mZPI) then
      begin
        ok := evalExpr(inner, v);
        emit(ops[k].code[mZPI]);
        zpCheck(v);
        emit(v)
      end
      else addrMode(k, s, mZPG, mABS)    { just grouping parentheses }
    end
    else addrMode(k, s, mZPG, mABS)
  end
end;

{ ---------------------------------------------------------------------- }
{ listing                                                                }
{ ---------------------------------------------------------------------- }

procedure openListing;
begin
  if not lstOpen then
  begin
    if not createFile(lst, lstName) then fatal('List file open error: ' + lstName, 3);
    lstOpen := true;
    pageNo := 0;
    pageLines := 0
  end
end;

procedure lstOut(const s: string);
begin
  if not lstOpen then exit;
  if pageOn then
  begin
    if (pageLines = 0) or (pageLines >= pageLen) or forceEject then
    begin
      if pageNo > 0 then write(lst, #12);
      inc(pageNo);
      writeln(lst, 'PTASM 6502/65C02 Assembler.  ', srcName, '  page ', pageNo);
      writeln(lst, title);
      writeln(lst);
      pageLines := 3;
      forceEject := false
    end;
    inc(pageLines)
  end;
  writeln(lst, s)
end;

procedure flushErrors;
var i: longint;
begin
  if pass = 2 then
    for i := 1 to nLineErr do lstOut(lineErr[i]);
  nLineErr := 0
end;

procedure listLine(const raw: string; skip: boolean);
var i, j, n, a, d: longint; src, bytes, prefix: string; flag: char;
begin
  flushErrors;
  if not listOn then exit;
  if wasExpanded and expandOpt then src := expandedText else src := raw;
  if not codesOn then
  begin
    lstOut(src);
    exit
  end;
  prefix := dec4(errLine);
  for d := 1 to lineDepth do prefix := prefix + '+';
  if length(prefix) >= 7 then prefix := prefix + ' '
  else while length(prefix) < 7 do prefix := prefix + ' ';
  n := lineBytes;
  if n > 0 then a := lineByteStart else a := lineAddr;
  bytes := '';
  i := 0;
  while (i < n) and (i < 4) do
  begin
    bytes := bytes + hex2(image[(a + i) and $FFFF]) + ' ';
    inc(i)
  end;
  while length(bytes) < 12 do bytes := bytes + ' ';
  if skip then flag := '~' else flag := ' ';
  lstOut(prefix + hex4(a) + flag + bytes + src);
  i := 4;
  while i < n do
  begin
    bytes := '';
    j := i;
    while (j < n) and (j < i + 4) do
    begin
      bytes := bytes + hex2(image[(a + j) and $FFFF]) + ' ';
      inc(j)
    end;
    lstOut(prefix + hex4((a + i) and $FFFF) + ' ' + trimR(bytes));
    i := i + 4
  end
end;

{ ---------------------------------------------------------------------- }
{ directives                                                             }
{ ---------------------------------------------------------------------- }

function directiveCode(const d: string): longint;
var r: longint;
begin
  r := 0;
  if d = 'EQU' then r := 1
  else if d = 'SET' then r := 2
  else if d = 'ORG' then r := 3
  else if (d = 'BYTE') or (d = 'DB') then r := 4
  else if (d = 'WORD') or (d = 'DW') then r := 5
  else if d = 'TEXT' then r := 6
  else if d = 'BLOCK' then r := 7
  else if d = 'FILL' then r := 8
  else if d = 'CHK' then r := 9
  else if d = 'END' then r := 10
  else if d = 'ECHO' then r := 11
  else if d = 'EJECT' then r := 12
  else if d = 'LIST' then r := 13
  else if d = 'NOLIST' then r := 14
  else if d = 'PAGE' then r := 15
  else if d = 'NOPAGE' then r := 16
  else if d = 'TITLE' then r := 17
  else if d = 'CODES' then r := 18
  else if d = 'NOCODES' then r := 19
  else if d = 'MODULE' then r := 20
  else if d = 'LOCALLABELCHAR' then r := 21
  else if d = 'LSFIRST' then r := 22
  else if d = 'MSFIRST' then r := 23
  else if d = 'EXPORT' then r := 24
  else if d = 'SYM' then r := 25
  else if d = 'AVSYM' then r := 26
  else if (d = 'BSEG') or (d = 'CSEG') or (d = 'DSEG') or
          (d = 'NSEG') or (d = 'XSEG') then r := 27
  else if d = 'ADDINSTR' then r := 28;
  directiveCode := r
end;

{ parse a "string" starting at s[p]; escapes as TASM }
function parseStr(const s: string; var p: longint; var r: string): boolean;
var c: char; n, k: longint; ok: boolean;
begin
  r := ''; ok := false;
  inc(p);
  while (p <= length(s)) and not ok do
  begin
    c := s[p];
    if c = '"' then
    begin
      ok := true;
      inc(p)
    end
    else if (c = '\') and (p < length(s)) then
    begin
      inc(p);
      c := s[p];
      case c of
        'n': r := r + #10;
        'r': r := r + #13;
        'b': r := r + #8;
        't': r := r + #9;
        'f': r := r + #12;
        '0'..'7':
          begin
            n := 0; k := 0;
            while (k < 3) and (p <= length(s)) and (s[p] >= '0') and (s[p] <= '7') do
            begin
              n := n * 8 + ord(s[p]) - 48;
              inc(p);
              inc(k)
            end;
            r := r + chr(n and 255);
            dec(p)
          end;
      else
        r := r + c
      end;
      inc(p)
    end
    else
    begin
      r := r + c;
      inc(p)
    end
  end;
  if not ok then error('No terminating quote', '');
  parseStr := ok
end;

{ next item of a comma separated list }
function nextItem(const s: string; var p: longint; var item: string): boolean;
var c: longint;
begin
  if p > length(s) then nextItem := false
  else
  begin
    c := findTopComma(s, p);
    if c = 0 then
    begin
      item := trimS(copy(s, p, 255));
      p := length(s) + 1
    end
    else
    begin
      item := trimS(copy(s, p, c - p));
      p := c + 1
    end;
    nextItem := true
  end
end;

{ a quoted string operand, or the bare operand }
function strOperand(const s: string): string;
var p: longint; r: string;
begin
  if (s <> '') and (s[1] = '"') then
  begin
    p := 1;
    if not parseStr(s, p, r) then r := ''
  end
  else r := s;
  strOperand := r
end;

procedure doEqu(const lab, e: string);
var v: longint; ok: boolean;
begin
  if lab = '' then
  begin
    error('EQU needs a label', '');
    exit
  end;
  ok := evalExpr(e, v);
  if (not exUndef) or (pass = 2) then defineLabel(lab, v, false)
end;

procedure doSetDir(const lab, e: string);
var v: longint; ok: boolean;
begin
  if lab = '' then
  begin
    error('SET needs a label', '');
    exit
  end;
  ok := evalExpr(e, v);
  defineLabel(lab, v, true)
end;

procedure doOrg(const lab, e: string);
var v: longint; ok: boolean;
begin
  ok := evalExpr(e, v);
  pc := v and $FFFF;
  if lineBytes = 0 then lineAddr := pc;
  if lab <> '' then defineLabel(lab, pc, false)
end;

procedure doData(code: longint; const operand: string);
var p, q, i, v: longint; item, sv: string; ok: boolean;
begin
  if operand = '' then
  begin
    error('Missing expression', '');
    exit
  end;
  p := 1;
  while nextItem(operand, p, item) do
    if item = '' then error('Missing expression', '')
    else if (item[1] = '"') and (code <> 5) then
    begin
      q := 1;
      if parseStr(item, q, sv) then
      begin
        for i := 1 to length(sv) do emit(ord(sv[i]));
        if q <= length(item) then error('Unknown token:', '(' + copy(item, q, 255) + ')')
      end
    end
    else
    begin
      ok := evalExpr(item, v);
      if code = 5 then
      begin
        if msFirst then
        begin
          emit(v shr 8);
          emit(v)
        end
        else emitWord(v)
      end
      else
      begin
        byteCheck(v);
        emit(v)
      end
    end
end;

procedure doFill(const operand: string);
var p, n, v, i: longint; item: string; ok: boolean;
begin
  p := 1; n := 0; v := 255;
  if nextItem(operand, p, item) then ok := evalExpr(item, n)
  else error('Missing expression', '');
  if nextItem(operand, p, item) then ok := evalExpr(item, v);
  if (n < 0) or (n > 65536) then
  begin
    error('Range of argument exceeded.', '');
    n := 0
  end;
  for i := 1 to n do emit(v)
end;

procedure doChk(const operand: string);
var a, v, sum: longint; ok: boolean;
begin
  ok := evalExpr(operand, v);
  sum := 0;
  a := v and $FFFF;
  if a > pc then error('Range of argument exceeded.', '')
  else if pass = 2 then
    while a < pc do
    begin
      sum := sum + image[a];
      inc(a)
    end;
  emit(sum)
end;

procedure doEcho(const operand: string);
var v, p: longint; r: string; ok: boolean;
begin
  if pass <> 2 then exit;
  if (operand <> '') and (operand[1] = '"') then
  begin
    p := 1;
    if parseStr(operand, p, r) then write(stderr, r)
  end
  else
  begin
    ok := evalExpr(operand, v);
    write(stderr, v)
  end
end;

procedure doExport(const operand: string);
var p: longint; item: string;
begin
  if pass <> 2 then exit;
  p := 1;
  while nextItem(operand, p, item) do
    if item <> '' then
    begin
      if nExport < MaxExport then
      begin
        inc(nExport);
        expKey[nExport] := makeKey(item);
        expShow[nExport] := item
      end
      else error('Too many EXPORT labels', '')
    end
end;

procedure doDirective(code: longint; const dname, lab, operand: string);
var v: longint; ok: boolean; r: string;
begin
  case code of
    1: doEqu(lab, operand);
    2: doSetDir(lab, operand);
    3: doOrg(lab, operand);
  else
    begin
      if lab <> '' then defineLabel(lab, pc, false);
      case code of
        4, 5, 6: doData(code, operand);
        7: begin
             ok := evalExpr(operand, v);
             pc := (pc + v) and $FFFF
           end;
        8: doFill(operand);
        9: doChk(operand);
        10: ended := true;
        11: doEcho(operand);
        12: if pass = 2 then forceEject := true;
        13: begin
              listOn := true;
              if pass = 2 then openListing
            end;
        14: listOn := false;
        15: pageOn := true;
        16: pageOn := false;
        17: title := copy(strOperand(operand), 1, 79);
        18: codesOn := true;
        19: codesOn := false;
        20: moduleName := firstWord(operand);
        21: begin
              r := strOperand(operand);
              if r <> '' then localChar := r[1]
            end;
        22: msFirst := false;
        23: msFirst := true;
        24: doExport(operand);
        25, 26:
          begin
            symOpt := true;
            avsym := code = 26;
            if (operand <> '') and not symNameSet then
              symName := strOperand(operand)
          end;
        27: curSeg := dname[1];
        28: error('ADDINSTR is not supported (PTASM has a built-in instruction set)', '');
      end
    end
  end
end;

{ ---------------------------------------------------------------------- }
{ statements and source lines                                            }
{ ---------------------------------------------------------------------- }

procedure processStatement(const st0: string);
var st, lab, op, uop, dname, operand, rest: string; i, code: longint;
begin
  st := stripComment(st0);
  exPC := pc;
  i := 1; lab := '';
  if (st <> '') and labelStart(st[1]) then
  begin
    lab := st[1];
    i := 2;
    while (i <= length(st)) and isLabelChar(st[i]) do
    begin
      lab := lab + st[i];
      inc(i)
    end;
    if (i <= length(st)) and (st[i] = ':') then inc(i)
  end;
  while (i <= length(st)) and isSpace(st[i]) do inc(i);
  rest := copy(st, i, 255);
  if rest = '' then
  begin
    if lab <> '' then defineLabel(lab, pc, false);
    exit
  end;
  if rest[1] = '=' then
  begin
    doEqu(lab, copy(rest, 2, 255));
    exit
  end;
  if (length(rest) >= 2) and ((rest[1] = '*') or (rest[1] = '$')) and (rest[2] = '=') then
  begin
    doOrg(lab, copy(rest, 3, 255));
    exit
  end;
  i := 1; op := '';
  while (i <= length(rest)) and not isSpace(rest[i]) do
  begin
    op := op + rest[i];
    inc(i)
  end;
  operand := trimS(copy(rest, i, 255));
  uop := upstr(op);
  if uop[1] = '.' then dname := copy(uop, 2, 255) else dname := uop;
  code := directiveCode(dname);
  if code > 0 then doDirective(code, dname, lab, operand)
  else
  begin
    if lab <> '' then defineLabel(lab, pc, false);
    if uop[1] = '.' then error('Unrecognized directive:', '(' + op + ')')
    else doInstruction(uop, operand)
  end
end;

function assembling: boolean;
begin
  assembling := (condDepth = 0) or condActive[condDepth]
end;

procedure doInclude(const rest: string);
var name: string; p: longint;
begin
  if (rest <> '') and (rest[1] = '"') then
  begin
    name := copy(rest, 2, 255);
    p := pos('"', name);
    if p > 0 then name := copy(name, 1, p - 1)
    else error('No terminating quote', '')
  end
  else name := trimS(rest);
  name := fixPath(name);
  if name = '' then
  begin
    error('Missing file name', '');
    exit
  end;
  if incDepth >= MaxInc then
  begin
    error('Too many nested INCLUDEs', '');
    exit
  end;
  if openFile(incFile[incDepth + 1], name) then
  begin
    inc(incDepth);
    incName[incDepth] := name
  end
  else if (dirOf(incName[incDepth]) <> '') and
          openFile(incFile[incDepth + 1], dirOf(incName[incDepth]) + name) then
  begin
    inc(incDepth);
    incName[incDepth] := dirOf(incName[incDepth - 1]) + name
  end
  else
  begin
    error('Source file open error:', '(' + name + ')');
    exit
  end;
  incLine[incDepth] := 0;
  incCondBase[incDepth] := condDepth
end;

{ '#' lines; returns true when the line is skipped by conditional assembly }
function doPreproc(const t: string): boolean;
var w, rest, e: string; i, v: longint; c, parent: boolean;
begin
  doPreproc := false;
  i := 2;
  while (i <= length(t)) and isSpace(t[i]) do inc(i);
  w := '';
  while (i <= length(t)) and isAlpha(t[i]) do
  begin
    w := w + upcase(t[i]);
    inc(i)
  end;
  rest := trimS(stripComment(copy(t, i, 255)));
  if (w = 'IF') or (w = 'IFDEF') or (w = 'IFNDEF') then
  begin
    parent := assembling;
    if condDepth >= MaxCond then
    begin
      error('Max number of nested conditionals exceeded', '');
      exit
    end;
    c := false;
    if parent then
    begin
      if w = 'IF' then
      begin
        e := rest;
        if nmac > 0 then expandLine(e);
        c := evalExpr(e, v) and (v <> 0)
      end
      else
      begin
        c := findMac(firstWord(rest)) > 0;
        if w = 'IFNDEF' then c := not c
      end
    end;
    inc(condDepth);
    condParent[condDepth] := parent;
    condActive[condDepth] := parent and c;
    condTaken[condDepth] := condActive[condDepth]
  end
  else if w = 'ELSE' then
  begin
    if condDepth <= incCondBase[incDepth] then error('Imbalanced conditional.', '')
    else
    begin
      condActive[condDepth] := condParent[condDepth] and not condTaken[condDepth];
      condTaken[condDepth] := true
    end
  end
  else if w = 'ENDIF' then
  begin
    if condDepth <= incCondBase[incDepth] then error('Imbalanced conditional.', '')
    else dec(condDepth)
  end
  else if not assembling then doPreproc := true
  else if w = 'DEFINE' then doDefine(copy(t, i, 255))
  else if w = 'DEFCONT' then doDefcont(rest)
  else if w = 'INCLUDE' then doInclude(rest)
  else error('Unrecognized directive:', '(#' + w + ')')
end;

procedure processSourceLine(const raw: string);
var t, s: string; i, start: longint; skip: boolean;
begin
  errFile := incName[incDepth];
  errLine := incLine[incDepth];
  lineDepth := incDepth;
  nLineErr := 0;
  lineAddr := pc;
  lineByteStart := pc;
  lineBytes := 0;
  wasExpanded := false;
  expandedText := raw;
  skip := false;
  t := trimL(raw);
  if (t <> '') and (t[1] = '#') then skip := doPreproc(t)
  else if not assembling then skip := true
  else
  begin
    s := raw;
    if nmac > 0 then
    begin
      expandLine(s);
      if s <> raw then
      begin
        wasExpanded := true;
        expandedText := s
      end
    end;
    { '\' separates statements }
    start := 1; i := 1;
    while (i <= length(s)) and not ended do
      if (s[i] = '"') or (s[i] = '''') then i := skipQuoted(s, i)
      else if s[i] = ';' then i := length(s) + 1
      else if s[i] = '\' then
      begin
        processStatement(copy(s, start, i - start));
        start := i + 1;
        inc(i)
      end
      else inc(i);
    if not ended then processStatement(copy(s, start, 255))
  end;
  if pass = 2 then listLine(raw, skip)
end;

procedure runPass;
var line: string; stop: boolean; n: longint;
begin
  pc := 0; instrSeq := 0; ended := false;
  moduleName := ''; localChar := '_'; msFirst := false;
  codesOn := true; listOn := not quiet; pageOn := pageOpt; curSeg := 'C';
  condDepth := 0; nExport := 0; forceEject := false;
  resetMacros;
  incDepth := 0;
  incName[0] := srcName;
  incLine[0] := 0;
  incCondBase[0] := 0;
  if not openFile(incFile[0], srcName) then fatal('Source file open error: ' + srcName, 3);
  stop := false;
  while not stop do
    if eof(incFile[incDepth]) then
    begin
      errFile := incName[incDepth];
      errLine := incLine[incDepth];
      nLineErr := 0;
      if condDepth <> incCondBase[incDepth] then
      begin
        error('Imbalanced conditional.', '');
        condDepth := incCondBase[incDepth]
      end;
      if incDepth = 0 then
      begin
        warning('No END directive before EOF', '');
        stop := true
      end;
      flushErrors;
      close(incFile[incDepth]);
      dec(incDepth)
    end
    else
    begin
      readln(incFile[incDepth], line);
      n := length(line);
      while (n > 0) and ((line[n] = #13) or (line[n] = #26)) do dec(n);
      line := copy(line, 1, n);
      inc(incLine[incDepth]);
      processSourceLine(line);
      if ended then stop := true
    end;
  while incDepth >= 0 do
  begin
    close(incFile[incDepth]);
    dec(incDepth)
  end
end;

{ ---------------------------------------------------------------------- }
{ output files                                                           }
{ ---------------------------------------------------------------------- }

function symGreater(a, b: longint): boolean;
var ua, ub: string;
begin
  ua := upstr(displayName(sym[a].name));
  ub := upstr(displayName(sym[b].name));
  if ua <> ub then symGreater := ua > ub
  else symGreater := sym[a].name > sym[b].name
end;

procedure collectSyms(all: boolean);
var k, i, j, t, gap: longint;
begin
  nsidx := 0;
  for k := 1 to nsym do
    if sym[k].defined and (all or (pos(':', sym[k].name) = 0)) then
    begin
      inc(nsidx);
      sidx[nsidx] := k
    end;
  gap := nsidx div 2;
  while gap > 0 do
  begin
    for i := gap + 1 to nsidx do
    begin
      t := sidx[i];
      j := i;
      while (j > gap) and symGreater(sidx[j - gap], t) do
      begin
        sidx[j] := sidx[j - gap];
        j := j - gap
      end;
      sidx[j] := t
    end;
    gap := gap div 2
  end
end;

procedure writeLabelTable;
var i, col: longint; line, item: string;
begin
  collectSyms(allLabels);
  lstOut('');
  if longLabels then
  begin
    lstOut('Label                            Value');
    lstOut('--------------------------------------');
    for i := 1 to nsidx do
      lstOut(padTo(displayName(sym[sidx[i]].name), 33) + hex4(sym[sidx[i]].value))
  end
  else
  begin
    lstOut('Label        Value      Label        Value      Label        Value');
    lstOut('------------------      ------------------      ------------------');
    line := ''; col := 0;
    for i := 1 to nsidx do
    begin
      item := padTo(displayName(sym[sidx[i]].name), 14) + hex4(sym[sidx[i]].value);
      if col < 2 then item := item + '      ';
      line := line + item;
      inc(col);
      if col = 3 then
      begin
        lstOut(trimR(line));
        line := '';
        col := 0
      end
    end;
    if line <> '' then lstOut(trimR(line))
  end
end;

procedure writeHexTable;
var row, j: longint; any: boolean; line: string;
begin
  lstOut('');
  lstOut('ADDR  00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F');
  lstOut('-----------------------------------------------------');
  row := 0;
  while row < 65536 do
  begin
    any := false;
    for j := 0 to 15 do
      if used[row + j] then any := true;
    if any then
    begin
      line := hex4(row) + ' ';
      for j := 0 to 15 do
        if used[row + j] then line := line + ' ' + hex2(image[row + j])
        else line := line + '   ';
      lstOut(trimR(line))
    end;
    row := row + 16
  end
end;

procedure writeSymFile;
var f: text; i, k: longint;
begin
  collectSyms(true);
  if not createFile(f, symName) then
  begin
    writeln('ptasm: Symbol file open error: ', symName);
    exitCode := 3;
    exit
  end;
  for i := 1 to nsidx do
  begin
    k := sidx[i];
    if avsym then
      writeln(f, 'AS     ', padTo(displayName(sym[k].name), 15), sym[k].sgm, ':', hex4(sym[k].value))
    else
      writeln(f, padTo(displayName(sym[k].name), 15), hex4(sym[k].value))
  end;
  close(f)
end;

procedure writeExpFile;
var f: text; i, k: longint;
begin
  if not createFile(f, expName) then
  begin
    writeln('ptasm: Export file open error: ', expName);
    exitCode := 3;
    exit
  end;
  for i := 1 to nExport do
  begin
    k := findSym(expKey[i]);
    if (k > 0) and sym[k].defined then
      writeln(f, padTo(expShow[i], 15), '.EQU   $', hex4(sym[k].value))
    else
    begin
      writeln('ptasm: EXPORT label not found: ', expShow[i]);
      inc(errCount)
    end
  end;
  close(f)
end;

procedure writeRecord(ad, n: longint);
var i, sum: longint;
begin
  sum := n + (ad shr 8) + (ad and $FF);
  if objFormat = 0 then write(objF, ':', hex2(n), hex4(ad), '00')
  else write(objF, ';', hex2(n), hex4(ad));
  for i := 0 to n - 1 do
  begin
    write(objF, hex2(image[ad + i]));
    sum := sum + image[ad + i]
  end;
  if objFormat = 0 then write(objF, hex2(-sum), #13, #10)
  else write(objF, hex4(sum), #13, #10);
  inc(recCount)
end;

procedure writeBinary;
var f: file; a, lo, hi, n, i: longint; buf: array[0..1023] of byte;
begin
  assign(f, objName);
  {$I-} rewrite(f, 1); {$I+}
  if ioresult <> 0 then
  begin
    writeln('ptasm: Object file open error: ', objName);
    exitCode := 3;
    exit
  end;
  lo := 0;
  while (lo <= 65535) and not used[lo] do inc(lo);
  hi := 65535;
  while (hi >= 0) and not used[hi] do dec(hi);
  a := lo;
  while a <= hi do
  begin
    n := hi - a + 1;
    if n > 1024 then n := 1024;
    for i := 0 to n - 1 do buf[i] := image[a + i];
    blockwrite(f, buf, n);
    a := a + n
  end;
  close(f)
end;

procedure writeObject;
var a, n, lo, hi: longint;
begin
  if objFormat = 3 then
  begin
    writeBinary;
    exit
  end;
  if not createFile(objF, objName) then
  begin
    writeln('ptasm: Object file open error: ', objName);
    exitCode := 3;
    exit
  end;
  recCount := 0;
  if contiguous then
  begin
    lo := 0;
    while (lo <= 65535) and not used[lo] do inc(lo);
    hi := 65535;
    while (hi >= 0) and not used[hi] do dec(hi);
    a := lo;
    while a <= hi do
    begin
      n := hi - a + 1;
      if n > recLen then n := recLen;
      writeRecord(a, n);
      a := a + n
    end
  end
  else
  begin
    a := 0;
    while a <= 65535 do
      if used[a] then
      begin
        n := 0;
        while (a + n <= 65535) and (n < recLen) and used[a + n] do inc(n);
        writeRecord(a, n);
        a := a + n
      end
      else inc(a)
  end;
  if objFormat = 0 then write(objF, ':00000001FF', #13, #10)
  else write(objF, ';00', hex4(recCount), hex4((recCount shr 8) + (recCount and $FF)), #13, #10);
  close(objF)
end;

{ ---------------------------------------------------------------------- }
{ command line                                                           }
{ ---------------------------------------------------------------------- }

procedure usage;
begin
  writeln('PTASM 6502/65C02 Assembler. Version ', Version);
  writeln('Usage: ptasm -65 [-options ...] src_file [obj_file [lst_file [exp_file [sym_file]]]]');
  writeln('Options:');
  writeln('  -65      6502 instruction set (default). -t65c02 = -65 -x3');
  writeln('  -a[mask] Assembly checks: 2=unused data in MS byte, 4=duplicate labels (default 4)');
  writeln('  -b       Binary object, one contiguous block (same as -g3)');
  writeln('  -c       Object file written as one contiguous block');
  writeln('  -dname   Define a macro (-dname=value gives it a value)');
  writeln('  -e       Show source lines after macro expansion');
  writeln('  -fXX     Fill memory with byte XX (hex)');
  writeln('  -g0      Intel hex object (default)');
  writeln('  -g1      MOS Technology hex (paper tape) object, same as -m');
  writeln('  -g3      Binary object, same as -b');
  writeln('  -h       Hex table of the object code in the listing');
  writeln('  -i       Ignore case in labels');
  writeln('  -l[al]   Label table in the listing (a=all labels, l=long form)');
  writeln('  -m       MOS Technology hex (paper tape) object');
  writeln('  -oXX     Bytes per object record (hex, default 18 = 24 bytes)');
  writeln('  -p[n]    Page the listing, n lines per page (default 60)');
  writeln('  -q       Quiet: no listing file');
  writeln('  -s       Write a symbol table file');
  writeln('  -x[mask] Extended instructions: -x3 65C02, -x5 R65C00/21 MUL, -x = all');
  writeln('  -y       Time the assembly');
  writeln('Default files: src.obj, src.lst, src.exp, src.sym');
  writeln('Environment:   TASMOPTS holds default options');
end;

function hexOpt(const s, opt: string): longint;
begin
  if not allDigits(s, 16) then fatal('Invalid hex value in option: ' + opt, 4);
  hexOpt := convNum(s, 16)
end;

procedure setTable(const t, opt: string);
var u: string;
begin
  u := upstr(t);
  if (u = '65') or (u = '6502') then table65C02 := false
  else if u = '65C02' then table65C02 := true
  else fatal('Unsupported table ' + opt + ': PTASM supports only 6502/65C02 (-65)', 4)
end;

procedure parseOption(const a: string);
var c: char; rest: string; code: word; n: longint;
begin
  c := upcase(a[2]);
  rest := copy(a, 3, 255);
  if isDigit(a[2]) then setTable(copy(a, 2, 255), a)
  else
    case c of
      'T': setTable(rest, a);
      'A': if rest = '' then amask := 15 else amask := hexOpt(rest, a);
      'B': objFormat := 3;
      'C': contiguous := true;
      'D': addCmdMacro(rest);
      'E': expandOpt := true;
      'F': fillVal := hexOpt(rest, a) and $FF;
      'G': if rest = '0' then objFormat := 0
           else if rest = '1' then objFormat := 1
           else if rest = '3' then objFormat := 3
           else fatal('Invalid Object file type: ' + a + ' (use -g0 Intel hex, -g1 MOS or -g3 binary)', 4);
      'H': hexTable := true;
      'I': ignoreCase := true;
      'L': begin
             labelTable := true;
             if pos('a', rest) + pos('A', rest) > 0 then allLabels := true;
             if pos('l', rest) + pos('L', rest) > 0 then longLabels := true
           end;
      'M': objFormat := 1;
      'O': begin
             recLen := hexOpt(rest, a);
             if (recLen < 1) or (recLen > 255) then fatal('Invalid record length: ' + a, 4)
           end;
      'P': begin
             pageOpt := true;
             if rest <> '' then
             begin
               val(rest, n, code);
               if (code <> 0) or (n < 10) then fatal('Invalid page length: ' + a, 4);
               pageLen := n
             end
           end;
      'Q': quiet := true;
      'S': symOpt := true;
      'X': begin
             xSet := true;
             if rest = '' then xmask := 15 else xmask := hexOpt(rest, a)
           end;
      'Y': timing := true;
    else
      fatal('Unknown option flag: ' + a, 4)
    end
end;

procedure addCmdArg(const s: string);
begin
  if nCmdArg < MaxCmdArg then
  begin
    inc(nCmdArg);
    cmdArg[nCmdArg] := s
  end
end;

procedure parseCommandLine;
var i, j: longint; env, w: string;
begin
  nCmdArg := 0;
  env := GetEnv('TASMOPTS');
  w := '';
  for j := 1 to length(env) do
    if isSpace(env[j]) then
    begin
      if w <> '' then addCmdArg(w);
      w := ''
    end
    else w := w + env[j];
  if w <> '' then addCmdArg(w);
  for i := 1 to paramcount do addCmdArg(paramstr(i));
  nFiles := 0;
  for i := 1 to nCmdArg do
    if (length(cmdArg[i]) > 1) and (cmdArg[i][1] = '-') then parseOption(cmdArg[i])
    else if nFiles < 5 then
    begin
      inc(nFiles);
      fileArg[nFiles] := cmdArg[i]
    end
    else fatal('Too many file names: ' + cmdArg[i], 4);
  if nFiles = 0 then
  begin
    usage;
    if paramcount = 0 then halt(0) else halt(4)
  end
end;

function extFor(const src, ext: string): string;
var p, i: longint; e: string; upper, letter: boolean;
begin
  p := length(src);
  while (p > 0) and not ((src[p] = '.') or (src[p] = '/') or
                         (src[p] = '\') or (src[p] = ':')) do dec(p);
  e := '';
  if (p > 0) and (src[p] = '.') then e := copy(src, p + 1, 255);
  upper := true; letter := false;
  for i := 1 to length(e) do
    if isAlpha(e[i]) then
    begin
      letter := true;
      if (e[i] >= 'a') and (e[i] <= 'z') then upper := false
    end;
  if letter and upper then extFor := changeExt(src, upstr(ext))
  else extFor := changeExt(src, ext)
end;

{ ---------------------------------------------------------------------- }
{ main                                                                   }
{ ---------------------------------------------------------------------- }

var
  i : longint;

begin
  objFormat := 0; recLen := 24; fillVal := 0; amask := 4; xmask := 1;
  xSet := false; table65C02 := false; contiguous := false; expandOpt := false;
  hexTable := false; ignoreCase := false; labelTable := false; allLabels := false;
  longLabels := false; pageOpt := false; pageLen := 60; quiet := false;
  symOpt := false; avsym := false; timing := false; symNameSet := false;
  nsym := 0; nmac := 0; cmdMacCount := 0; lastMac := 0;
  errCount := 0; warnCount := 0; exitCode := 0; title := '';
  localChar := '_'; moduleName := ''; lstOpen := false; nLineErr := 0;
  pass := 0; errFile := ''; errLine := 0;
  for i := 0 to SymHashSz - 1 do symHash[i] := 0;
  for i := 0 to MacHashSz - 1 do macHash[i] := 0;

  parseCommandLine;
  if table65C02 and not xSet then xmask := 3;

  srcName := fixPath(fileArg[1]);
  if nFiles >= 2 then objName := fileArg[2] else objName := extFor(srcName, '.obj');
  if nFiles >= 3 then lstName := fileArg[3] else lstName := extFor(srcName, '.lst');
  if nFiles >= 4 then expName := fileArg[4] else expName := extFor(srcName, '.exp');
  if nFiles >= 5 then
  begin
    symName := fileArg[5];
    symNameSet := true
  end
  else symName := extFor(srcName, '.sym');

  writeln('PTASM 6502/65C02 Assembler. Version ', Version);
  t0 := nowSeconds;
  initOps;
  for i := 0 to 65535 do
  begin
    image[i] := fillVal;
    used[i] := false;
    forcedAbs[i] := false
  end;

  pass := 1;
  runPass;
  writeln('ptasm: pass 1 complete.');

  pass := 2;
  if not quiet then openListing;
  runPass;
  writeln('ptasm: pass 2 complete.');

  if lstOpen then
  begin
    lstOut('');
    lstOut('ptasm: Number of errors = ' + decStr(errCount));
    if labelTable then writeLabelTable;
    if hexTable then writeHexTable;
    close(lst)
  end;
  writeObject;
  if symOpt then writeSymFile;
  if nExport > 0 then writeExpFile;

  writeln('ptasm: Number of errors = ', errCount);
  if timing then writeln('ptasm: Assembly time = ', nowSeconds - t0 : 0 : 2, ' seconds');
  if exitCode = 0 then
    if errCount > 0 then exitCode := 1;
  halt(exitCode)
end.

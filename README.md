# ptasm
PTASM a portable bugfixed version of TASM32

PTASM is a two pass cross assembler for the 6502 and 65C02. It reads the same
source files and accepts the same command line as TASM32 with the 6502 table
(`tasm -65`), so existing TASM sources and build scripts keep working.

It is one small standalone program written in plain Pascal, with the 6502 and
65C02 instruction sets built in (no `TASM65.TAB` needed). It compiles with
Free Pascal and runs on Windows, Linux, macOS, the BSDs, Raspberry Pi and more.

## Building

Install Free Pascal (2.6 or later) and compile the single source file:

    fpc ptasm.pas

or open `ptasm.lpi` in Lazarus and build it as a simple program
(this uses `ptasm.lpr`, the same source with the licence header and
the Windows resource file `ptasm.res`).

## Usage

    ptasm -65 [-options ...] src_file [obj_file [lst_file [exp_file [sym_file]]]]

Run without arguments for a summary of the options.
```
PTASM 6502/65C02 Assembler. Version 1.0
Usage: ptasm -65 [-options ...] src_file [obj_file [lst_file [exp_file [sym_file]]]]
Options:
  -65      6502 instruction set (default). -t65c02 = -65 -x3
  -a[mask] Assembly checks: 2=unused data in MS byte, 4=duplicate labels (default 4)
  -c       Object file written as one contiguous block
  -dname   Define a macro (-dname=value gives it a value)
  -e       Show source lines after macro expansion
  -fXX     Fill memory with byte XX (hex)
  -g0      Intel hex object (default)
  -g1      MOS Technology hex (paper tape) object, same as -m
  -h       Hex table of the object code in the listing
  -i       Ignore case in labels
  -l[al]   Label table in the listing (a=all labels, l=long form)
  -m       MOS Technology hex (paper tape) object
  -oXX     Bytes per object record (hex, default 18 = 24 bytes)
  -p[n]    Page the listing, n lines per page (default 60)
  -q       Quiet: no listing file
  -s       Write a symbol table file
  -x[mask] Extended instructions: -x3 65C02, -x5 R65C00/21 MUL, -x = all
  -y       Time the assembly
Default files: src.obj, src.lst, src.exp, src.sym
Environment:   TASMOPTS holds default options
```
## Main differences from TASM32

- `<` and `>` low/high byte operators (`LDA #<TABLE`, `LDA #>TABLE`).
- MOS paper tape end record with record count and checksum (`;00nnnncccc`).
- No "Label value misaligned" zero page phase errors on forward references.
- `;` inside character constants and strings, and `\` in comments, handled correctly.
- Directives accepted with or without the leading dot.

See the full manual for details and the list of unsupported TASM32 features.

## Files

| File | Contents |
|------|----------|
| `ptasm.exe` | Ready-built Windows (x86-64) executable |
| `ptasm.pas` | Source code (build with `fpc`) |
| `ptasm.lpr`, `ptasm.lpi`, `ptasm.res` | Lazarus project: source, project file, resources |
| `ptasm.txt` | User manual (text) |
| `ptasm.htm` | User manual (HTML) |
| `ptest.asm` | Test source (contains a deliberate error line) |
| `ptest.lst`, `ptest.obj`, `ptest.ihex`, `ptest.ee`, `ptest.sym` | Output from assembling `ptest.asm` |

## License

MIT, see [LICENSE](LICENSE).

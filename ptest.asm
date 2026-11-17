; PTASM feature test
; Assemble:  ptasm -65 -x3 -m ptest.asm      (MOS paper tape)
;            ptasm -65 -x3 ptest.asm         (Intel hex)
;
; Expected ptest.obj with -m:
;   ;120200A910A203A90385108DF000641080FEB210600744
;   ;0703103412341241420A0133
;   ;0000020002
; Expected ptest.obj without -m:
;   :12020000A910A203A90385108DF000641080FEB21060BC
;   :070310003412341241420ACD
;   :00000001FF
een foutje
#define VAL     $1234

zp      .equ    $10

        .org    $0200
start   lda     #<table         ; A9 10   low byte
        ldx     #>table         ; A2 03   high byte
        lda     #>table+1       ; A9 03   high byte of (table+1)
        sta     zp              ; 85 10   zero page
        sta     fwd             ; 8D F0 00 forward reference stays absolute
        stz     zp              ; 64 10   65C02
        bra     *               ; 80 FE   65C02
        lda     (zp)            ; B2 10   65C02 (zp) indirect
        rts                     ; 60

fwd     .equ    $F0

        .org    $0310
table   .byte   <VAL, >VAL      ; 34 12
        .word   VAL             ; 34 12
        .text   "AB\n"          ; 41 42 0A
		.byte   ';'
        .end

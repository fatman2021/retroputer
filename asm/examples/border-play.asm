.segment code 0x02000 {
    ld al, 100
    out 0x2B, al
    ld al, 2
    out 0x2A, al
    ld al, 0
top:
    ld x, 49152
    ld bl, 0xff
    ld dl, 0
    do {
        st [0x10000,x], al
        inc al
        mov bl, al
        or bl, 0b10100100
        out 0x2B, bl
        dec x
    } while !c
    br top
    brk
}

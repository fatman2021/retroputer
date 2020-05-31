########################################
#
# Retroputer Kernel : BASIC : Core
#
########################################

.namespace basic {
    .import "./constants.asm"

    .segment brodata kmemmap.basic.rodata-start .append {

###############################################################################
#
# Welcome message and prompt
#
###############################################################################
        welcome:
            .string constants.CLS
            .string 0x1B, "17", 0x12, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, constants.CR
            .string 0x1B, "18", 0x12, 0xDB, 0xE3, 0xDC, 0xE8, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0x1B, "255", 0x12, "  RETROPUTER BASIC 1.0"
            .string 0x1B, "19", 0x12, 0xDB, 0xDE, 0xDB, 0xDE, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0x1B, "255", 0x12, "   --------------------"
            .string 0x1B, "20", 0x12, 0xDB, 0xE3, 0xDC, 0xE8, 0xDB, 0xDB, 0xDB, 0xDB, 0x1B, "255", 0x12, constants.CR
            .string 0x1B, "21", 0x12, 0xDB, 0xDE, 0xDB, 0xDD, 0xDB, 0xDB, 0xDB, 0x1B, "255", 0x12, "   131072 Code Bytes Free"
            .string 0x1B, "22", 0x12, 0xDB, 0xDE, 0xDB, 0xDD, 0xDB, 0xDB, 0x1B, "255", 0x12, "     65536 Heap Bytes Free"
            .string 0x1B, "23", 0x12, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0x1B, "255", 0x12, constants.CR, constants.CR, constants.NUL
        prompt:
            .string "READY."
        newline:
            .byte constants.CR, constants.NUL
    }

    .import "./errors.asm"
    .import "./tokens.asm"
    
###############################################################################
#
# Global BASIC State
#
###############################################################################
    .segment bdata kmemmap.basic.data-start .append {
        buffer:              .byte[256]         # (0x100) input buffer
        crunch-buffer:       .byte[256]         # (0x100) line crunch buffer
        forsub-stack:        .word[256]         # (0x200) stack for FOR/GOSUB/CALL. 128 4-byte entries
                                                #         31:30 = type (0=FOR, 1=GOSUB, 2=CALL) 
                                                #         29:16 = variable (for FOR)
                                                #         15:0  = line number to return to
        expr-area:           .byte[256]         # (0x100) Area for evaluating expressions

        # 0x300 bytes remaining for non-array data
        forsub-stack-ptr:    .byte 0            # pointer into forsub stack
        execution-mode:      .byte 0            # are we (1)running or (0)entering code? 
        current-line-number: .word 0            # current line number of execution (or entry)
        current-line-ptr:
        current-line-bptr:   .word 0            # will point to the program bank
        current-line-aptr:   .word 0            # pointer to current program line
        
        heap-next-free:      .word 0            # pointer to next free area in heap
        prog-next-free:      .word 0            # pointer to next free area in program storage 

        accumulator-token:   .byte 0            # current accumulator type
        accumulator:         .word 0, 0, 0, 0   # current accumulator value (or ptr, if string)

        operand-token:       .byte 0            # second operand type
        operand:             .word 0, 0, 0, 0   # value of second operand

        itoa-buffer:         .byte[32]          # buffer for int-to-string ops


        # some self-modifying code lives here too :-/
        _self-mod:
        _in-port: {
            [_in-instr+2] := cl 
            c := 0
        _in-instr:
            in cl, 0
            ret
        }

        _out-port: {
            [_out-instr+2] := cl 
        _out-instr:
            out 0, cl
            ret
        }
    }

###############################################################################
#
# BASIC Logic
#
###############################################################################
    .segment bcode kmemmap.basic.code-start .append {
        start: {
            call patch                           # make sure self-modifying code is in place
            call init                            # Say hello
            call repl                            # Enter the REPL
            brk
        }

        .import "./utils.asm"
        .import "./tokenizer.asm"
        .import "./parser.asm"

        .import "./handlers/common.asm"
        .import "./handlers/op.asm"
        .import "./handlers/fn.asm"
        .import "./handlers/stmt.asm"

        .import "./eval.asm"
        .import "./exec.asm"

        patch: {
            # some of our requirements involve self-modifying code. That's done
            # in our data segment. Since that won't be initialized, we need to
            # write some code there.
            x := 20                             # total self modifying code
            do {
                dl := [_copy, x]                # read one of our bytes
                [bdata._self-mod, x] := dl      # and put it in data segment
                dec x
            } while !c
            ret
        _copy:
            .byte 0x25, 0x40                    # [_in-instr+2] := cl
            .word bdata._in-port+10
            .byte 0x14, 0x00, 0x00, 0x00        # c := 0
            .byte 0x30, 0x50, 0x00              # in cl, 0
            .byte 0xa7                          # ret
            .byte 0x25, 0x40                    # [_out-instr+2] := cl
            .word bdata._out-port+6 
            .byte 0x31, 0x50, 0x00              # out 0, cl
            .byte 0xa7                          # ret
        }

        #
        # Hi!
        #
        #######################################################################
        init: {
            d := brodata.welcome >> 3
            x := brodata.welcome & 7
            call [vectors.PRINT]
            call new
            ret
        }


        ########################################################################
        # Resets BASIC's internal state so that a new program can be entered.
        ########################################################################
        new: {
        _main:
            d := 0
            [bdata.forsub-stack-ptr] := d       # forsub stack pointer is reset
            [bdata.current-line-number] := d    # current line number is zero
            d := 1
            [bdata.heap-next-free] := d         # heap starts at 1 (so we avoid NUL)
            [bdata.prog-next-free] := d         # program code starts at 1
            LDPTR(d, x, kmemmap.basic.prog-start)
            [bdata.current-line-bptr] := d      # not pointing anywhere either
            [bdata.current-line-aptr] := x      # not pointing anywhere either
            d := constants.MODE_DIRECT
            [bdata.execution-mode] := d         # direct mode (not running)

            # Initialize variables
            al := 0
            d := 0
            x := kmemmap.basic.vars-start
            y := kmemmap.basic.vars-length
            do {
                dec y
                [d, x, y] := al                 # clear memory
            } while !z

            # initialize line number pointers
            LDPTR(d, x, kmemmap.basic.lptr-start)
            y := kmemmap.basic.lptr-size        # (technically zero)
            do {
                dec y
                [d, x, y] := al                 # clear memory
            } while !z

        _out:
            ret
        }


        #
        # getvar looks up a variable and stores the value into the accumulator
        # note: this only works while parsing a line (having already eaten the
        # TOK_VARIABLE token)
        #
        #######################################################################
        getvar: {
            push d
            push c
            push x
            push b
            push y
        _main:
            # [c,d] = [type, index]
            call gettok-word                    # get variable index & type
            c := d
            and c, 0b1100_0000_0000_0000        # just want the type
            shr c, 14                           # in the lower bits
            and d, 0b0011_1111_1111_1111        # for index, we don't want the type

            # advance parser past variable name
            call gettok                         # next byte is the length of the variable name
            x := [bdata.current-line-aptr]
            clr c
            add x, dl                           # x += variable length
            [bdata.current-line-aptr] := x      # and store it back

            # index our variable correctly
            x := d                              # use x so we can index in a bit
            cmp c, 0
            if z {                              # we're a word
                dl := brodata.TOK_WORD
                b := [kmemmap.basic.ints-start, x]
                brs _write-to-accumulator       # break
            }

            cmp c, 1
            if z {
                dl := brodata.TOK_STRING        # we're a string!
                b := [kmemmap.basic.strs-start, x]
                brs _write-to-accumulator       # break
            }

            cmp c, 2
            if z {
                dl := brodata.TOK_REAL          # we're a real!
                shl x, 2                        # multiply by eight instead (64 bits)
                b := [kmemmap.basic.dbls-start, x]
                brs _write-to-accumulator       # break
            }

            # @todo: handle array bits!

            brs _write-to-accumulator

        _write-real-to-accumulator:
                [bdata.accumulator-token] := dl
                [bdata.accumulator] := b        # write variable into accumulator
                inc x
                inc x
                y := 2
                b := [kmemmap.basic.dbls-start, x]
                [bdata.accumulator, y] := b
                inc x
                inc x
                y := 4
                b := [kmemmap.basic.dbls-start, x]
                [bdata.accumulator, y] := b
                inc x
                inc x 
                y := 6
                b := [kmemmap.basic.dbls-start, x]
                [bdata.accumulator, y] := b
                brs _out

        _write-to-accumulator:
                [bdata.accumulator-token] := dl
                [bdata.accumulator] := b        # write variable into accumulator

        _out:
            pop y
            pop b
            pop x
            pop c
            pop d
            ret
        }

        #
        # The REPL is responsible for:
        # 
        # 1. Print prompt, and take input (via vectors.INPUT)
        # 2. Crunching the line
        # 3a. If there's a line number, add it to program memory
        # 3b. If there's no line number, execute it immediately
        # 4. If an error has occurred, print it.
        # 5. Go back to 1.
        #
        #######################################################################
        repl: {
        _loop:
        _ready:

            #
            # STEP 1
            #
            d := brodata.prompt >> 3
            x := brodata.prompt & 7
            call [vectors.PRINT]                 # READY.

        _get-line:
            d := bdata.buffer >> 3
            x := bdata.buffer & 7
            c := 255
            call [vectors.INPUT]                 # Get input from user

            d := brodata.newline >> 3
            x := brodata.newline & 7
            call [vectors.PRINT]                 # NEWLINE, to be neat

            # Is the line too long, or no line at all?
            cmp c, 0x00
            if z {
                # no line; go again, but no prompt
                br _get-line
            }
            if n {
                # yup; too long
                c := 0
                dl := brodata.LINE_TOO_LONG_ERROR
                call print-error

                # try again.
                br _ready
            }


            #
            # STEP 2: Crunch
            #

            # 2a. UPPERCASE anything that's not a string; this is important
            #     to ensure that we can properly crunch later.
            d := bdata.buffer >> 3
            x := bdata.buffer & 7
            call convert-to-uppercase

            cmp dl, 0
            if !z {
                # we've got an error -- likely a quote mismatch
                c := 0
                call print-error
                br _ready
            }

            #
            # 2b. Find the first non-space character. (trimming the front)
            #     We do this so we can ensure that you can have spaces before a
            #     line number and not have it fall into direct mode.
            d := bdata.buffer >> 3
            x := bdata.buffer & 7
            y := 0
            do {
                al := [d, x, y]
                inc y
                cmp al, 32
            } while z
            dec y

            #
            # 2c. Now we can start crunching the line. There's some things we want
            #     to do:
            #     - convert integers into packed forms so that we don't have
            #       to re-parse them later
            #     - convert tokens into packed forms for easier parsing
            #     - strip extra spaces 

            d := bdata.buffer >> 3
            x := bdata.buffer & 7
            push x                              # BP+10
            push d                              # BP+8
            d := bdata.crunch-buffer >> 3
            x := bdata.crunch-buffer & 7
            push x                              # BP+6
            push d                              # BP+4
            call crunch-line
            cmp dl, 0
            br !z _display-errors               # sometimes crunching will render an error
            exc d
            bl := dl                            # save length of crunch
            exc d
            a := 8
            clr c                               # make sure carry is clear
            add sp, a                           # clean up our stack

            #
            # STEP 3: Store / execute
            #
            LDPTR(d, x, bdata.crunch-buffer)
            al := [d, x]                        # check the first byte of our crunch
            cmp al, brodata.TOK_BYTE            # if it's a byte
            brs z _store                        # ... store the line!
            cmp al, brodata.TOK_WORD            # or if it's a word 
            brs z _store                        # ... store the line

        _eval:
            # @todo write this bit!
            cl := 0
            [bdata.execution-mode] := cl        # 0 = direct
            c := 0xFFFF
            [bdata.current-line-number] := c    # When executing direct, the current line number is always -1
            [bdata.current-line-bptr] := d
            [bdata.current-line-aptr] := x      
            call exec                           # eval uses the above setup to execute code
            brs _display-errors                 # make sure we show any error messages

        _store:
            c := 0                              # "c" will be the current line number
            cmp al, brodata.TOK_BYTE            # how much do we read in?
            if z {
                inc x                           # skip past the token
                dec bl                          # reduce # of chars to copy
                cl := [d, x]                    # only want one byte
                inc x                           # and don't want to copy this one, either
                dec bl                          # reduce # of chars to copy
            } else {
                inc x                           # skip past the token
                dec bl                          # reduce # of chars to copy
                c := [d, x]                     # this one's a word
                inc x
                dec bl                          # reduce # of chars to copy
                inc x
                dec bl                          # reduce # of chars to copy
            }

            # @todo handle DELETING lines instead (bl is 0)

            [bdata.current-line-number] := c
            a := [bdata.prog-next-free]         # get next free address so we can write to it
            [bdata.current-line-aptr] := a

            # move the heap along
            a := [bdata.prog-next-free]
            clr c
            add a, bl
            [bdata.prog-next-free] := a

            # d,x is now at the portion where we can copy to the correct location
            # and bl has the number of crunched characters to copy (plus 1)
            y := bl
            dec y
            do {
                al := [d, x, y]                     # get byte
                <bdata.current-line-bptr>, y := al  # and write 
                dec y
            } while !c

            # write the address to our line # pointer 
            LDPTR(d, x, kmemmap.basic.lptr-start)
            shl c, 1                            # multiply by two, since it's now becoming a pointer
            clr c                               # don't forget to clear carry
            y := c                              # move ahead the right amount
            b := [bdata.current-line-aptr]
            [d, x, y] := b                      # write our pointer
            br _get-line


        _display-errors:
            #
            # STEP 4: Display errors
            #
            c := 0
            cmp dl, 0
            if !z {
                call print-error
            }

            #
            # STEP 5: Do it again
            #
            br _ready
            ret
        }
    }
}
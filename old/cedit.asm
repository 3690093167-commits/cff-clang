;============================================================
; cedit.asm - CF Language Line Editor for Windows x64
; Build: nasm -f bin cedit.asm -o cedit.exe
; Commands:
;   N        new buffer
;   L <file> load file
;   P        print buffer (numbered)
;   E <n>    edit line n (replace)
;   I <n>    insert line after n
;   D <n>    delete line n
;   S        save to file
;   Q        quit
;============================================================

%define IMAGE_BASE 0x140000000

; ---------- PE header ----------
section .hdr start=0 vstart=0
dos:
    db 'M','Z'
    times 0x3a db 0
    dd pe_sig - dos
pe_sig:
    db 'P','E',0,0
coff:
    dw 0x8664
    dw 3
    dd 0
    dd 0
    dd 0
    dw 0xF0
    dw 0x0022
opthdr:
    dw 0x20B
    db 0,0
    dd text_file_size
    dd idata_file_size + data_file_size
    dd 0
    dd entry - IMAGE_BASE
    dd text_start - IMAGE_BASE
    dq IMAGE_BASE
    dd 0x1000
    dd 0x200
    dw 6,0
    dw 0,0
    dw 6,0
    dd 0
    dd (data_vsize + 0x3000 + 0xFFF) & ~0xFFF
    dd 0x200
    dd 0
    dw 3
    dw 0
    dq 0x100000
    dq 0x1000
    dq 0x100000
    dq 0x1000
    dd 0
    dd 16
    dd 0,0
    dd 0x2000, idata_vsize
    times 14*8 db 0
sectab:
    db '.','t','e','x','t',0,0,0
    dd text_vsize
    dd 0x1000
    dd text_file_size
    dd 0x200
    dd 0,0
    dw 0,0
    dd 0x60000020
    db '.','i','d','a','t','a',0,0
    dd idata_vsize
    dd 0x2000
    dd idata_file_size
    dd idata_off
    dd 0,0
    dw 0,0
    dd 0xC0000040
    db '.','d','a','t','a',0,0,0
    dd data_vsize
    dd 0x3000
    dd data_file_size
    dd data_off
    dd 0,0
    dw 0,0
    dd 0xC0000040
    times (0x200 - ($ - dos)) db 0

; ---------- text section ----------
section .text start=0x200 vstart=(IMAGE_BASE + 0x1000)
bits 64
text_start:
entry:
    sub rsp, 0x58
    mov ecx, -11
    call [rel iat_GetStdHandle]
    mov [rel hOut], rax
    mov ecx, -10
    call [rel iat_GetStdHandle]
    mov [rel hIn], rax

    lea rdi, [rel msg_banner]
    call print_cstr
    lea rdi, [rel msg_help]
    call print_cstr

.main:
    lea rdi, [rel msg_prompt]
    call print_cstr
    call read_line            ; inbuf, rax = len
    test rax, rax
    jz .main
    lea rsi, [rel inbuf]
    movzx eax, byte [rsi]
    cmp eax, 'N'
    je .cmd_new
    cmp eax, 'L'
    je .cmd_load
    cmp eax, 'P'
    je .cmd_print
    cmp eax, 'E'
    je .cmd_edit
    cmp eax, 'I'
    je .cmd_ins
    cmp eax, 'D'
    je .cmd_del
    cmp eax, 'S'
    je .cmd_save
    cmp eax, 'Q'
    je .quit
    lea rdi, [rel msg_bad]
    call print_cstr
    jmp .main

.cmd_new:
    call buf_clear
    lea rdi, [rel msg_ok_new]
    call print_cstr
    jmp .main

.cmd_load:
    call parse_rest          ; rsi -> rest (filename)
    test rsi, rsi
    jz .main
    call load_file
    jmp .main

.cmd_print:
    call print_lines
    jmp .main

.cmd_edit:
    call parse_num_rest      ; rax = line number, rsi -> rest
    test rax, rax
    jz .main
    dec rax
    mov [rel edit_idx], rax
    lea rdi, [rel msg_newline]
    call print_cstr
    call read_line
    test rax, rax
    jz .main
    mov rcx, [rel edit_idx]
    lea rdx, [rel inbuf]
    mov r8, rax
    call replace_line
    jmp .main

.cmd_ins:
    call parse_num_rest
    test rax, rax
    jz .main
    dec rax
    mov [rel edit_idx], rax
    lea rdi, [rel msg_newline]
    call print_cstr
    call read_line
    test rax, rax
    jz .main
    mov rcx, [rel edit_idx]
    lea rdx, [rel inbuf]
    mov r8, rax
    call insert_line
    jmp .main

.cmd_del:
    call parse_num_rest
    test rax, rax
    jz .main
    dec rax
    mov rcx, rax
    call delete_line
    jmp .main

.cmd_save:
    call save_file
    jmp .main

.quit:
    xor ecx, ecx
    call [rel iat_ExitProcess]

; ---------- line input ----------
; read_line: reads one line into inbuf (max 255), returns rax = len (0 = empty/EOF)
read_line:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 0x38
    xor r12d, r12d            ; count
.rl:
    mov rcx, [rel hIn]
    lea rdx, [rel in_char]
    mov r8d, 1
    lea r9, [rsp+0x28]
    mov qword [rsp+0x20], 0
    call [rel iat_ReadFile]
    test rax, rax
    jz .rl_done               ; EOF
    movzx eax, byte [rel in_char]
    cmp eax, 13
    je .rl_cr
    cmp eax, 10
    je .rl_done
    cmp r12, 255
    jae .rl                  ; drop overflow
    lea rdi, [rel inbuf]
    add rdi, r12
    mov byte [rdi], al
    ; echo
    mov rcx, [rel hOut]
    lea rdx, [rel in_char]
    mov r8d, 1
    lea r9, [rsp+0x28]
    mov qword [rsp+0x20], 0
    call [rel iat_WriteFile]
    inc r12
    jmp .rl
.rl_cr:
    call read_line_drain      ; consume until LF
    jmp .rl_done
.rl_done:
    lea rdi, [rel inbuf]
    add rdi, r12
    mov byte [rdi], 0
    mov rax, r12
    add rsp, 0x38
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; read_line_drain: consume chars until LF or EOF
read_line_drain:
    push rbx
    push r14
    sub rsp, 0x38
.rd:
    mov rcx, [rel hIn]
    lea rdx, [rel in_char]
    mov r8d, 1
    lea r9, [rsp+0x28]
    mov qword [rsp+0x20], 0
    call [rel iat_ReadFile]
    test rax, rax
    jz .rd_done
    movzx eax, byte [rel in_char]
    cmp eax, 10
    je .rd_done
    jmp .rd
.rd_done:
    add rsp, 0x38
    pop r14
    pop rbx
    ret

; ---------- parsing ----------
; parse_rest: rsi points past command char; skip spaces, rax=0 -> no rest, else rsi -> rest
parse_rest:
    lea rsi, [rel inbuf]
    inc rsi
.skip:
    movzx eax, byte [rsi]
    cmp eax, ' '
    je .sp
    cmp eax, 9
    je .sp
    cmp eax, 0
    je .none
    ret
.sp:
    inc rsi
    jmp .skip
.none:
    xor esi, esi
    ret

; parse_num_rest: parse decimal at rest -> rax, rsi -> after number; 0 if none
parse_num_rest:
    push rbx
    call parse_rest
    test rsi, rsi
    jz .fail
    xor ebx, ebx
.pn:
    movzx eax, byte [rsi]
    cmp eax, '0'
    jb .done
    cmp eax, '9'
    ja .done
    sub eax, '0'
    imul rbx, rbx, 10
    add rbx, rax
    inc rsi
    jmp .pn
.done:
    mov rax, rbx
    pop rbx
    ret
.fail:
    xor eax, eax
    pop rbx
    ret

; ---------- buffer management ----------
; buf_clear: reset buffer + line table
buf_clear:
    mov qword [rel line_cnt], 0
    mov qword [rel buf_len], 0
    ret

; split_lines: rebuild line table from buf (CRLF or LF separated)
split_lines:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 0x38
    xor r12d, r12d            ; line count
    lea r13, [rel buf]
    lea r14, [rel buf]
    add r14, [rel buf_len]
    lea rbx, [rel line_off]
.sl:
    cmp r13, r14
    jae .sl_done
    mov rax, r13
    lea rdx, [rel buf]
    sub rax, rdx
    mov [rbx], rax
    add rbx, 8
    inc r12
    ; find end of line
.sl2:
    cmp r13, r14
    jae .sl_done
    movzx eax, byte [r13]
    cmp eax, 10
    je .sl_nl
    inc r13
    jmp .sl2
.sl_nl:
    inc r13
    cmp r13, r14
    jae .sl_done
    movzx eax, byte [r13]
    cmp eax, 13
    jne .sl
    inc r13
    jmp .sl
.sl_done:
    mov [rel line_cnt], r12
    add rsp, 0x38
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; print_lines: show numbered lines
print_lines:
    push rbx
    push r12
    push r13
    sub rsp, 0x38
    xor r12d, r12d
    mov r13, [rel line_cnt]
.pl:
    cmp r12, r13
    jae .pl_done
    ; print number
    mov rax, r12
    inc rax
    call print_num
    lea rdi, [rel c_colon]
    call print_cstr
    ; print line bytes until LF
    lea rdi, [rel line_off]
    mov rbx, [rdi+r12*8]
    lea rdi, [rel buf]
    add rdi, rbx
.pl2:
    movzx eax, byte [rdi]
    cmp eax, 10
    je .pl_nl
    cmp eax, 0
    je .pl_nl
    ; write one char
    mov [rel out_char], al
    mov rcx, [rel hOut]
    lea rdx, [rel out_char]
    mov r8d, 1
    lea r9, [rsp+0x28]
    mov qword [rsp+0x20], 0
    call [rel iat_WriteFile]
    inc rdi
    jmp .pl2
.pl_nl:
    lea rdi, [rel c_nl]
    call print_cstr
    inc r12
    jmp .pl
.pl_done:
    add rsp, 0x38
    pop r13
    pop r12
    pop rbx
    ret

; ---------- line operations (rebuild model) ----------
; replace_line: rcx = idx, rdx = text, r8 = len
replace_line:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 0x38
    mov r12, rcx
    mov r13, rdx
    mov r14, r8
    ; build new buf in tmpbuf
    lea r15, [rel tmpbuf]
    xor ebx, ebx              ; src line index
    xor r8d, r8d              ; written
.rp:
    cmp rbx, [rel line_cnt]
    jae .rp_done
    cmp rbx, r12
    je .rp_skip_src
    ; copy line rbx from buf
    lea rdi, [rel line_off]
    mov rax, rbx
    imul rax, rax, 8
    add rdi, rax
    mov rax, [rdi]
    lea rdi, [rel buf]
    add rdi, rax
    push rbx
    push rdi
    call line_len             ; rax = len until LF/end
    mov rcx, r15
    add rcx, r8
    mov rdx, rax
    pop rsi
    call mem_copy
    add r8, rax
    ; CRLF
    lea rdi, [rel c_crlf]
    call str_len
    push r8
    mov rcx, r15
    add rcx, r8
    mov rsi, rdi
    mov rdx, rax
    call mem_copy
    pop r8
    add r8, rax
    pop rbx
    jmp .rp_next
.rp_skip_src:
    ; copy replacement text + CRLF
    mov rcx, r15
    add rcx, r8
    mov rsi, r13
    mov rdx, r14
    call mem_copy
    add r8, r14
    lea rdi, [rel c_crlf]
    call str_len
    mov rcx, r15
    add rcx, r8
    mov rsi, rdi
    mov rdx, rax
    call mem_copy
    add r8, rax
.rp_next:
    inc rbx
    jmp .rp
.rp_done:
    ; copy tmpbuf -> buf
    mov [rel buf_len], r8
    lea rcx, [rel buf]
    lea rsi, [rel tmpbuf]
    mov rdx, r8
    call mem_copy
    call split_lines
    add rsp, 0x38
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; insert_line: rcx = idx (insert after this line), rdx = text, r8 = len
insert_line:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 0x38
    mov r12, rcx
    ; clamp: if idx >= line_cnt, insert after last line
    mov rax, [rel line_cnt]
    cmp r12, rax
    jb .il_noclamp
    dec rax
    mov r12, rax
.il_noclamp:
    mov r13, rdx
    mov r14, r8
    lea r15, [rel tmpbuf]
    xor ebx, ebx
    xor r8d, r8d
.il:
    cmp rbx, [rel line_cnt]
    jae .il_done
    ; copy line rbx
    lea rdi, [rel line_off]
    mov rax, rbx
    imul rax, rax, 8
    add rdi, rax
    mov rax, [rdi]
    lea rdi, [rel buf]
    add rdi, rax
    push rbx
    push rdi
    call line_len
    mov rcx, r15
    add rcx, r8
    mov rdx, rax
    pop rsi
    call mem_copy
    add r8, rax
    lea rdi, [rel c_crlf]
    call str_len
    mov rcx, r15
    add rcx, r8
    mov rsi, rdi
    mov rdx, rax
    call mem_copy
    add r8, rax
    pop rbx
    cmp rbx, r12
    jne .il_next
    ; insert text after this line
    mov rcx, r15
    add rcx, r8
    mov rsi, r13
    mov rdx, r14
    call mem_copy
    add r8, r14
    lea rdi, [rel c_crlf]
    call str_len
    mov rcx, r15
    add rcx, r8
    mov rsi, rdi
    mov rdx, rax
    call mem_copy
    add r8, rax
.il_next:
    inc rbx
    jmp .il
.il_done:
    mov [rel buf_len], r8
    lea rcx, [rel buf]
    lea rsi, [rel tmpbuf]
    mov rdx, r8
    call mem_copy
    call split_lines
    add rsp, 0x38
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; delete_line: rcx = idx
delete_line:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 0x38
    mov r12, rcx
    lea r15, [rel tmpbuf]
    xor ebx, ebx
    xor r8d, r8d
.dl:
    cmp rbx, [rel line_cnt]
    jae .dl_done
    cmp rbx, r12
    je .dl_skip
    lea rdi, [rel line_off]
    mov rax, rbx
    imul rax, rax, 8
    add rdi, rax
    mov rax, [rdi]
    lea rdi, [rel buf]
    add rdi, rax
    push rdi
    call line_len
    mov rcx, r15
    add rcx, r8
    mov rdx, rax
    pop rsi
    call mem_copy
    add r8, rax
    lea rdi, [rel c_crlf]
    call str_len
    mov rcx, r15
    add rcx, r8
    mov rsi, rdi
    mov rdx, rax
    call mem_copy
    add r8, rax
.dl_skip:
    inc rbx
    jmp .dl
.dl_done:
    mov [rel buf_len], r8
    lea rcx, [rel buf]
    lea rsi, [rel tmpbuf]
    mov rdx, r8
    call mem_copy
    call split_lines
    add rsp, 0x38
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; line_len: rdi -> start, returns rax = len until LF or end of buf
line_len:
    mov rax, rdi
    lea rcx, [rel buf]
    add rcx, [rel buf_len]
.ll:
    cmp rax, rcx
    jae .ll_done
    cmp byte [rax], 10
    je .ll_done
    cmp byte [rax], 13
    je .ll_done
    inc rax
    jmp .ll
.ll_done:
    sub rax, rdi
    ret

; mem_copy: rcx = dst, rsi = src, rdx = len
mem_copy:
    test rdx, rdx
    jz .mc_done
    push rcx
    push rsi
    push rdx
    push r10
.mc:
    mov r10b, [rsi]
    mov [rcx], r10b
    inc rcx
    inc rsi
    dec rdx
    jnz .mc
    pop r10
    pop rdx
    pop rsi
    pop rcx
.mc_done:
    ret

; ---------- file IO ----------
; load_file: rsi = filename -> read into buf
load_file:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 0x38
    mov rbx, rsi
    ; open
    mov rcx, rbx
    mov edx, 0x80000000       ; GENERIC_READ
    xor r8d, r8d              ; share 0
    xor r9d, r9d              ; security NULL
    mov qword [rsp+0x20], 3   ; OPEN_EXISTING
    mov qword [rsp+0x28], 0x80 ; FILE_ATTRIBUTE_NORMAL
    mov qword [rsp+0x30], 0   ; template
    call [rel iat_CreateFileA]
    cmp rax, -1
    je .lf_fail
    mov r12, rax
    ; size
    mov rcx, rax
    lea rdx, [rel file_hi]
    call [rel iat_GetFileSize]
    mov r13, rax
    cmp rax, 262144
    ja .lf_big
    ; read
    mov rcx, r12
    lea rdx, [rel buf]
    mov r8, r13
    lea r9, [rel bytes_read]
    mov qword [rsp+0x20], 0
    call [rel iat_ReadFile]
    ; close
    mov rcx, r12
    call [rel iat_CloseHandle]
    mov [rel buf_len], r13
    lea rcx, [rel buf]
    add rcx, r13
    mov byte [rcx], 0
    call split_lines
    lea rdi, [rel msg_loaded]
    call print_cstr
    mov rax, [rel line_cnt]
    call print_num
    lea rdi, [rel msg_lines]
    call print_cstr
    jmp .lf_done
.lf_fail:
    lea rdi, [rel msg_open_fail]
    call print_cstr
    jmp .lf_done
.lf_big:
    mov rcx, r12
    call [rel iat_CloseHandle]
    lea rdi, [rel msg_big]
    call print_cstr
.lf_done:
    add rsp, 0x38
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; save_file: write buf to filename in inbuf (rest)
save_file:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 0x38
    call parse_rest
    test rsi, rsi
    jz .sf_none
    mov rbx, rsi
    ; create
    mov rcx, rbx
    mov edx, 0x40000000       ; GENERIC_WRITE
    xor r8d, r8d              ; share 0
    xor r9d, r9d              ; security NULL
    mov qword [rsp+0x20], 2   ; CREATE_ALWAYS
    mov qword [rsp+0x28], 0x80 ; FILE_ATTRIBUTE_NORMAL
    mov qword [rsp+0x30], 0   ; template
    call [rel iat_CreateFileA]
    cmp rax, -1
    je .sf_fail
    mov r12, rax
    mov r13, [rel buf_len]
    mov rcx, r12
    lea rdx, [rel buf]
    mov r8, r13
    lea r9, [rel bytes_written]
    mov qword [rsp+0x20], 0
    call [rel iat_WriteFile]
    mov rcx, r12
    call [rel iat_CloseHandle]
    lea rdi, [rel msg_saved]
    call print_cstr
    mov rax, r13
    call print_num
    lea rdi, [rel msg_bytes]
    call print_cstr
    jmp .sf_done
.sf_none:
    lea rdi, [rel msg_save_usage]
    call print_cstr
    jmp .sf_done
.sf_fail:
    lea rdi, [rel msg_open_fail]
    call print_cstr
.sf_done:
    add rsp, 0x38
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---------- output ----------
; print_cstr: rdi = nul-terminated
print_cstr:
    push rdi
    push rsi
    push rbx
    sub rsp, 0x38
    xor esi, esi
.pc:
    cmp byte [rdi+rsi], 0
    je .pc_go
    inc rsi
    jmp .pc
.pc_go:
    mov rbx, rsi
    mov rcx, [rel hOut]
    mov rdx, rdi
    mov r8, rbx
    lea r9, [rsp+0x28]
    mov qword [rsp+0x20], 0
    call [rel iat_WriteFile]
    add rsp, 0x38
    pop rbx
    pop rsi
    pop rdi
    ret

; str_len: rdi -> returns rax = len
str_len:
    xor eax, eax
.sl:
    cmp byte [rdi+rax], 0
    je .sl_done
    inc rax
    jmp .sl
.sl_done:
    ret

; print_num: rax = value -> decimal to stdout
print_num:
    push rbx
    push rdi
    push rsi
    sub rsp, 0x38
    lea rdi, [rel numbuf+31]
    mov byte [rdi], 0
    mov rbx, 10
.pn:
    xor edx, edx
    div rbx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .pn
    mov rsi, rdi
    lea rdi, [rel numbuf+31]
    sub rdi, rsi
    mov rdx, rsi
    mov rcx, [rel hOut]
    mov r8, rdi
    lea r9, [rsp+0x28]
    mov qword [rsp+0x20], 0
    call [rel iat_WriteFile]
    add rsp, 0x38
    pop rsi
    pop rdi
    pop rbx
    ret

text_vsize equ ($ - text_start)
    align 0x200, db 0
text_file_size equ ($ - text_start)

; ---------- idata ----------
idata_off equ (0x200 + text_file_size + 0x1FF) & ~0x1FF
section .idata start=idata_off vstart=(IMAGE_BASE + 0x2000)
idata_start:
    dd oft - IMAGE_BASE
    dd 0
    dd 0
    dd dllname - IMAGE_BASE
    dd iat - IMAGE_BASE
    dd 0,0,0,0,0
    align 8, db 0
oft:
    dq hint_GetStdHandle - IMAGE_BASE
    dq hint_WriteFile - IMAGE_BASE
    dq hint_ReadFile - IMAGE_BASE
    dq hint_ExitProcess - IMAGE_BASE
    dq hint_CreateFileA - IMAGE_BASE
    dq hint_GetFileSize - IMAGE_BASE
    dq hint_CloseHandle - IMAGE_BASE
    dq 0
iat:
iat_GetStdHandle: dq hint_GetStdHandle - IMAGE_BASE
iat_WriteFile:    dq hint_WriteFile - IMAGE_BASE
iat_ReadFile:     dq hint_ReadFile - IMAGE_BASE
iat_ExitProcess:  dq hint_ExitProcess - IMAGE_BASE
iat_CreateFileA:  dq hint_CreateFileA - IMAGE_BASE
iat_GetFileSize:  dq hint_GetFileSize - IMAGE_BASE
iat_CloseHandle:  dq hint_CloseHandle - IMAGE_BASE
    dq 0
dllname:
    db 'kernel32.dll', 0
    align 2, db 0
hint_GetStdHandle:
    dw 0
    db 'GetStdHandle', 0
hint_WriteFile:
    dw 0
    db 'WriteFile', 0
hint_ReadFile:
    dw 0
    db 'ReadFile', 0
hint_ExitProcess:
    dw 0
    db 'ExitProcess', 0
hint_CreateFileA:
    dw 0
    db 'CreateFileA', 0
hint_GetFileSize:
    dw 0
    db 'GetFileSize', 0
hint_CloseHandle:
    dw 0
    db 'CloseHandle', 0
idata_vsize equ ($ - idata_start)
    align 0x200, db 0
idata_file_size equ ($ - idata_start)

; ---------- data ----------
data_off equ (idata_off + idata_file_size + 0x1FF) & ~0x1FF
section .data start=data_off vstart=(IMAGE_BASE + 0x3000)
data_start:
hOut: dq 0
hIn: dq 0
bytes_written: dq 0
bytes_read: dq 0
file_hi: dq 0
in_char: db 0
out_char: db 0
numbuf: times 32 db 0
inbuf: times 256 db 0
edit_idx: dq 0
buf_len: dq 0
line_cnt: dq 0
line_off: times 4096*8 db 0
buf: times 262144 db 0
tmpbuf: times 262144 db 0
; messages
c_colon: db ': ', 0
c_nl: db 13, 10, 0
c_crlf: db 13, 10, 0
msg_banner: db 'CEDIT v1.0 - CF Language Editor (NASM)', 13, 10, 0
msg_help: db 'Commands: [N]ew [L]oad <file> [P]rint [E]dit <n> [I]nsert <n> [D]elete <n> [S]ave <file> [Q]uit', 13, 10, 0
msg_prompt: db '> ', 0
msg_bad: db '? unknown command', 13, 10, 0
msg_ok_new: db 'buffer cleared', 13, 10, 0
msg_newline: db 13, 10, 0
msg_loaded: db 'loaded, lines: ', 0
msg_lines: db 13, 10, 0
msg_saved: db 'saved, bytes: ', 0
msg_bytes: db 13, 10, 0
msg_open_fail: db 'cannot open file', 13, 10, 0
msg_big: db 'file too big', 13, 10, 0
msg_save_usage: db 'usage: S <filename>', 13, 10, 0
data_vsize equ ($ - data_start)
    align 0x200, db 0
data_file_size equ ($ - data_start)

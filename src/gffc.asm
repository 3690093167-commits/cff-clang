%macro DBGMARK 1
%endmacro

; gffc.asm - CF language compiler written in NASM (v0.1)
; usage: gffc.exe <in.cf>
; reads CF source, emits NASM asm, invokes nasm to build exe
; outputs <inbase>.asm and <inbase>.exe in the same dir as input
bits 64
section .hdr start=0 vstart=0
dos:
    db 'M', 'Z'
    times 0x3a db 0
    dd pe_sig - dos
pe_sig:
    db 'P', 'E', 0, 0
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
    db 0, 0
    dd text_file_size
    dd idata_file_size + data_file_size
    dd 0
    dd entry - 0x140000000
    dd text_start - 0x140000000
    dq 0x140000000
    dd 0x1000
    dd 0x200
    dw 6, 0
    dw 0, 0
    dw 6, 0
    dd 0
    dd 0x100000
    dd 0x200
    dd 0
    dw 3
    dw 0
    dq 0x100000
    dq 0x10000
    dq 0x100000
    dq 0x1000
    dd 0
    dd 16
    dd 0, 0
    dd 0x1000 + ((text_vsize + 0xFFF) & ~0xFFF), idata_vsize
    times 14*8 db 0
sectab:
    db '.', 't', 'e', 'x', 't', 0, 0, 0
    dd text_vsize
    dd 0x1000
    dd text_file_size
    dd 0x200
    dd 0, 0
    dw 0, 0
    dd 0x60000020
    db '.', 'i', 'd', 'a', 't', 'a', 0, 0
    dd idata_vsize
    dd 0x1000 + ((text_vsize + 0xFFF) & ~0xFFF)
    dd idata_file_size
    dd idata_off
    dd 0, 0
    dw 0, 0
    dd 0xC0000040
    db '.', 'd', 'a', 't', 'a', 0, 0, 0
    dd data_vsize
    dd 0x1000 + ((text_vsize + 0xFFF) & ~0xFFF) + ((idata_vsize + 0xFFF) & ~0xFFF)
    dd data_file_size
    dd data_off
    dd 0, 0
    dw 0, 0
    dd 0xC0000040
    times (0x200 - ($ - dos)) db 0

section .text start=0x200 vstart=0x140001000
text_start:
entry:
    DBGMARK m0_name
    sub rsp, 0x58
    mov ecx, -11
    call [rel iat_GetStdHandle]
    mov [rel hout], rax
    ; ---- init ----
    mov qword [rel out_len], 0
    mov qword [rel stmts_cnt], 0
    mov qword [rel strpool_len], 0
    ; ---- parse command line ----
    call get_cmdline
    test rax, rax
    jz .usage_err
    ; ---- open source ----
    lea rcx, [rel arg1]
    mov edx, 0x80000000
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+0x20], 3
    mov qword [rsp+0x28], 0x80
    mov qword [rsp+0x30], 0
    call [rel iat_CreateFileA]
    cmp rax, -1
    je .open_err
    mov rbx, rax
    mov rcx, rax
    xor edx, edx
    call [rel iat_GetFileSize]
    cmp rax, -1
    je .open_err
    mov r12, rax
    test rax, rax
    jz .empty_src
    mov rcx, rbx
    lea rdx, [rel src_buf]
    mov r8, rax
    lea r9, [rel src_len]
    mov qword [rsp+0x20], 0
    call [rel iat_ReadFile]
.empty_src:
    mov rcx, rbx
    call [rel iat_CloseHandle]
    ; ---- skip UTF-8 BOM (EF BB BF) at head of main source ----
    mov rcx, [rel src_len]
    cmp rcx, 3
    jb .bom_done
    lea rdi, [rel src_buf]
    cmp byte [rdi], 0xEF
    jne .bom_done
    cmp byte [rdi+1], 0xBB
    jne .bom_done
    cmp byte [rdi+2], 0xBF
    jne .bom_done
    lea rsi, [rdi+3]
    sub rcx, 3
    mov [rel src_len], rcx
    cld
    rep movsb
.bom_done:
    ; ---- install builtins (write/str) ----
    call install_builtins
    test rax, rax
    jz .syntax_err
    ; ---- prescan function signatures (forward refs) ----
    call prescan_funcs
    ; ---- parse ----
    lea rsi, [rel src_buf]
    call parse_prog
    test rax, rax
    jz .syntax_err
    ; ---- emit asm ----
    call emit_all
    ; ---- make paths ----
    call make_paths
    ; ---- write asm file ----
    lea rcx, [rel asm_path]
    mov edx, 0x40000000
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+0x20], 2
    mov qword [rsp+0x28], 0x80
    mov qword [rsp+0x30], 0
    call [rel iat_CreateFileA]
    cmp rax, -1
    je .write_err
    mov rbx, rax
    mov rcx, rbx
    lea rdx, [rel out_buf]
    mov r8, [rel out_len]
    lea r9, [rel written]
    mov qword [rsp+0x20], 0
    call [rel iat_WriteFile]
    mov rcx, rbx
    call [rel iat_CloseHandle]
    ; ---- build nasm cmdline ----
    call make_nasm_cmd
    ; ---- init STARTUPINFO ----
    ; zero si and set cb
    lea rdi, [rel startup_info]
    mov rcx, 104
    xor eax, eax
.zsi:
    mov [rdi], al
    inc rdi
    dec rcx
    jnz .zsi
    mov dword [rel startup_info], 104
    ; ---- run nasm ----
    xor ecx, ecx
    lea rdx, [rel cmdline]
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+0x20], 0
    mov qword [rsp+0x28], 0
    mov qword [rsp+0x30], 0
    mov qword [rsp+0x38], 0
    lea rax, [rel startup_info]
    mov [rsp+0x40], rax
    lea rax, [rel pi]
    mov [rsp+0x48], rax
    call [rel iat_CreateProcessA]
    test rax, rax
    jz .spawn_err
    mov rcx, [rel pi]
    mov edx, 0xFFFFFFFF
    call [rel iat_WaitForSingleObject]
    mov rcx, [rel pi]
    lea rdx, [rel proc_code]
    call [rel iat_GetExitCodeProcess]
    cmp dword [rel proc_code], 0
    jne .nasm_err
    mov rcx, [rel pi]
    call [rel iat_CloseHandle]
    mov rcx, [rel pi+8]
    call [rel iat_CloseHandle]
    ; ---- debug: keep intermediate .asm ----
    jmp .skip_del
    lea rcx, [rel asm_path]
    call [rel iat_DeleteFileA]
.skip_del:
    ; ---- success ----
    lea rdi, [rel msg_ok]
    call puts_cstr
    lea rdi, [rel exe_path]
    call puts_cstr
    mov dil, 10
    call putch
    xor ecx, ecx
    call [rel iat_ExitProcess]
.usage_err:
    lea rdi, [rel msg_usage]
    call puts_cstr
    mov ecx, 1
    call [rel iat_ExitProcess]
.open_err:
    lea rdi, [rel msg_etype_file]
    call puts_cstr
    mov dil, ':'
    call putch
    mov dil, ' '
    call putch
    lea rdi, [rel msg_open]
    call puts_cstr
    mov dil, 39
    call putch
    lea rdi, [rel arg1]
    call puts_cstr
    mov dil, 39
    call putch
    mov dil, 10
    call putch
    mov ecx, 1
    call [rel iat_ExitProcess]
.syntax_err:
    call err_report
    mov ecx, 1
    call [rel iat_ExitProcess]
.write_err:
    lea rdi, [rel msg_etype_os]
    call puts_cstr
    mov dil, ':'
    call putch
    mov dil, ' '
    call putch
    lea rdi, [rel msg_write_new]
    call puts_cstr
    mov ecx, 1
    call [rel iat_ExitProcess]
.spawn_err:
    lea rdi, [rel msg_etype_os]
    call puts_cstr
    mov dil, ':'
    call putch
    mov dil, ' '
    call putch
    lea rdi, [rel msg_spawn_new]
    call puts_cstr
    mov ecx, 1
    call [rel iat_ExitProcess]
.nasm_err:
    lea rdi, [rel msg_etype_comp]
    call puts_cstr
    mov dil, ':'
    call putch
    mov dil, ' '
    call putch
    lea rdi, [rel msg_nasm_new]
    call puts_cstr
    mov rax, [rel proc_code]
    call print_dec
    mov dil, 10
    call putch
    mov ecx, 1
    call [rel iat_ExitProcess]


; ============ helpers ============
; puts_cstr: rdi = nul-terminated -> stdout
puts_cstr:
    push rbx
    push rsi
    sub rsp, 0x48
    mov rbx, rdi
    xor esi, esi
.len:
    cmp byte [rbx+rsi], 0
    je .go
    inc rsi
    jmp .len
.go:
    mov rcx, [rel hout]
    mov rdx, rbx
    mov r8, rsi
    lea r9, [rsp+0x38]
    mov qword [rsp+0x20], 0
    call [rel iat_WriteFile]
    add rsp, 0x48
    pop rsi
    pop rbx
    ret

; putch: dil = char
putch:
    sub rsp, 0x48
    mov byte [rsp+0x30], dil
    mov rcx, [rel hout]
    lea rdx, [rsp+0x30]
    mov r8d, 1
    lea r9, [rsp+0x38]
    mov qword [rsp+0x20], 0
    call [rel iat_WriteFile]
    add rsp, 0x48
    ret

; print_dec: rax = unsigned number -> stdout
print_dec:
    push rbx
    push rdi
    push rsi
    sub rsp, 0x28
    lea rdi, [rel num_tmp+31]
    mov byte [rdi], 0
    mov rbx, 10
    mov rsi, rdi
    test rax, rax
    jnz .pd_loop
    mov byte [rdi-1], '0'
    lea rdi, [rdi-1]
    jmp .pd_go
.pd_loop:
    xor edx, edx
    div rbx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .pd_loop
.pd_go:
.pd_out:
    mov rsi, rdi
.pd_out2:
    movzx eax, byte [rsi]
    test al, al
    jz .pd_done
    mov dil, al
    call putch
    inc rsi
    jmp .pd_out2
.pd_done:
    add rsp, 0x28
    pop rsi
    pop rdi
    pop rbx
    ret

; err_set_syntax: rax = msg ptr -> err_type=SyntaxError, err_msg=rax
err_set_syntax:
    lea rcx, [rel msg_etype_syntax]
    mov [rel err_type], rcx
    mov [rel err_msg], rax
    ret

; err_set_expected: rdi = keyword ptr -> err_msg_buf = "expected '<kw>'"
err_set_expected:
    push rsi
    push rcx
    push rax
    lea rsi, [rel err_msg_buf]
    lea rcx, [rel msg_expected_q]
.ese_cp1:
    mov al, [rcx]
    mov [rsi], al
    test al, al
    jz .ese_cp1d
    inc rcx
    inc rsi
    jmp .ese_cp1
.ese_cp1d:
.ese_cp2:
    mov al, [rdi]
    test al, al
    jz .ese_cp2d
    mov [rsi], al
    inc rdi
    inc rsi
    jmp .ese_cp2
.ese_cp2d:
    mov byte [rsi], 39
    inc rsi
    mov byte [rsi], 0
    lea rax, [rel msg_etype_syntax]
    mov [rel err_type], rax
    lea rax, [rel err_msg_buf]
    mov [rel err_msg], rax
    pop rax
    pop rcx
    pop rsi
    ret

; err_set_import: ?????"cannot open library '<lib_path_buf>'" -> err_msg_buf
err_set_import:
    push rsi
    push rcx
    push rax
    push rdx
    lea rsi, [rel err_msg_buf]
    lea rcx, [rel msg_imp_open]
.esi_cp1:
    mov al, [rcx]
    mov [rsi], al
    test al, al
    jz .esi_cp1d
    inc rcx
    inc rsi
    jmp .esi_cp1
.esi_cp1d:
    mov byte [rsi], 39
    inc rsi
    lea rcx, [rel lib_path_buf]
.esi_cp2:
    mov al, [rcx]
    test al, al
    jz .esi_cp2d
    mov [rsi], al
    inc rcx
    inc rsi
    jmp .esi_cp2
.esi_cp2d:
    mov byte [rsi], 39
    inc rsi
    mov byte [rsi], 0
    lea rax, [rel msg_etype_imp]
    mov [rel err_type], rax
    lea rax, [rel err_msg_buf]
    mov [rel err_msg], rax
    pop rdx
    pop rax
    pop rcx
    pop rsi
    ret

; err_report: ?????Python ?????????
; ????? rsi = src_buf ??????????? err_type/err_msg ?????????????????
err_report:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r12
    push r13
    push r14
    sub rsp, 0x20
    mov r13, rsi
    ; ---- ????? r14=line, r8=line_start offset, rbx=col ----
    lea rdi, [rel src_buf]
    xor edx, edx
    mov r14, 1
    xor r8d, r8d
.el_loop:
    cmp rdi, r13
    jae .el_done
    mov al, [rdi]
    cmp al, 0
    je .el_done
    cmp al, 10
    jne .el_cont
    inc r14
    inc rdx
    inc rdi
    mov r8, rdx
    jmp .el_loop
.el_cont:
    inc rdi
    inc rdx
    jmp .el_loop
.el_done:
    lea rax, [rel src_buf]
    mov rbx, r13
    sub rbx, rax
    sub rbx, r8
    lea r12, [rel src_buf]
    add r12, r8
    ; ---- '  File "<arg1>", line N, in <module>' ----
    lea rdi, [rel msg_file_line]
    call puts_cstr
    lea rdi, [rel arg1]
    call puts_cstr
    lea rdi, [rel msg_line2]
    call puts_cstr
    mov rax, r14
    call print_dec
    lea rdi, [rel msg_line3]
    call puts_cstr
    mov dil, 10
    call putch
    ; ---- ???????----
    mov dil, ' '
    call putch
    mov dil, ' '
    call putch
.el_ln:
    mov al, [r12]
    cmp al, 0
    je .el_ln_done
    cmp al, 10
    je .el_ln_done
    cmp al, 13
    je .el_ln_done
    mov r10b, al
    mov dil, r10b
    call putch
    inc r12
    jmp .el_ln
.el_ln_done:
    mov dil, 10
    call putch
    ; ---- caret ??----
    mov dil, ' '
    call putch
    mov dil, ' '
    call putch
.el_cr:
    test rbx, rbx
    jz .el_cr_done
    mov dil, ' '
    call putch
    dec rbx
    jmp .el_cr
.el_cr_done:
    mov dil, '^'
    call putch
    mov dil, 10
    call putch
    ; ---- 'Type: msg' ----
    mov rdi, [rel err_type]
    test rdi, rdi
    jnz .el_tok
    lea rdi, [rel msg_etype_syntax]
.el_tok:
    call puts_cstr
    mov dil, ':'
    call putch
    mov dil, ' '
    call putch
    mov rdi, [rel err_msg]
    test rdi, rdi
    jnz .el_mok
    lea rdi, [rel msg_invalid]
.el_mok:
    call puts_cstr
    mov dil, 10
    call putch
    add rsp, 0x20
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; emit: rdi = ptr, rsi = len -> append to out_buf
emit:
    push rbx
    push rcx
    push rsi
    push rdi
    sub rsp, 0x28
    mov rbx, rsi
    mov rax, [rel out_len]
    lea rcx, [rel out_buf]
    add rcx, rax
    xor r8d, r8d
.copy:
    cmp r8, rbx
    jae .done
    mov al, [rdi+r8]
    mov [rcx], al
    inc rcx
    inc r8
    jmp .copy
.done:
    mov rax, [rel out_len]
    add rax, rbx
    mov [rel out_len], rax
    add rsp, 0x28
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; emit_cstr: rdi = nul-terminated
emit_cstr:
    push rdi
    push rsi
    xor esi, esi
.len:
    cmp byte [rdi+rsi], 0
    je .go
    inc rsi
    jmp .len
.go:
    call emit
    pop rsi
    pop rdi
    ret

; emit_num: rax = number -> decimal ascii
emit_num:
    push rbx
    push rdi
    push rsi
    sub rsp, 0x28
    lea rdi, [rel num_tmp+31]
    mov byte [rdi], 0
    mov rbx, 10
    mov rsi, rdi
.loop:
    xor edx, edx
    div rbx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .loop
    mov rdx, rsi
    sub rdx, rdi
    mov rsi, rdx
    call emit
    add rsp, 0x28
    pop rsi
    pop rdi
    pop rbx
    ret

; ============ command line ============
get_cmdline:
    sub rsp, 0x28
    call [rel iat_GetCommandLineA]
    add rsp, 0x28
    mov rsi, rax
    ; skip argv0: past spaces (quotes not handled deeply)
.skip0:
    mov al, [rsi]
    cmp al, ' '
    je .got
    cmp al, 0
    je .none
    inc rsi
    jmp .skip0
.got:
    inc rsi
.sp1:
    cmp byte [rsi], ' '
    jne .read
    inc rsi
    jmp .sp1
.read:
    cmp byte [rsi], 0
    je .none
    lea rdi, [rel arg1]
    mov rbx, rsi
.l1:
    mov al, [rbx]
    cmp al, ' '
    je .l1d
    cmp al, 0
    je .l1d
    cmp al, '"'
    je .l1d
    mov [rdi], al
    inc rdi
    inc rbx
    jmp .l1
.l1d:
    mov byte [rdi], 0
    ; optional arg2
    mov rsi, rbx
.sp2:
    cmp byte [rsi], ' '
    jne .check2
    inc rsi
    jmp .sp2
.check2:
    cmp byte [rsi], 0
    je .done
    lea rdi, [rel arg2]
.l2:
    mov al, [rsi]
    cmp al, ' '
    je .l2d
    cmp al, 0
    je .l2d
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .l2
.l2d:
    mov byte [rdi], 0
.done:
    mov rax, 1
    ret
.none:
    xor eax, eax
    ret

; ============ paths ============
; make_paths: from arg1 -> asm_path(base.asm), exe_path(base.exe)
make_paths:
    push rbx
    push rcx
    push r8
    push r9
    lea rsi, [rel arg1]
    xor r9d, r9d
.find:
    mov al, [rsi]
    cmp al, 0
    je .found
    cmp al, '.'
    jne .nx
    mov r9, rsi
.nx:
    inc rsi
    jmp .find
.found:
    ; copy prefix to asm_path
    lea rsi, [rel arg1]
    lea rdi, [rel asm_path]
    lea r8, [rel exe_path]
.copy:
    cmp rsi, r9
    je .copied
    cmp byte [rsi], 0
    je .copied
    mov al, [rsi]
    mov [rdi], al
    mov [r8], al
    inc rdi
    inc r8
    inc rsi
    jmp .copy
.copied:
    ; asm_path += ".asm"
    mov byte [rdi], '.'
    mov byte [rdi+1], 'a'
    mov byte [rdi+2], 's'
    mov byte [rdi+3], 'm'
    mov byte [rdi+4], 0
    ; exe_path += ".exe"
    mov byte [r8], '.'
    mov byte [r8+1], 'e'
    mov byte [r8+2], 'x'
    mov byte [r8+3], 'e'
    mov byte [r8+4], 0
    pop r9
    pop r8
    pop rcx
    pop rbx
    ret

; make_nasm_cmd: cmdline = "\"nasm_path\" -f bin \"asm_path\" -o \"exe_path\""
make_nasm_cmd:
    push rbx
    lea rdi, [rel cmdline]
    mov byte [rdi], '"'
    inc rdi
    lea rsi, [rel nasm_path]
.c1:
    mov al, [rsi]
    cmp al, 0
    je .c1d
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .c1
.c1d:
    mov byte [rdi], '"'
    inc rdi
    lea rsi, [rel nasm_args]
.c2:
    mov al, [rsi]
    cmp al, 0
    je .c2d
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .c2
.c2d:
    mov byte [rdi], '"'
    inc rdi
    lea rsi, [rel asm_path]
.c3:
    mov al, [rsi]
    cmp al, 0
    je .c3d
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .c3
.c3d:
    mov byte [rdi], '"'
    inc rdi
    lea rsi, [rel nasm_args2]
.c4:
    mov al, [rsi]
    cmp al, 0
    je .c4d
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .c4
.c4d:
    mov byte [rdi], '"'
    inc rdi
    lea rsi, [rel exe_path]
.c5:
    mov al, [rsi]
    cmp al, 0
    je .c5d
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .c5
.c5d:
    mov byte [rdi], '"'
    inc rdi
    mov byte [rdi], 0
    pop rbx
    ret

; ============ parser ============
; ---- prescan_funcs: pre-register function signatures so calls can precede definitions ----
prescan_funcs:
    push rsi
    push rdi
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rsi, [rel src_buf]
    mov r14, 1
.pfs_loop:
    movzx eax, byte [rsi]
    test eax, eax
    jz .pfs_end
    cmp al, 34
    je .pfs_skip_dq
    cmp al, 39
    je .pfs_skip_sq
    cmp al, 32
    jbe .pfs_bound
    cmp al, ';'
    je .pfs_bound
    cmp al, '{'
    je .pfs_bound
    cmp al, '}'
    je .pfs_bound
    cmp al, '('
    je .pfs_bound
    cmp al, ','
    je .pfs_bound
    test r14, r14
    jz .pfs_next
    call ps_try_match
    jmp .pfs_next
.pfs_bound:
    mov r14, 1
    inc rsi
    jmp .pfs_loop
.pfs_skip_dq:
    inc rsi
.pfs_sdq_loop:
    movzx eax, byte [rsi]
    test eax, eax
    jz .pfs_end
    inc rsi
    cmp al, 34
    jne .pfs_sdq_loop
    xor r14d, r14d
    jmp .pfs_loop
.pfs_skip_sq:
    inc rsi
.pfs_ssq_loop:
    movzx eax, byte [rsi]
    test eax, eax
    jz .pfs_end
    inc rsi
    cmp al, 39
    jne .pfs_ssq_loop
    xor r14d, r14d
    jmp .pfs_loop
.pfs_next:
    xor r14d, r14d
    inc rsi
    jmp .pfs_loop
.pfs_end:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rdi
    pop rsi
    mov rax, 1
    ret

; ps_skip_ws: advance rsi past whitespace
ps_skip_ws:
    push rax
.pssw_loop:
    movzx eax, byte [rsi]
    test al, al
    jz .pssw_done
    cmp al, 32
    ja .pssw_done
    inc rsi
    jmp .pssw_loop
.pssw_done:
    pop rax
    ret

; ps_cmp: compare rcx bytes at r12 vs rdi, next char must be space / NUL / '('
; out: rax=1 match, 0 no
ps_cmp:
    push rbx
    push r8
    xor r8d, r8d
.pc_loop:
    cmp r8, rcx
    jae .pc_tail
    mov al, [r12+r8]
    cmp al, [rdi+r8]
    jne .pc_no
    inc r8
    jmp .pc_loop
.pc_tail:
    movzx eax, byte [rdi+r8]
    test al, al
    jz .pc_yes
    cmp al, 32
    jbe .pc_yes
    cmp al, '('
    je .pc_yes
    jmp .pc_no
.pc_yes:
    mov rax, 1
    pop r8
    pop rbx
    ret
.pc_no:
    xor eax, eax
    pop r8
    pop rbx
    ret

; ps_try_match: rsi at token start; match "<type|def> <name> (" then register forward func
; out: rax=1 registered/known, rax=0 no match
ps_try_match:
    push rbx
    push rcx
    push rdx
    push rdi
    push r12
    mov rbx, rsi
    mov rdi, rbx
    lea r12, [rel ps_kw_def]
    mov rcx, 3
    call ps_cmp
    test rax, rax
    jnz .ptm_kw_ok
    mov rdi, rbx
    lea r12, [rel ps_kw_string]
    mov rcx, 6
    call ps_cmp
    test rax, rax
    jnz .ptm_kw_ok
    mov rdi, rbx
    lea r12, [rel ps_kw_str]
    mov rcx, 3
    call ps_cmp
    test rax, rax
    jnz .ptm_kw_ok
    mov rdi, rbx
    lea r12, [rel ps_kw_char]
    mov rcx, 4
    call ps_cmp
    test rax, rax
    jnz .ptm_kw_ok
    mov rdi, rbx
    lea r12, [rel ps_kw_bigint]
    mov rcx, 6
    call ps_cmp
    test rax, rax
    jnz .ptm_kw_ok
    mov rdi, rbx
    lea r12, [rel ps_kw_bool]
    mov rcx, 4
    call ps_cmp
    test rax, rax
    jnz .ptm_kw_ok
    mov rdi, rbx
    lea r12, [rel ps_kw_int]
    mov rcx, 3
    call ps_cmp
    test rax, rax
    jz .ptm_no
.ptm_kw_ok:
    lea rsi, [rbx + rcx]
    call ps_skip_ws
    call parse_name
    test rax, rax
    jz .ptm_no
    ; skip main
    lea rdi, [rel tmp_name]
    cmp byte [rdi], 'm'
    jne .ptm_not_main
    cmp byte [rdi+1], 'a'
    jne .ptm_not_main
    cmp byte [rdi+2], 'i'
    jne .ptm_not_main
    cmp byte [rdi+3], 'n'
    jne .ptm_not_main
    cmp byte [rdi+4], 0
    je .ptm_no
.ptm_not_main:
    call is_keyword
    test rax, rax
    jnz .ptm_no
    call ps_skip_ws
    cmp byte [rsi], '('
    jne .ptm_no
    call ps_skip_ws
    ; already registered?
    call find_func
    cmp r15, -1
    jne .ptm_no
    call add_func
    test rax, rax
    jz .ptm_no
    lea rdx, [rel func_forward]
    add rdx, r15
    mov byte [rdx], 1
    mov rax, 1
    jmp .ptm_out
.ptm_no:
    xor eax, eax
.ptm_out:
    pop r12
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; parse_prog: rsi = src -> rax=1 ok / 0 fail
parse_prog:
    DBGMARK m3_name
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 0x20
    ; ?????????????? SyntaxError: invalid syntax
    lea rax, [rel msg_etype_syntax]
    mov [rel err_type], rax
    lea rax, [rel msg_invalid]
    mov [rel err_msg], rax
    ; ????????????????????(import ???????????
    mov rax, [rel src_len]
    mov [rel src_len_orig], rax
    ; ---- import list: `import <libname>;` zero or more ----
.imp_loop:
    call ws_skip
    cmp byte [rsi], 0
    je .fail_missing_main
    mov r13, 6
    call expect_id_import
    test rax, rax
    jnz .imp_have_kw
    mov r13, 3
    call expect_id_imp
    test rax, rax
    jz .main_or_func
.imp_have_kw:
    DBGMARK md_name
    call ws_skip
    mov dil, '<'
    call expect_char
    test rax, rax
    jz .fail
    call ws_skip
    mov rax, [rel import_cnt]
    cmp rax, 8
    jae .fail
    lea rbx, [rel import_libs]
    imul rax, rax, 64
    add rbx, rax
    mov r14, rbx
    xor r12d, r12d
.lib_loop:
    mov al, [rsi]
    cmp al, '>'
    je .lib_done
    cmp al, 0
    je .fail
    cmp al, ' '
    je .fail
    cmp al, 9
    je .fail
    mov [rbx], al
    inc rbx
    inc rsi
    inc r12
    cmp r12, 63
    jae .fail
    jmp .lib_loop
.lib_done:
    DBGMARK me_name
    mov byte [rbx], 0
    inc qword [rel import_cnt]
    call ws_skip
    mov dil, '>'
    call expect_char
    test rax, rax
    jz .fail
    call ws_skip
    ; optional trailing ';' after `import <lib>` (both styles accepted)
    cmp byte [rsi], ';'
    jne .imp_no_semi
    inc rsi
.imp_no_semi:
    DBGMARK mf_name
    ; ??????????????: .cf ????????? / .dll/.so ????????????
    ; r14 = ??????????????
    mov qword [rel imp_top], 1
    mov byte [rel cur_pkg], 0
    mov qword [rel cur_pkg_set], 0
    call resolve_import
    test rax, rax
    jz .fail
    jmp .imp_loop
.main_or_func:
    ; === import ????? ???????cf ?????????, ?????rsi ?????===
    mov rax, [rel src_len]
    mov rbx, [rel src_len_orig]
    sub rax, rbx
    jz .mof_nocf
    ; rax = cf_len; ?????cf ?????[src_buf+src_len_orig, src_buf+src_len) ??src_extra
    push rax
    lea r8, [rel src_buf]
    add r8, [rel src_len_orig]
    lea r9, [rel src_extra]
    mov rdx, rax
    DBGMARK mx1_name
.mof_sv:
    test rdx, rdx
    jz .mof_sv_done
    mov al, [r8]
    mov [r9], al
    inc r8
    inc r9
    dec rdx
    jmp .mof_sv
.mof_sv_done:
    DBGMARK mx2_name
    pop rax
    ; ???????????[rsi, src_buf+src_len_orig) ???? cf_len
    lea rcx, [rel src_buf]
    add rcx, [rel src_len_orig]
    mov rdx, rcx
    sub rdx, rsi
    lea r8, [rsi+rdx]
    lea r9, [rsi+rdx]
    add r9, rax
.mof_mv:
    test rdx, rdx
    jz .mof_mv_done
    dec r9
    dec r8
    mov al, [r8]
    mov [r9], al
    dec rdx
    jmp .mof_mv
.mof_mv_done:
    DBGMARK mx3_name
    ; rax ?????.mof_mv ??al ????? ?????cf_len
    mov rax, [rel src_len]
    sub rax, [rel src_len_orig]
    ; cf ???????src_extra ?????rsi
    push rax
    lea r8, [rel src_extra]
    mov r9, rsi
    mov rdx, rax
.mof_cp:
    test rdx, rdx
    jz .mof_cp_done
    mov al, [r8]
    mov [r9], al
    inc r8
    inc r9
    dec rdx
    jmp .mof_cp
.mof_cp_done:
    DBGMARK mx4_name
    pop rax
    mov rax, [rel src_len]
    mov [rel src_len_orig], rax
    mov qword [rel cf_pending], 0
.mof_nocf:
    call ws_skip
    ; ---- imports inside library files: import <lib>; (expanded in place) ----
    mov r13, 6
    call expect_id_import
    test rax, rax
    jnz .mof_imp_hit
    mov r13, 3
    call expect_id_imp
    test rax, rax
    jz .mof_imp_miss
.mof_imp_hit:
    DBGMARK m8_name
    call ws_skip
    mov dil, '<'
    call expect_char
    test rax, rax
    jz .fail
    call ws_skip
    lea rdi, [rel imp_sub_buf]
    xor r12d, r12d
.mof_rd_name:
    mov al, [rsi]
    cmp al, '>'
    je .mof_rd_done
    cmp al, 0
    je .fail
    cmp al, ' '
    je .fail
    cmp al, 9
    je .fail
    cmp r12, 63
    jae .fail
    mov [rdi], al
    inc rsi
    inc rdi
    inc r12
    jmp .mof_rd_name
.mof_rd_done:
    DBGMARK m9_name
    mov byte [rdi], 0
    push rsi
    xor r13d, r13d
.mof_dup_loop:
    cmp r13, [rel import_cnt]
    jae .mof_dup_new
    lea rcx, [rel import_libs]
    mov rax, r13
    shl rax, 6
    add rcx, rax
    lea rdx, [rel imp_sub_buf]
.mof_dup_cmp:
    mov al, [rcx]
    mov r8b, [rdx]
    cmp al, r8b
    jne .mof_dup_next
    test al, al
    jz .mof_dup_skip
    inc rcx
    inc rdx
    jmp .mof_dup_cmp
.mof_dup_next:
    inc r13
    jmp .mof_dup_loop
.mof_dup_new:
    DBGMARK ma_name
    pop rsi
    mov rax, [rel import_cnt]
    cmp rax, 8
    jae .fail
    lea rdi, [rel import_libs]
    shl rax, 6
    add rdi, rax
    lea rsi, [rel imp_sub_buf]
.mof_cp_name:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .mof_cp_name_done
    inc rsi
    inc rdi
    jmp .mof_cp_name
.mof_cp_name_done:
    inc qword [rel import_cnt]
    call ws_skip
    mov dil, '>'
    call expect_char
    test rax, rax
    jz .fail
    call ws_skip
    cmp byte [rsi], ';'
    jne .mof_imp_no_semi
    inc rsi
.mof_imp_no_semi:
    DBGMARK mb_name
    mov qword [rel imp_top], 1
    lea r14, [rel imp_sub_buf]
    call resolve_import
    test rax, rax
    jz .fail
    jmp .main_or_func
.mof_dup_skip:
    pop rsi
    call ws_skip
    mov dil, '>'
    call expect_char
    test rax, rax
    jz .fail
    call ws_skip
    cmp byte [rsi], ';'
    jne .mof_imp_miss
    inc rsi
.mof_imp_miss:
    ; try namespace declaration: namesp <name>;  (skipped)
    mov r13, 6
    call expect_id_namesp
    test rax, rax
    jz .mof_def
    call ws_skip
    call parse_name
    test rax, rax
    jz .fail
    call ws_skip
    cmp byte [rsi], ';'
    jne .ns_no_semi
    inc rsi
.ns_no_semi:
    jmp .main_or_func
.mof_def:
    ; try def function: def name(args) { ... }
    mov r13, 3
    call expect_id_def
    test rax, rax
    jz .try_main
    call ws_skip
    call parse_name
    test rax, rax
    jz .fail
    ; def main() { ... } ??????????????, ?????main ?????????
    lea rbx, [rel tmp_name]
    cmp byte [rbx], 'm'
    jne .def_regular
    cmp byte [rbx+1], 'a'
    jne .def_regular
    cmp byte [rbx+2], 'i'
    jne .def_regular
    cmp byte [rbx+3], 'n'
    jne .def_regular
    cmp byte [rbx+4], 0
    je .main_body
.def_regular:
    call is_keyword
    test rax, rax
    jz .def_kw_ok
    ; allow user function to shadow builtin keyword `print` (iostrpm print(*obj))
    lea rdi, [rel tmp_name]
    cmp byte [rdi], 'p'
    jne .fail
    cmp byte [rdi+1], 'r'
    jne .fail
    cmp byte [rdi+2], 'i'
    jne .fail
    cmp byte [rdi+3], 'n'
    jne .fail
    cmp byte [rdi+4], 't'
    jne .fail
    cmp byte [rdi+5], 0
    jne .fail
.def_kw_ok:
    ; reuse forward-registered entry if present, else create a new one
    call find_func
    cmp r15, -1
    je .def_add_new
    lea rdx, [rel func_forward]
    add rdx, r15
    cmp byte [rdx], 1
    jne .def_add_new
    mov byte [rdx], 0
    jmp .def_have_idx
.def_add_new:
    call add_func
    test rax, rax
    jz .fail
.def_have_idx:
    mov [rel cur_func], r15
    mov qword [rel cur_local_cnt], 0
    mov qword [rel cur_param_slot], 0
    mov qword [rel cur_param_cnt], 0
    call ws_skip
    mov dil, '('
    call expect_char
    test rax, rax
    jz .fail
    call ws_skip
    cmp byte [rsi], ')'
    jne .param_loop
    inc rsi
    jmp .func_params_done
.param_loop:
    mov qword [rel cur_param_ref], 0
    mov qword [rel cur_param_type], 0
    xor r14d, r14d
    call ws_skip
    cmp byte [rsi], '*'
    jne .pl_ws_skip2
    ; varargs declaration: *name (does not consume a param slot)
    inc rsi
    call ws_skip
    call parse_name
    test rax, rax
    jz .fail
    mov rax, [rel cur_func]
    imul rax, rax, 56
    lea rdx, [rel func_table]
    add rdx, rax
    mov dword [rdx+52], 1
    call ws_skip
    cmp byte [rsi], ')'
    jne .pl_varargs_comma
    inc rsi
    jmp .func_params_done
.pl_varargs_comma:
    cmp byte [rsi], ','
    jne .fail
    inc rsi
    call ws_skip
    jmp .param_loop
.pl_ws_skip2:
    ; optional no-swap (reference) prefix: int_ns / str_ns
    push rsi
    call parse_name
    test rax, rax
    jz .pl_prefix_fail
    lea rdi, [rel tmp_name]
    mov al, [rdi]
    cmp al, 'i'
    jne .pl_check_str
    cmp byte [rdi+1], 'n'
    jne .pl_check_str
    cmp byte [rdi+2], 't'
    jne .pl_check_str
    cmp byte [rdi+3], '_'
    jne .pl_check_str
    cmp byte [rdi+4], 'n'
    jne .pl_check_str
    cmp byte [rdi+5], 's'
    jne .pl_check_str
    cmp byte [rdi+6], 0
    jne .pl_check_str
    mov qword [rel cur_param_ref], 1
    mov r14, 0
    mov r13, 0
    jmp .pl_read_name
.pl_check_str:
    mov al, [rdi]
    cmp al, 's'
    jne .pl_check_type
    cmp byte [rdi+1], 't'
    jne .pl_check_type
    cmp byte [rdi+2], 'r'
    jne .pl_check_type
    cmp byte [rdi+3], '_'
    jne .pl_check_type
    cmp byte [rdi+4], 'n'
    jne .pl_check_type
    cmp byte [rdi+5], 's'
    jne .pl_check_type
    cmp byte [rdi+6], 0
    jne .pl_check_type
    mov qword [rel cur_param_ref], 1
    mov r14, 1
    jmp .pl_read_name
.pl_check_type:
    mov qword [rel cur_param_type], 0
    ; typed param prefix: int/string/char/bigint/bool before param name
    mov al, [rdi]
    cmp al, 'i'
    jne .pct_try_string
    cmp byte [rdi+1], 'n'
    jne .pct_try_string
    cmp byte [rdi+2], 't'
    jne .pct_try_string
    cmp byte [rdi+3], 0
    jne .pct_try_string
    jmp .pct_type_ok
.pct_try_string:
    cmp al, 's'
    jne .pct_try_char
    cmp byte [rdi+1], 't'
    jne .pct_try_char
    cmp byte [rdi+2], 'r'
    jne .pct_try_char
    cmp byte [rdi+3], 0
    jne .pct_str_long
    mov qword [rel cur_param_type], 1
    jmp .pct_type_ok
.pct_str_long:
    cmp byte [rdi+3], 'i'
    jne .pct_try_char
    cmp byte [rdi+4], 'n'
    jne .pct_try_char
    cmp byte [rdi+5], 'g'
    jne .pct_try_char
    cmp byte [rdi+6], 0
    jne .pct_try_char
    mov qword [rel cur_param_type], 1
    jmp .pct_type_ok
.pct_try_char:
    cmp al, 'c'
    jne .pct_try_bigint
    cmp byte [rdi+1], 'h'
    jne .pct_try_bigint
    cmp byte [rdi+2], 'a'
    jne .pct_try_bigint
    cmp byte [rdi+3], 'r'
    jne .pct_try_bigint
    cmp byte [rdi+4], 0
    jne .pct_try_bigint
    mov qword [rel cur_param_type], 1
    jmp .pct_type_ok
.pct_try_bigint:
    cmp al, 'b'
    jne .pct_try_bool
    cmp byte [rdi+1], 'i'
    jne .pct_try_bool
    cmp byte [rdi+2], 'g'
    jne .pct_try_bool
    cmp byte [rdi+3], 'i'
    jne .pct_try_bool
    cmp byte [rdi+4], 'n'
    jne .pct_try_bool
    cmp byte [rdi+5], 't'
    jne .pct_try_bool
    cmp byte [rdi+6], 0
    jne .pct_try_bool
    jmp .pct_type_ok
.pct_try_bool:
    cmp al, 'b'
    jne .pct_not_type
    cmp byte [rdi+1], 'o'
    jne .pct_not_type
    cmp byte [rdi+2], 'o'
    jne .pct_not_type
    cmp byte [rdi+3], 'l'
    jne .pct_not_type
    cmp byte [rdi+4], 0
    jne .pct_not_type
.pct_type_ok:
    mov qword [rel cur_param_ref], 0
    jmp .pl_read_name
.pct_not_type:
    pop rsi
    jmp .pl_normal
.pl_prefix_fail:
    pop rsi
    jmp .fail
.pl_read_name:
    call ws_skip
    call parse_name
    test rax, rax
    jz .fail
    call is_keyword
    mov r12, rax
    test r12, r12
    jnz .fail
    mov r13, 0
    mov r14, [rel cur_param_type]
    call add_var
    test rax, rax
    jz .fail
    mov rax, [rel cur_param_ref]
    test rax, rax
    jz .pl_no_bit
    mov rax, [rel cur_func]
    imul rax, rax, 8
    lea rdx, [rel ref_bmap]
    add rdx, rax
    mov rcx, [rel cur_param_cnt]
    mov rbx, 1
    shl rbx, cl
    or [rdx], rbx
.pl_no_bit:
    inc qword [rel cur_param_cnt]
    ; ????????.param_loop ??push ??rsi ?????????????????????????? pop??
    add rsp, 8
    call ws_skip
    cmp byte [rsi], ','
    jne .func_rparen
    inc rsi
    call ws_skip
    jmp .param_loop
.pl_normal:
    call parse_name
    test rax, rax
    jz .fail
    call is_keyword
    test rax, rax
    jz .pl_n_ok
    lea rax, [rel msg_param_kw]
    call err_set_syntax
    jmp .fail
.pl_n_ok:
    mov r13, 0
    call add_var
    test rax, rax
    jz .fail
    inc qword [rel cur_param_cnt]
    call ws_skip
    cmp byte [rsi], ','
    jne .func_rparen
    inc rsi
    call ws_skip
    jmp .param_loop
.func_rparen:
    mov dil, ')'
    call expect_char
    test rax, rax
    jz .fail
.func_params_done:
    call ws_skip
    mov dil, '{'
    call expect_char
    test rax, rax
    jz .fail
    ; record stmts_start for this func
    mov rax, [rel cur_func]
    lea rbx, [rel func_table]
    imul rax, rax, 56
    add rbx, rax
    mov rax, [rel cur_param_cnt]
    mov [rbx+16], rax
    mov rax, [rel stmts_cnt]
    mov [rbx+24], rax
    jmp .stmt
.try_main:
    call ws_skip
    ; accept main() { ... } or int main() { ... }
    mov r13, 4
    call expect_id_main
    test rax, rax
    jz .try_main_int
    jmp .main_body
.try_main_int:
    mov r13, 3
    call expect_id
    test rax, rax
    jz .fail
    call ws_skip
    mov r13, 4
    call expect_id_main
    test rax, rax
    jz .fail
.main_body:
    call ws_skip
    mov dil, '('
    call expect_char
    test rax, rax
    jz .fail
    call ws_skip
    mov dil, ')'
    call expect_char
    test rax, rax
    jz .fail
    call ws_skip
    mov dil, '{'
    call expect_char
    test rax, rax
    jz .fail
    ; main context: owner=-1, fresh locals, record stmts_start
    mov qword [rel cur_func], -1
    mov qword [rel cur_local_cnt], 0
    mov qword [rel cur_param_slot], 0
    mov qword [rel cur_param_cnt], 0
    mov rax, [rel stmts_cnt]
    mov [rel main_start], rax
.stmt:
    call ws_skip
    cmp byte [rsi], '}'
    je .stmt_brk
    ; try while
    mov r13, 5
    call expect_id_while
    test rax, rax
    jz .stmt_after_while
    jmp .try_while
.stmt_after_while:
    ; try else
    mov r13, 4
    call expect_id_else
    test rax, rax
    jz .stmt_after_else
    jmp .try_else
.stmt_after_else:
    ; try if
    mov r13, 2
    call expect_id_if
    test rax, rax
    jz .stmt_after_if
    jmp .try_if
.stmt_after_if:
    ; try for
    mov r13, 3
    call expect_id_for
    test rax, rax
    jz .stmt_after_for
    jmp .try_for
.stmt_after_for:
    ; try break
    mov r13, 5
    call expect_id_break
    test rax, rax
    jz .stmt_after_break
    jmp .try_break
.stmt_after_break:
    ; try continue
    mov r13, 8
    call expect_id_continue
    test rax, rax
    jz .stmt_after_continue
    jmp .try_continue
.stmt_after_continue:
    ; try print
    mov r13, 5
    call expect_id_print
    test rax, rax
    jz .try_ret
    ; user-defined print() shadows builtin print: route to function call
    lea rdi, [rel tmp_name]
    mov dword [rdi], 0x6E697270
    mov byte [rdi+4], 't'
    mov byte [rdi+5], 0
    call find_func
    cmp r15, -1
    jne .print_user_call
    call ws_skip
    mov dil, '('
    call expect_char
    test rax, rax
    jz .fail
    call ws_skip
    cmp byte [rsi], '"'
    je .str_arg
    cmp byte [rsi], 39
    je .char_arg
    cmp byte [rsi], '*'
    je .deref_arg
    movzx eax, byte [rsi]
    cmp eax, 't'
    je .tf_arg_try
    cmp eax, 'f'
    jne .digit_arg_check
.tf_arg_try:
    ; true/false literal probe (parse_num advances rsi only on match)
    mov r14, rsi
    call parse_num
    cmp rsi, r14
    je .ident_arg
    mov r12, rax
    mov r13, rsi
    mov rax, [rel strpool_len]
    mov rcx, rax
    lea rbx, [rel strpool]
    add rbx, rax
    jmp .num_copy
.digit_arg_check:
    cmp eax, '0'
    jb .ident_arg
    cmp eax, '9'
    ja .ident_arg
    jmp .num_arg
.deref_arg:
    ; print(*p) : print value at address held by ptr p (type39)
    inc rsi
    call ws_skip
    call parse_name
    test rax, rax
    jz .fail
    call is_keyword
    test rax, rax
    jnz .fail
    call find_var
    cmp r15, -1
    je .fail
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    cmp qword [rcx+32], 1
    je .fail
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 39
    mov [rbx+8], r15
    jmp .arg_done
.str_arg:
    inc rsi
    mov rax, [rel strpool_len]
    mov rcx, rax
    lea rbx, [rel strpool]
    add rbx, rax
    xor r12d, r12d
.str_loop:
    mov al, [rsi]
    cmp al, '"'
    je .str_done
    cmp al, 0
    je .fail_unterm_str
    cmp al, 10
    je .fail_unterm_str
    cmp al, '\'
    jne .str_esc_plain
    ; escape sequence: \n -> LF(10)
    inc rsi
    mov al, [rsi]
    cmp al, 'n'
    jne .str_esc_other
    mov al, 10
    jmp .str_esc_done
.str_esc_other:
    ; unknown escape: keep backslash and reprocess next char
    mov al, '\'
    dec rsi
.str_esc_done:
    mov [rbx], al
    inc rbx
    inc rsi
    inc r12
    jmp .str_loop
.str_esc_plain:
    mov [rbx], al
    inc rbx
    inc rsi
    inc r12
    jmp .str_loop
.str_done:
    inc rsi
    ; append NUL terminator to strpool (for strlen / cstr safety)
    mov byte [rbx], 0
    inc rbx
    mov rax, [rel strpool_len]
    add rax, r12
    inc rax
    mov [rel strpool_len], rax
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 1
    mov [rbx+8], rcx
    mov [rbx+16], r12
    jmp .arg_done
; char literal: print('x',char)
.char_arg:
    inc rsi
    mov r12b, [rsi]
    cmp r12b, 0
    je .fail_unterm_char
    cmp r12b, 10
    je .fail_unterm_char
    cmp r12b, 39
    je .fail_unterm_char
    mov rax, [rel strpool_len]
    mov rcx, rax
    lea rbx, [rel strpool]
    add rbx, rax
    mov [rbx], r12b
    inc rsi
    cmp byte [rsi], 39
    jne .fail_unterm_char
    inc rsi
    ; append NUL terminator after char literal
    mov byte [rbx+1], 0
    mov rax, [rel strpool_len]
    add rax, 2
    mov [rel strpool_len], rax
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 1
    mov [rbx+8], rcx
    mov qword [rbx+16], 1
    jmp .arg_done
; identifier arg: variable? function call? or bare text (e.g. print(hello,str))
.ident_arg:
    call parse_name
    test rax, rax
    jz .fail
    call is_keyword
    test rax, rax
    jnz .fail
    ; variable in current scope -> print var (type4)
    call find_var
    cmp r15, -1
    je .ident_func
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 4
    mov [rbx+8], r15
    jmp .arg_done
.ident_func:
    ; function call print(func(args)) -> type13
    call find_func
    cmp r15, -1
    je .ident_text
    mov r12, r15
    call ws_skip
    cmp byte [rsi], '('
    jne .ident_text
    inc rsi
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 13
    mov [rbx+8], r12
    mov qword [rbx+16], 0
    inc qword [rel stmts_cnt]
    mov rax, [rel stmts_cnt]
    push rax
    call parse_args
    test rax, rax
    jz .fail
    pop r15
    lea rbx, [rel stmts]
    mov rax, r15
    dec rax
    imul rax, rax, 32
    add rbx, rax
    mov [rbx+24], r14
    dec qword [rel stmts_cnt]
    jmp .arg_done
.ident_text:
    ; copy name text into strpool (e.g. print(hello,str))
    mov rax, [rel strpool_len]
    mov rcx, rax
    lea rbx, [rel strpool]
    add rbx, rax
    lea r15, [rel tmp_name]
    xor r12d, r12d
.text_loop:
    mov al, [r15]
    test al, al
    jz .text_done
    mov [rbx], al
    inc rbx
    inc r15
    inc r12
    cmp r12, 255
    jae .fail
    jmp .text_loop
.text_done:
    mov rax, [rel strpool_len]
    add rax, r12
    mov [rel strpool_len], rax
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 1
    mov [rbx+8], rcx
    mov [rbx+16], r12
    jmp .arg_done
; numeric value: keep qword value ([8]) plus text copy ([24] offset, [16] len) for bigint
.num_arg:
    push rsi
    call parse_num
    mov r12, rax
    pop r14
    mov r13, rsi
    mov rax, [rel strpool_len]
    mov rcx, rax
    lea rbx, [rel strpool]
    add rbx, rax
.num_copy:
    cmp r14, r13
    jae .num_copy_done
    mov al, [r14]
    mov [rbx], al
    inc rbx
    inc r14
    jmp .num_copy
.num_copy_done:
    lea rax, [rel strpool]
    sub rbx, rax
    mov [rel strpool_len], rbx
    mov rax, rbx
    sub rax, rcx
    mov rdx, [rel stmts_cnt]
    lea rdi, [rel stmts]
    imul rdx, rdx, 32
    add rdi, rdx
    mov qword [rdi], 2
    mov [rdi+8], r12
    mov [rdi+16], rax
    mov [rdi+24], rcx
    jmp .arg_done
.arg_done:
    call ws_skip
    mov dil, ','
    call expect_char
    test rax, rax
    jz .no_type
    call ws_skip
    ; type keyword: int / bigint / char / str
    mov r13, 3
    call expect_id
    test rax, rax
    jz .try_bigint
    mov r12, 0
    jmp .type_ok
.try_bigint:
    mov r13, 6
    call expect_id_bigint
    test rax, rax
    jz .try_char
    mov r12, 1
    jmp .type_ok
.try_char:
    mov r13, 4
    call expect_id_char
    test rax, rax
    jz .try_string
    mov r12, 2
    jmp .type_ok
.try_string:
    mov r13, 6
    call expect_id_string
    test rax, rax
    jz .try_bool
    mov r12, 3
    jmp .type_ok
.try_bool:
    mov r13, 4
    call expect_id_bool
    test rax, rax
    jz .try_str
    mov r12, 0
    jmp .type_ok
.try_str:
    mov r13, 3
    call expect_id_str
    test rax, rax
    jnz .str_plain
    ; quoted form: 'int' / 'bigint' / 'char' / 'str' / 'string' / 'bool'
    cmp byte [rsi], 39
    jne .fail
    inc rsi
    mov r13, 3
    call expect_id
    test rax, rax
    jnz .q_int
    mov r13, 6
    call expect_id_bigint
    test rax, rax
    jnz .q_bigint
    mov r13, 4
    call expect_id_char
    test rax, rax
    jnz .q_char
    mov r13, 6
    call expect_id_string
    test rax, rax
    jnz .q_str
    mov r13, 3
    call expect_id_str
    test rax, rax
    jnz .q_str
    mov r13, 4
    call expect_id_bool
    test rax, rax
    jnz .q_bool
    jmp .fail
.q_int:
    mov r12, 0
    jmp .q_close
.q_bigint:
    mov r12, 1
    jmp .q_close
.q_char:
    mov r12, 2
    jmp .q_close
.q_bool:
    mov r12, 0
.q_close:
    cmp byte [rsi], 39
    jne .fail
    inc rsi
    jmp .type_ok
.q_str:
    mov r12, 3
    jmp .q_close
.str_plain:
    mov r12, 3
.type_ok:
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    ; var / call / call-arg output already carries its own type: skip explicit type
    cmp qword [rbx], 4
    je .after_type
    cmp qword [rbx], 13
    je .after_type
    cmp qword [rbx], 12
    je .after_type
    cmp qword [rbx], 39
    je .after_type
    cmp r12, 0
    je .final_int
    cmp r12, 1
    je .final_bigint
    ; char/str: string output; if value was numeric, output its text
    cmp qword [rbx], 2
    jne .final_cs_ok
    mov rax, [rbx+24]
    mov [rbx+8], rax
    mov qword [rbx], 1
.final_cs_ok:
    jmp .after_type
.final_int:
    cmp qword [rbx], 2
    jne .fail
    jmp .after_type
.final_bigint:
    cmp qword [rbx], 2
    jne .fail
    mov rax, [rbx+24]
    mov [rbx+8], rax
    mov qword [rbx], 1
.after_type:
    inc qword [rel stmts_cnt]
    jmp .type_done
.no_type:
    inc qword [rel stmts_cnt]
.type_done:
    call ws_skip
    mov dil, ')'
    call expect_char
    test rax, rax
    jz .fail
    call opt_semi
    test rax, rax
    jz .fail
    jmp .stmt
.stmt_brk:
    cmp qword [rel blk_depth], 0
    jne .stmt_blk_close
    jmp .body_brk
.stmt_blk_close:
    mov rax, [rel blk_depth]
    dec rax
    imul rax, rax, 16
    lea rbx, [rel blk_stack]
    add rbx, rax
    cmp qword [rbx], 42
    je .stmt_if_close_try
    cmp qword [rbx], 47
    je .stmt_for_close
    ; ---- while block ----
    mov r13, [rbx+8]
    inc rsi
    lea rcx, [rel stmts]
    mov rax, [rel stmts_cnt]
    imul rax, rax, 32
    add rcx, rax
    mov qword [rcx], 41
    mov [rcx+8], r13
    inc qword [rel stmts_cnt]
    dec qword [rel blk_depth]
    jmp .stmt
.stmt_if_close_try:
    ; if block: peek whether next token after '}' is 'else' -> keep block open
    mov r14, rsi
    inc rsi
    call ws_skip
    mov eax, [rsi]
    cmp eax, 0x65736C65
    jne .stmt_if_close
    jmp .stmt
.stmt_if_close:
    mov rsi, r14
    mov r13, [rbx+8]
    inc rsi
    lea rcx, [rel stmts]
    mov rax, [rel stmts_cnt]
    imul rax, rax, 32
    add rcx, rax
    mov qword [rcx], 43
    mov [rcx+8], r13
    inc qword [rel stmts_cnt]
    dec qword [rel blk_depth]
    jmp .stmt
; ---- for block close: emit .WC label, step stmt, then loop end ----
.stmt_for_close:
    mov r13, [rbx+8]                 ; while stmt idx of this for
    mov rax, [rel blk_depth]
    dec rax
    imul rax, rax, 8
    lea rbx, [rel for_step_var]
    add rbx, rax
    mov rdx, [rbx]
    mov [rel for_st_var], rdx
    lea rbx, [rel for_step_op]
    add rbx, rax
    mov rdx, [rbx]
    mov [rel for_st_op], rdx
    lea rbx, [rel for_step_val]
    add rbx, rax
    mov rdx, [rbx]
    mov [rel for_st_val], rdx
    inc rsi                          ; skip '}'
    ; 1) continue target label marker (type 48)
    lea rcx, [rel stmts]
    mov rax, [rel stmts_cnt]
    imul rax, rax, 32
    add rcx, rax
    mov qword [rcx], 48
    mov [rcx+8], r13
    mov qword [rcx+16], 0
    mov qword [rcx+24], 0
    inc qword [rel stmts_cnt]
    ; 2) step stmt: type = 14 + op*2 + 1  (op 0=+ 1=-), [8]=dst var, [16]=src var, [24]=const
    lea rcx, [rel stmts]
    mov rax, [rel stmts_cnt]
    imul rax, rax, 32
    add rcx, rax
    mov rax, 15
    cmp qword [rel for_st_op], 0
    je .sfc_type_ok
    mov rax, 17
.sfc_type_ok:
    mov [rcx], rax
    mov rax, [rel for_st_var]
    mov [rcx+8], rax
    mov [rcx+16], rax
    mov rax, [rel for_st_val]
    mov [rcx+24], rax
    inc qword [rel stmts_cnt]
    ; 3) loop end stmt (type 41) -> jmp .W / .WE:
    lea rcx, [rel stmts]
    mov rax, [rel stmts_cnt]
    imul rax, rax, 32
    add rcx, rax
    mov qword [rcx], 41
    mov [rcx+8], r13
    inc qword [rel stmts_cnt]
    dec qword [rel blk_depth]
    jmp .stmt
; ---- break / continue: find nearest enclosing loop frame ----
.find_loop_frame:
    ; -> rax = loop opener stmt idx (-1 if none), rdx = 1 if for else 0
    mov rcx, [rel blk_depth]
    test rcx, rcx
    jz .flf_fail
.flf_scan:
    dec rcx
    mov rax, rcx
    imul rax, rax, 16
    lea rbx, [rel blk_stack]
    add rbx, rax
    mov rax, [rbx]
    cmp rax, 40
    je .flf_while
    cmp rax, 47
    je .flf_for
    test rcx, rcx
    jz .flf_fail
    jmp .flf_scan
.flf_while:
    mov rax, [rbx+8]
    xor edx, edx
    ret
.flf_for:
    mov rax, [rbx+8]
    mov rdx, 1
    ret
.flf_fail:
    mov rax, -1
    xor edx, edx
    ret
.try_break:
    call .find_loop_frame
    cmp rax, -1
    je .fail
    mov [rel tb_target], rax
    call ws_skip
    cmp byte [rsi], ';'
    jne .tbk_nosemi
    inc rsi
.tbk_nosemi:
    lea rcx, [rel stmts]
    mov rax, [rel stmts_cnt]
    imul rax, rax, 32
    add rcx, rax
    mov qword [rcx], 45
    mov rax, [rel tb_target]
    mov [rcx+8], rax
    mov qword [rcx+16], 0
    mov qword [rcx+24], 0
    inc qword [rel stmts_cnt]
    jmp .stmt
.try_continue:
    call .find_loop_frame
    cmp rax, -1
    je .fail
    mov [rel tb_target], rax
    mov [rel for_rhs_tmp], rdx       ; 1 = for (jump to .WC), 0 = while (jump to .W)
    call ws_skip
    cmp byte [rsi], ';'
    jne .tcn_nosemi
    inc rsi
.tcn_nosemi:
    lea rcx, [rel stmts]
    mov rax, [rel stmts_cnt]
    imul rax, rax, 32
    add rcx, rax
    mov qword [rcx], 46
    mov rax, [rel tb_target]
    mov [rcx+8], rax
    mov rax, [rel for_rhs_tmp]
    mov [rcx+16], rax
    mov qword [rcx+24], 0
    inc qword [rel stmts_cnt]
    jmp .stmt
; ---- for ( ... ) { ... }   /   for (k in range(a, b)) { ... } ----
.try_for:
    call ws_skip
    mov dil, '('
    call expect_char
    test rax, rax
    jz .fail
    call ws_skip
    mov [rel for_save_rsi], rsi
    ; ---- probe for-in form: name in range(a, b) ----
    call parse_name
    test rax, rax
    jz .for_cstyle
    call is_keyword
    test rax, rax
    jnz .for_cstyle
    call ws_skip
    cmp byte [rsi], 'i'
    jne .for_cstyle
    cmp byte [rsi+1], 'n'
    jne .for_cstyle
    mov al, [rsi+2]
    cmp al, ' '
    je .for_in_hit
    cmp al, 9
    je .for_in_hit
    cmp al, 'r'
    je .for_in_hit
    jmp .for_cstyle
.for_in_hit:
    ; loop variable name still in tmp_name
    call find_var
    cmp r15, -1
    jne .for_in_var_ok
    mov r13, 1
    xor r14d, r14d
    call add_var
    test rax, rax
    jz .fail
.for_in_var_ok:
    mov [rel for_var_idx], r15
    add rsi, 2                       ; skip 'in'
    call ws_skip
    cmp dword [rsi], 0x676E6172      ; 'rang'
    jne .fail
    cmp byte [rsi+4], 'e'
    jne .fail
    add rsi, 5
    call ws_skip
    mov dil, '('
    call expect_char
    test rax, rax
    jz .fail
    call ws_skip
    call is_digit_here
    test rax, rax
    jz .fail
    call parse_num
    mov [rel for_init_val], rax
    mov qword [rel for_init_kind], 1
    call ws_skip
    mov dil, ','
    call expect_char
    test rax, rax
    jz .fail
    call ws_skip
    call is_digit_here
    test rax, rax
    jz .fail
    call parse_num
    mov [rel wh_rhs_val], rax
    mov qword [rel wh_rhs_kind], 1
    call ws_skip
    mov dil, ')'
    call expect_char
    test rax, rax
    jz .fail
    ; close for's own ')'
    call ws_skip
    mov dil, ')'
    call expect_char
    test rax, rax
    jz .fail
    ; condition: var < end
    mov rax, [rel for_var_idx]
    mov [rel wh_lhs_var], rax
    mov qword [rel wh_op], 3
    ; step: +1
    mov rax, [rel for_var_idx]
    mov [rel for_st_var], rax
    mov qword [rel for_st_op], 0
    mov qword [rel for_st_val], 1
    call ws_skip
    mov dil, '{'
    call expect_char
    test rax, rax
    jz .fail
    jmp .for_emit
; ---- C-style for (init; cond; step) ----
.for_cstyle:
    mov rsi, [rel for_save_rsi]
    push rsi
    mov r13, 3
    call expect_id
    test rax, rax
    jz .for_c_noprefix
    pop rax                          ; keep advanced rsi
    mov qword [rel for_decl_flag], 1
    jmp .for_c_name
.for_c_noprefix:
    pop rsi
    mov qword [rel for_decl_flag], 0
.for_c_name:
    call ws_skip
    call parse_name
    test rax, rax
    jz .fail
    call is_keyword
    test rax, rax
    jnz .fail
    ; backup name
    push rsi
    lea rdi, [rel tmp_name_bak]
    lea rsi, [rel tmp_name]
.fc_bak:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .fc_bak
    pop rsi
    call ws_skip
    cmp byte [rsi], '='
    jne .fail
    inc rsi
    call ws_skip
    call is_digit_here
    test rax, rax
    jz .fc_rhs_var
    call parse_num
    mov [rel for_init_val], rax
    mov qword [rel for_init_kind], 1
    jmp .fc_rhs_done
.fc_rhs_var:
    call parse_name
    test rax, rax
    jz .fail
    call find_var
    cmp r15, -1
    je .fail
    mov [rel for_init_val], r15
    mov qword [rel for_init_kind], 2
.fc_rhs_done:
    ; restore var name
    push rsi
    lea rdi, [rel tmp_name]
    lea rsi, [rel tmp_name_bak]
.fc_rest:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .fc_rest
    pop rsi
    ; register loop variable
    call find_var
    cmp r15, -1
    jne .fc_have_var
    mov r13, 1
    xor r14d, r14d
    call add_var
    test rax, rax
    jz .fail
.fc_have_var:
    mov [rel for_var_idx], r15
    ; ---- condition ----
    call ws_skip
    cmp byte [rsi], ';'
    jne .fail
    inc rsi
    call ws_skip
    call parse_name
    test rax, rax
    jz .fail
    call is_keyword
    test rax, rax
    jnz .fail
    call find_var
    cmp r15, -1
    je .fail
    mov [rel wh_lhs_var], r15
    mov qword [rel wh_op], 1
    call ws_skip
    movzx eax, byte [rsi]
    cmp al, '>'
    je .fc_op_gt
    cmp al, '<'
    je .fc_op_lt
    cmp al, '='
    je .fc_op_eq
    cmp al, '!'
    je .fc_op_ne
    jmp .fail
.fc_op_gt:
    inc rsi
    mov qword [rel wh_op], 2
    jmp .fc_cond_rhs
.fc_op_lt:
    inc rsi
    mov qword [rel wh_op], 3
    jmp .fc_cond_rhs
.fc_op_eq:
    inc rsi
    cmp byte [rsi], '='
    jne .fail
    inc rsi
    mov qword [rel wh_op], 6
    jmp .fc_cond_rhs
.fc_op_ne:
    inc rsi
    cmp byte [rsi], '='
    jne .fail
    inc rsi
    mov qword [rel wh_op], 7
.fc_cond_rhs:
    call ws_skip
    call is_digit_here
    test rax, rax
    jz .fc_cond_var
    call parse_num
    mov [rel wh_rhs_val], rax
    mov qword [rel wh_rhs_kind], 1
    jmp .fc_cond_done
.fc_cond_var:
    call parse_name
    test rax, rax
    jz .fail
    call is_keyword
    test rax, rax
    jnz .fail
    call find_var
    cmp r15, -1
    je .fail
    mov [rel wh_rhs_val], r15
    mov qword [rel wh_rhs_kind], 2
.fc_cond_done:
    call ws_skip
    cmp byte [rsi], ';'
    jne .fail
    inc rsi
    ; ---- step ----
    call ws_skip
    call parse_name
    test rax, rax
    jz .fail
    call is_keyword
    test rax, rax
    jnz .fail
    call find_var
    cmp r15, -1
    je .fail
    mov [rel for_st_var], r15
    call ws_skip
    cmp byte [rsi], '+'
    je .fc_step_pp
    cmp byte [rsi], '-'
    je .fc_step_mm
    cmp byte [rsi], '='
    jne .fail
    inc rsi
    call ws_skip
    call parse_name
    test rax, rax
    jz .fail
    call is_keyword
    test rax, rax
    jnz .fail
    call find_var
    cmp r15, -1
    je .fail
    cmp r15, [rel for_st_var]
    jne .fail
    call ws_skip
    cmp byte [rsi], '+'
    je .fc_step_add
    cmp byte [rsi], '-'
    jne .fail
    mov qword [rel for_st_op], 1
    inc rsi
    jmp .fc_step_const
.fc_step_add:
    mov qword [rel for_st_op], 0
    inc rsi
.fc_step_const:
    call ws_skip
    call is_digit_here
    test rax, rax
    jz .fail
    call parse_num
    mov [rel for_st_val], rax
    jmp .fc_step_done
.fc_step_pp:
    inc rsi
    cmp byte [rsi], '+'
    jne .fail
    inc rsi
    mov qword [rel for_st_op], 0
    mov qword [rel for_st_val], 1
    jmp .fc_step_done
.fc_step_mm:
    inc rsi
    cmp byte [rsi], '-'
    jne .fail
    inc rsi
    mov qword [rel for_st_op], 1
    mov qword [rel for_st_val], 1
.fc_step_done:
    call ws_skip
    mov dil, ')'
    call expect_char
    test rax, rax
    jz .fail
    call ws_skip
    mov dil, '{'
    call expect_char
    test rax, rax
    jz .fail
; ---- shared: emit init stmt + while header + push for frame ----
.for_emit:
    ; init assignment stmt
    lea rcx, [rel stmts]
    mov rax, [rel stmts_cnt]
    imul rax, rax, 32
    add rcx, rax
    mov rax, 5
    cmp qword [rel for_init_kind], 2
    jne .for_emit_type
    mov rax, 7
.for_emit_type:
    mov [rcx], rax
    mov rax, [rel for_var_idx]
    mov [rcx+8], rax
    mov qword [rcx+16], 0
    mov rax, [rel for_init_val]
    mov [rcx+24], rax
    inc qword [rel stmts_cnt]
    ; while header stmt (type 40)
    lea rcx, [rel stmts]
    mov rax, [rel stmts_cnt]
    imul rax, rax, 32
    add rcx, rax
    mov qword [rcx], 40
    mov rax, [rel wh_op]
    mov [rcx+8], rax
    mov rax, [rel wh_lhs_var]
    mov [rcx+16], rax
    mov rax, [rel wh_rhs_kind]
    mov [rcx+24], rax
    inc qword [rel stmts_cnt]
    ; while_meta
    mov rax, [rel stmts_cnt]
    dec rax
    imul rax, rax, 16
    lea rbx, [rel while_meta]
    add rbx, rax
    mov rdx, [rel wh_op]
    mov [rbx], rdx
    mov rdx, [rel wh_rhs_val]
    mov [rbx+8], rdx
    inc qword [rel w_depth]
    ; push block frame (type 47 = for)
    mov rax, [rel stmts_cnt]
    dec rax
    mov rdx, rax
    mov rax, [rel blk_depth]
    imul rax, rax, 16
    lea rbx, [rel blk_stack]
    add rbx, rax
    mov qword [rbx], 47
    mov [rbx+8], rdx
    inc qword [rel blk_depth]
    ; save step at frame index (blk_depth-1)
    mov rax, [rel blk_depth]
    dec rax
    imul rax, rax, 8
    lea rbx, [rel for_step_var]
    add rbx, rax
    mov rdx, [rel for_st_var]
    mov [rbx], rdx
    lea rbx, [rel for_step_op]
    add rbx, rax
    mov rdx, [rel for_st_op]
    mov [rbx], rdx
    lea rbx, [rel for_step_val]
    add rbx, rax
    mov rdx, [rel for_st_val]
    mov [rbx], rdx
    jmp .stmt
.try_while:
    call ws_skip
    mov dil, '('
    call expect_char
    test rax, rax
    jz .fail
    call ws_skip
    ; LHS must be a declared var
    call parse_name
    test rax, rax
    jz .fail
    call is_keyword
    test rax, rax
    jnz .fail
    call find_var
    cmp r15, -1
    je .fail
    mov [rel wh_lhs_var], r15
    mov qword [rel wh_op], 1
    call ws_skip
    movzx eax, byte [rsi]
    cmp al, '>'
    je .tw_op_gt
    cmp al, '<'
    je .tw_op_lt
    cmp al, '='
    je .tw_op_eq
    cmp al, '!'
    je .tw_op_ne
    jmp .tw_cond_ready
.tw_op_gt:
    inc rsi
    mov qword [rel wh_op], 2
    jmp .tw_parse_rhs
.tw_op_lt:
    inc rsi
    mov qword [rel wh_op], 3
    jmp .tw_parse_rhs
.tw_op_eq:
    inc rsi
    movzx eax, byte [rsi]
    cmp al, '='
    jne .fail
    inc rsi
    mov qword [rel wh_op], 6
    jmp .tw_parse_rhs
.tw_op_ne:
    inc rsi
    movzx eax, byte [rsi]
    cmp al, '='
    jne .fail
    inc rsi
    mov qword [rel wh_op], 7
    jmp .tw_parse_rhs
.tw_parse_rhs:
    call ws_skip
    movzx eax, byte [rsi]
    cmp al, '0'
    jb .tw_rhs_ident
    cmp al, '9'
    ja .tw_rhs_ident
    call parse_num
    mov [rel wh_rhs_val], rax
    mov qword [rel wh_rhs_kind], 1
    jmp .tw_cond_ready
.tw_rhs_ident:
    call parse_name
    test rax, rax
    jz .fail
    call is_keyword
    test rax, rax
    jnz .fail
    call find_var
    cmp r15, -1
    je .fail
    mov [rel wh_rhs_val], r15
    mov qword [rel wh_rhs_kind], 2
.tw_cond_ready:
    call ws_skip
    mov dil, ')'
    call expect_char
    test rax, rax
    jz .fail
    call ws_skip
    mov dil, '{'
    call expect_char
    test rax, rax
    jz .fail
    ; record while stmt: type 40, [8]=op, [16]=lhs var idx, [24]=rhs kind
    lea rcx, [rel stmts]
    mov rax, [rel stmts_cnt]
    imul rax, rax, 32
    add rcx, rax
    mov qword [rcx], 40
    mov rax, [rel wh_op]
    mov [rcx+8], rax
    mov rax, [rel wh_lhs_var]
    mov [rcx+16], rax
    mov rax, [rel wh_rhs_kind]
    mov [rcx+24], rax
    inc qword [rel stmts_cnt]
    ; rhs const/var value: stash into while_meta[idx] for emit phase
    mov rax, [rel stmts_cnt]
    dec rax
    imul rax, rax, 16
    lea rbx, [rel while_meta]
    add rbx, rax
    mov rdx, [rel wh_op]
    mov [rbx], rdx
    mov rdx, [rel wh_rhs_val]
    mov [rbx+8], rdx
    inc qword [rel w_depth]
    ; push block frame (type 40 = while)
    mov rax, [rel stmts_cnt]
    dec rax
    mov rdx, rax
    mov rax, [rel blk_depth]
    imul rax, rax, 16
    lea rbx, [rel blk_stack]
    add rbx, rax
    mov qword [rbx], 40
    mov [rbx+8], rdx
    inc qword [rel blk_depth]
    jmp .stmt
; ---- if (cond) { ... } ----
.try_if:
    call ws_skip
    mov dil, '('
    call expect_char
    test rax, rax
    jz .fail
    call ws_skip
    call parse_name
    test rax, rax
    jz .fail
    call is_keyword
    test rax, rax
    jnz .fail
    call find_var
    cmp r15, -1
    je .fail
    mov [rel wh_lhs_var], r15
    mov qword [rel wh_op], 1
    call ws_skip
    movzx eax, byte [rsi]
    cmp al, '>'
    je .ti_op_gt
    cmp al, '<'
    je .ti_op_lt
    cmp al, '='
    je .ti_op_eq
    cmp al, '!'
    je .ti_op_ne
    jmp .ti_cond_ready
.ti_op_gt:
    inc rsi
    mov qword [rel wh_op], 2
    jmp .ti_parse_rhs
.ti_op_lt:
    inc rsi
    mov qword [rel wh_op], 3
    jmp .ti_parse_rhs
.ti_op_eq:
    inc rsi
    movzx eax, byte [rsi]
    cmp al, '='
    jne .fail
    inc rsi
    mov qword [rel wh_op], 6
    jmp .ti_parse_rhs
.ti_op_ne:
    inc rsi
    movzx eax, byte [rsi]
    cmp al, '='
    jne .fail
    inc rsi
    mov qword [rel wh_op], 7
    jmp .ti_parse_rhs
.ti_parse_rhs:
    call ws_skip
    movzx eax, byte [rsi]
    cmp al, '0'
    jb .ti_rhs_ident
    cmp al, '9'
    ja .ti_rhs_ident
    call parse_num
    mov [rel wh_rhs_val], rax
    mov qword [rel wh_rhs_kind], 1
    jmp .ti_cond_ready
.ti_rhs_ident:
    call parse_name
    test rax, rax
    jz .fail
    call is_keyword
    test rax, rax
    jnz .fail
    call find_var
    cmp r15, -1
    je .fail
    mov [rel wh_rhs_val], r15
    mov qword [rel wh_rhs_kind], 2
.ti_cond_ready:
    call ws_skip
    mov dil, ')'
    call expect_char
    test rax, rax
    jz .fail
    call ws_skip
    mov dil, '{'
    call expect_char
    test rax, rax
    jz .fail
    ; record if stmt: type 42, [8]=op, [16]=lhs var idx, [24]=rhs kind
    lea rcx, [rel stmts]
    mov rax, [rel stmts_cnt]
    imul rax, rax, 32
    add rcx, rax
    mov qword [rcx], 42
    mov rax, [rel wh_op]
    mov [rcx+8], rax
    mov rax, [rel wh_lhs_var]
    mov [rcx+16], rax
    mov rax, [rel wh_rhs_kind]
    mov [rcx+24], rax
    inc qword [rel stmts_cnt]
    ; stash rhs value into while_meta (shared array)
    mov rax, [rel stmts_cnt]
    dec rax
    imul rax, rax, 16
    lea rbx, [rel while_meta]
    add rbx, rax
    mov rdx, [rel wh_rhs_val]
    mov [rbx+8], rdx
    ; push block frame (type 42 = if)
    mov rax, [rel stmts_cnt]
    dec rax
    mov rdx, rax
    mov rax, [rel blk_depth]
    imul rax, rax, 16
    lea rbx, [rel blk_stack]
    add rbx, rax
    mov qword [rbx], 42
    mov [rbx+8], rdx
    inc qword [rel blk_depth]
    jmp .stmt
; ---- else { ... } ----
.try_else:
    cmp qword [rel blk_depth], 0
    je .fail
    mov rax, [rel blk_depth]
    dec rax
    imul rax, rax, 16
    lea rbx, [rel blk_stack]
    add rbx, rax
    cmp qword [rbx], 42
    jne .fail
    mov r13, [rbx+8]
    call ws_skip
    mov dil, '{'
    call expect_char
    test rax, rax
    jz .fail
    lea rcx, [rel stmts]
    mov rax, [rel stmts_cnt]
    imul rax, rax, 32
    add rcx, rax
    mov qword [rcx], 44
    mov [rcx+8], r13
    inc qword [rel stmts_cnt]
    jmp .stmt
.try_ret:
    mov r13, 3
    call expect_id_ret
    test rax, rax
    jz parse_prog.try_type_decl
    call ws_skip
    cmp byte [rsi], '"'
    je .ret_str
    cmp byte [rsi], 39
    je .ret_str
    movzx eax, byte [rsi]
    cmp eax, '0'
    jb .ret_ident
    cmp eax, '9'
    ja .ret_ident
    call parse_num
    mov [rel ret_lval], rax
    mov qword [rel ret_lkind], 0
    call set_ret_type_num
    jmp .ret_end
.ret_ident:
    call parse_name
    test rax, rax
    jz .fail
    call find_var
    cmp r15, -1
    je .fail
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    mov r12, [rcx+32]
    cmp r12, 1
    je .ret_ident_str
    mov [rel ret_lval], r15
    mov qword [rel ret_lkind], 2
    call set_ret_type_num
    jmp .ret_end
.ret_ident_str:
    cmp qword [rel cur_func], -1
    je .fail
    mov [rel ret_lval], r15
    mov qword [rel ret_lkind], 3
    call set_ret_type_str
    jmp .ret_end
.ret_str:
    inc rsi
    mov rax, [rel strpool_len]
    mov r15, rax
    lea rbx, [rel strpool]
    add rbx, rax
    xor r12d, r12d
.ret_str_loop:
    mov al, [rsi]
    cmp al, '"'
    je .ret_str_done
    cmp al, 39
    je .ret_str_done
    cmp al, 0
    je .fail_unterm_str
    cmp al, 10
    je .fail_unterm_str
    mov [rbx], al
    inc rbx
    inc rsi
    inc r12
    cmp r12, 255
    jae .fail
    jmp .ret_str_loop
.ret_str_done:
    inc rsi
    mov rax, [rel strpool_len]
    add rax, r12
    mov [rel strpool_len], rax
    cmp qword [rel cur_func], -1
    je .fail
    mov [rel ret_lval], r15
    mov qword [rel ret_lkind], 1
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 3
    mov [rbx+8], r15
    mov qword [rbx+16], 1
    mov [rbx+24], r12
    call set_ret_type_str
.ret_end:
    call ws_skip
    mov al, [rsi]
    cmp al, '+'
    je .ret_op_plus
    cmp al, '-'
    je .ret_op_minus
    cmp al, '*'
    je .ret_op_mul
    cmp al, '/'
    je .ret_op_div
    cmp al, '%'
    je .ret_op_mod
    jmp .ret_plain
.ret_op_plus:
    mov qword [rel cur_op], 0
    jmp .ret_expr_check
.ret_op_minus:
    mov qword [rel cur_op], 1
    jmp .ret_expr_check
.ret_op_mul:
    mov qword [rel cur_op], 2
    jmp .ret_expr_check
.ret_op_div:
    mov qword [rel cur_op], 3
    jmp .ret_expr_check
.ret_op_mod:
    mov qword [rel cur_op], 4
.ret_expr_check:
    mov rax, [rel ret_lkind]
    cmp rax, 0
    je .ret_expr_go
    cmp rax, 2
    je .ret_expr_go
    jmp .fail
.ret_expr_go:
    inc rsi
    call ws_skip
    movzx eax, byte [rsi]
    cmp eax, '0'
    jb .rg_rhs_var
    cmp eax, '9'
    ja .rg_rhs_var
    call parse_num
    mov r14, rax
    mov r12, 0
    mov rax, [rel cur_op]
    imul rax, rax, 2
    add rax, 5
    jmp .rg_subtype
.rg_rhs_var:
    call parse_name
    test rax, rax
    jz .fail
    call find_var
    cmp r15, -1
    je .fail
    mov r14, r15
    mov r12, 1
    mov rax, [rel cur_op]
    imul rax, rax, 2
    add rax, 4
.rg_subtype:
    ; ????????ret_lkind??=???(?????-13????=???(?????4-23??
    cmp qword [rel ret_lkind], 2
    je .rg_subtype_ok
    add rax, 10
.rg_subtype_ok:
    mov r13, rax
    ; ????????ws_skip ??????????????
    call ws_skip
    mov al, [rsi]
    cmp al, '+'
    je .rg_chain
    cmp al, '-'
    je .rg_chain
    cmp al, '*'
    je .rg_chain
    cmp al, '/'
    je .rg_chain
    cmp al, '%'
    je .rg_chain
    ; ---- ????????ret stmt ?????----
    lea rcx, [rel stmts]
    mov rax, [rel stmts_cnt]
    imul rax, rax, 32
    add rcx, rax
    mov qword [rcx], 3
    mov rax, [rel ret_lval]
    mov [rcx+8], rax
    mov [rcx+16], r13
    mov [rcx+24], r14
    call opt_semi
    test rax, rax
    jz .fail
    inc qword [rel stmts_cnt]
    jmp .stmt
.rg_chain:
    ; ---- ????????assign_expr stmt ----
    ; ???: [rcx]=type(14-33), [rcx+8]=???tmp, [rcx+16]=?? [rcx+24]=??
    ; type = (??ar?14:24) + cur_op*2 + (??onst?1:0)
    lea rcx, [rel stmts]
    mov rax, [rel stmts_cnt]
    imul rax, rax, 32
    add rcx, rax
    mov rax, [rel cur_op]
    imul rax, rax, 2
    cmp qword [rel ret_lkind], 2
    je .rg_left_var
    add rax, 24
    jmp .rg_type_done
.rg_left_var:
    add rax, 14
.rg_type_done:
    test r12, r12
    jnz .rg_rhs_is_var
    inc rax
.rg_rhs_is_var:
    mov [rcx], rax
    ; ????????? -> r15=idx
    call alloc_tmp_num
    test rax, rax
    jz .fail
    mov [rcx+8], r15
    mov rax, [rel ret_lval]
    mov [rcx+16], rax
    mov [rcx+24], r14
    inc qword [rel stmts_cnt]
    ; ????????????
    mov [rel ret_lval], r15
    mov qword [rel ret_lkind], 2
    ; ???????????si ???????????????
    mov al, [rsi]
    cmp al, '+'
    je .rg_op_plus
    cmp al, '-'
    je .rg_op_minus
    cmp al, '*'
    je .rg_op_mul
    cmp al, '/'
    je .rg_op_div
    mov qword [rel cur_op], 4
    jmp .ret_expr_go
.rg_op_plus:
    mov qword [rel cur_op], 0
    jmp .ret_expr_go
.rg_op_minus:
    mov qword [rel cur_op], 1
    jmp .ret_expr_go
.rg_op_mul:
    mov qword [rel cur_op], 2
    jmp .ret_expr_go
.rg_op_div:
    mov qword [rel cur_op], 3
    jmp .ret_expr_go
.ret_plain:
    ; ?????ret ??? .ret_str ??? stmt????????um ?????? stmt
    cmp qword [rel ret_lkind], 1
    je .rp_done
    lea rcx, [rel stmts]
    mov rax, [rel stmts_cnt]
    imul rax, rax, 32
    add rcx, rax
    mov qword [rcx], 3
    mov rax, [rel ret_lval]
    mov [rcx+8], rax
    mov rax, [rel ret_lkind]
    mov [rcx+16], rax
.rp_done:
    call opt_semi
    test rax, rax
    jz .fail
    inc qword [rel stmts_cnt]
    jmp .stmt

; *p = ... : deref store (LHS must be a num/ptr variable holding an address)
.assign_deref_lhs:
    inc rsi
    call ws_skip
    call parse_name
    test rax, rax
    jz .fail
    call is_keyword
    test rax, rax
    jnz .fail
    call find_var
    cmp r15, -1
    je .fail
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    cmp qword [rcx+32], 1
    je .fail
    mov r12, r15
    call ws_skip
    mov dil, '='
    call expect_char
    test rax, rax
    jz .fail
    call ws_skip
    cmp byte [rsi], '"'
    je .fail
    cmp byte [rsi], 39
    je .fail
    cmp byte [rsi], '&'
    je .fail
    cmp byte [rsi], '*'
    je .ds_deref
    movzx eax, byte [rsi]
    cmp eax, '0'
    jb .ds_var
    cmp eax, '9'
    ja .ds_var
    call parse_num
    mov r13, rax
    call ws_skip_inline
    movzx eax, byte [rsi]
    cmp eax, '+'
    je .fail
    cmp eax, '-'
    je .fail
    cmp eax, '*'
    je .fail
    cmp eax, '/'
    je .fail
    cmp eax, '%'
    je .fail
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 35
    mov [rbx+8], r12
    mov [rbx+24], r13
    jmp .stmt_done
.ds_var:
    call parse_name
    test rax, rax
    jz .fail
    call find_var
    cmp r15, -1
    je .fail
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    cmp qword [rcx+32], 1
    je .fail
    mov r13, r15
    call ws_skip
    movzx eax, byte [rsi]
    cmp eax, '+'
    je .fail
    cmp eax, '-'
    je .fail
    cmp eax, '*'
    je .fail
    cmp eax, '/'
    je .fail
    cmp eax, '%'
    je .fail
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 36
    mov [rbx+8], r12
    mov [rbx+16], r13
    jmp .stmt_done
.ds_deref:
    inc rsi
    call ws_skip
    call parse_name
    test rax, rax
    jz .fail
    call find_var
    cmp r15, -1
    je .fail
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    cmp qword [rcx+32], 1
    je .fail
    mov r13, r15
    call ws_skip
    movzx eax, byte [rsi]
    cmp eax, '+'
    je .fail
    cmp eax, '-'
    je .fail
    cmp eax, '*'
    je .fail
    cmp eax, '/'
    je .fail
    cmp eax, '%'
    je .fail
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 37
    mov [rbx+8], r12
    mov [rbx+16], r13
    jmp .stmt_done

; ---- type declaration statement: int/string/char/bigint/bool x [= init] ----
.try_type_decl:
    push rsi
    mov r13, 3
    call expect_id
    test rax, rax
    jz .ttd_try_str
    pop rax
    mov r12, 0
    jmp .ttd_have_type
.ttd_try_str:
    pop rsi
    push rsi
    mov r13, 3
    call expect_id_str
    test rax, rax
    jz .ttd_try_string
    pop rax
    mov r12, 1
    jmp .ttd_have_type
.ttd_try_string:
    pop rsi
    push rsi
    mov r13, 6
    call expect_id_string
    test rax, rax
    jz .ttd_try_char
    pop rax
    mov r12, 1
    jmp .ttd_have_type
.ttd_try_char:
    pop rsi
    push rsi
    mov r13, 4
    call expect_id_char
    test rax, rax
    jz .ttd_try_bigint
    pop rax
    mov r12, 1
    jmp .ttd_have_type
.ttd_try_bigint:
    pop rsi
    push rsi
    mov r13, 6
    call expect_id_bigint
    test rax, rax
    jz .ttd_try_bool
    pop rax
    mov r12, 0
    jmp .ttd_have_type
.ttd_try_bool:
    pop rsi
    push rsi
    mov r13, 4
    call expect_id_bool
    test rax, rax
    jz .ttd_none
    pop rax
    mov r12, 0
.ttd_have_type:
    ; r12 = declared type (0=num, 1=str) -- save immediately, parse_name may clobber r12
    mov [rel decl_type], r12
    call ws_skip
    call parse_name
    test rax, rax
    jz .fail
    call is_keyword
    test rax, rax
    jnz .fail
    ; backup lhs name (RHS parsing may clobber tmp_name)
    push rsi
    lea rdi, [rel tmp_name_bak]
    lea rsi, [rel tmp_name]
.ttd_bak_loop:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ttd_bak_loop
    pop rsi
    call ws_skip
    cmp byte [rsi], '='
    jne .ttd_decl_only
    inc rsi
    ; initialized decl: force new var + type check via assign_prep
    mov r14, -1
    jmp .assign_rhs
.ttd_decl_only:
    ; plain declaration: register var, no runtime stmt
    mov r13, 1
    mov r14, [rel decl_type]
    call add_var
    test rax, rax
    jz .fail
    mov qword [rel decl_type], -1
    jmp .stmt_done
.ttd_none:
    pop rsi
    jmp parse_prog.try_assign

; ---- assignment / function call statement ----
.try_assign:
    cmp byte [rsi], '*'
    je .assign_deref_lhs
    call parse_name
    test rax, rax
    jz .fail
    call is_keyword
    test rax, rax
    jnz .fail
    ; backup lhs name (RHS parsing may clobber tmp_name)
    push rsi
    lea rdi, [rel tmp_name_bak]
    lea rsi, [rel tmp_name]
.bak_loop:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .bak_loop
    pop rsi
    call ws_skip
    cmp byte [rsi], '('
    je .call_stmt
    cmp byte [rsi], '='
    jne .fail
    inc rsi
    call find_var
    cmp r15, -1
    jne .assign_existing
    mov r14, -1
    jmp .assign_rhs
.assign_existing:
    mov r14, r15
.assign_rhs:
    ; restore lhs name for potential new var
    push rsi
    lea rdi, [rel tmp_name]
    lea rsi, [rel tmp_name_bak]
.rest_loop:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .rest_loop
    pop rsi
    call ws_skip
    cmp byte [rsi], '&'
    je .rhs_addr
    cmp byte [rsi], '*'
    je .rhs_deref
    cmp byte [rsi], '"'
    je .rhs_str
    cmp byte [rsi], 39
    je .rhs_char_const
    movzx eax, byte [rsi]
    cmp eax, 't'
    je .rhs_tf_try
    cmp eax, 'f'
    jne .rhs_digit_check
.rhs_tf_try:
    ; true/false literal probe (parse_num advances rsi only on match)
    mov rcx, rsi
    call parse_num
    cmp rsi, rcx
    je .rhs_tf_fail
    mov r12, rax
    jmp .rhs_lit_done
.rhs_tf_fail:
    jmp .rhs_ident
.rhs_digit_check:
    cmp eax, '0'
    jb .rhs_ident
    cmp eax, '9'
    ja .rhs_ident
    call parse_num
    mov r12, rax
.rhs_lit_done:
    call ws_skip_inline
    movzx eax, byte [rsi]
    cmp eax, '+'
    je .rhs_num_expr
    cmp eax, '-'
    je .rhs_num_expr
    cmp eax, '*'
    je .rhs_num_expr
    cmp eax, '/'
    je .rhs_num_expr
    cmp eax, '%'
    je .rhs_num_expr
    mov r11, 0
    push r12
    call assign_prep
    test rax, rax
    jz .fail
    pop r12
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 5
    mov [rbx+8], r15
    mov [rbx+24], r12
    jmp .stmt_done
.rhs_num_expr:
    ; r12 = ??????????
    mov [rel expr_lhs], r12
    mov qword [rel expr_ltype], 0
    jmp .rhs_expr_common
.rhs_addr:
    ; a = &b : lhs becomes a ptr variable (stores address of b)
    inc rsi
    call ws_skip
    call parse_name
    test rax, rax
    jz .fail
    call is_keyword
    test rax, rax
    jnz .fail
    call find_var
    cmp r15, -1
    je .fail
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    cmp qword [rcx+32], 1
    je .fail
    mov r13, r15
    ; no arithmetic after & (v1)
    call ws_skip_inline
    movzx eax, byte [rsi]
    cmp eax, '+'
    je .fail
    cmp eax, '-'
    je .fail
    cmp eax, '*'
    je .fail
    cmp eax, '/'
    je .fail
    cmp eax, '%'
    je .fail
    ; restore lhs name for assign_prep (new ptr var)
    push rsi
    lea rdi, [rel tmp_name]
    lea rsi, [rel tmp_name_bak]
.rest_lhs_addr:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .rest_lhs_addr
    pop rsi
    mov r12, r13
    mov r11, 2
    call assign_prep
    test rax, rax
    jz .fail
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 38
    mov [rbx+8], r15
    mov [rbx+16], r12
    jmp .stmt_done
.rhs_deref:
    ; a = *p : lhs becomes a num variable (deref-read)
    inc rsi
    call ws_skip
    call parse_name
    test rax, rax
    jz .fail
    call is_keyword
    test rax, rax
    jnz .fail
    call find_var
    cmp r15, -1
    je .fail
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    cmp qword [rcx+32], 1
    je .fail
    mov r13, r15
    ; no arithmetic after deref-read (v1)
    call ws_skip
    movzx eax, byte [rsi]
    cmp eax, '+'
    je .fail
    cmp eax, '-'
    je .fail
    cmp eax, '*'
    je .fail
    cmp eax, '/'
    je .fail
    cmp eax, '%'
    je .fail
    ; restore lhs name for assign_prep (new num var)
    push rsi
    lea rdi, [rel tmp_name]
    lea rsi, [rel tmp_name_bak]
.rest_lhs_deref:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .rest_lhs_deref
    pop rsi
    mov r12, r13
    mov r11, 0
    call assign_prep
    test rax, rax
    jz .fail
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 34
    mov [rbx+8], r15
    mov [rbx+16], r12
    jmp .stmt_done
.rhs_char_const:
    ; char / multi-char literal -> numeric constant assignment (C-style: first char highest)
    inc rsi
    xor r12d, r12d
    xor ebx, ebx
.rcc_loop:
    mov al, [rsi]
    cmp al, 39
    je .rcc_done
    cmp al, 0
    je .fail
    cmp al, 10
    je .fail
    cmp al, '\'
    jne .rcc_plain
    inc rsi
    mov al, [rsi]
    cmp al, 'n'
    jne .rcc_esc_keep
    mov al, 10
    jmp .rcc_esc_done
.rcc_esc_keep:
    mov al, [rsi]
.rcc_esc_done:
    shl r12, 8
    movzx eax, al
    or r12, rax
    inc rsi
    inc ebx
    cmp ebx, 8
    ja .fail
    jmp .rcc_loop
.rcc_plain:
    shl r12, 8
    movzx eax, al
    or r12, rax
    inc rsi
    inc ebx
    cmp ebx, 8
    ja .fail
    jmp .rcc_loop
.rcc_done:
    test ebx, ebx
    jz .fail
    inc rsi
    jmp .rhs_lit_done
.rhs_str:
    inc rsi
    mov rax, [rel strpool_len]
    mov r15, rax
    lea rbx, [rel strpool]
    add rbx, rax
    xor r12d, r12d
.rhs_str_loop:
    mov al, [rsi]
    cmp al, '"'
    je .rhs_str_done
    cmp al, 39
    je .rhs_str_done
    cmp al, 0
    je .fail_unterm_str
    cmp al, 10
    je .fail_unterm_str
    mov [rbx], al
    inc rbx
    inc rsi
    inc r12
    cmp r12, 255
    jae .fail
    jmp .rhs_str_loop
.rhs_str_done:
    inc rsi
    mov rax, [rel strpool_len]
    add rax, r12
    mov [rel strpool_len], rax
    mov r11, 1
    push r15
    push r12
    call assign_prep
    test rax, rax
    jz .fail
    mov r13, r15
    pop r12
    pop r15
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 6
    mov [rbx+8], r13
    mov [rbx+16], r15
    mov [rbx+24], r12
    jmp .stmt_done
.rhs_ident:
    call parse_name
    test rax, rax
    jz .fail
    call find_var
    cmp r15, -1
    je .rhs_ident_func
    mov r12, r15
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    mov r11, [rcx+32]
    call ws_skip
    movzx eax, byte [rsi]
    cmp eax, '+'
    je .rhs_var_expr
    cmp eax, '-'
    je .rhs_var_expr
    cmp eax, '*'
    je .rhs_var_expr
    cmp eax, '/'
    je .rhs_var_expr
    cmp eax, '%'
    je .rhs_var_expr
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    mov r11, [rcx+32]
    push r15
    ; restore lhs name for assign_prep (RHS parse clobbered tmp_name)
    push rsi
    lea rdi, [rel tmp_name]
    lea rsi, [rel tmp_name_bak]
.rest_lhs_rv:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .rest_lhs_rv
    pop rsi
    call assign_prep
    test rax, rax
    jz .fail
    pop r12
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 7
    cmp r11, 1
    je .rhs_var_str
    jmp .rhs_var_num
.rhs_var_str:
    mov qword [rbx], 8
.rhs_var_num:
    mov [rbx+8], r15
    mov [rbx+16], r12
    jmp .stmt_done
.rhs_var_expr:
    ; ptr variables cannot take part in arithmetic (v1)
    cmp r11, 2
    je .fail
    ; r12 = ???????idx
    mov [rel expr_lhs], r12
    mov qword [rel expr_ltype], 2
    jmp .rhs_expr_common
.rhs_expr_common:
    ; expr_lhs/expr_ltype ?????????rsi ?????????????????? cur_op
    movzx eax, byte [rsi]
    cmp eax, '+'
    je .aex_op_plus
    cmp eax, '-'
    je .aex_op_minus
    cmp eax, '*'
    je .aex_op_mul
    cmp eax, '/'
    je .aex_op_div
    cmp eax, '%'
    je .aex_op_mod
    jmp .fail
.aex_op_plus:
    mov qword [rel cur_op], 0
    jmp .aex_op_set
.aex_op_minus:
    mov qword [rel cur_op], 1
    jmp .aex_op_set
.aex_op_mul:
    mov qword [rel cur_op], 2
    jmp .aex_op_set
.aex_op_div:
    mov qword [rel cur_op], 3
    jmp .aex_op_set
.aex_op_mod:
    mov qword [rel cur_op], 4
.aex_op_set:
    inc rsi
    call ws_skip
    movzx eax, byte [rsi]
    cmp eax, '0'
    jb .rhs_expr_rhs_var
    cmp eax, '9'
    ja .rhs_expr_rhs_var
    call parse_num
    mov [rel expr_rhs], rax
    mov rax, [rel cur_op]
    imul rax, rax, 2
    add rax, 15
    jmp .rhs_expr_subtype
.rhs_expr_rhs_var:
    call parse_name
    test rax, rax
    jz .fail
    call find_var
    cmp r15, -1
    je .fail
    mov [rel expr_rhs], r15
    mov rax, [rel cur_op]
    imul rax, rax, 2
    add rax, 14
.rhs_expr_subtype:
    cmp qword [rel expr_ltype], 2
    je .rhs_expr_subtype_ok
    add rax, 10
.rhs_expr_subtype_ok:
    mov [rel expr_sub], rax
    ; restore lhs name for assign_prep
    push rsi
    lea rdi, [rel tmp_name]
    lea rsi, [rel tmp_name_bak]
.rest_lhs_expr:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .rest_lhs_expr
    pop rsi
    mov r11, 0
    call assign_prep
    test rax, rax
    jz .fail
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov rax, [rel expr_sub]
    mov [rbx], rax
    mov [rbx+8], r15
    mov rax, [rel expr_lhs]
    mov [rbx+16], rax
    mov rax, [rel expr_rhs]
    mov [rbx+24], rax
    jmp .stmt_done
.rhs_ident_func:
    call find_func
    cmp r15, -1
    je .fail
.resolve_rhs_fwd:
    lea rcx, [rel func_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    cmp dword [rcx+52], 1
    jne .rhs_fwd_done
    mov r15d, [rcx+48]
    test r15, r15
    jz .fail
    jmp .resolve_rhs_fwd
.rhs_fwd_done:
    mov r12, r15
    call ws_skip
    cmp byte [rsi], '('
    jne .fail
    inc rsi
    lea rcx, [rel func_table]
    mov rax, r12
    imul rax, rax, 56
    add rcx, rax
    mov r11, [rcx+40]
    ; restore lhs name for assign_prep (RHS parse clobbered tmp_name)
    push rsi
    lea rdi, [rel tmp_name]
    lea rsi, [rel tmp_name_bak]
.rest_lhs_rf:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .rest_lhs_rf
    pop rsi
    call assign_prep
    test rax, rax
    jz .fail
    mov r13, r15
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 9
    cmp r11, 0
    je .rhs_cl_num
    mov qword [rbx], 10
.rhs_cl_num:
    mov [rbx+8], r12
    mov [rbx+16], r13
    mov qword [rbx+24], 0
    inc qword [rel stmts_cnt]
    mov rax, [rel stmts_cnt]
    push rax
    call parse_args
    test rax, rax
    jz .cf1_fail
    pop r15
    lea rbx, [rel stmts]
    mov rax, r15
    dec rax
    imul rax, rax, 32
    add rbx, rax
    mov [rbx+24], r14
    dec qword [rel stmts_cnt]
    jmp .stmt_done
.cf1_fail:
    pop r15
    dec qword [rel stmts_cnt]
    jmp .fail
.print_user_call:
    call ws_skip
    cmp byte [rsi], '('
    jne .fail
    jmp .call_stmt
.call_stmt:
    call find_func
    cmp r15, -1
    je .fail
.resolve_call_fwd:
    lea rcx, [rel func_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    mov r12, rcx
    cmp dword [r12+52], 1
    jne .call_fwd_done
    mov rax, r15
    imul rax, rax, 8
    lea rdx, [rel vararg_fwd]
    add rdx, rax
    mov r15, [rdx]
    cmp r15, -1
    je .fail
    jmp .resolve_call_fwd
.call_fwd_done:
    mov r12, r15
    push r12
    inc rsi
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 11
    mov [rbx+8], r12
    mov qword [rbx+16], 0
    inc qword [rel stmts_cnt]
    mov rax, [rel stmts_cnt]
    push rax
    call parse_args
    test rax, rax
    jz .cf2_fail
    pop r15
    pop r12
    lea rbx, [rel stmts]
    mov rax, r15
    dec rax
    imul rax, rax, 32
    add rbx, rax
    ; varargs forward: single marker arg inside varargs func -> record & drop
    mov rax, [rel cur_func]
    cmp rax, -1
    je .call_keep
    cmp r14, 1
    jne .call_keep
    lea rdx, [rel stmts]
    mov rax, r15
    imul rax, rax, 32
    add rdx, rax
    cmp qword [rdx+8], 5
    jne .call_keep
    mov rax, [rel cur_func]
    imul rax, rax, 8
    lea rdx, [rel vararg_fwd]
    add rdx, rax
    mov [rdx], r12
    mov rax, [rel cur_func]
    imul rax, rax, 56
    lea rdx, [rel func_table]
    add rdx, rax
    mov dword [rdx+52], 1
    dec qword [rel stmts_cnt]
    dec qword [rel stmts_cnt]
    jmp .stmt_done
.call_keep:
    mov [rbx+24], r14
    dec qword [rel stmts_cnt]
    jmp .stmt_done
.cf2_fail:
    pop r15
    pop r12
    dec qword [rel stmts_cnt]
    jmp .fail

.body_brk:
    cmp qword [rel cur_func], -1
    jne .func_body_done
    jmp .body_done
.body_done:
    mov dil, '}'
    call expect_char
    test rax, rax
    jz .fail
    mov rax, [rel cur_local_cnt]
    mov [rel main_locals], rax
    mov rax, [rel stmts_cnt]
    mov rbx, [rel main_start]
    sub rax, rbx
    mov [rel main_len], rax
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    sub rbx, 32
    mov rax, [rbx]
    cmp rax, 3
    je .has_ret
    mov rcx, [rel stmts_cnt]
    lea rdx, [rel stmts]
    imul rcx, rcx, 32
    add rdx, rcx
    mov qword [rdx], 3
    mov qword [rdx+8], 0
    mov qword [rdx+16], 0
    inc qword [rel stmts_cnt]
    inc qword [rel main_len]
.has_ret:
    ; main ?????????? .cf ???????main ??????????? ?????????
    mov rax, 1
    jmp .ok
.func_body_done:
    mov dil, '}'
    call expect_char
    test rax, rax
    jz .fail
    mov rbx, [rel cur_func]
    lea rcx, [rel func_table]
    imul rbx, rbx, 56
    add rcx, rbx
    mov rax, [rel stmts_cnt]
    mov rdx, [rcx+24]
    sub rax, rdx
    mov [rcx+32], rax
    mov rax, [rel cur_local_cnt]
    mov [rcx+48], eax
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    sub rbx, 32
    mov rax, [rbx]
    cmp rax, 3
    je .func_ret_ok
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 3
    mov qword [rbx+8], 0
    mov qword [rbx+16], 0
    inc qword [rel stmts_cnt]
    inc qword [rcx+32]
.func_ret_ok:
    jmp .main_or_func
.stmt_done:
    inc qword [rel stmts_cnt]
    call opt_semi
    test rax, rax
    jz .fail
    jmp .stmt
.fail_unterm_str:
    lea rax, [rel msg_unterm_str]
    call err_set_syntax
    jmp .fail
.fail_unterm_char:
    lea rax, [rel msg_unterm_char]
    call err_set_syntax
    jmp .fail
.fail_missing_main:
    lea rax, [rel msg_missing_main]
    call err_set_syntax
.fail:
    xor eax, eax
.ok:
    add rsp, 0x20
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- import file resolution ----
; resolve_import: r14 = ?????????(import_libs 64???????
; ??lib ???????????????? ???????.cf/.dll/.so ????????????????
; ???????????????????.cf/.dll/.so??cf ????????????????src_buf,
; .dll/.so ???????????dll_list???????rax=1 ?????/ 0 ???????
resolve_import:
    DBGMARK mc_name
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r12
    push r13
    push r15
    push rsi
    sub rsp, 0x40

    ; r15 = ?????????
    xor r15d, r15d
.ri_len:
    mov al, [r14+r15]
    test al, al
    jz .ri_len_done
    inc r15
    cmp r15, 63
    jae .ri_fail
    jmp .ri_len
.ri_len_done:
    ; ---- skip libraries already loaded (recursive/duplicate import guard) ----
    xor r12d, r12d
.ri_ldchk_loop:
    cmp r12, [rel loaded_cnt]
    jae .ri_ldchk_done
    lea rcx, [rel loaded_libs]
    mov rax, r12
    shl rax, 6
    add rcx, rax
    mov rdx, r14
.ri_ldchk_cmp:
    mov al, [rcx]
    mov r8b, [rdx]
    cmp al, r8b
    jne .ri_ldchk_next
    test al, al
    jz .ri_ldchk_hit
    inc rcx
    inc rdx
    jmp .ri_ldchk_cmp
.ri_ldchk_next:
    inc r12
    jmp .ri_ldchk_loop
.ri_ldchk_hit:
    mov rax, 1
    jmp .ri_out
.ri_ldchk_done:
    ; ?????????????????
    ; builtin os module: "os" -> succeed without lib file
    cmp r15, 2
    jne .ri_not_os
    cmp byte [r14], 'o'
    jne .ri_not_os
    cmp byte [r14+1], 's'
    jne .ri_not_os
    mov rax, 1
    jmp .ri_out
.ri_not_os:
    mov r13d, -1
    cmp r15, 3
    jb .ri_copy
    lea rbx, [r14+r15]
    sub rbx, 3
    cmp byte [rbx], '.'
    jne .ri_chk_dll
    cmp byte [rbx+1], 'c'
    jne .ri_chk_dll
    cmp byte [rbx+2], 'f'
    jne .ri_chk_dll
    mov r13d, 0
    jmp .ri_copy
.ri_chk_dll:
    cmp r15, 4
    jb .ri_copy
    lea rbx, [r14+r15]
    sub rbx, 4
    cmp byte [rbx], '.'
    jne .ri_chk_so
    cmp byte [rbx+1], 'd'
    jne .ri_chk_so
    cmp byte [rbx+2], 'l'
    jne .ri_chk_so
    cmp byte [rbx+3], 'l'
    jne .ri_chk_so
    mov r13d, 1
    jmp .ri_copy
.ri_chk_so:
    cmp r15, 3
    jb .ri_copy
    lea rbx, [r14+r15]
    sub rbx, 3
    cmp byte [rbx], '.'
    jne .ri_copy
    cmp byte [rbx+1], 's'
    jne .ri_copy
    cmp byte [rbx+2], 'o'
    jne .ri_copy
    mov r13d, 2
.ri_copy:
    ; lib_path_buf = "lib/" + name
    lea rdi, [rel lib_path_buf]
    mov dword [rdi], 'lib/'
    add rdi, 4
    xor r12d, r12d
.ri_cp:
    mov al, [r14+r12]
    mov [rdi+r12], al
    test al, al
    jz .ri_cp_done
    inc r12
    cmp r12, 63
    jae .ri_fail
    jmp .ri_cp
.ri_cp_done:
    cmp r13d, -1
    jne .ri_try
    ; ???????? ???????????cur_pkg_set==1) ?????lib/<cur_pkg>/<name>.cf ??????????
    cmp qword [rel cur_pkg_set], 1
    jne .ri_nopkg
    lea rdi, [rel pkg_path_buf]
    mov dword [rdi], 'lib/'
    add rdi, 4
    lea rsi, [rel cur_pkg]
.ri_pc1:
    mov al, [rsi]
    test al, al
    jz .ri_pc1_done
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .ri_pc1
.ri_pc1_done:
    mov byte [rdi], '/'
    inc rdi
    mov rsi, r14
.ri_pc2:
    mov al, [rsi]
    test al, al
    jz .ri_pc2_done
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .ri_pc2
.ri_pc2_done:
    mov dword [rdi], '.cf'
    mov byte [rdi+3], 0
    lea rcx, [rel pkg_path_buf]
    call ri_try_open
    test rax, rax
    jnz .ri_ok
.ri_nopkg:
    ; ?????Python ???????lib/<name>/__init__.cf, ???????????? .cf/.dll/.so
    lea rdi, [rel lib_path_buf]
    add rdi, r15
    add rdi, 4
    mov byte [rdi], '/'
    mov byte [rdi+1], '_'
    mov byte [rdi+2], '_'
    mov byte [rdi+3], 'i'
    mov byte [rdi+4], 'n'
    mov byte [rdi+5], 'i'
    mov byte [rdi+6], 't'
    mov byte [rdi+7], '_'
    mov byte [rdi+8], '_'
    mov byte [rdi+9], '.'
    mov byte [rdi+10], 'c'
    mov byte [rdi+11], 'f'
    mov byte [rdi+12], 0
    lea rcx, [rel lib_path_buf]
    call ri_try_open
    test rax, rax
    jz .ri_init_fail
    ; pkg dir ok: set cur_pkg = name
    lea rdi, [rel cur_pkg]
    mov rsi, r14
.ri_setpkg:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .ri_setpkg_done
    inc rsi
    inc rdi
    jmp .ri_setpkg
.ri_setpkg_done:
    mov qword [rel cur_pkg_set], 1
    jmp .ri_ok
.ri_init_fail:
    lea rdi, [rel lib_path_buf]
    add rdi, r15
    add rdi, 4
    mov dword [rdi], '.cf'
    mov byte [rdi+3], 0
    lea rcx, [rel lib_path_buf]
    call ri_try_open
    test rax, rax
    jnz .ri_ok
    lea rdi, [rel lib_path_buf]
    add rdi, r15
    add rdi, 4
    mov dword [rdi], '.dll'
    mov byte [rdi+4], 0
    lea rcx, [rel lib_path_buf]
    call ri_try_open
    test rax, rax
    jnz .ri_ok
    lea rdi, [rel lib_path_buf]
    add rdi, r15
    add rdi, 4
    mov dword [rdi], '.so'
    mov byte [rdi+3], 0
    lea rcx, [rel lib_path_buf]
    call ri_try_open
    test rax, rax
    jnz .ri_ok
    call ri_try_exe
    test rax, rax
    jnz .ri_ok
    jmp .ri_fail
.ri_try:
    lea rcx, [rel lib_path_buf]
    call ri_try_open
    test rax, rax
    jnz .ri_ok
    call ri_try_exe
    test rax, rax
    jnz .ri_ok
    jmp .ri_fail
.ri_ok:
    ; ---- register as loaded BEFORE recursing (self-import protection) ----
    mov rax, [rel loaded_cnt]
    cmp rax, 8
    jae .ri_reg_skip
    lea rdi, [rel loaded_libs]
    shl rax, 6
    add rdi, rax
    mov rsi, r14
.ri_reg_cp:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .ri_reg_done
    inc rsi
    inc rdi
    jmp .ri_reg_cp
.ri_reg_done:
    inc qword [rel loaded_cnt]
.ri_reg_skip:
    cmp qword [rel cf_pending], 1
    jne .ri_ok_plain
    mov rax, [rel src_len]
    sub rax, [rel src_extra_len]
    mov rbx, [rel src_extra_len]
    mov rsi, rax
    mov rdx, rbx
    call imp_scan_remove
    test rax, rax
    jz .ri_fail
.ri_ok_plain:
    DBGMARK mx7_name
    mov rax, 1
    jmp .ri_out
.ri_fail:
    call err_set_import
    xor eax, eax
.ri_out:
    ; [DEBUG] pkg restore disabled
    add rsp, 0x40
    pop rsi
    pop r15
    pop r13
    pop r12
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; imp_scan_remove: rsi=src_buf ???????????????? rdx=?????????
; ???????????? `import <name>` ???: ?????????????????????????
; ?????rax=1 ?????/ 0 ?????
imp_scan_remove:
    DBGMARK m4_name
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r12
    push r13
    push r14
    push r15
    push rsi
    push rdi
    sub rsp, 0x20
    ; r12 = ???????????????, r13 = ?????
    lea r12, [rel src_buf]
    add r12, rsi
    lea r13, [rel src_buf]
    add r13, rsi
    add r13, rdx
    mov qword [rel skip_cnt], 0
.isr_loop:
    cmp r12, r13
    jae .isr_done
    mov al, [r12]
    cmp al, '"'
    jne .isr_kw
    ; ????????????????????
    inc r12
.isr_skip_str:
    cmp r12, r13
    jae .isr_done
    mov al, [r12]
    cmp al, '"'
    je .isr_str_end
    cmp al, 0
    je .isr_done
    inc r12
    jmp .isr_skip_str
.isr_str_end:
    inc r12
    jmp .isr_loop
.isr_kw:
    cmp al, 'i'
    jne .isr_next
    ; ????? ??????????????????
    lea r14, [rel src_buf]
    cmp r12, r14
    je .isr_kw_chk
    mov al, [r12-1]
    cmp al, 'a'
    jae .isr_prev_low
    jmp .isr_kw_chk
.isr_prev_low:
    cmp al, 'z'
    jbe .isr_next
    cmp al, 'A'
    jb .isr_kw_chk
    cmp al, 'Z'
    jbe .isr_next
.isr_kw_chk:
    ; ?????"import"
    lea rbx, [r12]
    lea r8, [rel kw_import]
    xor ecx, ecx
.isr_kwc:
    mov al, [rbx+rcx]
    mov r9b, [r8+rcx]
    test r9b, r9b
    jz .isr_kwc_done
    cmp al, r9b
    jne .isr_next
    inc rcx
    cmp rcx, 6
    jae .isr_kwc_done
    jmp .isr_kwc
.isr_kwc_done:
    ; ???????????????????'<' ??';'
    mov al, [rbx+6]
    cmp al, ' '
    je .isr_found
    cmp al, 9
    je .isr_found
    cmp al, '<'
    je .isr_found
    cmp al, ';'
    je .isr_found
    jmp .isr_next
.isr_found:
    ; ?????????
    lea rsi, [rbx+6]
.isr_ws:
    mov al, [rsi]
    cmp al, ' '
    je .isr_ws_adv
    cmp al, 9
    je .isr_ws_adv
    cmp al, 13
    je .isr_ws_adv
    cmp al, 10
    je .isr_ws_adv
    jmp .isr_ws_done
.isr_ws_adv:
    inc rsi
    jmp .isr_ws
.isr_ws_done:
    cmp byte [rsi], '<'
    jne .isr_next
    inc rsi
    ; ????????????????imp_sub_buf
    lea rdi, [rel imp_sub_buf]
    xor r15d, r15d
.isr_nm:
    mov al, [rsi]
    cmp al, '>'
    je .isr_nm_done
    cmp al, 0
    je .isr_next
    cmp r15, 63
    jae .isr_next
    mov [rdi], al
    inc rsi
    inc rdi
    inc r15
    jmp .isr_nm
.isr_nm_done:
    mov byte [rdi], 0
    ; ????????????: rsi ?????'>' ????? ??????????
    mov rbx, rsi
.isr_eol:
    cmp rbx, r13
    jae .isr_eol_done
    mov al, [rbx]
    cmp al, 10
    je .isr_eol_done
    cmp al, 13
    je .isr_eol_done
    cmp al, 0
    je .isr_eol_done
    inc rbx
    jmp .isr_eol
.isr_eol_done:
    ; ?????????, ????????
    cmp rbx, r13
    jae .isr_rec
    mov al, [rbx]
    cmp al, 10
    jne .isr_chk13
    inc rbx
    jmp .isr_rec
.isr_chk13:
    cmp al, 13
    jne .isr_rec
    inc rbx
    cmp rbx, r13
    jae .isr_rec
    cmp byte [rbx], 10
    jne .isr_rec
    inc rbx
.isr_rec:
    ; ????????? [r12, rbx) ??skip_list
    mov rax, [rel skip_cnt]
    cmp rax, 31
    jae .isr_fail
    lea rdi, [rel skip_list]
    shl rax, 4
    add rdi, rax
    mov [rdi], r12
    mov [rdi+8], rbx
    inc qword [rel skip_cnt]
    ; ?????resolve_import(imp_sub_buf)
    ; backup skip state (inner imp_scan_remove will clobber it)
    mov rax, [rel skip_cnt]
    mov [rel skip_save_cnt], rax
    lea rsi, [rel skip_list]
    lea rdi, [rel skip_save_list]
    mov ecx, 32*16
    rep movsb
    push r12
    push r13
    push r14
    sub rsp, 8          ; align rsp to 16 before call (Win64 ABI)
    mov qword [rel imp_top], 0
    lea r14, [rel imp_sub_buf]
    DBGMARK m6_name
    call resolve_import
    DBGMARK m7_name
    mov [rel ri_result], rax
    add rsp, 8
    pop r14
    pop r13
    pop r12
    ; restore skip state
    mov rax, [rel skip_save_cnt]
    mov [rel skip_cnt], rax
    lea rsi, [rel skip_save_list]
    lea rdi, [rel skip_list]
    mov ecx, 32*16
    rep movsb
    cmp qword [rel ri_result], 1
    jne .isr_fail
    mov r12, rbx
    jmp .isr_loop
.isr_next:
    inc r12
    jmp .isr_loop
.isr_done:
    ; ??????????????skip_list ??????????
    mov rax, [rel skip_cnt]
    test rax, rax
    jz .isr_ok
.isr_del:
    dec rax
    lea rdi, [rel skip_list]
    mov rdx, rax
    shl rdx, 4
    add rdi, rdx
    mov r8, [rdi]
    mov r9, [rdi+8]
    mov rcx, r9
    sub rcx, r8
    test rcx, rcx
    jz .isr_del_next
    mov rsi, r9
    mov rdi, r8
    lea rdx, [rel src_buf]
    add rdx, [rel src_len]
    sub rdx, r9
.isr_mv:
    test rdx, rdx
    jz .isr_mv_done
    mov r10b, [rsi]
    mov [rdi], r10b
    inc rsi
    inc rdi
    dec rdx
    jmp .isr_mv
.isr_mv_done:
    sub [rel src_len], rcx
.isr_del_next:
    test rax, rax
    jz .isr_ok
    jmp .isr_del
.isr_ok:
    DBGMARK mx5_name
    mov rax, 1
    jmp .isr_out
.isr_fail:
    xor eax, eax
.isr_out:
    DBGMARK mx6_name
    add rsp, 0x20
    pop rdi
    pop rsi
    pop r15
    pop r14
    pop r13
    pop r12
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; ri_try_exe: exe ???????lib ???????????CWD ??????????????
; ???: r14 = ??????, r15 = ??????, r13 = ???????-1 ????? / 0=.cf / 1=.dll / 2=.so)
; ???: GetModuleFileNameA ??gffc.exe ??? -> ?????? -> ??exe_dir\lib/<name>
;       ??????????__init__.cf / .cf / .dll / .so???????????
; ??? rax=1 ??? / 0 ???????????exe ????????lib_path_buf ??????
ri_try_exe:
    DBGMARK m1_name
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r12
    push r13
    push r15
    push rsi
    push rdi
    sub rsp, 0x28

    ; ---- ???????????exe ???
        cmp qword [rel exe_dir_ready], 1
    je .tx_have_dir
    xor ecx, ecx
    lea rdx, [rel exe_path_buf]
    mov r8d, 512
    call [rel iat_GetModuleFileNameA]
    lea rdi, [rel exe_path_buf]
    xor r9d, r9d
.tx_scan:
    mov al, [rdi]
    test al, al
    jz .tx_scan_done
    cmp al, 0x5C
    jne .tx_next
    mov r9, rdi
.tx_next:
    inc rdi
    jmp .tx_scan
.tx_scan_done:
    test r9, r9
    jz .tx_noslash
    mov byte [r9+1], 0
    ; save exe dir (with trailing backslash) into its own buffer
    lea rax, [rel exe_path_buf]
    mov rcx, r9
    sub rcx, rax
    inc rcx
    mov [rel exe_dir_len], rcx
    lea rsi, [rel exe_path_buf]
    lea rdi, [rel exe_dir_buf]
    rep movsb
    mov qword [rel exe_dir_ready], 1
    jmp .tx_have_dir
.tx_noslash:
    xor eax, eax
    jmp .tx_out
.tx_have_dir:
    lea rsi, [rel exe_dir_buf]
    lea rdi, [rel exe_path_buf]
    mov rcx, [rel exe_dir_len]
    rep movsb
    lea rdi, [rel exe_path_buf]
    add rdi, [rel exe_dir_len]
    lea rax, [rel exe_path_buf]
    mov rbx, rdi
    sub rbx, rax
    ; ---- package-relative attempt: exe_dir/lib/<cur_pkg>/<name>.cf ----
    ; a lib already importing from inside a package (e.g. iostrpm/__init__.cf
    ; doing `import <math>`) must resolve to lib/iostrpm/math.cf
    cmp qword [rel cur_pkg_set], 1
    jne .tx_pkg_skip
    mov r8, rdi
    mov byte [r8], 'l'
    mov byte [r8+1], 'i'
    mov byte [r8+2], 'b'
    mov byte [r8+3], '/'
    lea rsi, [rel cur_pkg]
    lea rdi, [r8+4]
.tx_pkg_cp:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .tx_pkg_cpd
    inc rsi
    inc rdi
    jmp .tx_pkg_cp
.tx_pkg_cpd:
    mov byte [rdi], '/'
    inc rdi
    mov rsi, r14
.tx_pkg_cn:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .tx_pkg_cnd
    inc rsi
    inc rdi
    jmp .tx_pkg_cn
.tx_pkg_cnd:
    mov dword [rdi], '.cf'
    mov byte [rdi+3], 0
    lea rcx, [rel exe_path_buf]
    call ri_try_open
    test rax, rax
    jnz .tx_ok
    mov rdi, r8
    mov byte [rdi], 0
.tx_pkg_skip:
    mov byte [rdi], 'l'
    mov byte [rdi+1], 'i'
    mov byte [rdi+2], 'b'
    mov byte [rdi+3], 0x2F
    add rdi, 4
    xor r12d, r12d
.tx_cp:
    mov al, [r14+r12]
    mov [rdi+r12], al
    test al, al
    jz .tx_cp_done
    inc r12
    cmp r12, 63
    jae .tx_fail
    jmp .tx_cp
.tx_cp_done:
    ; name ?????? = rbx + 4 + r15
    cmp r13d, -1
    jne .tx_try_suffix
    ; ---- ???????_init__.cf / .cf / .dll / .so
    lea rdi, [rel exe_path_buf]
    add rdi, rbx
    add rdi, 4
    add rdi, r15
    mov byte [rdi], 0x2F
    mov dword [rdi+1], '__in'
    mov byte [rdi+5], 'i'
    mov byte [rdi+6], 't'
    mov byte [rdi+7], '_'
    mov byte [rdi+8], '_'
    mov byte [rdi+9], '.'
    mov byte [rdi+10], 'c'
    mov byte [rdi+11], 'f'
    mov byte [rdi+12], 0
    lea rcx, [rel exe_path_buf]
    call ri_try_open
    test rax, rax
    jnz .tx_ok_init
    lea rdi, [rel exe_path_buf]
    add rdi, rbx
    add rdi, 4
    add rdi, r15
    mov dword [rdi], '.cf'
    mov byte [rdi+3], 0
    lea rcx, [rel exe_path_buf]
    call ri_try_open
    test rax, rax
    jnz .tx_ok
    lea rdi, [rel exe_path_buf]
    add rdi, rbx
    add rdi, 4
    add rdi, r15
    mov dword [rdi], '.dll'
    mov byte [rdi+4], 0
    lea rcx, [rel exe_path_buf]
    call ri_try_open
    test rax, rax
    jnz .tx_ok
    lea rdi, [rel exe_path_buf]
    add rdi, rbx
    add rdi, 4
    add rdi, r15
    mov dword [rdi], '.so'
    mov byte [rdi+3], 0
    lea rcx, [rel exe_path_buf]
    call ri_try_open
    test rax, rax
    jnz .tx_ok
    jmp .tx_fail
.tx_try_suffix:
    lea rcx, [rel exe_path_buf]
    call ri_try_open
    test rax, rax
    jnz .tx_ok
.tx_ok_init:
    ; opened <name>/__init__.cf -> remember package so its own `import <sub>`
    ; resolves inside exe_dir/lib/<name>/
    lea rdi, [rel cur_pkg]
    mov rsi, r14
.tx_sp:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .tx_sp_done
    inc rsi
    inc rdi
    jmp .tx_sp
.tx_sp_done:
    mov qword [rel cur_pkg_set], 1
    jmp .tx_ok
.tx_ok:
    DBGMARK m2_name
    mov rax, 1
    jmp .tx_out
.tx_fail:
    ; ??exe ????????lib_path_buf????????????????????
    lea rsi, [rel exe_path_buf]
    lea rdi, [rel lib_path_buf]
.tx_fcopy:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .tx_fcopy_done
    inc rsi
    inc rdi
    jmp .tx_fcopy
.tx_fcopy_done:
    xor eax, eax
.tx_out:
    add rsp, 0x28
    pop rdi
    pop rsi
    pop r15
    pop r13
    pop r12
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; ri_try_open: rcx=?????????
; ???????????????? .cf -> ?????src_extra ?????src_buf, ??cf_pending
; .dll/.so -> ??????????????dll_list???????rax=1 ?????/ 0 ?????
ri_try_open:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r12
    push r13
    push r15
    push rsi
    push rdi
    sub rsp, 0x60
    mov r15, rcx
    ; ---- ANSI -> UTF-16 ??lib_wbuf ----
    lea rdi, [rel lib_wbuf]
    xor ecx, ecx
.rto_conv:
    movzx eax, byte [r15+rcx]
    test al, al
    jz .rto_conv_done
    mov [rdi], ax
    add rdi, 2
    inc ecx
    cmp ecx, 255
    jb .rto_conv
.rto_conv_done:
    mov word [rdi], 0
    ; ---- CreateFileW ----
    lea rcx, [rel lib_wbuf]
    mov edx, 0x80000000
    mov r8d, 3
    xor r9d, r9d
    mov qword [rsp+0x20], 3
    mov qword [rsp+0x28], 0x80
    mov qword [rsp+0x30], 0
    call [rel iat_CreateFileW]
    cmp rax, -1
    jne .rto_opened
    ; ANSI(GBK) fallback: the byte->wide zero extension above is Latin-1 only,
    ; so a non-ASCII path (e.g. a CJK project dir) fails in CreateFileW.
    ; Retry with CreateFileA which takes the raw ANSI bytes as-is.
    mov rcx, r15
    mov edx, 0x80000000
    mov r8d, 3
    xor r9d, r9d
    mov qword [rsp+0x20], 3
    mov qword [rsp+0x28], 0x80
    mov qword [rsp+0x30], 0
    call [rel iat_CreateFileA]
    cmp rax, -1
    je .rto_fail
.rto_opened:
    mov r12, rax
    mov rcx, r12
    xor edx, edx
    call [rel iat_GetFileSize]
    cmp rax, -1
    je .rto_cls_fail
    mov r13, rax
    test r13, r13
    jz .rto_ok
    cmp r13, 65536
    jae .rto_cls_fail
    mov rcx, r12
    lea rdx, [rel src_extra]
    mov r8, r13
    lea r9, [rel src_extra_len]
    mov qword [rsp+0x20], 0
    call [rel iat_ReadFile]
    mov rcx, r12
    call [rel iat_CloseHandle]
    ; ?????????: ??????????????
    lea rdi, [r15]
    xor ecx, ecx
.rto_sl:
    cmp byte [rdi], 0
    je .rto_sl_done
    inc rdi
    inc rcx
    cmp rcx, 256
    jae .rto_sl_done
    jmp .rto_sl
.rto_sl_done:
    cmp rcx, 4
    jb .rto_is_cf
    lea rbx, [r15+rcx]
    sub rbx, 4
    cmp byte [rbx], '.'
    jne .rto_chk_so
    cmp byte [rbx+1], 'd'
    jne .rto_chk_so
    cmp byte [rbx+2], 'l'
    jne .rto_chk_so
    cmp byte [rbx+3], 'l'
    jne .rto_chk_so
    jmp .rto_is_dll
.rto_chk_so:
    cmp rcx, 3
    jb .rto_is_cf
    lea rbx, [r15+rcx]
    sub rbx, 3
    cmp byte [rbx], '.'
    jne .rto_is_cf
    cmp byte [rbx+1], 's'
    jne .rto_is_cf
    cmp byte [rbx+2], 'o'
    jne .rto_is_cf
    jmp .rto_is_dll
.rto_is_cf:
    mov rax, [rel src_len]
    add rax, [rel src_extra_len]
    cmp rax, 196608
    jae .rto_fail
    lea rsi, [rel src_extra]
    ; skip UTF-8 BOM (EF BB BF) if present in imported lib file
    cmp byte [rsi], 0xEF
    jne .rto_mg_ready
    cmp byte [rsi+1], 0xBB
    jne .rto_mg_ready
    cmp byte [rsi+2], 0xBF
    jne .rto_mg_ready
    add rsi, 3
    sub qword [rel src_extra_len], 3
.rto_mg_ready:
    lea rdi, [rel src_buf]
    add rdi, [rel src_len]
    mov rcx, [rel src_extra_len]
.rto_mg:
    test rcx, rcx
    jz .rto_mg_done
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jmp .rto_mg
.rto_mg_done:
    mov rax, [rel src_extra_len]
    add [rel src_len], rax
    mov qword [rel cf_pending], 1
    jmp .rto_ok
.rto_is_dll:
    mov qword [rel cf_pending], 0
    mov rax, [rel dll_cnt]
    cmp rax, 8
    jae .rto_fail
    lea rbx, [rel dll_list]
    imul rax, rax, 64
    add rbx, rax
.rto_cp:
    mov al, [r15]
    mov [rbx], al
    test al, al
    jz .rto_cp_done
    inc r15
    inc rbx
    jmp .rto_cp
.rto_cp_done:
    inc qword [rel dll_cnt]
    jmp .rto_ok
.rto_ok:
    mov rax, 1
    jmp .rto_out
.rto_cls_fail:
    mov rcx, r12
    call [rel iat_CloseHandle]
.rto_fail:
    mov qword [rel cf_pending], 0
    xor eax, eax
.rto_out:
    add rsp, 0x60
    pop rdi
    pop rsi
    pop r15
    pop r13
    pop r12
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; print_hex64: rax = value -> 16 hex digits + LF to stdout
print_hex64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    sub rsp, 0x48
    lea rdi, [rsp+0x30]
    mov byte [rdi+16], 10
    mov byte [rdi+17], 0
    add rdi, 15
    mov rsi, 16
.ph64_loop:
    mov rcx, rax
    and ecx, 0xF
    mov bl, cl
    cmp bl, 10
    jb .ph64_digit
    add bl, 'A'-10
    jmp .ph64_store
.ph64_digit:
    add bl, '0'
.ph64_store:
    mov [rdi], bl
    dec rdi
    shr rax, 4
    dec rsi
    jnz .ph64_loop
    lea rdx, [rsp+0x30]
    mov rcx, [rel hout]
    mov r8d, 17
    lea r9, [rsp+0x28]
    mov qword [rsp+0x20], 0
    call [rel iat_WriteFile]
    add rsp, 0x48
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ---- parse helpers (def/var support) ----
set_ret_type_num:
    push rax
    push rbx
    push rcx
    mov rax, [rel cur_func]
    cmp rax, -1
    je .srtn_out
    lea rbx, [rel func_table]
    imul rax, rax, 56
    add rbx, rax
    mov qword [rbx+40], 0
.srtn_out:
    pop rcx
    pop rbx
    pop rax
    ret

set_ret_type_str:
    push rax
    push rbx
    push rcx
    mov rax, [rel cur_func]
    cmp rax, -1
    je .srts_out
    lea rbx, [rel func_table]
    imul rax, rax, 56
    add rbx, rax
    mov qword [rbx+40], 1
.srts_out:
    pop rcx
    pop rbx
    pop rax
    ret

; assign_prep: r14=target var idx or -1(new), r11=type(0 num/1 str)
; tmp_name must hold var name for new var; -> r15=var idx, rax=ok
assign_prep:
    push rbx
    push rcx
    mov rax, [rel decl_type]
    cmp rax, -1
    je .ap_norm
    ; typed declaration: force new var and check RHS type consistency
    cmp r11, rax
    jne .ap_fail
    cmp r14, -1
    jne .ap_fail
    mov qword [rel decl_type], -1
.ap_norm:
    cmp r14, -1
    jne .ap_existing
    mov r13, 1
    mov r14, r11
    call add_var
    test rax, rax
    jz .ap_fail
    jmp .ap_out
.ap_existing:
    lea rcx, [rel var_table]
    mov rax, r14
    imul rax, rax, 56
    add rcx, rax
    cmp qword [rcx+32], r11
    jne .ap_fail
    mov r15, r14
    jmp .ap_out
.ap_fail:
    xor eax, eax
    pop rcx
    pop rbx
    ret
.ap_out:
    mov rax, 1
    pop rcx
    pop rbx
    ret

; parse_args: rsi after '(' of a call; append type12 params; r14=param_cnt, rax=ok
parse_args:
    push rbx
    push rcx
    push r12
    push r13
    ; r12 = func idx -> load its reference bitmap into call_ref_bmap
    lea rdx, [rel ref_bmap]
    mov rax, r12
    imul rax, rax, 8
    add rdx, rax
    mov rax, [rdx]
    mov [rel call_ref_bmap], rax
    xor r14d, r14d
    call ws_skip
    cmp byte [rsi], ')'
    je .parg_empty
.parg_loop:
    call ws_skip
    mov al, [rsi]
    cmp al, '*'
    je .parg_vararg
    cmp al, '"'
    je .parg_str
    cmp al, 39
    je .parg_char_const
    cmp byte [rsi], '&'
    je .parg_addr
    movzx eax, byte [rsi]
    cmp eax, 't'
    je .parg_tf_try
    cmp eax, 'f'
    jne .parg_digit_check
.parg_tf_try:
    ; true/false literal probe (parse_num advances rsi only on match)
    mov rcx, rsi
    call parse_num
    cmp rsi, rcx
    je .parg_var
    mov r12, rax
    ; reference params must receive a variable (cannot take address of const)
    mov r10, r14
    mov rbx, 1
    mov rcx, r10
    shl rbx, cl
    test qword [rel call_ref_bmap], rbx
    jnz .fail
    mov rcx, [rel stmts_cnt]
    lea rdx, [rel stmts]
    imul rcx, rcx, 32
    add rdx, rcx
    mov qword [rdx], 12
    mov qword [rdx+8], 0
    mov [rdx+16], r12
    inc qword [rel stmts_cnt]
    inc r14
    jmp .parg_next
.parg_digit_check:
    cmp eax, '0'
    jb .parg_var
    cmp eax, '9'
    ja .parg_var
    call parse_num
    mov r12, rax
    ; reference params must receive a variable (cannot take address of const)
    mov r10, r14
    mov rbx, 1
    mov rcx, r10
    shl rbx, cl
    test qword [rel call_ref_bmap], rbx
    jnz .fail
    mov rcx, [rel stmts_cnt]
    lea rdx, [rel stmts]
    imul rcx, rcx, 32
    add rdx, rcx
    mov qword [rdx], 12
    mov qword [rdx+8], 0
    mov [rdx+16], r12
    inc qword [rel stmts_cnt]
    inc r14
    jmp .parg_next
.parg_addr:
    ; pass address of variable: f(&x)
    inc rsi
    call ws_skip
    call parse_name
    test rax, rax
    jz .fail
    call find_var
    cmp r15, -1
    je .fail
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    cmp qword [rcx+32], 1
    je .fail
    mov rcx, [rel stmts_cnt]
    lea rdx, [rel stmts]
    imul rcx, rcx, 32
    add rdx, rcx
    mov qword [rdx], 12
    mov qword [rdx+8], 3
    mov [rdx+16], r15
    inc qword [rel stmts_cnt]
    inc r14
    jmp .parg_next
.parg_var:
    call parse_name
    test rax, rax
    jz .fail
    call find_var
    cmp r15, -1
    je .fail
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    cmp qword [rcx+32], 2
    ja .fail
    mov rcx, [rel stmts_cnt]
    lea rdx, [rel stmts]
    imul rcx, rcx, 32
    add rdx, rcx
    ; no-swap (reference) param -> pass address of variable (&var)
    mov r10, r14
    mov rbx, 1
    mov rcx, r10
    shl rbx, cl
    test qword [rel call_ref_bmap], rbx
    jz .parg_var_val
    mov qword [rdx], 12
    mov qword [rdx+8], 3
    mov [rdx+16], r15
    inc qword [rel stmts_cnt]
    inc r14
    jmp .parg_next
.parg_var_val:
    mov qword [rdx], 12
    mov qword [rdx+8], 2
    mov [rdx+16], r15
    inc qword [rel stmts_cnt]
    inc r14
    jmp .parg_next
.parg_vararg:
    ; varargs forward marker: *name -> kind 12, [8]=5
    inc rsi
    call ws_skip
    call parse_name
    test rax, rax
    jz .fail
    mov rcx, [rel stmts_cnt]
    lea rdx, [rel stmts]
    imul rcx, rcx, 32
    add rdx, rcx
    mov qword [rdx], 12
    mov qword [rdx+8], 5
    mov qword [rdx+16], 0
    inc qword [rel stmts_cnt]
    inc r14
.parg_next:
    call ws_skip
    cmp byte [rsi], ','
    je .parg_comma
    mov dil, ')'
    call expect_char
    test rax, rax
    jz .fail
    jmp .parg_done
.parg_comma:
    inc rsi
    jmp .parg_loop
.parg_empty:
    mov dil, ')'
    call expect_char
    test rax, rax
    jz .fail
    jmp .parg_done
.parg_char_const:
    ; char / multi-char literal: pack into numeric const (kind12 kind0, C-style: first char highest)
    inc rsi
    xor r12d, r12d
    xor ebx, ebx
.pcc_loop:
    mov al, [rsi]
    cmp al, 39
    je .pcc_done
    cmp al, 0
    je .fail
    cmp al, 10
    je .fail
    cmp al, '\'
    jne .pcc_plain
    inc rsi
    mov al, [rsi]
    cmp al, 'n'
    jne .pcc_esc_keep
    mov al, 10
    jmp .pcc_esc_done
.pcc_esc_keep:
    mov al, [rsi]
.pcc_esc_done:
    shl r12, 8
    movzx eax, al
    or r12, rax
    inc rsi
    inc ebx
    cmp ebx, 8
    ja .fail
    jmp .pcc_loop
.pcc_plain:
    shl r12, 8
    movzx eax, al
    or r12, rax
    inc rsi
    inc ebx
    cmp ebx, 8
    ja .fail
    jmp .pcc_loop
.pcc_done:
    test ebx, ebx
    jz .fail
    inc rsi
    ; reference params must receive a variable (cannot take address of const)
    mov r10, r14
    mov rbx, 1
    mov rcx, r10
    shl rbx, cl
    test qword [rel call_ref_bmap], rbx
    jnz .fail
    mov rcx, [rel stmts_cnt]
    lea rdx, [rel stmts]
    imul rcx, rcx, 32
    add rdx, rcx
    mov qword [rdx], 12
    mov qword [rdx+8], 0
    mov [rdx+16], r12
    inc qword [rel stmts_cnt]
    inc r14
    jmp .parg_next
.parg_str:
    ; string literal arg (str const, ref-style): kind 4, [16]=strpool off, [24]=len
    inc rsi
    mov rax, [rel strpool_len]
    mov rcx, rax
    lea rbx, [rel strpool]
    add rbx, rax
    xor r12d, r12d
.ps_str_loop:
    mov al, [rsi]
    cmp al, '"'
    je .ps_str_done
    cmp al, 39
    je .ps_str_done
    cmp al, 0
    je .fail
    cmp al, 10
    je .fail
    cmp al, '\'
    jne .ps_str_plain
    inc rsi
    mov al, [rsi]
    cmp al, 'n'
    jne .ps_str_esc_other
    mov al, 10
    jmp .ps_str_esc_done
.ps_str_esc_other:
    mov al, '\'
    dec rsi
.ps_str_esc_done:
    mov [rbx], al
    inc rbx
    inc rsi
    inc r12
    jmp .ps_str_loop
.ps_str_plain:
    mov [rbx], al
    inc rbx
    inc rsi
    inc r12
    jmp .ps_str_loop
.ps_str_done:
    inc rsi
    mov rax, [rel strpool_len]
    add rax, r12
    mov [rel strpool_len], rax
    mov rax, [rel stmts_cnt]
    lea rdx, [rel stmts]
    imul rax, rax, 32
    add rdx, rax
    mov qword [rdx], 12
    mov qword [rdx+8], 4
    mov [rdx+16], rcx
    mov [rdx+24], r12
    inc qword [rel stmts_cnt]
    inc r14
    jmp .parg_next
.parg_done:
    mov rax, 1
    jmp .parg_out
.fail:
    xor eax, eax
.parg_out:
    pop r13
    pop r12
    pop rcx
    pop rbx
    ret

; opt_semi: semicolon optional at statement end. rax=1 ok (rsi advanced past ';' if present, else at next stmt start)
opt_semi:
    push rsi
    call ws_skip
    mov dil, ';'
    call expect_char
    test rax, rax
    jnz .os_consume
    pop rsi
    call ws_skip
    mov al, [rsi]
    cmp al, 0
    je .os_ok
    cmp al, '}'
    je .os_ok
    cmp al, '{'
    je .os_ok
    cmp al, '"'
    je .os_ok
    cmp al, 39
    je .os_ok
    cmp al, '*'
    je .os_ok
    movzx eax, al
    cmp eax, 'a'
    jb .os_dig
    cmp eax, 'z'
    jbe .os_ok
.os_dig:
    cmp eax, 'A'
    jb .os_num
    cmp eax, 'Z'
    jbe .os_ok
.os_num:
    cmp eax, '0'
    jb .os_fail
    cmp eax, '9'
    jbe .os_ok
    cmp eax, '_'
    je .os_ok
.os_fail:
    xor eax, eax
    ret
.os_ok:
    mov eax, 1
    ret
.os_consume:
    add rsp, 8
    mov eax, 1
    ret

; ws_skip_inline: rsi -> advance past spaces/tabs only (no newline)
ws_skip_inline:
    mov al, [rsi]
    cmp al, ' '
    je .ni
    cmp al, 9
    je .ni
    ret
.ni:
    inc rsi
    jmp ws_skip_inline

; ws_skip: rsi -> advance past whitespace
ws_skip:
    mov al, [rsi]
    cmp al, ' '
    je .n
    cmp al, 9
    je .n
    cmp al, 13
    je .n
    cmp al, 10
    je .n
    ret
.n:
    inc rsi
    jmp ws_skip

; is_digit_here: -> rax=1 if current char is '0'..'9'
is_digit_here:
    movzx eax, byte [rsi]
    cmp al, '0'
    jb .idh_no
    cmp al, '9'
    ja .idh_no
    mov rax, 1
    ret
.idh_no:
    xor eax, eax
    ret

; expect_id variants: r13 = keyword len
expect_id:
    lea rdi, [rel kw_int]
    jmp expect_id_gen
expect_id_main:
    lea rdi, [rel kw_main]
    jmp expect_id_gen
expect_id_print:
    lea rdi, [rel kw_print]
    jmp expect_id_gen
expect_id_ret:
    lea rdi, [rel kw_ret]
    jmp expect_id_gen
expect_id_while:
    lea rdi, [rel kw_while]
    jmp expect_id_gen
expect_id_if:
    lea rdi, [rel kw_if]
    jmp expect_id_gen
expect_id_else:
    lea rdi, [rel kw_else]
    jmp expect_id_gen
expect_id_import:
    lea rdi, [rel kw_import]
    jmp expect_id_gen
expect_id_imp:
    lea rdi, [rel kw_imp]
    jmp expect_id_gen
expect_id_namesp:
    lea rdi, [rel kw_namesp]
    jmp expect_id_gen
expect_id_def:
    lea rdi, [rel kw_def]
    jmp expect_id_gen
expect_id_bigint:
    lea rdi, [rel kw_bigint]
    jmp expect_id_gen
expect_id_char:
    lea rdi, [rel kw_char]
    jmp expect_id_gen
expect_id_str:
    lea rdi, [rel kw_str]
    jmp expect_id_gen
expect_id_string:
    lea rdi, [rel kw_string]
    jmp expect_id_gen
expect_id_bool:
    lea rdi, [rel kw_bool]
    jmp expect_id_gen
expect_id_ptr:
    lea rdi, [rel kw_ptr]
    jmp expect_id_gen
expect_id_for:
    lea rdi, [rel kw_for]
    jmp expect_id_gen
expect_id_break:
    lea rdi, [rel kw_break]
    jmp expect_id_gen
expect_id_continue:
    lea rdi, [rel kw_continue]
    jmp expect_id_gen
expect_id_gen:
    push rbx
    push rsi
    push rdi
    mov rbx, rsi
    mov rcx, r13
.loop:
    test rcx, rcx
    jz .match
    mov al, [rdi]
    cmp byte [rbx], al
    jne .no
    inc rdi
    inc rbx
    dec rcx
    jmp .loop
.match:
    mov al, [rbx]
    cmp al, ' '
    je .ok
    cmp al, '('
    je .ok
    cmp al, ')'
    je .ok
    cmp al, '{'
    je .ok
    cmp al, '}'
    je .ok
    cmp al, ';'
    je .ok
    cmp al, 39
    je .ok
    cmp al, '<'
    je .ok
    cmp al, ','
    je .ok
    cmp al, 9
    je .ok
    cmp al, 13
    je .ok
    cmp al, 10
    je .ok
    cmp al, 0
    je .ok
    jmp .no
.ok:
    pop rdi
    pop rsi
    pop rbx
    add rsi, r13
    mov rax, 1
    ret
.no:
    mov rdi, [rsp]
    call err_set_expected
    pop rdi
    pop rsi
    pop rbx
    xor eax, eax
    ret

; expect_char: dil = char
expect_char:
    cmp byte [rsi], dil
    jne .no
    inc rsi
    mov rax, 1
    ret
.no:
    push rsi
    lea rdi, [rel msg_expect_char]
    lea rsi, [rel err_msg_buf]
.nc_cp:
    mov al, [rdi]
    mov [rsi], al
    test al, al
    jz .nc_cp_done
    inc rdi
    inc rsi
    jmp .nc_cp
.nc_cp_done:
    mov rax, [rsp]
    movzx ecx, byte [rax]
    cmp ecx, 0
    je .nc_eof
    cmp ecx, 10
    je .nc_nl
    cmp ecx, 9
    je .nc_tab
    mov [rsi], cl
    inc rsi
    jmp .nc_close
.nc_eof:
    lea rcx, [rel msg_expect_eof]
    jmp .nc_append
.nc_nl:
    lea rcx, [rel msg_expect_nl]
    jmp .nc_append
.nc_tab:
    lea rcx, [rel msg_expect_tab]
.nc_append:
    mov al, [rcx]
    mov [rsi], al
    test al, al
    jz .nc_ap_done
    inc rcx
    inc rsi
    jmp .nc_append
.nc_ap_done:
.nc_close:
    mov byte [rsi], 39
    inc rsi
    mov byte [rsi], 0
    lea rax, [rel msg_etype_syntax]
    mov [rel err_type], rax
    lea rax, [rel err_msg_buf]
    mov [rel err_msg], rax
    pop rsi
    xor eax, eax
    ret

; parse_name: rsi -> parse identifier into tmp_name; r12=len, rax=ok
parse_name:
    push rbx
    push rcx
    push rdx
    push rdi
    lea rdi, [rel tmp_name]
    xor r12d, r12d
    movzx eax, byte [rsi]
    cmp eax, 'a'
    jb .pn_upper
    cmp eax, 'z'
    jbe .pn_first_ok
.pn_upper:
    cmp eax, 'A'
    jb .pn_us
    cmp eax, 'Z'
    jbe .pn_first_ok
.pn_us:
    cmp eax, '_'
    jne .pn_fail
.pn_first_ok:
    mov [rdi], al
    inc rdi
    inc rsi
    inc r12
.pn_loop:
    movzx eax, byte [rsi]
    cmp eax, 'a'
    jb .pn_c2
    cmp eax, 'z'
    jbe .pn_ok
.pn_c2:
    cmp eax, 'A'
    jb .pn_c3
    cmp eax, 'Z'
    jbe .pn_ok
.pn_c3:
    cmp eax, '0'
    jb .pn_c4
    cmp eax, '9'
    jbe .pn_ok
.pn_c4:
    cmp eax, '_'
    je .pn_ok
    cmp eax, '.'
    jne .pn_done
.pn_ok:
    mov [rdi], al
    inc rdi
    inc rsi
    inc r12
    cmp r12, 15
    jae .pn_fail
    jmp .pn_loop
.pn_done:
    mov byte [rdi], 0
    mov rax, 1
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret
.pn_fail:
    mov byte [rdi], 0
    xor eax, eax
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; is_keyword: tmp_name -> rax=1 if keyword else 0
is_keyword:
    push rbx
    push rcx
    push rdx
    push r12
    push rsi
    lea rbx, [rel kw_def]
    call .kw_cmp_one
    test rax, rax
    jnz .kw_out
    lea rbx, [rel kw_import]
    call .kw_cmp_one
    test rax, rax
    jnz .kw_out
    lea rbx, [rel kw_int]
    call .kw_cmp_one
    test rax, rax
    jnz .kw_out
    lea rbx, [rel kw_print]
    call .kw_cmp_one
    test rax, rax
    jnz .kw_out
    lea rbx, [rel kw_ret]
    call .kw_cmp_one
    test rax, rax
    jnz .kw_out
    lea rbx, [rel kw_bigint]
    call .kw_cmp_one
    test rax, rax
    jnz .kw_out
    lea rbx, [rel kw_char]
    call .kw_cmp_one
    test rax, rax
    jnz .kw_out
    lea rbx, [rel kw_str]
    call .kw_cmp_one
    test rax, rax
    jnz .kw_out
    lea rbx, [rel kw_string]
    call .kw_cmp_one
    test rax, rax
    jnz .kw_out
    lea rbx, [rel kw_bool]
    call .kw_cmp_one
    test rax, rax
    jnz .kw_out
    lea rbx, [rel kw_true]
    call .kw_cmp_one
    test rax, rax
    jnz .kw_out
    lea rbx, [rel kw_false]
    call .kw_cmp_one
    test rax, rax
    jnz .kw_out
    lea rbx, [rel kw_ptr]
    call .kw_cmp_one
    test rax, rax
    jnz .kw_out
    lea rbx, [rel kw_while]
    call .kw_cmp_one
    test rax, rax
    jnz .kw_out
    lea rbx, [rel kw_for]
    call .kw_cmp_one
    test rax, rax
    jnz .kw_out
    lea rbx, [rel kw_break]
    call .kw_cmp_one
    test rax, rax
    jnz .kw_out
    lea rbx, [rel kw_continue]
    call .kw_cmp_one
    test rax, rax
    jnz .kw_out
    lea rbx, [rel kw_if]
    call .kw_cmp_one
    test rax, rax
    jnz .kw_out
    lea rbx, [rel kw_else]
    call .kw_cmp_one
.kw_out:
    pop rsi
    pop r12
    pop rdx
    pop rcx
    pop rbx
    ret
.kw_cmp_one:
    lea rsi, [rel tmp_name]
    xor rdx, rdx
.kw_loop:
    mov al, [rsi]
    mov r8b, [rbx+rdx]
    cmp al, r8b
    jne .kw_nomatch
    test al, al
    jz .kw_match
    inc rsi
    inc rdx
    cmp rdx, 15
    jae .kw_nomatch
    jmp .kw_loop
.kw_match:
    mov rax, 1
    ret
.kw_nomatch:
    xor eax, eax
    ret

; add_func: add func entry from tmp_name; -> r15=idx, rax=ok
add_func:
    push rbx
    push rcx
    push rdx
    push r12
    push rsi
    mov rbx, [rel func_cnt]
    cmp rbx, 256
    jae .af_fail
    lea rcx, [rel func_table]
    imul rbx, rbx, 56
    add rcx, rbx
    lea rsi, [rel tmp_name]
    xor r12d, r12d
.af_copy:
    mov al, [rsi]
    mov [rcx+r12], al
    inc rsi
    inc r12
    cmp r12, 15
    jae .af_done
    test al, al
    jnz .af_copy
.af_done:
    mov qword [rcx+16], 0
    mov qword [rcx+24], 0
    mov qword [rcx+32], 0
    mov qword [rcx+40], 0
    mov dword [rcx+48], 0
    mov dword [rcx+52], 0
    mov rax, [rel func_cnt]
    imul rax, rax, 8
    lea rdx, [rel vararg_fwd]
    add rdx, rax
    mov qword [rdx], -1
    mov rax, [rel func_cnt]
    inc rax
    mov [rel func_cnt], rax
    dec rax
    mov r15, rax
    mov rax, 1
    pop rsi
    pop r12
    pop rdx
    pop rcx
    pop rbx
    ret
.af_fail:
    xor eax, eax
    pop rsi
    pop r12
    pop rdx
    pop rcx
    pop rbx
    ret

; install_builtins: register write(s) and str(s) as compiler-provided builtins.
; write(s): returns num; str(s): returns str. Both take one str-ref param (bit0 in ref_bmap).
install_builtins:
    push rbx
    push rcx
    push rdx
    push rsi
    push r12
    ; ---- write ----
    lea rsi, [rel kw_write]
    lea rdi, [rel tmp_name]
.ib_copy1:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy1
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_write], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 1
    mov qword [rcx+40], 0
    lea rdx, [rel ref_bmap]
    imul rax, r15, 8
    add rdx, rax
    mov qword [rdx], 1
    ; ---- str ----
    lea rsi, [rel kw_str]
    lea rdi, [rel tmp_name]
.ib_copy2:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy2
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_str], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 1
    mov qword [rcx+40], 1
    lea rdx, [rel ref_bmap]
    imul rax, r15, 8
    add rdx, rax
    mov qword [rdx], 1
    ; ---- os.create : no args, returns stdout id ----
    lea rsi, [rel kw_os_create]
    lea rdi, [rel tmp_name]
.ib_copy_osc:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy_osc
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_os_create], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 1
    mov qword [rcx+40], 0
    ; ---- os.init : one handle arg, returns 0 ----
    lea rsi, [rel kw_os_init]
    lea rdi, [rel tmp_name]
.ib_copy_osi:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy_osi
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_os_init], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 1
    mov qword [rcx+40], 0
    ; ---- os.print : varargs multi-object output -> 0 ----
    lea rsi, [rel kw_os_print]
    lea rdi, [rel tmp_name]
.ib_copy_ospr:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy_ospr
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_os_print], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 0
    mov qword [rcx+40], 0
    ; ---- os.print_s : (handle, str) -> 0 ----
    lea rsi, [rel kw_os_print_s]
    lea rdi, [rel tmp_name]
.ib_copy_osps:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy_osps
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_os_ps], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 2
    mov qword [rcx+40], 0
    lea rdx, [rel ref_bmap]
    imul rax, r15, 8
    add rdx, rax
    mov qword [rdx], 2
    ; ---- os.print_n : (handle, num) -> 0 ----
    lea rsi, [rel kw_os_print_n]
    lea rdi, [rel tmp_name]
.ib_copy_ospn:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy_ospn
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_os_pn], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 2
    mov qword [rcx+40], 0
    ; ---- os.nl : (handle) -> 0 ----
    lea rsi, [rel kw_os_nl]
    lea rdi, [rel tmp_name]
.ib_copy_osnl:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy_osnl
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_os_nl], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 1
    mov qword [rcx+40], 0
    ; ---- read_num : no args, returns int from stdin ----
    lea rsi, [rel kw_read_num]
    lea rdi, [rel tmp_name]
.ib_copy_rn:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy_rn
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_read_num], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 1
    mov qword [rcx+40], 0
    ; ---- get_char : no args, returns one char from stdin ----
    lea rsi, [rel kw_get_char]
    lea rdi, [rel tmp_name]
.ib_copy_gc:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy_gc
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_get_char], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 1
    mov qword [rcx+40], 0
    ; ---- tick_ms : no args, returns GetTickCount64 ----
    lea rsi, [rel kw_tick_ms]
    lea rdi, [rel tmp_name]
.ib_copy_tm:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy_tm
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_tick_ms], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 1
    mov qword [rcx+40], 0
    ; ---- rand : one num arg, returns 0..arg-1 ----
    lea rsi, [rel kw_rand]
    lea rdi, [rel tmp_name]
.ib_copy_rd:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy_rd
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_rand], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 1
    mov qword [rcx+40], 0
    ; ---- putch : one num arg, output low byte as char, returns 0 ----
.ib_putch_block:
    lea rsi, [rel kw_putch]
    lea rdi, [rel tmp_name]
.ib_copy_putch:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy_putch
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_putch], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 1
    mov qword [rcx+40], 0
    ; ---- str_len : one str arg, returns byte length ----
.ib_sl_block:
    lea rsi, [rel kw_str_len]
    lea rdi, [rel tmp_name]
.ib_copy_sl:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy_sl
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_str_len], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 1
    mov qword [rcx+40], 0
    ; ---- str_get : (str, int) -> int byte at index ----
.ib_sg_block:
    lea rsi, [rel kw_str_get]
    lea rdi, [rel tmp_name]
.ib_copy_sg:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy_sg
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_str_get], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 2
    mov qword [rcx+40], 0
    ; ---- win_create : () -> int hwnd (NULL ???) ----
.ib_wc_block:
    ; ?????? window.dll ??dll_list??t_win_* ?????? GetProcAddress ??????
    mov rax, [rel dll_cnt]
    cmp rax, 8
    jae .ib_wc_skip
    lea rbx, [rel dll_list]
    imul rax, rax, 64
    add rbx, rax
    lea r15, [rel win_dll_path]
.ib_wc_cp:
    mov al, [r15]
    mov [rbx], al
    test al, al
    jz .ib_wc_cp_done
    inc r15
    inc rbx
    jmp .ib_wc_cp
.ib_wc_cp_done:
    inc qword [rel dll_cnt]
.ib_wc_skip:
    lea rsi, [rel kw_win_create]
    lea rdi, [rel tmp_name]
.ib_copy_wc:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy_wc
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_win_create], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 1
    mov qword [rcx+40], 0
    ; ---- win_show : (hwnd) -> int ----
.ib_ws_block:
    lea rsi, [rel kw_win_show]
    lea rdi, [rel tmp_name]
.ib_copy_ws:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy_ws
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_win_show], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 1
    mov qword [rcx+40], 0
    ; ---- win_hide : (hwnd) -> int ----
.ib_wh_block:
    lea rsi, [rel kw_win_hide]
    lea rdi, [rel tmp_name]
.ib_copy_wh:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy_wh
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_win_hide], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 1
    mov qword [rcx+40], 0
    ; ---- win_close : (hwnd) -> int ----
.ib_wcl_block:
    lea rsi, [rel kw_win_close]
    lea rdi, [rel tmp_name]
.ib_copy_wcl:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy_wcl
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_win_close], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 1
    mov qword [rcx+40], 0
    ; ---- win_title : (hwnd, str) -> int ----
.ib_wt_block:
    lea rsi, [rel kw_win_title]
    lea rdi, [rel tmp_name]
.ib_copy_wt:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .ib_copy_wt
    call add_func
    test rax, rax
    jz .ib_fail
    mov [rel builtin_win_title], r15
    lea rcx, [rel func_table]
    imul rax, r15, 56
    add rcx, rax
    mov qword [rcx+16], 2
    mov qword [rcx+40], 0
    mov rax, 1
    jmp .ib_out
.ib_fail:
    xor eax, eax
.ib_out:
    pop r12
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; alloc_tmp_num: ??????????num ???????????????????????????????
; -> r15=idx, rax=1 ok / 0 fail. ????????????????r15/rax ???
alloc_tmp_num:
    push rbx
    push rcx
    push rdx
    push r12
    push rsi
    mov rax, [rel var_cnt]
    cmp rax, 256
    jae .atn_fail
    lea rcx, [rel var_table]
    imul rax, rax, 56
    add rcx, rax
    mov qword [rcx], 0
    mov qword [rcx+16], 1
    mov rax, [rel cur_local_cnt]
    mov [rcx+24], rax
    mov qword [rcx+32], 0
    mov rax, [rel cur_func]
    mov [rcx+40], rax
    mov qword [rcx+48], 0
    inc qword [rel cur_local_cnt]
    mov rax, [rel var_cnt]
    inc rax
    mov [rel var_cnt], rax
    dec rax
    mov r15, rax
    mov rax, 1
    pop rsi
    pop r12
    pop rdx
    pop rcx
    pop rbx
    ret
.atn_fail:
    xor eax, eax
    pop rsi
    pop r12
    pop rdx
    pop rcx
    pop rbx
    ret

; add_var: r13=kind(0 param/1 local), r14=type(0 num/1 str); tmp_name=name
; -> r15=idx, rax=ok. param slot via cur_param_slot, local via cur_local_cnt
add_var:
    push rbx
    push rcx
    push rdx
    push r12
    push rsi
    mov rbx, [rel var_cnt]
    cmp rbx, 256
    jae .av_fail
    lea rcx, [rel var_table]
    imul rbx, rbx, 56
    add rcx, rbx
    lea rsi, [rel tmp_name]
    xor r12d, r12d
.av_copy:
    mov al, [rsi]
    mov [rcx+r12], al
    inc rsi
    inc r12
    cmp r12, 15
    jae .av_done
    test al, al
    jnz .av_copy
.av_done:
    mov [rcx+16], r13
    mov qword [rcx+24], 0
    mov [rcx+32], r14
    mov rax, [rel cur_func]
    mov [rcx+40], rax
    cmp r13, 0
    jne .av_local
    mov rax, [rel cur_param_slot]
    mov [rcx+24], rax
    mov rax, [rel cur_param_ref]
    mov [rcx+48], rax
    inc qword [rel cur_param_slot]
    jmp .av_cnt
.av_local:
    mov rax, [rel cur_local_cnt]
    mov [rcx+24], rax
    mov qword [rcx+48], 0
    cmp r14, 1
    jne .av_local_num
    add qword [rel cur_local_cnt], 2
    jmp .av_cnt
.av_local_num:
    inc qword [rel cur_local_cnt]
.av_cnt:
    mov rax, [rel var_cnt]
    inc rax
    mov [rel var_cnt], rax
    dec rax
    mov r15, rax
    mov rax, 1
    pop rsi
    pop r12
    pop rdx
    pop rcx
    pop rbx
    ret
.av_fail:
    xor eax, eax
    pop rsi
    pop r12
    pop rdx
    pop rcx
    pop rbx
    ret

; find_func: tmp_name -> r15=idx or -1
find_func:
    push rbx
    push rcx
    push rdx
    push r12
    push rsi
    mov r15, -1
    mov rcx, [rel func_cnt]
    test rcx, rcx
    jz .ff_out
    lea rbx, [rel func_table]
    xor r12d, r12d
.ff_loop:
    lea rsi, [rel tmp_name]
    xor rdx, rdx
.ff_cmp:
    mov al, [rsi]
    mov r8b, [rbx+rdx]
    cmp al, r8b
    jne .ff_next
    test al, al
    jz .ff_found
    inc rsi
    inc rdx
    cmp rdx, 15
    jae .ff_next
    jmp .ff_cmp
.ff_next:
    add rbx, 56
    inc r12
    cmp r12, rcx
    jb .ff_loop
    jmp .ff_out
.ff_found:
    mov r15, r12
.ff_out:
    pop rsi
    pop r12
    pop rdx
    pop rcx
    pop rbx
    ret

; find_var: tmp_name -> r15=idx or -1 (visible: same func locals or main globals)
find_var:
    push rbx
    push rcx
    push rdx
    push r12
    push rsi
    mov r15, -1
    mov rcx, [rel var_cnt]
    test rcx, rcx
    jz .fv_out
    lea rbx, [rel var_table]
    xor r12d, r12d
.fv_loop:
    lea rsi, [rel tmp_name]
    xor rdx, rdx
.fv_cmp:
    mov al, [rsi]
    mov r8b, [rbx+rdx]
    cmp al, r8b
    jne .fv_next
    test al, al
    jz .fv_name_ok
    inc rsi
    inc rdx
    cmp rdx, 15
    jae .fv_next
    jmp .fv_cmp
.fv_name_ok:
    mov rax, [rbx+40]
    cmp rax, [rel cur_func]
    je .fv_found
    cmp rax, -1
    je .fv_found
.fv_next:
    add rbx, 56
    inc r12
    cmp r12, rcx
    jb .fv_loop
    jmp .fv_out
.fv_found:
    mov r15, r12
.fv_out:
    pop rsi
    pop r12
    pop rdx
    pop rcx
    pop rbx
    ret

; parse_num: rsi -> rax (also recognizes true/false literals)
parse_num:
    push rbx
    push rdx
    push r8
    lea rbx, [rel kw_true]
    call .lit_cmp
    test rax, rax
    jz .lit_nf
    mov rax, 1
    pop r8
    pop rdx
    pop rbx
    ret
.lit_nf:
    lea rbx, [rel kw_false]
    call .lit_cmp
    test rax, rax
    jz .lit_none
    mov rax, 0
    pop r8
    pop rdx
    pop rbx
    ret
.lit_none:
    xor ebx, ebx
    cmp byte [rsi], '0'
    jne .dec
    cmp byte [rsi+1], 'x'
    jne .dec
    add rsi, 2
.hex:
    movzx eax, byte [rsi]
    cmp eax, '0'
    jb .hexd
    cmp eax, '9'
    ja .hex1
    sub eax, '0'
    jmp .hexadd
.hex1:
    movzx eax, byte [rsi]
    or eax, 0x20
    cmp eax, 'a'
    jb .hexd
    cmp eax, 'f'
    ja .hexd
    sub eax, 'a'
    add eax, 10
.hexadd:
    shl rbx, 4
    add rbx, rax
    inc rsi
    jmp .hex
.hexd:
    mov rax, rbx
    pop r8
    pop rdx
    pop rbx
    ret
.dec:
    movzx eax, byte [rsi]
    cmp eax, '0'
    jb .decd
    cmp eax, '9'
    ja .decd
    sub eax, '0'
    imul rbx, rbx, 10
    add rbx, rax
    inc rsi
    jmp .dec
.decd:
    mov rax, rbx
    pop r8
    pop rdx
    pop rbx
    ret
; .lit_cmp: rbx=&keyword, rsi=&src -> rax=1 if keyword matches and next char not idchar (rsi advanced), else rax=0
.lit_cmp:
    xor rdx, rdx
.lc_loop:
    mov al, [rsi+rdx]
    mov r8b, [rbx+rdx]
    test r8b, r8b
    jz .lc_key_end
    cmp al, r8b
    jne .lc_no
    inc rdx
    cmp rdx, 8
    jae .lc_no
    jmp .lc_loop
.lc_key_end:
    mov al, [rsi+rdx]
    cmp al, 'a'
    jb .lc_c2
    cmp al, 'z'
    jbe .lc_no
.lc_c2:
    cmp al, 'A'
    jb .lc_c3
    cmp al, 'Z'
    jbe .lc_no
.lc_c3:
    cmp al, '0'
    jb .lc_c4
    cmp al, '9'
    jbe .lc_no
.lc_c4:
    cmp al, '_'
    je .lc_no
    add rsi, rdx
    mov rax, 1
    ret
.lc_no:
    xor eax, eax
    ret

; ---- emit helpers (def/var support) ----
; emit_load_num: r15=var idx -> 'mov rax, [rbp+-N]'
emit_load_num:
    push rbx
    push rcx
    push rdx
    push rdi
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    mov rdx, [rcx+16]
    mov rbx, [rcx+24]
    cmp rdx, 0
    je .eln_param
    lea rdi, [rel c_mov_rax_rbp_sub]
    call emit_cstr
    mov rax, rbx
    inc rax
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
    jmp .eln_out
.eln_param:
    ; param slot holds value directly (num or str ptr), no double deref
    lea rdi, [rel c_mov_rax_rbp_add]
    call emit_cstr
    mov rax, rbx
    imul rax, rax, 8
    add rax, 16
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
.eln_out:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; emit_add_num: r15=var idx -> 'add rax, [rbp+-N]'
emit_add_num:
    push rbx
    push rcx
    push rdx
    push rdi
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    mov rdx, [rcx+16]
    mov rbx, [rcx+24]
    cmp rdx, 0
    je .ean_param
    lea rdi, [rel c_add_rax_rbp_sub]
    call emit_cstr
    mov rax, rbx
    inc rax
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
    jmp .ean_out
.ean_param:
    lea rdi, [rel c_add_rax_rbp_add]
    call emit_cstr
    mov rax, rbx
    imul rax, rax, 8
    add rax, 16
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
.ean_out:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; emit_sub_num: r15=var idx -> 'sub rax, [rbp+-N]'
emit_sub_num:
    push rbx
    push rcx
    push rdx
    push rdi
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    mov rdx, [rcx+16]
    mov rbx, [rcx+24]
    cmp rdx, 0
    je .esn2_param
    lea rdi, [rel c_sub_rax_rbp_sub]
    call emit_cstr
    mov rax, rbx
    inc rax
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
    jmp .esn2_out
.esn2_param:
    lea rdi, [rel c_sub_rax_rbp_add]
    call emit_cstr
    mov rax, rbx
    imul rax, rax, 8
    add rax, 16
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
.esn2_out:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; emit_mul_num: r15=var idx -> 'imul rax, [rbp+-N]'
emit_mul_num:
    push rbx
    push rcx
    push rdx
    push rdi
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    mov rdx, [rcx+16]
    mov rbx, [rcx+24]
    cmp rdx, 0
    je .emn_param
    lea rdi, [rel c_imul_rax_rbp_sub]
    call emit_cstr
    mov rax, rbx
    inc rax
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
    jmp .emn_out
.emn_param:
    lea rdi, [rel c_imul_rax_rbp_add]
    call emit_cstr
    mov rax, rbx
    imul rax, rax, 8
    add rax, 16
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
.emn_out:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; emit_div_num: r15=var idx -> 'mov rcx,[rbp+-N]' + 'xor edx,edx' + 'div rcx'
emit_div_num:
    push rbx
    push rcx
    push rdx
    push rdi
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    mov rdx, [rcx+16]
    mov rbx, [rcx+24]
    cmp rdx, 0
    je .edn_param
    lea rdi, [rel c_mov_rcx_rbp_sub]
    call emit_cstr
    mov rax, rbx
    inc rax
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
    jmp .edn_div
.edn_param:
    lea rdi, [rel c_mov_rcx_rbp_add]
    call emit_cstr
    mov rax, rbx
    imul rax, rax, 8
    add rax, 16
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
.edn_div:
    lea rdi, [rel c_xor_edx]
    call emit_cstr
    lea rdi, [rel c_div_rcx]
    call emit_cstr
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; emit_store_num: r15=var idx -> 'mov [rbp+-N], rax'
emit_store_num:
    push rbx
    push rcx
    push rdx
    push rdi
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    mov rdx, [rcx+16]
    mov rbx, [rcx+24]
    cmp rdx, 0
    je .esn_param
    lea rdi, [rel c_mov_rbp_sub]
    call emit_cstr
    mov rax, rbx
    inc rax
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_mov_rbp_sub_rax]
    call emit_cstr
    jmp .esn_out
.esn_param:
    cmp qword [rcx+48], 0
    je .esn_param_val
    ; ref (no-swap): param slot holds address -> rcx=&var; [rcx]=value(rax)
    lea rdi, [rel c_mov_rcx_rbp_add]
    call emit_cstr
    mov rax, rbx
    imul rax, rax, 8
    add rax, 16
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
    lea rdi, [rel c_mov_mem_rcx_rax]
    call emit_cstr
    jmp .esn_out
.esn_param_val:
    lea rdi, [rel c_mov_rbp_add]
    call emit_cstr
    mov rax, rbx
    imul rax, rax, 8
    add rax, 16
    call emit_num
    lea rdi, [rel c_mov_rbp_sub_rax]
    call emit_cstr
.esn_out:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; emit_addr_of: r15=var idx -> 'lea rax, [rbp-N]' (address of variable)
emit_addr_of:
    push rbx
    push rcx
    push rdx
    push rdi
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    mov rdx, [rcx+16]
    mov rbx, [rcx+24]
    cmp rdx, 0
    je .eao_param
    lea rdi, [rel c_lea_rax_rbp_sub]
    call emit_cstr
    mov rax, rbx
    inc rax
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
    jmp .eao_out
.eao_param:
    lea rdi, [rel c_lea_rax_rbp_add]
    call emit_cstr
    mov rax, rbx
    imul rax, rax, 8
    add rax, 16
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
.eao_out:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; emit_load_str: r15=var idx -> rsi=str ptr, rdx=len (local or ref str param)
emit_load_str:
    push rbx
    push rcx
    push rdx
    push rdi
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    mov rdx, [rcx+16]
    mov rbx, [rcx+24]
    cmp rdx, 0
    je .els_param
    lea rdi, [rel c_mov_rsi_rbp_sub]
    call emit_cstr
    mov rax, rbx
    inc rax
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
    lea rdi, [rel c_mov_rdx_rbp_sub]
    call emit_cstr
    mov rax, rbx
    inc rax
    imul rax, rax, 8
    add rax, 8
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
    jmp .els_out
.els_param:
    cmp qword [rcx+32], 1
    jne .els_out
    ; str param: slot holds ptr value directly
    lea rdi, [rel c_mov_rsi_rbp_add]
    call emit_cstr
    mov rax, rbx
    imul rax, rax, 8
    add rax, 16
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
    lea rdi, [rel c_call_strlen]
    call emit_cstr
    lea rdi, [rel c_mov_rdx_rax]
    call emit_cstr
.els_out:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; emit_store_str: r15=var idx, rsi=ptr, rdx=len -> store 2 slots (local or ref str param)
emit_store_str:
    push rbx
    push rcx
    push rdx
    push rdi
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    mov rax, [rcx+16]
    mov rbx, [rcx+24]
    cmp rax, 0
    je .ess_param
    lea rdi, [rel c_mov_rbp_sub]
    call emit_cstr
    mov rax, rbx
    inc rax
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_mov_rbp_sub_rsi]
    call emit_cstr
    lea rdi, [rel c_mov_rbp_sub]
    call emit_cstr
    mov rax, rbx
    inc rax
    imul rax, rax, 8
    add rax, 8
    call emit_num
    lea rdi, [rel c_mov_rbp_sub_rdx]
    call emit_cstr
    jmp .ess_out
.ess_param:
    cmp qword [rcx+32], 1
    jne .ess_out
    ; str param: slot holds ptr value; store ptr at slot (no write-back)
    lea rdi, [rel c_mov_rbp_add]
    call emit_cstr
    mov rax, rbx
    imul rax, rax, 8
    add rax, 16
    call emit_num
    lea rdi, [rel c_mov_rbp_sub_rsi]
    call emit_cstr
.ess_out:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; emit_qword_const: r15=var idx, rax=value -> 'mov qword [rbp+-N], <value>'
emit_qword_const:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rcx, rax
    mov rdx, [rcx+16]
    mov rbx, [rcx+24]
    cmp rdx, 0
    je .eqc_param
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, [rsp+32]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_mov_rbp_sub]
    call emit_cstr
    mov rax, rbx
    inc rax
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_mov_rbp_sub_rax]
    call emit_cstr
    jmp .eqc_out
.eqc_param:
    cmp qword [rcx+48], 0
    je .eqc_param_val
    ; ref (no-swap): param slot holds address -> deref store with const
    lea rdi, [rel c_mov_rax_rbp_add]
    call emit_cstr
    mov rax, rbx
    imul rax, rax, 8
    add rax, 16
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
    lea rdi, [rel c_mov_rcx_rax]
    call emit_cstr
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, [rsp+32]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_mov_mem_rcx_rax]
    call emit_cstr
    jmp .eqc_out
.eqc_param_val:
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, [rsp+32]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_mov_rbp_add]
    call emit_cstr
    mov rax, rbx
    imul rax, rax, 8
    add rax, 16
    call emit_num
    lea rdi, [rel c_mov_rbp_sub_rax]
    call emit_cstr
.eqc_out:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; emit_call_prep: rcx=stmt ptr, r12=stmt idx -> push args(reverse), call func, add rsp
emit_call_prep:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 0x28
    mov r13, [rcx+8]
    mov r15, [rcx+24]
    test r15, r15
    jz .ecp_noargs
    mov rbx, r12
    add rbx, r15
.ecp_loop:
    cmp rbx, r12
    jle .ecp_noargs
    lea rdx, [rel stmts]
    mov rax, rbx
    imul rax, rax, 32
    add rdx, rax
    cmp qword [rdx+8], 3
    je .ecp_addr
    cmp qword [rdx+8], 0
    je .ecp_const
    cmp qword [rdx+8], 4
    je .ecp_str
    mov r14, [rdx+16]
    ; str var -> push slot address (lea) so inlined/os readers can access [slot]=ptr,[slot-8]=len; num/ptr -> push value
    ; NOTE: keep rcx (func_table ptr) intact; use rsi as scratch
    lea rsi, [rel var_table]
    mov rax, r14
    imul rax, rax, 56
    add rsi, rax
    cmp qword [rsi+32], 1
    push rbx
    push rcx
    mov r15, r14
    ; str var -> push value (mov rax,[rbp-N]) instead of slot address (lea),
    ; so callee-side single deref ([rbp+16]->[rcx]) yields string pointer uniformly
    call emit_load_num
    jmp .ecp_loop_var_push
.ecp_loop_var_num:
    call emit_load_num
.ecp_loop_var_push:
    pop rcx
    pop rbx
    lea rdi, [rel c_push_rax]
    call emit_cstr
    dec rbx
    jmp .ecp_loop
.ecp_addr:
    ; variable arg: only ptr type passes address; num/str push value
    mov r14, [rdx+16]
    push rbx
    push rcx
    mov r15, r14
    lea rsi, [rel var_table]
    mov rax, r14
    imul rax, rax, 56
    add rsi, rax
    cmp qword [rsi+32], 2
    jne .ecp_addr_val
    call emit_addr_of
    jmp .ecp_addr_push
.ecp_addr_val:
    call emit_load_num
.ecp_addr_push:
    pop rcx
    pop rbx
    lea rdi, [rel c_push_rax]
    call emit_cstr
    dec rbx
    jmp .ecp_loop
.ecp_const:
    push rbx
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, [rdx+16]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_push_rax]
    call emit_cstr
    pop rbx
    dec rbx
    jmp .ecp_loop
.ecp_str:
    ; str const arg: lea rax,[rel str_<stmt idx>]; push rax
    push rbx
    lea rdi, [rel c_lea_rax_str]
    call emit_cstr
    mov rax, rbx
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
    lea rdi, [rel c_push_rax]
    call emit_cstr
    pop rbx
    dec rbx
    jmp .ecp_loop
.ecp_noargs:
    ; builtin interception: write(s) and str(s) are inlined at call site
    mov rax, [rel builtin_write]
    cmp r13, rax
    je .ecp_bw
    mov rax, [rel builtin_str]
    cmp r13, rax
    je .ecp_bs
    mov rax, [rel builtin_read_num]
    cmp r13, rax
    je .ecp_read_num
    mov rax, [rel builtin_get_char]
    cmp r13, rax
    je .ecp_get_char
    mov rax, [rel builtin_tick_ms]
    cmp r13, rax
    je .ecp_tick_ms
    mov rax, [rel builtin_rand]
    cmp r13, rax
    je .ecp_rand
    mov rax, [rel builtin_putch]
    cmp r13, rax
    je .ecp_putch
    mov rax, [rel builtin_str_len]
    cmp r13, rax
    je .ecp_strlen
    mov rax, [rel builtin_str_get]
    cmp r13, rax
    je .ecp_strget
    mov rax, [rel builtin_os_create]
    cmp r13, rax
    je .ecp_os_create
    mov rax, [rel builtin_os_init]
    cmp r13, rax
    je .ecp_os_init
    mov rax, [rel builtin_os_ps]
    cmp r13, rax
    je .ecp_os_ps
    mov rax, [rel builtin_os_pn]
    cmp r13, rax
    je .ecp_os_pn
    mov rax, [rel builtin_os_nl]
    cmp r13, rax
    je .ecp_os_nl
    mov rax, [rel builtin_os_print]
    cmp r13, rax
    je .ecp_os_print
    mov rax, [rel builtin_win_create]
    cmp r13, rax
    je .ecp_win_create
    mov rax, [rel builtin_win_show]
    cmp r13, rax
    je .ecp_win_show
    mov rax, [rel builtin_win_hide]
    cmp r13, rax
    je .ecp_win_hide
    mov rax, [rel builtin_win_close]
    cmp r13, rax
    je .ecp_win_close
    mov rax, [rel builtin_win_title]
    cmp r13, rax
    je .ecp_win_title
    lea rdi, [rel c_call_func]
    call emit_cstr
    mov rax, r13
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    mov r15, [rcx+24]
    test r15, r15
    jz .ecp_noadd
    lea rdi, [rel c_add_rsp]
    call emit_cstr
    mov rax, r15
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
.ecp_noadd:
    add rsp, 0x28
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.ecp_putch:
    ; putch(c): rax=[rsp]; call rt_putch; add rsp, 8
    lea rdi, [rel c_mov_rax_rsp]
    call emit_cstr
    lea rdi, [rel c_call_putch]
    call emit_cstr
    lea rdi, [rel c_add_rsp]
    call emit_cstr
    mov rax, 8
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .ecp_noadd
.ecp_strlen:
    ; str_len(s): rsi=[rsp]; call rt_strlen; add rsp, 8
    lea rdi, [rel c_mov_rsi_rsp]
    call emit_cstr
    lea rdi, [rel c_call_strlen]
    call emit_cstr
    lea rdi, [rel c_add_rsp]
    call emit_cstr
    mov rax, 8
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .ecp_noadd
.ecp_strget:
    ; str_get(s,i): rsi=[rsp]; rcx=[rsp+8]; call rt_str_get; add rsp, 16
    lea rdi, [rel c_mov_rsi_rsp]
    call emit_cstr
    lea rdi, [rel c_mov_rcx_rsp8]
    call emit_cstr
    lea rdi, [rel c_call_strget]
    call emit_cstr
    lea rdi, [rel c_add_rsp]
    call emit_cstr
    mov rax, 16
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .ecp_noadd
.ecp_win_create:
    ; win_create(): call rt_win_create -> rax = hwnd (0 ???)
    lea rdi, [rel c_call_wincreate]
    call emit_cstr
    jmp .ecp_noadd
.ecp_win_show:
    ; win_show(w): rcx=[rsp]; call rt_win_show; add rsp, 8
    lea rdi, [rel c_mov_rcx_rsp]
    call emit_cstr
    lea rdi, [rel c_call_winshow]
    call emit_cstr
    lea rdi, [rel c_add_rsp]
    call emit_cstr
    mov rax, 8
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .ecp_noadd
.ecp_win_hide:
    ; win_hide(w): rcx=[rsp]; call rt_win_hide; add rsp, 8
    lea rdi, [rel c_mov_rcx_rsp]
    call emit_cstr
    lea rdi, [rel c_call_winhide]
    call emit_cstr
    lea rdi, [rel c_add_rsp]
    call emit_cstr
    mov rax, 8
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .ecp_noadd
.ecp_win_close:
    ; win_close(w): rcx=[rsp]; call rt_win_close; add rsp, 8
    lea rdi, [rel c_mov_rcx_rsp]
    call emit_cstr
    lea rdi, [rel c_call_winclose]
    call emit_cstr
    lea rdi, [rel c_add_rsp]
    call emit_cstr
    mov rax, 8
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .ecp_noadd
.ecp_win_title:
    ; win_title(w,s): rcx=[rsp]; rdx=[rsp+8]; call rt_win_title; add rsp, 16
    lea rdi, [rel c_mov_rcx_rsp]
    call emit_cstr
    lea rdi, [rel c_mov_rdx_rsp8]
    call emit_cstr
    lea rdi, [rel c_call_wintitle]
    call emit_cstr
    lea rdi, [rel c_add_rsp]
    call emit_cstr
    mov rax, 16
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .ecp_noadd
.ecp_read_num:
    ; read_num(): call rt read_int_stdin -> rax = value
    lea rdi, [rel c_call_readint]
    call emit_cstr
    jmp .ecp_noadd
.ecp_get_char:
    ; get_char(): call rt getchar_stdin -> rax = char
    lea rdi, [rel c_call_getchar]
    call emit_cstr
    jmp .ecp_noadd
.ecp_tick_ms:
    ; tick_ms(): call rt time_ms -> rax = ms
    lea rdi, [rel c_call_timems]
    call emit_cstr
    jmp .ecp_noadd
.ecp_rand:
    ; rand(n): arg pushed at [rsp] -> rcx=[rsp]; call rt random_rand; caller adds rsp
    lea rdi, [rel c_mov_rcx_rsp]
    call emit_cstr
    lea rdi, [rel c_call_random]
    call emit_cstr
    jmp .ecp_noadd
.ecp_os_create:
    ; os.create(): rax=1 (stdout id)
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, 1
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .ecp_noadd
.ecp_os_init:
    ; os.init(h): ignore h at [rsp]; ret 0; caller adds rsp
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, 0
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_add_rsp]
    call emit_cstr
    mov rax, [rcx+24]
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .ecp_noadd
.ecp_os_ps:
    ; os.print_s(h,s): ignore h ([rsp]); print s ([rsp+8]); caller adds rsp
    lea rdx, [rel stmts]
    mov rax, r12
    add rax, 2
    imul rax, rax, 32
    add rdx, rax
    cmp qword [rdx+8], 4
    je .ecp_os_ps_lit
    lea rdi, [rel c_mov_rcx_rsp8]
    call emit_cstr
    lea rdi, [rel c_mov_rsi_mem_rcx]
    call emit_cstr
    lea rdi, [rel c_call_strlen]
    call emit_cstr
    lea rdi, [rel c_mov_rdx_rax]
    call emit_cstr
    lea rdi, [rel c_call_pstr]
    call emit_cstr
    lea rdi, [rel c_add_rsp]
    call emit_cstr
    mov rax, [rcx+24]
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .ecp_noadd
.ecp_os_ps_lit:
    ; literal string: rsi=[rsp+8] (ptr), rdx=len const
    mov rbx, [rdx+24]
    push rbx
    lea rdi, [rel c_mov_rsi_rsp8]
    call emit_cstr
    lea rdi, [rel c_mov_rdx]
    call emit_cstr
    pop rbx
    mov rax, rbx
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_call_pstr]
    call emit_cstr
    lea rdi, [rel c_add_rsp]
    call emit_cstr
    mov rax, [rcx+24]
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .ecp_noadd
.ecp_os_pn:
    ; os.print_n(h,n): ignore h ([rsp]); print n ([rsp+8]) via rt_print_num
    lea rdi, [rel c_mov_rax_rsp8]
    call emit_cstr
    lea rdi, [rel c_call_pnum]
    call emit_cstr
    lea rdi, [rel c_add_rsp]
    call emit_cstr
    mov rax, [rcx+24]
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .ecp_noadd
.ecp_os_nl:
    ; os.nl(h): ignore h ([rsp]); print CRLF
    lea rdi, [rel c_lea_rsi_osnl]
    call emit_cstr
    lea rdi, [rel c_mov_rdx]
    call emit_cstr
    mov rax, 2
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_call_pstr]
    call emit_cstr
    lea rdi, [rel c_add_rsp]
    call emit_cstr
    mov rax, [rcx+24]
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .ecp_noadd
.ecp_os_print:
    ; os.print(*args): N args on stack, [rsp]=arg0 ... [rsp+(N-1)*8]=argN-1
    ; per-arg: num -> rt_print_num; str lit -> ptr+len; str var -> desc ptr+len; ptr var -> rt_print_hex
    mov r14, [rcx+24]
    test r14, r14
    jz .ecp_os_print_end
    xor r15d, r15d
.ecp_os_print_loop:
    lea rdx, [rel stmts]
    mov rax, r12
    inc rax
    add rax, r15
    imul rax, rax, 32
    add rdx, rax
    mov rbx, [rdx+8]
    mov rcx, r15
    imul rcx, rcx, 8
    cmp rbx, 0
    je .ecp_os_p_num
    cmp rbx, 4
    je .ecp_os_p_strlit
    cmp rbx, 2
    je .ecp_os_p_var
    jmp .ecp_os_p_skip
.ecp_os_p_num:
    lea rdi, [rel c_mov_rax_rsp_off]
    call emit_cstr
    mov rax, rcx
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
    lea rdi, [rel c_call_pnum]
    call emit_cstr
    jmp .ecp_os_print_next
.ecp_os_p_strlit:
    lea rdi, [rel c_mov_rsi_rsp_off]
    call emit_cstr
    mov rax, rcx
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
    lea rdx, [rel stmts]
    mov rax, r12
    inc rax
    add rax, r15
    imul rax, rax, 32
    add rdx, rax
    mov rbx, [rdx+24]
    lea rdi, [rel c_mov_rdx]
    call emit_cstr
    mov rax, rbx
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_call_pstr]
    call emit_cstr
    jmp .ecp_os_print_next
.ecp_os_p_var:
    ; num/str/ptr decided by var_table[var*56+32]
    lea rdx, [rel stmts]
    mov rax, r12
    inc rax
    add rax, r15
    imul rax, rax, 32
    add rdx, rax
    mov rax, [rdx+16]
    imul rax, rax, 56
    lea rdx, [rel var_table]
    add rdx, rax
    cmp qword [rdx+32], 1
    je .ecp_os_p_var_str
    cmp qword [rdx+32], 2
    je .ecp_os_p_var_ptr
    jmp .ecp_os_p_num
.ecp_os_p_var_str:
    ; str var arg is pushed as ptr value now (emit_call_prep change), so [rsp+off]=ptr
    lea rdi, [rel c_mov_rsi_rsp_off]
    call emit_cstr
    mov rax, rcx
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
    lea rdi, [rel c_call_strlen]
    call emit_cstr
    lea rdi, [rel c_mov_rdx_rax]
    call emit_cstr
    lea rdi, [rel c_call_pstr]
    call emit_cstr
    jmp .ecp_os_print_next
.ecp_os_p_var_ptr:
    lea rdi, [rel c_mov_rax_rsp_off]
    call emit_cstr
    mov rax, rcx
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
    lea rdi, [rel c_call_phex]
    call emit_cstr
    jmp .ecp_os_print_next
.ecp_os_p_skip:
    jmp .ecp_os_print_next
.ecp_os_print_next:
    inc r15
    cmp r15, r14
    jb .ecp_os_print_loop
.ecp_os_print_end:
    ; clean up N args (restores 16-byte alignment of caller stack)
    lea rcx, [rel stmts]
    mov rax, r12
    imul rax, rax, 32
    add rcx, rax
    mov r15, [rcx+24]
    test r15, r15
    jz .ecp_op_no
    lea rdi, [rel c_add_rsp]
    call emit_cstr
    mov rax, r15
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
.ecp_op_no:
    jmp .ecp_noadd
.ecp_bw:
    ; write(s): inspect first arg stmt (stmts[r12+1]); kind=4 literal -> ptr=[rsp], len=const
    lea rdx, [rel stmts]
    mov rax, r12
    inc rax
    imul rax, rax, 32
    add rdx, rax
    cmp qword [rdx+8], 4
    je .ecp_bw_lit
    ; var arg: [rsp]=addr of str slot -> rsi=[addr]=ptr, rdx=[addr-8]=len
    lea rdi, [rel c_mov_rcx_rsp]
    call emit_cstr
    lea rdi, [rel c_mov_rsi_mem_rcx]
    call emit_cstr
    lea rdi, [rel c_call_strlen]
    call emit_cstr
    lea rdi, [rel c_mov_rdx_rax]
    call emit_cstr
    lea rdi, [rel c_call_pstr]
    call emit_cstr
    lea rdi, [rel c_add_rsp]
    call emit_cstr
    mov rax, [rcx+24]
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .ecp_builtin_out
.ecp_bw_lit:
    ; literal arg: [rsp]=str_N address, len = stmts[r12+1].len ([rdx+24])
    mov rbx, [rdx+24]
    push rbx
    lea rdi, [rel c_mov_rsi_rsp]
    call emit_cstr
    lea rdi, [rel c_mov_rdx]
    call emit_cstr
    pop rbx
    mov rax, rbx
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_call_pstr]
    call emit_cstr
    lea rdi, [rel c_add_rsp]
    call emit_cstr
    mov rax, [rcx+24]
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .ecp_builtin_out
.ecp_bs:
    ; str(s): same arg dispatch; returns ptr in rax (and rsi), len in rdx
    lea rdx, [rel stmts]
    mov rax, r12
    inc rax
    imul rax, rax, 32
    add rdx, rax
    cmp qword [rdx+8], 4
    je .ecp_bs_lit
    lea rdi, [rel c_mov_rax_rsp]
    call emit_cstr
    lea rdi, [rel c_mov_rsi_mem_rax]
    call emit_cstr
    lea rdi, [rel c_mov_rdx_mem_rax8_sub]
    call emit_cstr
    lea rdi, [rel c_mov_rax_rsi]
    call emit_cstr
    lea rdi, [rel c_add_rsp]
    call emit_cstr
    mov rax, [rcx+24]
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .ecp_builtin_out
.ecp_bs_lit:
    mov rbx, [rdx+24]
    push rbx
    lea rdi, [rel c_mov_rsi_rsp]
    call emit_cstr
    lea rdi, [rel c_mov_rdx]
    call emit_cstr
    pop rbx
    mov rax, rbx
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_mov_rax_rsi]
    call emit_cstr
    lea rdi, [rel c_add_rsp]
    call emit_cstr
    mov rax, [rcx+24]
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .ecp_builtin_out
.ecp_builtin_out:
    add rsp, 0x28
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; emit_stmt_range: rsi=start idx, rdx=end idx (exclusive), r13=func idx (main=-1)
emit_stmt_range:
    push rbx
    push rcx
    push rdx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 0x28
    mov r12, rsi
    mov r14, rdx
.range_loop:
    cmp r12, r14
    jae .range_done
    lea rcx, [rel stmts]
    mov rax, r12
    imul rax, rax, 32
    add rcx, rax
    mov rax, [rcx]
    cmp rax, 1
    je .r_pstr
    cmp rax, 2
    je .r_pnum
    cmp rax, 3
    je .r_ret
    cmp rax, 4
    je .r_print_var
    cmp rax, 5
    je .r_assign_num
    cmp rax, 6
    je .r_assign_str
    cmp rax, 7
    je .r_assign_var_num
    cmp rax, 8
    je .r_assign_var_str
    cmp rax, 9
    je .r_assign_call
    cmp rax, 10
    je .r_assign_call
    cmp rax, 11
    je .r_call
    cmp rax, 13
    je .r_print_call
    cmp rax, 34
    je .r_assign_deref
    cmp rax, 35
    je .r_deref_store_const
    cmp rax, 36
    je .r_deref_store_var
    cmp rax, 37
    je .r_deref_store_deref
    cmp rax, 38
    je .r_assign_addr
    cmp rax, 39
    je .r_print_deref
    cmp rax, 40
    je .r_while
    cmp rax, 41
    je .r_end
    cmp rax, 42
    je .r_if
    cmp rax, 43
    je .r_ifend
    cmp rax, 44
    je .r_else
    cmp rax, 45
    je .r_break
    cmp rax, 46
    je .r_continue
    cmp rax, 48
    je .r_forcont
    cmp rax, 14
    jb .r_next
    cmp rax, 33
    ja .r_next
    jmp .r_assign_expr
    jmp .r_next
.r_break:
    ; jmp .WE<idx>
    mov r11, [rcx+8]
    lea rdi, [rel c_jmp_we]
    call emit_cstr
    mov rax, r11
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .r_next
.r_continue:
    mov r11, [rcx+8]
    mov r10, [rcx+16]
    test r10, r10
    jz .r_cont_while
    lea rdi, [rel c_jmp_wc]
    call emit_cstr
    jmp .r_cont_tail
.r_cont_while:
    lea rdi, [rel c_jmp_w]
    call emit_cstr
.r_cont_tail:
    mov rax, r11
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .r_next
.r_forcont:
    ; define label .WC<idx>:
    mov r11, [rcx+8]
    lea rdi, [rel c_wc_lbl]
    call emit_cstr
    mov rax, r11
    call emit_num
    lea rdi, [rel c_colon]
    call emit_cstr
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .r_next
.r_while:
    ; while stmt at idx r12: [8]=op, [16]=lhs var idx, [24]=rhs kind(1 const/2 var)
    ; while_meta[r12]: [0]=op(dup), [8]=rhs val/idx
    ; NOTE: emit_cstr/emit_num clobber rax/rdx/r8; r9-r15 are safe.
    lea rcx, [rel stmts]
    mov rax, r12
    imul rax, rax, 32
    add rcx, rax
    mov r11, [rcx+8]     ; op -> r11 (safe across emit)
    mov r10, [rcx+16]    ; lhs var idx -> r10 (preserve r14=end idx)
    mov r15, [rcx+24]    ; rhs kind (safe)
    lea rbx, [rel while_meta]
    mov rax, r12
    imul rax, rax, 16
    add rbx, rax
    mov r9, [rbx+8]      ; rhs const value / var idx (safe; r13=func idx kept)
    ; emit .W<idx>:
    lea rdi, [rel c_w_lbl]
    call emit_cstr
    mov rax, r12
    call emit_num
    lea rdi, [rel c_colon]
    call emit_cstr
    lea rdi, [rel c_nl]
    call emit_cstr
    ; load lhs -> rax (string lhs -> strlen)
    lea rcx, [rel var_table]
    mov rax, r10
    imul rax, rax, 56
    add rcx, rax
    cmp qword [rcx+32], 1
    je .r_wl_str
    mov r15, r10
    call emit_load_num
    jmp .r_wl_done
.r_wl_str:
    mov r15, r10
    call emit_load_str
    lea rdi, [rel c_mov_rax_rdx]
    call emit_cstr
.r_wl_done:
    ; reload rhs kind from stmts (r15 was clobbered by lhs emit)
    lea rcx, [rel stmts]
    mov rax, r12
    imul rax, rax, 32
    add rcx, rax
    mov r15, [rcx+24]
    ; emit rhs -> rcx
    cmp r15, 2
    je .r_wr_var
    lea rdi, [rel c_mov_rcx]
    call emit_cstr
    mov rax, r9
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .r_wr_done
.r_wr_var:
    lea rdi, [rel c_push_rax]
    call emit_cstr
    lea rcx, [rel var_table]
    mov rax, r9
    imul rax, rax, 56
    add rcx, rax
    cmp qword [rcx+32], 1
    je .r_wr_str
    mov r15, r9
    call emit_load_num
    lea rdi, [rel c_mov_rcx_rax]
    call emit_cstr
    lea rdi, [rel c_pop_rax]
    call emit_cstr
    jmp .r_wr_done
.r_wr_str:
    mov r15, r9
    call emit_load_str
    lea rdi, [rel c_mov_rax_rdx]
    call emit_cstr
    lea rdi, [rel c_mov_rcx_rax]
    call emit_cstr
.r_wr_done:
    ; compare rax, rcx; conditional jump to exit
    lea rdi, [rel c_cmp_rax_rcx]
    call emit_cstr
    cmp r11, 1
    jne .r_w_op2
    lea rdi, [rel c_jz_w]
    call emit_cstr
    jmp .r_w_jmp
.r_w_op2:
    cmp r11, 2
    jne .r_w_op3
    lea rdi, [rel c_jle_w]
    call emit_cstr
    jmp .r_w_jmp
.r_w_op3:
    cmp r11, 3
    jne .r_w_op6
    lea rdi, [rel c_jge_w]
    call emit_cstr
    jmp .r_w_jmp
.r_w_op6:
    cmp r11, 6
    jne .r_w_op7
    lea rdi, [rel c_jne_w]
    call emit_cstr
    jmp .r_w_jmp
.r_w_op7:
    lea rdi, [rel c_je_w]
    call emit_cstr
.r_w_jmp:
    ; tail shared by all op branches: emit <idx> then newline (no colon!
    ; the .WE<idx>: jump target label is NOT a definition here)
    mov rax, r12
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    ; push while idx to emit stack
    mov rax, [rel emit_w_depth]
    lea rbx, [rel emit_while_stack]
    imul rax, rax, 8
    add rbx, rax
    mov [rbx], r12
    inc qword [rel emit_w_depth]
    jmp .r_next
.r_end:
    ; pop while idx; emit jmp .W<idx> then .WE<idx>:
    mov rax, [rel emit_w_depth]
    test rax, rax
    jz .range_done
    dec rax
    mov [rel emit_w_depth], rax
    lea rbx, [rel emit_while_stack]
    imul rax, rax, 8
    add rbx, rax
    mov rax, [rbx]
    mov [rel emit_w_save], rax
    lea rdi, [rel c_jmp_w]
    call emit_cstr
    mov rax, [rel emit_w_save]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_w_end_lbl]
    call emit_cstr
    mov rax, [rel emit_w_save]
    call emit_num
    lea rdi, [rel c_colon]
    call emit_cstr
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .r_next
.r_if:
    ; stmts[r12]: [8]=op, [16]=lhs var, [24]=rhs kind ; while_meta[r12][8]=rhs val
    lea rcx, [rel stmts]
    mov rax, r12
    imul rax, rax, 32
    add rcx, rax
    mov r11, [rcx+8]
    mov r10, [rcx+16]
    lea rbx, [rel while_meta]
    mov rax, r12
    imul rax, rax, 16
    add rbx, rax
    mov r9, [rbx+8]
    lea rcx, [rel var_table]
    mov rax, r10
    imul rax, rax, 56
    add rcx, rax
    cmp qword [rcx+32], 1
    je .r_if_lhs_str
    mov r15, r10
    call emit_load_num
    jmp .r_if_lhs_done
.r_if_lhs_str:
    mov r15, r10
    call emit_load_str
    lea rdi, [rel c_mov_rax_rdx]
    call emit_cstr
.r_if_lhs_done:
    lea rcx, [rel stmts]
    mov rax, r12
    imul rax, rax, 32
    add rcx, rax
    mov r15, [rcx+24]
    cmp r15, 2
    je .r_if_rhs_var
    lea rdi, [rel c_mov_rcx]
    call emit_cstr
    mov rax, r9
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .r_if_cmp
.r_if_rhs_var:
    lea rdi, [rel c_push_rax]
    call emit_cstr
    lea rcx, [rel var_table]
    mov rax, r9
    imul rax, rax, 56
    add rcx, rax
    cmp qword [rcx+32], 1
    je .r_if_rhs_str
    mov r15, r9
    call emit_load_num
    lea rdi, [rel c_mov_rcx_rax]
    call emit_cstr
    lea rdi, [rel c_pop_rax]
    call emit_cstr
    jmp .r_if_cmp
.r_if_rhs_str:
    mov r15, r9
    call emit_load_str
    lea rdi, [rel c_mov_rax_rdx]
    call emit_cstr
    lea rdi, [rel c_mov_rcx_rax]
    call emit_cstr
.r_if_cmp:
    lea rdi, [rel c_cmp_rax_rcx]
    call emit_cstr
    cmp r11, 1
    jne .r_if_op2
    lea rdi, [rel c_jz_if]
    jmp .r_if_jmp_tail
.r_if_op2:
    cmp r11, 2
    jne .r_if_op3
    lea rdi, [rel c_jle_if]
    jmp .r_if_jmp_tail
.r_if_op3:
    cmp r11, 3
    jne .r_if_op6
    lea rdi, [rel c_jge_if]
    jmp .r_if_jmp_tail
.r_if_op6:
    cmp r11, 6
    jne .r_if_op7
    lea rdi, [rel c_jne_if]
    jmp .r_if_jmp_tail
.r_if_op7:
    lea rdi, [rel c_je_if]
.r_if_jmp_tail:
    call emit_cstr
    mov rax, r12
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .r_next
.r_else:
    lea rcx, [rel stmts]
    mov rax, r12
    imul rax, rax, 32
    add rcx, rax
    mov r9, [rcx+8]
    lea rbx, [rel if_meta]
    mov rax, r9
    imul rax, rax, 16
    add rbx, rax
    mov qword [rbx], 1
    lea rdi, [rel c_jmp_if]
    call emit_cstr
    mov rax, r9
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_if_else_lbl]
    call emit_cstr
    mov rax, r9
    call emit_num
    lea rdi, [rel c_colon]
    call emit_cstr
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .r_next
.r_ifend:
    lea rcx, [rel stmts]
    mov rax, r12
    imul rax, rax, 32
    add rcx, rax
    mov r9, [rcx+8]
    lea rbx, [rel if_meta]
    mov rax, r9
    imul rax, rax, 16
    add rbx, rax
    cmp qword [rbx], 0
    jne .r_ifend_tail
    lea rdi, [rel c_if_else_lbl]
    call emit_cstr
    mov rax, r9
    call emit_num
    lea rdi, [rel c_colon]
    call emit_cstr
    lea rdi, [rel c_nl]
    call emit_cstr
.r_ifend_tail:
    lea rdi, [rel c_if_end_lbl]
    call emit_cstr
    mov rax, r9
    call emit_num
    lea rdi, [rel c_colon]
    call emit_cstr
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .r_next
.r_pstr:
    lea rdi, [rel c_mov_rsi]
    call emit_cstr
    lea rdi, [rel c_str_lbl]
    call emit_cstr
    mov rax, r12
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_mov_rdx]
    call emit_cstr
    mov rax, [rcx+16]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_call_pstr]
    call emit_cstr
    jmp .r_next
.r_pnum:
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, [rcx+8]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_call_pnum]
    call emit_cstr
    jmp .r_next
.r_ret:
    lea rcx, [rel stmts]
    mov rax, r12
    imul rax, rax, 32
    add rcx, rax
    mov rax, [rcx+16]
    cmp rax, 0
    je .r_ret_num_const
    cmp rax, 1
    je .r_ret_str_const
    cmp rax, 2
    je .r_ret_num_var
    cmp rax, 4
    je .r_ret_add_var
    cmp rax, 5
    je .r_ret_add_const
    cmp rax, 6
    je .r_ret_sub_var
    cmp rax, 7
    je .r_ret_sub_const
    cmp rax, 8
    je .r_ret_mul_var
    cmp rax, 9
    je .r_ret_mul_const
    cmp rax, 10
    je .r_ret_div_var
    cmp rax, 11
    je .r_ret_div_const
    cmp rax, 12
    je .r_ret_mod_var
    cmp rax, 13
    je .r_ret_mod_const
    cmp rax, 14
    je .r_ret_addc_var
    cmp rax, 15
    je .r_ret_addc_const
    cmp rax, 16
    je .r_ret_subc_var
    cmp rax, 17
    je .r_ret_subc_const
    cmp rax, 18
    je .r_ret_mulc_var
    cmp rax, 19
    je .r_ret_mulc_const
    cmp rax, 20
    je .r_ret_divc_var
    cmp rax, 21
    je .r_ret_divc_const
    cmp rax, 22
    je .r_ret_modc_var
    cmp rax, 23
    je .r_ret_modc_const
    mov r15, [rcx+8]
    call emit_load_str
    jmp .r_ret_jmp
.r_ret_add_var:
    mov r15, [rcx+8]
    call emit_load_num
    mov r15, [rcx+24]
    call emit_add_num
    jmp .r_ret_jmp
.r_ret_add_const:
    mov r15, [rcx+8]
    call emit_load_num
    lea rdi, [rel c_add_rax]
    call emit_cstr
    mov rax, [rcx+24]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .r_ret_jmp
.r_ret_sub_var:
    mov r15, [rcx+8]
    call emit_load_num
    mov r15, [rcx+24]
    call emit_sub_num
    jmp .r_ret_jmp
.r_ret_sub_const:
    mov r15, [rcx+8]
    call emit_load_num
    lea rdi, [rel c_sub_rax]
    call emit_cstr
    mov rax, [rcx+24]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .r_ret_jmp
.r_ret_mul_var:
    mov r15, [rcx+8]
    call emit_load_num
    mov r15, [rcx+24]
    call emit_mul_num
    jmp .r_ret_jmp
.r_ret_mul_const:
    mov r15, [rcx+8]
    call emit_load_num
    lea rdi, [rel c_imul_rax]
    call emit_cstr
    mov rax, [rcx+24]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .r_ret_jmp
.r_ret_div_var:
    mov r15, [rcx+8]
    call emit_load_num
    mov r15, [rcx+24]
    call emit_div_num
    jmp .r_ret_jmp
.r_ret_div_const:
    mov r15, [rcx+8]
    call emit_load_num
    lea rdi, [rel c_mov_rcx]
    call emit_cstr
    mov rax, [rcx+24]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_xor_edx]
    call emit_cstr
    lea rdi, [rel c_div_rcx]
    call emit_cstr
    jmp .r_ret_jmp
.r_ret_mod_var:
    mov r15, [rcx+8]
    call emit_load_num
    mov r15, [rcx+24]
    call emit_div_num
    lea rdi, [rel c_mov_rax_rdx]
    call emit_cstr
    jmp .r_ret_jmp
.r_ret_mod_const:
    mov r15, [rcx+8]
    call emit_load_num
    lea rdi, [rel c_mov_rcx]
    call emit_cstr
    mov rax, [rcx+24]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_xor_edx]
    call emit_cstr
    lea rdi, [rel c_div_rcx]
    call emit_cstr
    lea rdi, [rel c_mov_rax_rdx]
    call emit_cstr
    jmp .r_ret_jmp
.r_ret_addc_var:
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, [rcx+8]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    mov r15, [rcx+24]
    call emit_add_num
    jmp .r_ret_jmp
.r_ret_addc_const:
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, [rcx+8]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_add_rax]
    call emit_cstr
    mov rax, [rcx+24]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .r_ret_jmp
.r_ret_subc_var:
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, [rcx+8]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    mov r15, [rcx+24]
    call emit_sub_num
    jmp .r_ret_jmp
.r_ret_subc_const:
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, [rcx+8]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_sub_rax]
    call emit_cstr
    mov rax, [rcx+24]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .r_ret_jmp
.r_ret_mulc_var:
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, [rcx+8]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    mov r15, [rcx+24]
    call emit_mul_num
    jmp .r_ret_jmp
.r_ret_mulc_const:
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, [rcx+8]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_imul_rax]
    call emit_cstr
    mov rax, [rcx+24]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .r_ret_jmp
.r_ret_divc_var:
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, [rcx+8]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    mov r15, [rcx+24]
    call emit_div_num
    jmp .r_ret_jmp
.r_ret_divc_const:
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, [rcx+8]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_mov_rcx]
    call emit_cstr
    mov rax, [rcx+24]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_xor_edx]
    call emit_cstr
    lea rdi, [rel c_div_rcx]
    call emit_cstr
    jmp .r_ret_jmp
.r_ret_modc_var:
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, [rcx+8]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    mov r15, [rcx+24]
    call emit_div_num
    lea rdi, [rel c_mov_rax_rdx]
    call emit_cstr
    jmp .r_ret_jmp
.r_ret_modc_const:
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, [rcx+8]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_mov_rcx]
    call emit_cstr
    mov rax, [rcx+24]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_xor_edx]
    call emit_cstr
    lea rdi, [rel c_div_rcx]
    call emit_cstr
    lea rdi, [rel c_mov_rax_rdx]
    call emit_cstr
    jmp .r_ret_jmp
.r_ret_num_var:
    mov r15, [rcx+8]
    call emit_load_num
    jmp .r_ret_jmp
.r_ret_num_const:
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, [rcx+8]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .r_ret_jmp
.r_ret_str_const:
    lea rdi, [rel c_lea_rsi_str]
    call emit_cstr
    mov rax, r12
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
    lea rdi, [rel c_mov_rdx]
    call emit_cstr
    mov rax, [rcx+24]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_mov_rax_rsi]
    call emit_cstr
    jmp .r_ret_jmp
.r_ret_jmp:
    cmp r13, -1
    je .r_ret_exit
    lea rdi, [rel c_jmp_lret]
    call emit_cstr
    mov rax, r13
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .r_next
.r_ret_exit:
    lea rdi, [rel c_exit]
    call emit_cstr
    jmp .r_next
.r_print_var:
    mov r15, [rcx+8]
    lea rdx, [rel var_table]
    mov rax, r15
    imul rax, rax, 56
    add rdx, rax
    cmp qword [rdx+32], 1
    je .r_print_var_str
    cmp qword [rdx+32], 2
    je .r_print_var_ptr
    call emit_load_num
    lea rdi, [rel c_call_pnum]
    call emit_cstr
    jmp .r_next
.r_print_var_str:
    call emit_load_str
    lea rdi, [rel c_call_pstr]
    call emit_cstr
    jmp .r_next
.r_print_var_ptr:
    call emit_load_num
    lea rdi, [rel c_call_phex]
    call emit_cstr
    jmp .r_next
.r_assign_num:
    mov r15, [rcx+8]
    mov rax, [rcx+24]
    call emit_qword_const
    jmp .r_next
.r_assign_str:
    lea rdi, [rel c_lea_rsi_str]
    call emit_cstr
    mov rax, r12
    call emit_num
    lea rdi, [rel c_bracket]
    call emit_cstr
    lea rdi, [rel c_mov_rdx]
    call emit_cstr
    mov rax, [rcx+24]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    mov r15, [rcx+8]
    call emit_store_str
    jmp .r_next
.r_assign_var_num:
    mov r15, [rcx+16]
    call emit_load_num
    mov r15, [rcx+8]
    call emit_store_num
    jmp .r_next
.r_assign_var_str:
    mov r15, [rcx+16]
    call emit_load_str
    mov r15, [rcx+8]
    call emit_store_str
    jmp .r_next
.r_assign_call:
    push rcx
    call emit_call_prep
    pop rcx
    mov r15, [rcx+16]
    cmp qword [rcx], 10
    je .r_ac_str
    call emit_store_num
    jmp .r_next
.r_ac_str:
    call emit_store_str
    jmp .r_next
.r_call:
    push rcx
    call emit_call_prep
    pop rcx
    jmp .r_next
.r_print_call:
    push rcx
    call emit_call_prep
    pop rcx
    lea rdx, [rel func_table]
    mov rax, [rcx+8]
    imul rax, rax, 56
    add rdx, rax
    cmp qword [rdx+40], 0
    jne .r_pc_str
    lea rdi, [rel c_call_pnum]
    call emit_cstr
    jmp .r_next
.r_pc_str:
    lea rdi, [rel c_mov_rsi_rax]
    call emit_cstr
    lea rdi, [rel c_call_pstr]
    call emit_cstr
    jmp .r_next
.r_assign_deref:
    ; a = *p : rax=[p], rax=[rax]
    mov r15, [rcx+16]
    call emit_load_num
    lea rdi, [rel c_mov_rax_mem_rax]
    call emit_cstr
    mov r15, [rcx+8]
    call emit_store_num
    jmp .r_next
.r_deref_store_const:
    ; *p = N : rcx=[p]; rax=N; [rcx]=rax
    mov r15, [rcx+8]
    call emit_load_num
    lea rdi, [rel c_mov_rcx_rax]
    call emit_cstr
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, [rcx+24]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_mov_mem_rcx_rax]
    call emit_cstr
    jmp .r_next
.r_deref_store_var:
    ; *p = b : rcx=[p]; rax=[b]; [rcx]=rax
    mov r15, [rcx+8]
    call emit_load_num
    lea rdi, [rel c_mov_rcx_rax]
    call emit_cstr
    mov r15, [rcx+16]
    call emit_load_num
    lea rdi, [rel c_mov_mem_rcx_rax]
    call emit_cstr
    jmp .r_next
.r_deref_store_deref:
    ; *p = *q : rcx=[p]; rax=[q]; rax=[rax]; [rcx]=rax
    mov r15, [rcx+8]
    call emit_load_num
    lea rdi, [rel c_mov_rcx_rax]
    call emit_cstr
    mov r15, [rcx+16]
    call emit_load_num
    lea rdi, [rel c_mov_rax_mem_rax]
    call emit_cstr
    lea rdi, [rel c_mov_mem_rcx_rax]
    call emit_cstr
    jmp .r_next
.r_assign_addr:
    ; a = &b : lea rax,[b]; store into a
    mov r15, [rcx+16]
    call emit_addr_of
    mov r15, [rcx+8]
    call emit_store_num
    jmp .r_next
.r_print_deref:
    ; print(*p) : rax=[p]; rax=[rax]; call rt_print_num
    mov r15, [rcx+8]
    call emit_load_num
    lea rdi, [rel c_mov_rax_mem_rax]
    call emit_cstr
    lea rdi, [rel c_call_pnum]
    call emit_cstr
    jmp .r_next
.r_assign_expr:
    ; stmt ???????14-33???cx = slot
    ; [rcx+8]=???var idx, [rcx+16]=??????, [rcx+24]=??????
    ; ??????? 14-23 ??????? 24-33 ??????? ????????? ?????????
    mov rax, [rcx]
    cmp rax, 24
    jb .aex_left_var
    ; ???????
    lea rdi, [rel c_mov_rax]
    call emit_cstr
    mov rax, [rcx+16]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .aex_rhs_sel
.aex_left_var:
    mov r15, [rcx+16]
    call emit_load_num
.aex_rhs_sel:
    ; ?????op ?? 24-33??-9, 14-23??-9
    mov rax, [rcx]
    cmp rax, 24
    jb .aex_op_base14
    sub rax, 24
    jmp .aex_op_have
.aex_op_base14:
    sub rax, 14
.aex_op_have:
    ; rax=0-9: op=rax/2, ???????rax%2
    test al, 1
    jnz .aex_rhs_const
    ; ??????? op=rax/2
    shr rax, 1
    mov r15, [rcx+24]
    cmp rax, 0
    je .aex_add_rv
    cmp rax, 1
    je .aex_sub_rv
    cmp rax, 2
    je .aex_mul_rv
    cmp rax, 3
    je .aex_div_rv
    call emit_div_num
    lea rdi, [rel c_mov_rax_rdx]
    call emit_cstr
    jmp .aex_store
.aex_rhs_const:
    ; ??????? op=rax/2
    shr rax, 1
    cmp rax, 0
    je .aex_add_rc
    cmp rax, 1
    je .aex_sub_rc
    cmp rax, 2
    je .aex_mul_rc
    cmp rax, 3
    je .aex_div_rc
    lea rdi, [rel c_mov_rcx]
    call emit_cstr
    mov rax, [rcx+24]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_xor_edx]
    call emit_cstr
    lea rdi, [rel c_div_rcx]
    call emit_cstr
    lea rdi, [rel c_mov_rax_rdx]
    call emit_cstr
    jmp .aex_store
.aex_add_rv:
    call emit_add_num
    jmp .aex_store
.aex_sub_rv:
    call emit_sub_num
    jmp .aex_store
.aex_mul_rv:
    call emit_mul_num
    jmp .aex_store
.aex_div_rv:
    call emit_div_num
    jmp .aex_store
.aex_add_rc:
    lea rdi, [rel c_add_rax]
    call emit_cstr
    mov rax, [rcx+24]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .aex_store
.aex_sub_rc:
    lea rdi, [rel c_sub_rax]
    call emit_cstr
    mov rax, [rcx+24]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .aex_store
.aex_mul_rc:
    lea rdi, [rel c_imul_rax]
    call emit_cstr
    mov rax, [rcx+24]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .aex_store
.aex_div_rc:
    lea rdi, [rel c_mov_rcx]
    call emit_cstr
    mov rax, [rcx+24]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_xor_edx]
    call emit_cstr
    lea rdi, [rel c_div_rcx]
    call emit_cstr
    jmp .aex_store
.aex_store:
    ; ???????rax????????????????[rcx+8]
    mov r15, [rcx+8]
    call emit_store_num
    jmp .r_next
.r_next:
    inc r12
    jmp .range_loop
.range_done:
    add rsp, 0x28
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============ emitter ============
emit_all:
    sub rsp, 0x28
    ; header
    lea rdi, [rel tpl_hdr]
    call emit_cstr
    ; ??import ????? .cf ?????????????? .dll/.so ??DLL_LOAD ???????????
.imp_e_done:
    ; DLL_LOAD stub: ???????????.dll/.so ??
    lea rdi, [rel c_dll_lbl]
    call emit_cstr
    lea rdi, [rel c_dll_pro]
    call emit_cstr
    mov r13, 0
.dll_e_loop:
    cmp r13, [rel dll_cnt]
    jae .dll_e_done
    lea rdi, [rel c_dll_mov]
    call emit_cstr
    mov rax, r13
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_dll_call]
    call emit_cstr
    inc r13
    jmp .dll_e_loop
.dll_e_done:
    ; LoadLibraryA ???????????ret ?????entry (???????????dll)
    lea rdi, [rel c_ret]
    call emit_cstr
.dll_skip_ret:
    mov r13, 0
.dll_p_loop:
    cmp r13, [rel dll_cnt]
    jae .dll_p_done
    lea rdi, [rel c_dll_path_lbl]
    call emit_cstr
    mov rax, r13
    call emit_num
    lea rdi, [rel c_dll_path_val]
    call emit_cstr
    lea rbx, [rel dll_list]
    imul rax, r13, 64
    add rbx, rax
    mov rdi, rbx
    call emit_cstr
    lea rdi, [rel c_dll_path_end]
    call emit_cstr
    inc r13
    jmp .dll_p_loop
.dll_p_done:
    ; ---- functions first ----
    xor r13d, r13d
.func_e_loop:
    cmp r13, [rel func_cnt]
    jae .func_e_done
    lea rcx, [rel func_table]
    mov rax, r13
    imul rax, rax, 56
    add rcx, rax
    ; cache table fields first: emit_* clobbers rcx/rdx
    mov rax, [rcx+48]
    mov [rel e_cur_locals], rax
    mov rax, [rcx+24]
    mov [rel e_cur_start], rax
    mov rax, [rcx+32]
    mov [rel e_cur_len], rax
    ; func_<idx>:
    lea rdi, [rel c_func_lbl]
    call emit_cstr
    mov rax, r13
    call emit_num
    lea rdi, [rel c_colon]
    call emit_cstr
    lea rdi, [rel c_nl]
    call emit_cstr
    ; prologue
    lea rdi, [rel c_prologue]
    call emit_cstr
    ; sub rsp, locals*8
    mov rax, [rel e_cur_locals]
    test rax, rax
    jz .func_no_sub
    lea rdi, [rel c_sub_rsp]
    call emit_cstr
    mov rax, [rel e_cur_locals]
    imul rax, rax, 8
    add rax, 15
    and rax, -16
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
.func_no_sub:
    ; body
    mov rsi, [rel e_cur_start]
    mov rdx, [rel e_cur_len]
    add rdx, rsi
    call emit_stmt_range
    ; Lret_<idx>:
    lea rdi, [rel c_lret_lbl]
    call emit_cstr
    mov rax, r13
    call emit_num
    lea rdi, [rel c_colon]
    call emit_cstr
    lea rdi, [rel c_nl]
    call emit_cstr
    lea rdi, [rel c_epilogue]
    call emit_cstr
    inc r13
    jmp .func_e_loop
.func_e_done:
    ; ---- main ----
    lea rdi, [rel c_main_lbl]
    call emit_cstr
    lea rdi, [rel c_prologue]
    call emit_cstr
    lea rdi, [rel c_and_rsp]
    call emit_cstr
    mov rax, [rel main_locals]
    test rax, rax
    jz .main_no_sub
    lea rdi, [rel c_sub_rsp]
    call emit_cstr
    mov rax, [rel main_locals]
    imul rax, rax, 8
    add rax, 15
    and rax, -16
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
.main_no_sub:
    mov rsi, [rel main_start]
    mov rdx, [rel main_len]
    add rdx, rsi
    mov r13, -1
    call emit_stmt_range
    jmp .stmt_done
.stmt_done:
    ; runtime + sections
    lea rdi, [rel tpl_rt]
    call emit_cstr
    lea rdi, [rel tpl_text_end]
    call emit_cstr
    lea rdi, [rel tpl_data_hdr]
    call emit_cstr
    ; string pool
    xor ebx, ebx
.str_loop:
    cmp rbx, [rel stmts_cnt]
    jae .str_done
    lea rcx, [rel stmts]
    mov rax, rbx
    imul rax, rax, 32
    add rcx, rax
    mov rax, [rcx]
    cmp rax, 1
    je .str_emit_ok
    cmp rax, 6
    je .str_emit_ok
    cmp rax, 3
    jne .str_t12s
    cmp qword [rcx+16], 1
    jne .str_next
    jmp .str_emit_ok
.str_t12s:
    cmp rax, 12
    jne .str_next
    cmp qword [rcx+8], 4
    jne .str_next
.str_emit_ok:
    ; offset/len by type
    mov rax, [rcx]
    cmp rax, 12
    je .str_t12o
    cmp rax, 1
    jne .str_t6
    mov rax, [rcx+8]
    mov r12, [rcx+16]
    jmp .str_got
.str_t6:
    cmp rax, 6
    jne .str_t3
    mov rax, [rcx+16]
    mov r12, [rcx+24]
    jmp .str_got
.str_t3:
    mov rax, [rcx+8]
    mov r12, [rcx+24]
    jmp .str_got
.str_t12o:
    mov rax, [rcx+16]
    mov r12, [rcx+24]
    jmp .str_got
.str_got:
    mov r14, rax
    lea rdi, [rel c_str_lbl]
    call emit_cstr
    mov rax, rbx
    call emit_num
    lea rdi, [rel c_db_colon]
    call emit_cstr
    ; bytes
    lea rdi, [rel strpool]
    add rdi, r14
    xor r13d, r13d
.byte_loop:
    cmp r13, r12
    jae .byte_done
    movzx eax, byte [rdi+r13]
    call emit_num
    push rdi
    lea rdi, [rel c_comma]
    mov rsi, 1
    call emit
    pop rdi
    inc r13
    jmp .byte_loop
.byte_done:
    ; strip trailing comma -> simple: emit nl, nasm tolerates? no; fix by regenerating
    ; we emitted trailing commas; NASM db allows trailing comma? safer: fix below by emitting newline then a comment-free correction is hard.
    ; approach: write bytes without trailing comma by remembering last, handled via out_buf length adjustment
    ; subtract last comma (1 byte) from out_len
    cmp r12, 0
    je .empty_str
    sub qword [rel out_len], 1
    lea rdi, [rel c_comma]
    mov rsi, 1
    call emit
.empty_str:
    ; append NUL byte to str literal db (strlen / cstr safety)
    lea rdi, [rel c_zero]
    mov rsi, 1
    call emit
    lea rdi, [rel c_nl]
    call emit_cstr
.str_next:
    inc rbx
    jmp .str_loop
.str_done:
    lea rdi, [rel tpl_data_tail]
    call emit_cstr
    add rsp, 0x28
    ret

; ============ data ============
text_vsize equ ($ - text_start)
    align 0x200, db 0
text_file_size equ ($ - text_start)
idata_off equ (0x200 + text_file_size + 0x1FF) & ~0x1FF

section .idata start=idata_off vstart=0x140001000+((text_vsize+0xFFF)&~0xFFF)
idata_start:
    dd oft - 0x140000000
    dd 0
    dd 0
    dd dllname - 0x140000000
    dd iat - 0x140000000
    dd ntdll_oft - 0x140000000
    dd 0
    dd 0
    dd ntdll_dllname - 0x140000000
    dd ntdll_iat - 0x140000000
    dd 0, 0, 0, 0, 0
    align 8, db 0
oft:
    dq hint_GetStdHandle - 0x140000000
    dq hint_WriteFile - 0x140000000
    dq hint_ExitProcess - 0x140000000
    dq hint_CreateFileA - 0x140000000
    dq hint_CreateFileW - 0x140000000
    dq hint_GetFileSize - 0x140000000
    dq hint_ReadFile - 0x140000000
    dq hint_CloseHandle - 0x140000000
    dq hint_CreateProcessA - 0x140000000
    dq hint_WaitForSingleObject - 0x140000000
    dq hint_GetExitCodeProcess - 0x140000000
    dq hint_GetCommandLineA - 0x140000000
    dq hint_DeleteFileA - 0x140000000
    dq hint_GetModuleFileNameA - 0x140000000
    dq 0
iat:
iat_GetStdHandle: dq hint_GetStdHandle - 0x140000000
iat_WriteFile:    dq hint_WriteFile - 0x140000000
iat_ExitProcess:  dq hint_ExitProcess - 0x140000000
iat_CreateFileA:  dq hint_CreateFileA - 0x140000000
iat_CreateFileW:  dq hint_CreateFileW - 0x140000000
iat_GetFileSize:  dq hint_GetFileSize - 0x140000000
iat_ReadFile:     dq hint_ReadFile - 0x140000000
iat_CloseHandle:  dq hint_CloseHandle - 0x140000000
iat_CreateProcessA: dq hint_CreateProcessA - 0x140000000
iat_WaitForSingleObject: dq hint_WaitForSingleObject - 0x140000000
iat_GetExitCodeProcess: dq hint_GetExitCodeProcess - 0x140000000
iat_GetCommandLineA: dq hint_GetCommandLineA - 0x140000000
iat_DeleteFileA:  dq hint_DeleteFileA - 0x140000000
iat_GetModuleFileNameA: dq hint_GetModuleFileNameA - 0x140000000
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
hint_ExitProcess:
    dw 0
    db 'ExitProcess', 0
hint_CreateFileA:
    dw 0
    db 'CreateFileA', 0
hint_CreateFileW:
    dw 0
    db 'CreateFileW', 0
hint_GetFileSize:
    dw 0
    db 'GetFileSize', 0
hint_ReadFile:
    dw 0
    db 'ReadFile', 0
hint_CloseHandle:
    dw 0
    db 'CloseHandle', 0
hint_CreateProcessA:
    dw 0
    db 'CreateProcessA', 0
hint_WaitForSingleObject:
    dw 0
    db 'WaitForSingleObject', 0
hint_GetExitCodeProcess:
    dw 0
    db 'GetExitCodeProcess', 0
hint_GetCommandLineA:
    dw 0
    db 'GetCommandLineA', 0
hint_DeleteFileA:
    dw 0
    db 'DeleteFileA', 0
hint_GetModuleFileNameA:
    dw 0
    db 'GetModuleFileNameA', 0
ntdll_oft:
    dq hint_NtCreateFile - 0x140000000
    dq 0
ntdll_iat:
iat_NtCreateFile: dq hint_NtCreateFile - 0x140000000
    dq 0
ntdll_dllname:
    db 'ntdll.dll', 0
    align 2, db 0
hint_NtCreateFile:
    dw 0
    db 'NtCreateFile', 0
idata_vsize equ ($ - idata_start)
    align 0x200, db 0
idata_file_size equ ($ - idata_start)
data_off equ (idata_off + idata_file_size + 0x1FF) & ~0x1FF

section .data start=data_off vstart=0x140001000+((text_vsize+0xFFF)&~0xFFF)+((idata_vsize+0xFFF)&~0xFFF)
data_start:
hout: dq 0
written: dq 0
proc_code: dq 0
src_len: dq 0
out_len: dq 0
stmts_cnt: dq 0
strpool_len: dq 0
startup_info: times 104 db 0
pi: dq 0, 0, 0, 0
nasm_path: db 'C:\Program Files\NASM\nasm.exe', 0
nasm_args: db ' -f bin "', 0
nasm_args2: db '" -o "', 0
arg1: times 512 db 0
arg2: times 64 db 0
asm_path: times 512 db 0
exe_path: times 512 db 0
cmdline: times 1024 db 0
src_buf: times 262144 db 0
out_buf: times 262144 db 0
strpool: times 65536 db 0
stmts: times 512*32 db 0
func_cnt: dq 0
func_table: times 256*56 db 0
vararg_fwd: times 256*8 dq 0
e_cur_locals: dq 0
e_cur_start: dq 0
e_cur_len: dq 0
func_forward: times 256 db 0
ps_kw_def: db 'def', 0
ps_kw_string: db 'string', 0
ps_kw_str: db 'str', 0
ps_kw_char: db 'char', 0
ps_kw_bigint: db 'bigint', 0
ps_kw_bool: db 'bool', 0
ps_kw_int: db 'int', 0
var_cnt: dq 0
var_table: times 256*56 db 0
cur_func: dq -1
cur_local_cnt: dq 0
cur_param_slot: dq 0
cur_param_cnt: dq 0
cur_param_type: dq 0
cur_param_ref: dq 0
call_ref_bmap: dq 0
ref_bmap: times 256*8 db 0
builtin_write: dq -1
builtin_str: dq -1
builtin_read_num: dq -1
builtin_get_char: dq -1
builtin_tick_ms: dq -1
builtin_rand: dq -1
builtin_os_create: dq -1
builtin_os_init: dq -1
builtin_os_ps: dq -1
builtin_os_pn: dq -1
builtin_os_nl: dq -1
builtin_os_print: dq -1
builtin_putch: dq -1
builtin_str_len: dq -1
builtin_str_get: dq -1
builtin_win_create: dq -1
builtin_win_show: dq -1
builtin_win_hide: dq -1
builtin_win_close: dq -1
builtin_win_title: dq -1
wh_lhs_var: dq 0
wh_op: dq 0
wh_rhs_kind: dq 0
wh_rhs_val: dq 0
w_depth: dq 0
while_meta: times 256*16 db 0
emit_while_stack: times 256*8 db 0
emit_w_depth: dq 0
blk_stack: times 256*16 db 0
blk_depth: dq 0
; ---- for / break / continue support ----
for_step_var: times 256*8 db 0      ; per blk level: loop var idx (step target)
for_step_op: times 256*8 db 0       ; per blk level: 0 = + , 1 = -
for_step_val: times 256*8 db 0      ; per blk level: step constant
for_save_rsi: dq 0                  ; rsi snapshot at '(' for backtracking
for_var_idx: dq 0                   ; loop variable idx
for_init_val: dq 0                  ; init constant value
for_init_kind: dq 0                 ; init rhs: 1 = const, 2 = var
for_rhs_tmp: dq 0                   ; scratch
for_decl_flag: dq 0                 ; 1 = init had an 'int' prefix
for_st_var: dq 0                    ; step: target var idx
for_st_op: dq 0                     ; step: 0 = + , 1 = -
for_st_val: dq 0                    ; step: constant
tb_target: dq 0                     ; break/continue target loop stmt idx
if_meta: times 256*16 db 0
emit_w_save: dq 0
main_start: dq 0
main_len: dq 0
main_locals: dq 0
tmp_name: times 16 db 0
tmp_name_bak: times 16 db 0
import_cnt: dq 0
import_libs: times 8*64 db 0
cur_pkg: times 64 db 0
cur_pkg_set: dq 0
imp_pkg_bak: times 64 db 0
imp_pkg_set_bak: dq 0
pkg_name_buf: times 64 db 0
imp_sub_buf: times 64 db 0
dbg_name: db 'dbg_src.txt', 0
dbg_written: dq 0
ri_result: dq 0
loaded_cnt: dq 0
loaded_libs: times 8*64 db 0
exe_dir_len: dq 0
exe_dir_buf: times 512 db 0
m0_name: db 'm0.txt', 0
md_name: db 'md.txt', 0
me_name: db 'me.txt', 0
mf_name: db 'mf.txt', 0
m8_name: db 'm8.txt', 0
m9_name: db 'm9.txt', 0
ma_name: db 'ma.txt', 0
mb_name: db 'mb.txt', 0
mc_name: db 'mc.txt', 0
m1_name: db 'm1.txt', 0
m2_name: db 'm2.txt', 0
m3_name: db 'm3.txt', 0
m4_name: db 'm4.txt', 0
m5_name: db 'm5.txt', 0
m6_name: db 'm6.txt', 0
m7_name: db 'm7.txt', 0
mx1_name: db 'mx1.txt', 0
mx2_name: db 'mx2.txt', 0
mx3_name: db 'mx3.txt', 0
mx4_name: db 'mx4.txt', 0
mx5_name: db 'mx5.txt', 0
mx6_name: db 'mx6.txt', 0
mx7_name: db 'mx7.txt', 0
imp_sub_len: dq 0
imp_top: dq 0
imp_depth: dq 0
cf_old_len: dq 0
skip_list: times 32*16 db 0
skip_cnt: dq 0
skip_save_list: times 32*16 db 0
skip_save_cnt: dq 0
sub_names: times 32*64 db 0
sub_cnt: dq 0
loaded_cf_cnt: dq 0
loaded_cf_list: times 32*96 db 0
src_len_orig: dq 0
cur_op: dq 0
decl_type: dq -1
ret_lval: dq 0
ret_lkind: dq 0
expr_lhs: dq 0
expr_ltype: dq 0
expr_rhs: dq 0
expr_sub: dq 0
lib_path_buf: times 512 db 0
pkg_path_buf: times 128 db 0
exe_path_buf: times 512 db 0
exe_dir_ready: dq 0
nt_hfile: dq 0
nt_oa: times 48 db 0
nt_io: times 16 db 0
nt_us: times 16 db 0
lib_wbuf: times 512 db 0
src_extra: times 65536 db 0
src_extra_len: dq 0
cf_pending: dq 0
dll_cnt: dq 0
dll_list: times 8*64 db 0
num_tmp: times 32 db 0
kw_def: db 'def', 0
kw_import: db 'import', 0
kw_imp: db 'imp', 0
kw_namesp: db 'namesp', 0
kw_int: db 'int', 0
c_dbgf: db 'FUNCS:', 0
kw_main: db 'main', 0
kw_print: db 'print', 0
kw_ret: db 'ret', 0
kw_bigint: db 'bigint', 0
kw_char: db 'char', 0
kw_str: db 'str', 0
kw_string: db 'string', 0
kw_bool: db 'bool', 0
kw_true: db 'true', 0
kw_false: db 'false', 0
kw_while: db 'while', 0
kw_if: db 'if', 0
kw_else: db 'else', 0
kw_for: db 'for', 0
kw_break: db 'break', 0
kw_continue: db 'continue', 0
kw_putch: db 'putch', 0
kw_str_len: db 'str_len', 0
kw_str_get: db 'str_get', 0
kw_read_num: db 'read_num', 0
kw_get_char: db 'get_char', 0
kw_tick_ms: db 'tick_ms', 0
kw_rand: db 'rand', 0
kw_os_create: db 'os.create', 0
kw_os_init: db 'os.init', 0
kw_os_print: db 'os.print', 0
kw_os_print_s: db 'os.print_s', 0
kw_os_print_n: db 'os.print_n', 0
kw_os_nl: db 'os.nl', 0
kw_win_create: db 'win_create', 0
win_dll_path: db 'lib/window/window.dll', 0
kw_win_show: db 'win_show', 0
kw_win_hide: db 'win_hide', 0
kw_win_close: db 'win_close', 0
kw_win_title: db 'win_title', 0
kw_ptr: db 'ptr', 0
msg_usage: db 'usage: gffc <in.cf>', 13, 10, 0
msg_open: db 'cannot open file: ', 0
msg_syntax: db 'syntax error', 0
msg_write: db 'cannot write asm', 13, 10, 0
msg_spawn: db 'cannot start nasm', 13, 10, 0
msg_nasm: db 'nasm failed', 13, 10, 0
msg_ok: db 'ok: ', 0

err_type: dq 0
err_msg: dq 0
err_msg_buf: times 600 db 0
msg_etype_syntax: db 'SyntaxError', 0
msg_etype_file: db 'FileNotFoundError', 0
msg_etype_imp: db 'ImportError', 0
msg_etype_comp: db 'CompilerError', 0
msg_etype_os: db 'OSError', 0
msg_invalid: db 'invalid syntax', 0
msg_missing_main: db 'missing main function', 0
msg_unterm_str: db 'unterminated string literal', 0
msg_unterm_char: db 'unterminated char literal', 0
msg_expected_q: db "expected '", 0
msg_param_kw: db 'cannot use keyword as parameter name', 0
msg_expect_char: db 'unexpected character ', 0
msg_expect_eof: db '<EOF>', 0
msg_expect_nl: db '<newline>', 0
msg_expect_tab: db '<tab>', 0
msg_imp_open: db 'cannot open library ', 0
msg_file_line: db '  File "', 0
msg_line2: db '", line ', 0
msg_line3: db ', in <module>', 13, 10, 0
msg_nasm_new: db 'nasm failed with exit code ', 0
msg_write_new: db 'cannot write asm file', 13, 10, 0
msg_spawn_new: db 'cannot start nasm', 13, 10, 0

c_mov_rsi: db '    mov rsi, ', 0
c_mov_rdx: db '    mov rdx, ', 0
c_mov_rax: db '    mov rax, ', 0
c_str_lbl: db 'str_', 0
c_call_pstr: db '    call rt_print_str', 13, 10, 0
c_call_pnum: db '    call rt_print_num', 13, 10, 0
c_exit: db '    mov ecx, eax', 13, 10, '    call [rel iat_ExitProcess]', 13, 10, 13, 10, '    xor ecx, ecx', 13, 10, '    call [rel iat_ExitProcess]', 13, 10, 0
c_db_colon: db ': db ', 0
c_comma: db ',', 0
c_zero: db '0', 0
c_nl: db 13, 10, 0
c_dll_lbl: db 'DLL_LOAD:', 13, 10, 0
c_dll_mov: db '    mov rcx, dll_path_', 0
c_dll_call: db '    call [rel iat_LoadLibraryA]', 13, 10, '    mov [rel dll_hmod], rax', 13, 10, 0
c_ret: db '    mov rsp, rbx', 13, 10, '    pop rbx', 13, 10, '    ret', 13, 10, 0
c_dll_pro: db '    push rbx', 13, 10, '    mov rbx, rsp', 13, 10, '    and rsp, -16', 13, 10, '    sub rsp, 0x20', 13, 10, 0
c_dll_path_lbl: db 'dll_path_', 0
c_dll_path_val: db ': db ', 0x27, 0
c_dll_path_end: db 0x27, ', 0', 13, 10, 0
c_main_lbl: db 'main:', 13, 10, 0
c_func_lbl: db 'func_', 0
c_colon: db ':', 0
c_prologue: db '    push rbp', 13, 10, '    mov rbp, rsp', 13, 10, 0
c_and_rsp: db '    and rsp, -16', 13, 10, 0
c_sub_rsp8: db '    sub rsp, 8', 13, 10, 0
c_sub_rsp: db '    sub rsp, ', 0
c_epilogue: db '    mov rsp, rbp', 13, 10, '    pop rbp', 13, 10, '    ret', 13, 10, 0
c_push_rax: db '    push rax', 13, 10, 0
c_pop_rax: db '    pop rax', 13, 10, 0
c_add_rsp: db '    add rsp, ', 0
c_call_readint: db '    call read_int_stdin', 13, 10, 0
c_call_getchar: db '    call getchar_stdin', 13, 10, 0
c_call_timems: db '    call time_ms', 13, 10, 0
c_call_random: db '    call random_rand', 13, 10, 0
c_call_func: db '    call func_', 0
c_mov_eax: db '    mov eax, ', 0
c_mov_rax_rbp_sub: db '    mov rax, [rbp-', 0
c_add_rax_rbp_sub: db '    add rax, [rbp-', 0
c_add_rax_rbp_add: db '    add rax, [rbp+', 0
c_add_rax: db '    add rax, ', 0
c_sub_rax_rbp_sub: db '    sub rax, [rbp-', 0
c_sub_rax_rbp_add: db '    sub rax, [rbp+', 0
c_sub_rax: db '    sub rax, ', 0
c_imul_rax_rbp_sub: db '    imul rax, [rbp-', 0
c_imul_rax_rbp_add: db '    imul rax, [rbp+', 0
c_imul_rax: db '    imul rax, ', 0
c_mov_rcx_rbp_sub: db '    mov rcx, [rbp-', 0
c_mov_rcx_rbp_add: db '    mov rcx, [rbp+', 0
c_mov_rcx: db '    mov rcx, ', 0
c_xor_edx: db '    xor edx, edx', 13, 10, 0
c_div_rcx: db '    div rcx', 13, 10, 0
c_mov_rax_rdx: db '    mov rax, rdx', 13, 10, 0
c_mov_rsi_rbp_sub: db '    mov rsi, [rbp-', 0
c_mov_rdx_rbp_sub: db '    mov rdx, [rbp-', 0
c_mov_rbp_sub: db '    mov [rbp-', 0
c_mov_rax_rbp_add: db '    mov rax, [rbp+', 0
c_mov_rsi_rbp_add: db '    mov rsi, [rbp+', 0
c_mov_rdx_rbp_add: db '    mov rdx, [rbp+', 0
c_mov_rbp_add: db '    mov [rbp+', 0
c_bracket: db ']', 13, 10, 0
c_mov_rsi_rax: db '    mov rsi, rax', 13, 10, 0
c_mov_rdx_rax: db '    mov rdx, rax', 13, 10, 0
c_mov_rdx_rdx: db '    mov rdx, rdx', 13, 10, 0
c_mov_rbp_sub_rax: db '], rax', 13, 10, 0
c_mov_rax_mem_rax: db '    mov rax, [rax]', 13, 10, 0
c_mov_mem_rcx_rax: db '    mov [rcx], rax', 13, 10, 0
c_mov_rcx_rax: db '    mov rcx, rax', 13, 10, 0
c_mov_mem_rcx_rsi: db '    mov [rcx], rsi', 13, 10, 0
c_mov_mem_rcx8_rdx: db '    mov [rcx+8], rdx', 13, 10, 0
c_mov_mem_rcx8_sub_rdx: db '    mov [rcx-8], rdx', 13, 10, 0
c_mov_rsi_mem_rcx: db '    mov rsi, [rcx]', 13, 10, 0
c_mov_rsi_rsp: db '    mov rsi, [rsp]', 13, 10, 0
c_mov_rdx_mem_rcx8: db '    mov rdx, [rcx+8]', 13, 10, 0
c_mov_rdx_mem_rcx8_sub: db '    mov rdx, [rcx-8]', 13, 10, 0
c_call_strlen: db '    call rt_strlen', 13, 10, 0
c_call_phex: db '    call rt_print_hex', 13, 10, 0
c_lea_rax_rbp_sub: db '    lea rax, [rbp-', 0
c_lea_rax_rbp_add: db '    lea rax, [rbp+', 0
c_jmp_lret: db '    jmp .Lret_', 0
c_lret_lbl: db '.Lret_', 0
c_lea_rsi_str: db '    lea rsi, [rel str_', 0
c_mov_qword_rbp_sub: db '    mov qword [rbp-', 0
c_mov_qword_rbp_add: db '    mov qword [rbp+', 0
c_rbp_close_comma: db '], ', 0
c_mov_rax_rsi: db '    mov rax, rsi', 13, 10, 0
c_lea_rax_str: db '    lea rax, [rel str_', 0
c_mov_rcx_rsp: db '    mov rcx, [rsp]', 13, 10, 0
c_mov_rcx_rsp8: db '    mov rcx, [rsp+8]', 13, 10, 0
c_mov_rax_rsp8: db '    mov rax, [rsp+8]', 13, 10, 0
c_mov_rsi_rsp8: db '    mov rsi, [rsp+8]', 13, 10, 0
c_mov_rax_rsp_off: db '    mov rax, [rsp+', 0
c_mov_rsi_rsp_off: db '    mov rsi, [rsp+', 0
c_mov_rcx_rsp_off: db '    mov rcx, [rsp+', 0
c_lea_rsi_osnl: db '    lea rsi, [rel os_nl_s]', 13, 10, 0
c_mov_rax_rsp: db '    mov rax, [rsp]', 13, 10, 0
c_call_putch: db '    call rt_putch', 13, 10, 0
c_call_strget: db '    call rt_str_get', 13, 10, 0
c_call_wincreate: db '    call rt_win_create', 13, 10, 0
c_call_winshow: db '    call rt_win_show', 13, 10, 0
c_call_winhide: db '    call rt_win_hide', 13, 10, 0
c_call_winclose: db '    call rt_win_close', 13, 10, 0
c_call_wintitle: db '    call rt_win_title', 13, 10, 0
c_mov_rdx_rsp8: db '    mov rdx, [rsp+8]', 13, 10, 0
c_cmp_rax_rcx: db '    cmp rax, rcx', 13, 10, 0
c_jz_w: db '    jz .WE', 0
c_jle_w: db '    jle .WE', 0
c_jge_w: db '    jge .WE', 0
c_jne_w: db '    jne .WE', 0
c_je_w: db '    je .WE', 0
c_jmp_w: db '    jmp .W', 0
c_jmp_we: db '    jmp .WE', 0
c_jmp_wc: db '    jmp .WC', 0
c_wc_lbl: db '    .WC', 0
c_w_lbl: db '    .W', 0
c_w_end_lbl: db '.WE', 0
c_jz_if: db '    jz .IF', 0
c_jle_if: db '    jle .IF', 0
c_jge_if: db '    jge .IF', 0
c_jne_if: db '    jne .IF', 0
c_je_if: db '    je .IF', 0
c_jmp_if: db '    jmp .IFE', 0
c_if_else_lbl: db '.IF', 0
c_if_end_lbl: db '.IFE', 0
c_test_rax: db '    test rax, rax', 13, 10, 0
c_mov_rsi_mem_rax: db '    mov rsi, [rax]', 13, 10, 0
c_mov_rdx_mem_rax8_sub: db '    mov rdx, [rax-8]', 13, 10, 0
kw_write: db 'write', 0
c_mov_rbp_sub_rsi: db '], rsi', 13, 10, 0
c_mov_rbp_sub_rdx: db '], rdx', 13, 10, 0

; ---- generated template fragments ----
tpl_hdr:
db `bits 64\nsection .hdr start=0 vstart=0\ndos:\n    db 'M', 'Z'\n    times 0x3a db 0\n    dd pe_sig - dos\npe_sig:\n    db 'P', 'E', 0, 0\ncoff:\n    dw 0x8664\n    dw 3\n    dd 0\n    dd 0\n    dd 0\n    dw 0xF0\n    dw 0x0022\nopthdr:\n    dw 0x20B\n    db 0, 0\n    dd text_file_size\n    dd idata_file_size + data_file_size\n    dd 0\n    dd entry - 0x140000000\n    dd text_start - 0x140000000\n    dq 0x140000000\n    dd 0x1000\n    dd 0x200\n    dw 6, 0\n    dw 0, 0\n    dw 6, 0\n    dd 0\n    dd (data_va + data_vsize + 0xFFF) & ~0xFFF\n    dd 0x200\n    dd 0\n    dw 3\n    dw 0\n    dq 0x100000\n    dq 0x1000\n    dq 0x100000\n    dq 0x1000\n    dd 0\n    dd 16\n    dd 0, 0\n    dd idata_va, idata_vsize\n    times 14*8 db 0\nsectab:\n    db '.', 't', 'e', 'x', 't', 0, 0, 0\n    dd text_vsize\n    dd 0x1000\n    dd text_file_size\n    dd 0x200\n    dd 0, 0\n    dw 0, 0\n    dd 0x60000020\n    db '.', 'i', 'd', 'a', 't', 'a', 0, 0\n    dd idata_vsize\n    dd idata_va\n    dd idata_file_size\n    dd idata_off\n    dd 0, 0\n    dw 0, 0\n    dd 0xC0000040\n    db '.', 'd', 'a', 't', 'a', 0, 0, 0\n    dd data_vsize\n    dd data_va\n    dd data_file_size\n    dd data_off\n    dd 0, 0\n    dw 0, 0\n    dd 0xC0000040\n    times (0x200 - ($ - dos)) db 0\n\nsection .text start=0x200 vstart=0x140001000\ntext_start:\nentry:\n    sub rsp, 0x58\n    mov ecx, -11\n    call [rel iat_GetStdHandle]\n    mov r12, rax\n    call DLL_LOAD\n    jmp main\n`, 0

tpl_rt:
db `\n; ---- runtime ----\nrt_strlen:\n    mov rdi, rsi\n    xor rdx, rdx\n.sl:\n    cmp byte [rdi+rdx], 0\n    je .sld\n    inc rdx\n    jmp .sl\n.sld:\n    mov rax, rdx\n    ret\n\nrt_print_str:\n    push rsi\n    push rdx\n    sub rsp, 0x58\n    mov rax, rsp\n    and rax, 15\n    jnz .pst_pad\n    mov rcx, r12\n    mov rdx, rsi\n    mov r8d, [rsp+0x58]\n    lea r9, [rsp+0x28]\n    mov qword [rsp+0x20], 0\n    call [rel iat_WriteFile]\n    add rsp, 0x58\n    pop rdx\n    pop rsi\n    ret\n.pst_pad:\n    sub rsp, 8\n    mov rcx, r12\n    mov rdx, rsi\n    mov r8d, [rsp+0x60]\n    lea r9, [rsp+0x28]\n    mov qword [rsp+0x20], 0\n    call [rel iat_WriteFile]\n    add rsp, 0x60\n    pop rdx\n    pop rsi\n    ret\n\nrt_putch:\n    push rbx\n    push r12\n    push rsi\n    sub rsp, 0x58\n    mov byte [rel putch_buf], al\n    mov byte [rel putch_buf+1], 0\n    mov rcx, r12\n    lea rdx, [rel putch_buf]\n    mov r8d, 1\n    lea r9, [rsp+0x28]\n    mov qword [rsp+0x20], 0\n    call [rel iat_WriteFile]\n    add rsp, 0x58\n    pop rsi\n    pop r12\n    pop rbx\n    ret\n\nrt_str_get:\n    push rbx\n    sub rsp, 0x58\n    mov rax, rsi\n    add rax, rcx\n    movzx eax, byte [rax]\n    add rsp, 0x58\n    pop rbx\n    ret\n\nrt_print_num:\n    push rbx\n    push r12\n    sub rsp, 0x58\n    lea rdi, [rel num_buf+31]\n    mov byte [rdi], 0\n    mov rbx, 10\n.l1:\n    xor edx, edx\n    div rbx\n    add dl, '0'\n    dec rdi\n    mov [rdi], dl\n    test rax, rax\n    jnz .l1\n    mov rax, rsp\n    and rax, 15\n    jnz .pn_pad\n    mov rcx, r12\n    mov rdx, rdi\n    lea rax, [rel num_buf+31]\n    sub rax, rdi\n    mov r8d, eax\n    lea r9, [rsp+0x28]\n    mov qword [rsp+0x20], 0\n    call [rel iat_WriteFile]\n    add rsp, 0x58\n    pop r12\n    pop rbx\n    ret\n.pn_pad:\n    sub rsp, 8\n    mov rcx, r12\n    mov rdx, rdi\n    lea rax, [rel num_buf+31]\n    sub rax, rdi\n    mov r8d, eax\n    lea r9, [rsp+0x28]\n    mov qword [rsp+0x20], 0\n    call [rel iat_WriteFile]\n    add rsp, 0x60\n    pop r12\n    pop rbx\n    ret\n\nrt_print_hex:\n    push rbx\n    push r12\n    sub rsp, 0x58\n    lea rdi, [rel num_buf+31]\n    mov byte [rdi], 0\n    mov rbx, 16\n    mov rcx, rax\n.lh:\n    mov rax, rcx\n    xor edx, edx\n    div rbx\n    mov rcx, rax\n    mov al, dl\n    cmp al, 10\n    jb .lhd\n    add al, 'a'-10\n    jmp .lhst\n.lhd:\n    add al, '0'\n.lhst:\n    dec rdi\n    mov [rdi], al\n    test rcx, rcx\n    jnz .lh\n    mov rax, rsp\n    and rax, 15\n    jnz .ph_pad\n    mov rcx, r12\n    mov rdx, rdi\n    lea rax, [rel num_buf+31]\n    sub rax, rdi\n    mov r8d, eax\n    lea r9, [rsp+0x28]\n    mov qword [rsp+0x20], 0\n    call [rel iat_WriteFile]\n    add rsp, 0x58\n    pop r12\n    pop rbx\n    ret\n.ph_pad:\n    sub rsp, 8\n    mov rcx, r12\n    mov rdx, rdi\n    lea rax, [rel num_buf+31]\n    sub rax, rdi\n    mov r8d, eax\n    lea r9, [rsp+0x28]\n    mov qword [rsp+0x20], 0\n    call [rel iat_WriteFile]\n    add rsp, 0x60\n    pop r12\n    pop rbx\n    ret\n\nread_int_stdin:\n    push rbx\n    sub rsp, 0x60\n    xor ebx, ebx\n.skip:\n    mov ecx, -10\n    call [rel iat_GetStdHandle]\n    mov rcx, rax\n    lea rdx, [rel stdin_ch]\n    mov r8d, 1\n    lea r9, [rsp+0x28]\n    mov qword [rsp+0x20], 0\n    call [rel iat_ReadFile]\n    test rax, rax\n    jz .done\n    cmp dword [rsp+0x28], 0\n    je .done\n    movzx ecx, byte [rel stdin_ch]\n    cmp ecx, ' '\n    je .skip\n    cmp ecx, 0x0a\n    je .skip\n    cmp ecx, 0x0d\n    je .skip\n    cmp ecx, '0'\n    jb .done\n    cmp ecx, '9'\n    ja .done\n.digits:\n    lea rax, [rbx+rbx*4]\n    lea rax, [rax+rax]\n    movzx rcx, byte [rel stdin_ch]\n    sub rcx, '0'\n    add rax, rcx\n    mov rbx, rax\n    mov ecx, -10\n    call [rel iat_GetStdHandle]\n    mov rcx, rax\n    lea rdx, [rel stdin_ch]\n    mov r8d, 1\n    lea r9, [rsp+0x28]\n    mov qword [rsp+0x20], 0\n    call [rel iat_ReadFile]\n    test rax, rax\n    jz .done\n    cmp dword [rsp+0x28], 0\n    je .done\n    movzx rcx, byte [rel stdin_ch]\n    cmp rcx, '0'\n    jb .done\n    cmp rcx, '9'\n    ja .done\n    jmp .digits\n.done:\n    mov rax, rbx\n    add rsp, 0x60\n    pop rbx\n    ret\n\ngetchar_stdin:\n    sub rsp, 0x58\n.skip:\n    mov ecx, -10\n    call [rel iat_GetStdHandle]\n    mov rcx, rax\n    lea rdx, [rel stdin_ch]\n    mov r8d, 1\n    lea r9, [rsp+0x28]\n    mov qword [rsp+0x20], 0\n    call [rel iat_ReadFile]\n    test rax, rax\n    jz .eof\n    cmp dword [rsp+0x28], 0\n    je .eof\n    movzx eax, byte [rel stdin_ch]\n    cmp eax, ' '\n    je .skip\n    cmp eax, 0x0a\n    je .skip\n    cmp eax, 0x0d\n    je .skip\n    add rsp, 0x58\n    ret\n.eof:\n    xor eax, eax\n    add rsp, 0x58\n    ret\n\ntime_ms:\n    call [rel iat_GetTickCount64]\n    ret\n\nrandom_next:\n    mov rax, [rel rng_state]\n    test rax, rax\n    jnz .seed_ok\n    call time_ms\n    mov [rel rng_state], rax\n.seed_ok:\n    mov rax, [rel rng_state]\n    mov rbx, rax\n    shl rbx, 13\n    xor rax, rbx\n    mov rbx, rax\n    shr rbx, 7\n    xor rax, rbx\n    mov rbx, rax\n    shl rbx, 17\n    xor rax, rbx\n    mov [rel rng_state], rax\n    ret\n\nrandom_rand:\n    push rbx\n    push rcx\n    call random_next\n    pop rcx\n    xor edx, edx\n    div rcx\n    mov rax, rdx\n    pop rbx\n    ret\n\nrt_win_create:\n    push rbx\n    push rsi\n    push rdx\n    sub rsp, 0x58\n    mov rbx, rsp\n    and rsp, -16\n    sub rsp, 0x20\n    mov rcx, [rel dll_hmod]\n    test rcx, rcx\n    jz .wcr_fail\n    lea rdx, [rel n_win_create]\n    call [rel iat_GetProcAddress]\n    test rax, rax\n    jz .wcr_fail\n    lea rcx, [rel n_win_dft]\n    call rax\n.wcr_done:\n    mov rsp, rbx\n    add rsp, 0x58\n    pop rdx\n    pop rsi\n    pop rbx\n    ret\n.wcr_fail:\n    xor eax, eax\n    jmp .wcr_done\n\nrt_win_show:\n    push rbx\n    push rsi\n    push rdx\n    sub rsp, 0x58\n    mov rbx, rsp\n    and rsp, -16\n    sub rsp, 0x20\n    mov [rsp+0x48], rcx\n    mov rcx, [rel dll_hmod]\n    test rcx, rcx\n    jz .wws_fail\n    lea rdx, [rel n_win_show]\n    call [rel iat_GetProcAddress]\n    test rax, rax\n    jz .wws_fail\n    mov rcx, [rsp+0x48]\n    call rax\n.wws_done:\n    mov rsp, rbx\n    add rsp, 0x58\n    pop rdx\n    pop rsi\n    pop rbx\n    ret\n.wws_fail:\n    xor eax, eax\n    jmp .wws_done\n\nrt_win_hide:\n    push rbx\n    push rsi\n    push rdx\n    sub rsp, 0x58\n    mov rbx, rsp\n    and rsp, -16\n    sub rsp, 0x20\n    mov [rsp+0x48], rcx\n    mov rcx, [rel dll_hmod]\n    test rcx, rcx\n    jz .wwh_fail\n    lea rdx, [rel n_win_hide]\n    call [rel iat_GetProcAddress]\n    test rax, rax\n    jz .wwh_fail\n    mov rcx, [rsp+0x48]\n    call rax\n.wwh_done:\n    mov rsp, rbx\n    add rsp, 0x58\n    pop rdx\n    pop rsi\n    pop rbx\n    ret\n.wwh_fail:\n    xor eax, eax\n    jmp .wwh_done\n\nrt_win_close:\n    push rbx\n    push rsi\n    push rdx\n    sub rsp, 0x58\n    mov rbx, rsp\n    and rsp, -16\n    sub rsp, 0x20\n    mov [rsp+0x48], rcx\n    mov rcx, [rel dll_hmod]\n    test rcx, rcx\n    jz .wwc_fail\n    lea rdx, [rel n_win_close]\n    call [rel iat_GetProcAddress]\n    test rax, rax\n    jz .wwc_fail\n    mov rcx, [rsp+0x48]\n    call rax\n.wwc_done:\n    mov rsp, rbx\n    add rsp, 0x58\n    pop rdx\n    pop rsi\n    pop rbx\n    ret\n.wwc_fail:\n    xor eax, eax\n    jmp .wwc_done\n\nrt_win_title:\n    push rbx\n    push rsi\n    push rdx\n    sub rsp, 0x58\n    mov rbx, rsp\n    and rsp, -16\n    sub rsp, 0x20\n    mov [rsp+0x48], rcx\n    mov [rsp+0x50], rdx\n    mov rcx, [rel dll_hmod]\n    test rcx, rcx\n    jz .wwt_fail\n    lea rdx, [rel n_win_title]\n    call [rel iat_GetProcAddress]\n    test rax, rax\n    jz .wwt_fail\n    mov rcx, [rsp+0x48]\n    mov rdx, [rsp+0x50]\n    call rax\n.wwt_done:\n    mov rsp, rbx\n    add rsp, 0x58\n    pop rdx\n    pop rsi\n    pop rbx\n    ret\n.wwt_fail:\n    xor eax, eax\n    jmp .wwt_done\n\nn_win_create: db 'win_create', 0\nn_win_show: db 'win_show', 0\nn_win_hide: db 'win_hide', 0\nn_win_close: db 'win_close', 0\nn_win_title: db 'win_title', 0\nn_win_dft: db 'CF Window', 0\n`, 0

tpl_text_end:
db `text_vsize equ ($ - text_start)\n    align 0x200, db 0\ntext_file_size equ ($ - text_start)\nidata_off equ (0x200 + text_file_size + 0x1FF) & ~0x1FF\nidata_va equ 0x1000 + ((text_vsize + 0xFFF) & ~0xFFF)\n\nsection .idata start=idata_off vstart=0x140001000+((text_vsize+0xFFF)&~0xFFF)\nidata_start:\n    dd oft - 0x140000000\n    dd 0\n    dd 0\n    dd dllname - 0x140000000\n    dd iat - 0x140000000\n    dd 0, 0, 0, 0, 0\n    align 8, db 0\noft:\n    dq hint_GetStdHandle - 0x140000000\n    dq hint_WriteFile - 0x140000000\n    dq hint_ExitProcess - 0x140000000\n    dq hint_GetCurrentProcessId - 0x140000000\n    dq hint_GetTickCount64 - 0x140000000\n    dq hint_Sleep - 0x140000000\n    dq hint_ReadFile - 0x140000000\n    dq hint_CreateFileA - 0x140000000\n    dq hint_GetFileSize - 0x140000000\n    dq hint_CreateProcessA - 0x140000000\n    dq hint_WaitForSingleObject - 0x140000000\n    dq hint_GetExitCodeProcess - 0x140000000\n    dq hint_CloseHandle - 0x140000000\n    dq hint_LoadLibraryA - 0x140000000\n    dq hint_GetProcAddress - 0x140000000\n    dq 0\niat:\niat_GetStdHandle: dq hint_GetStdHandle - 0x140000000\niat_WriteFile:    dq hint_WriteFile - 0x140000000\niat_ExitProcess:  dq hint_ExitProcess - 0x140000000\niat_GetCurrentProcessId: dq hint_GetCurrentProcessId - 0x140000000\niat_GetTickCount64: dq hint_GetTickCount64 - 0x140000000\niat_Sleep:        dq hint_Sleep - 0x140000000\niat_ReadFile:     dq hint_ReadFile - 0x140000000\niat_CreateFileA:  dq hint_CreateFileA - 0x140000000\niat_GetFileSize:  dq hint_GetFileSize - 0x140000000\niat_CreateProcessA: dq hint_CreateProcessA - 0x140000000\niat_WaitForSingleObject: dq hint_WaitForSingleObject - 0x140000000\niat_GetExitCodeProcess: dq hint_GetExitCodeProcess - 0x140000000\niat_CloseHandle:  dq hint_CloseHandle - 0x140000000\niat_LoadLibraryA: dq hint_LoadLibraryA - 0x140000000\niat_GetProcAddress: dq hint_GetProcAddress - 0x140000000\n    dq 0\ndllname:\n    db 'kernel32.dll', 0\n    align 2, db 0\nhint_GetStdHandle:\n    dw 0\n    db 'GetStdHandle', 0\nhint_WriteFile:\n    dw 0\n    db 'WriteFile', 0\nhint_ExitProcess:\n    dw 0\n    db 'ExitProcess', 0\nhint_GetCurrentProcessId:\n    dw 0\n    db 'GetCurrentProcessId', 0\nhint_GetTickCount64:\n    dw 0\n    db 'GetTickCount64', 0\nhint_Sleep:\n    dw 0\n    db 'Sleep', 0\nhint_ReadFile:\n    dw 0\n    db 'ReadFile', 0\nhint_CreateFileA:\n    dw 0\n    db 'CreateFileA', 0\nhint_GetFileSize:\n    dw 0\n    db 'GetFileSize', 0\nhint_CreateProcessA:\n    dw 0\n    db 'CreateProcessA', 0\nhint_WaitForSingleObject:\n    dw 0\n    db 'WaitForSingleObject', 0\nhint_GetExitCodeProcess:\n    dw 0\n    db 'GetExitCodeProcess', 0\nhint_CloseHandle:\n    dw 0\n    db 'CloseHandle', 0\nhint_LoadLibraryA:\n    dw 0\n    db 'LoadLibraryA', 0\nhint_GetProcAddress:\n    dw 0\n    db 'GetProcAddress', 0\nidata_vsize equ ($ - idata_start)\n    align 0x200, db 0\nidata_file_size equ ($ - idata_start)\ndata_off equ (idata_off + idata_file_size + 0x1FF) & ~0x1FF\ndata_va equ idata_va + ((idata_vsize + 0xFFF) & ~0xFFF)\n\nsection .data start=data_off vstart=0x140001000+((text_vsize+0xFFF)&~0xFFF)+((idata_vsize+0xFFF)&~0xFFF)\ndata_start:\n`, 0

tpl_data_hdr:
db ``, 0

tpl_data_tail:
db `\nnum_buf: times 32 db 0\nputch_buf: times 32 db 0\ntv_buf: dq 0, 0\nrng_state: dq 0\nstdin_ch: db 0\nos_nl_s: db 13, 10, 0\ndll_hmod: dq 0\ndata_vsize equ ($ - data_start)\n    align 0x200, db 0\ndata_file_size equ ($ - data_start)\n`, 0

data_vsize equ ($ - data_start)
    align 0x200, db 0
data_file_size equ ($ - data_start)

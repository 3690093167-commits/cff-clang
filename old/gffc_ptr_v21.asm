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
    ; ---- success: drop intermediate .asm ----
    lea rcx, [rel asm_path]
    call [rel iat_DeleteFileA]
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

; err_set_import: 构造 "cannot open library '<lib_path_buf>'" -> err_msg_buf
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

; err_report: 打印 Python 风格错误
; 输入: rsi = src_buf 内出错位置; err_type/err_msg 已设置(可为0兜底)
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
    ; ---- 定位: r14=line, r8=line_start offset, rbx=col ----
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
    ; ---- 行内容 ----
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
    ; ---- caret 行 ----
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
; parse_prog: rsi = src -> rax=1 ok / 0 fail
parse_prog:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 0x20
    ; 默认错误兜底: SyntaxError: invalid syntax
    lea rax, [rel msg_etype_syntax]
    mov [rel err_type], rax
    lea rax, [rel msg_invalid]
    mov [rel err_msg], rax
    ; 记录主程序原始长度 (import 内联追加前)
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
    jz .main_or_func
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
    mov byte [rbx], 0
    inc qword [rel import_cnt]
    call ws_skip
    mov dil, '>'
    call expect_char
    test rax, rax
    jz .fail
    call ws_skip
    ; C++-style: import 不带分号, 出现分号即报错
    cmp byte [rsi], ';'
    je .fail
    ; 按库类型处理: .cf 源码合并 / .dll/.so 动态库登记
    ; r14 = 当前库名起点
    call resolve_import
    test rax, rax
    jz .fail
    jmp .imp_loop
.main_or_func:
    ; === import 内联: 若存在 cf 追加内容, 移到 rsi 之前 ===
    mov rax, [rel src_len]
    mov rbx, [rel src_len_orig]
    sub rax, rbx
    jz .mof_nocf
    ; rax = cf_len; 先存 cf 内容 [src_buf+src_len_orig, src_buf+src_len) 到 src_extra
    push rax
    lea r8, [rel src_buf]
    add r8, [rel src_len_orig]
    lea r9, [rel src_extra]
    mov rdx, rax
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
    pop rax
    ; 主程序剩余 [rsi, src_buf+src_len_orig) 后移 cf_len
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
    ; rax 已被 .mof_mv 的 al 破坏, 重算 cf_len
    mov rax, [rel src_len]
    sub rax, [rel src_len_orig]
    ; cf 内容从 src_extra 搬到 rsi
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
    pop rax
    mov rax, [rel src_len]
    mov [rel src_len_orig], rax
    mov qword [rel cf_pending], 0
.mof_nocf:
    call ws_skip
    ; try def function: def name(args) { ... }
    mov r13, 3
    call expect_id_def
    test rax, rax
    jz .try_main
    call ws_skip
    call parse_name
    test rax, rax
    jz .fail
    ; def main() { ... } 直接作为入口, 复用 main 解析流程
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
    jnz .fail
    call add_func
    test rax, rax
    jz .fail
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
    call parse_name
    test rax, rax
    jz .fail
    call is_keyword
    test rax, rax
    jnz .fail
    mov r14, 0
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
    mov rax, [rel func_cnt]
    dec rax
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
    je .body_brk
    ; try print
    mov r13, 5
    call expect_id_print
    test rax, rax
    jz .try_ret
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
    imul rax, rax, 48
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
    mov [rbx], al
    inc rbx
    inc rsi
    inc r12
    jmp .str_loop
.str_done:
    inc rsi
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
    mov rax, [rel strpool_len]
    inc rax
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
    jz .try_str
    mov r12, 2
    jmp .type_ok
.try_str:
    mov r13, 3
    call expect_id_str
    test rax, rax
    jz .fail
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
.try_ret:
    mov r13, 3
    call expect_id_ret
    test rax, rax
    jz parse_prog.try_assign
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
    mov r12, rax
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 3
    mov [rbx+8], r12
    mov qword [rbx+16], 0
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
    imul rax, rax, 48
    add rcx, rax
    mov r12, [rcx+32]
    cmp r12, 1
    je .ret_ident_str
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 3
    mov [rbx+8], r15
    mov qword [rbx+16], 2
    call set_ret_type_num
    jmp .ret_end
.ret_ident_str:
    cmp qword [rel cur_func], -1
    je .fail
    mov rax, [rel stmts_cnt]
    lea rbx, [rel stmts]
    imul rax, rax, 32
    add rbx, rax
    mov qword [rbx], 3
    mov [rbx+8], r15
    mov qword [rbx+16], 3
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
    cmp qword [rbx+16], 0
    je .ret_expr_go
    cmp qword [rbx+16], 2
    je .ret_expr_go
    jmp .fail
.ret_expr_go:
    inc rsi
    call ws_skip
    movzx eax, byte [rsi]
    cmp eax, '0'
    jb .ret_expr_rhs_var
    cmp eax, '9'
    ja .ret_expr_rhs_var
    call parse_num
    mov [rbx+24], rax
    mov rax, [rel cur_op]
    imul rax, rax, 2
    add rax, 5
    jmp .ret_expr_subtype
.ret_expr_rhs_var:
    call parse_name
    test rax, rax
    jz .fail
    call find_var
    cmp r15, -1
    je .fail
    mov [rbx+24], r15
    mov rax, [rel cur_op]
    imul rax, rax, 2
    add rax, 4
.ret_expr_subtype:
    ; 此时 [rbx+16] 仍为左操作数类型：2=变量(子类型4-13区)，0=常量(子类型+10 → 14-23区)
    cmp qword [rbx+16], 2
    je .ret_expr_subtype_ok
    add rax, 10
.ret_expr_subtype_ok:
    mov [rbx+16], rax
    jmp .ret_expr_done
.ret_expr_done:
    call opt_semi
    test rax, rax
    jz .fail
    inc qword [rel stmts_cnt]
    jmp .stmt
.ret_plain:
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
    imul rax, rax, 48
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
    imul rax, rax, 48
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
    imul rax, rax, 48
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
    je .rhs_str
    movzx eax, byte [rsi]
    cmp eax, '0'
    jb .rhs_ident
    cmp eax, '9'
    ja .rhs_ident
    call parse_num
    mov r12, rax
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
    ; r12 = 左常量值
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
    imul rax, rax, 48
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
    imul rax, rax, 48
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
    imul rax, rax, 48
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
    imul rax, rax, 48
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
    ; r12 = 左变量 idx
    mov [rel expr_lhs], r12
    mov qword [rel expr_ltype], 2
    jmp .rhs_expr_common
.rhs_expr_common:
    ; expr_lhs/expr_ltype 已设置；rsi 指向运算符，先设 cur_op
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
    jz .fail
    pop r15
    lea rbx, [rel stmts]
    mov rax, r15
    dec rax
    imul rax, rax, 32
    add rbx, rax
    mov [rbx+24], r14
    dec qword [rel stmts_cnt]
    jmp .stmt_done
.call_stmt:
    call find_func
    cmp r15, -1
    je .fail
    mov r12, r15
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
    jz .fail
    pop r15
    lea rbx, [rel stmts]
    mov rax, r15
    dec rax
    imul rax, rax, 32
    add rbx, rax
    mov [rbx+24], r14
    dec qword [rel stmts_cnt]
    jmp .stmt_done

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
    ; main 解析完毕: .cf 库已在 main 前内联解析, 直接收尾
    mov rax, 1
    jmp .ok
.func_body_done:
    mov dil, '}'
    call expect_char
    test rax, rax
    jz .fail
    mov rbx, [rel func_cnt]
    dec rbx
    lea rcx, [rel func_table]
    imul rbx, rbx, 56
    add rcx, rbx
    mov rax, [rel stmts_cnt]
    mov rdx, [rcx+24]
    sub rax, rdx
    mov [rcx+32], rax
    mov rax, [rel cur_local_cnt]
    mov [rcx+48], rax
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
; resolve_import: r14 = 库名起点(import_libs 64字节项)
; 在 lib 目录查找库文件: 名已带 .cf/.dll/.so 后缀则直接使用;
; 无后缀则依次尝试 .cf/.dll/.so。.cf 源码读入并追加 src_buf,
; .dll/.so 路径登记到 dll_list。返回 rax=1 成功 / 0 失败。
resolve_import:
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
    ; r15 = 库名长度
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
    ; 检查是否带后缀
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
    ; 无后缀: 优先 Python 包目录 lib/<name>/__init__.cf, 失败再回退 .cf/.dll/.so
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
    jnz .ri_ok
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
    jmp .ri_fail
.ri_try:
    lea rcx, [rel lib_path_buf]
    call ri_try_open
    test rax, rax
    jz .ri_fail
.ri_ok:
    mov rax, 1
    jmp .ri_out
.ri_fail:
    call err_set_import
    xor eax, eax
.ri_out:
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

; ri_try_open: rcx=路径指针
; 打开文件并分类: .cf -> 读入 src_extra 追加 src_buf, 置 cf_pending
; .dll/.so -> 完整路径登记 dll_list。返回 rax=1 成功 / 0 失败
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
    ; ---- ANSI -> UTF-16 到 lib_wbuf ----
    lea rdi, [rel lib_wbuf]
    xor ecx, ecx
.rto_conv:
    movzx eax, byte [r15+rcx]
    test al, al
    jz .rto_conv_done
    mov [rdi], ax
    add rdi, 2
    inc ecx
    cmp ecx, 95
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
    je .rto_fail
    mov r12, rax
    mov rcx, rax
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
    ; 判断后缀: 先算路径长度
    lea rdi, [r15]
    xor ecx, ecx
.rto_sl:
    cmp byte [rdi], 0
    je .rto_sl_done
    inc rdi
    inc rcx
    cmp rcx, 96
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
    imul rax, rax, 48
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
    xor r14d, r14d
    call ws_skip
    cmp byte [rsi], ')'
    je .parg_empty
.parg_loop:
    call ws_skip
    cmp byte [rsi], '&'
    je .parg_addr
    movzx eax, byte [rsi]
    cmp eax, '0'
    jb .parg_var
    cmp eax, '9'
    ja .parg_var
    call parse_num
    mov r12, rax
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
    imul rax, rax, 48
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
    imul rax, rax, 48
    add rcx, rax
    cmp qword [rcx+32], 2
    ja .fail
    mov rcx, [rel stmts_cnt]
    lea rdx, [rel stmts]
    imul rcx, rcx, 32
    add rdx, rcx
    mov qword [rdx], 12
    mov qword [rdx+8], 2
    mov [rdx+16], r15
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
expect_id_import:
    lea rdi, [rel kw_import]
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
expect_id_ptr:
    lea rdi, [rel kw_ptr]
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
    lea rbx, [rel kw_ptr]
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
    cmp rbx, 64
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
    mov qword [rcx+48], 0
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

; add_var: r13=kind(0 param/1 local), r14=type(0 num/1 str); tmp_name=name
; -> r15=idx, rax=ok. param slot via cur_param_slot, local via cur_local_cnt
add_var:
    push rbx
    push rcx
    push rdx
    push r12
    push rsi
    mov rbx, [rel var_cnt]
    cmp rbx, 64
    jae .av_fail
    lea rcx, [rel var_table]
    imul rbx, rbx, 48
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
    inc qword [rel cur_param_slot]
    jmp .av_cnt
.av_local:
    mov rax, [rel cur_local_cnt]
    mov [rcx+24], rax
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
    add rbx, 48
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

; parse_num: rsi -> rax
parse_num:
    push rbx
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
    pop rbx
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
    imul rax, rax, 48
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
    imul rax, rax, 48
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
    imul rax, rax, 48
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
    imul rax, rax, 48
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
    imul rax, rax, 48
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
    imul rax, rax, 48
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
    imul rax, rax, 48
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

; emit_load_str: r15=var idx (str local) -> 'mov rsi,[rbp-N]' + 'mov rdx,[rbp-(N+8)]'
emit_load_str:
    push rbx
    push rcx
    push rdx
    push rdi
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 48
    add rcx, rax
    mov rbx, [rcx+24]
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
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; emit_store_str: r15=var idx (str local), rsi=ptr, rdx=len -> store 2 slots
emit_store_str:
    push rbx
    push rcx
    push rdx
    push rdi
    lea rcx, [rel var_table]
    mov rax, r15
    imul rax, rax, 48
    add rcx, rax
    mov rbx, [rcx+24]
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
    imul rax, rax, 48
    add rcx, rax
    mov rdx, [rcx+16]
    mov rbx, [rcx+24]
    cmp rdx, 0
    je .eqc_param
    lea rdi, [rel c_mov_qword_rbp_sub]
    call emit_cstr
    mov rax, rbx
    inc rax
    imul rax, rax, 8
    call emit_num
    lea rdi, [rel c_rbp_close_comma]
    call emit_cstr
    mov rax, [rsp+32]
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    jmp .eqc_out
.eqc_param:
    lea rdi, [rel c_mov_qword_rbp_add]
    call emit_cstr
    mov rax, rbx
    imul rax, rax, 8
    add rax, 16
    call emit_num
    lea rdi, [rel c_rbp_close_comma]
    call emit_cstr
    mov rax, [rsp+32]
    call emit_num
    lea rdi, [rel c_nl]
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
    mov r14, [rdx+16]
    push rbx
    push rcx
    mov r15, r14
    call emit_load_num
    pop rcx
    pop rbx
    lea rdi, [rel c_push_rax]
    call emit_cstr
    dec rbx
    jmp .ecp_loop
.ecp_addr:
    ; pass address of variable: lea rax,[rbp-N]; push rax
    mov r14, [rdx+16]
    push rbx
    push rcx
    mov r15, r14
    call emit_addr_of
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
.ecp_noargs:
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
    cmp rax, 14
    jb .r_next
    cmp rax, 33
    ja .r_next
    jmp .r_assign_expr
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
    imul rax, rax, 48
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
    ; stmt 子类型 14-33；rcx = slot
    ; [rcx+8]=目标var idx, [rcx+16]=左操作数, [rcx+24]=右操作数
    ; 子类型: 14-23 左变量, 24-33 左常量; 偶=右变量, 奇=右常量
    mov rax, [rcx]
    cmp rax, 24
    jb .aex_left_var
    ; 左常量
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
    ; 归一 op 区: 24-33→0-9, 14-23→0-9
    mov rax, [rcx]
    cmp rax, 24
    jb .aex_op_base14
    sub rax, 24
    jmp .aex_op_have
.aex_op_base14:
    sub rax, 14
.aex_op_have:
    ; rax=0-9: op=rax/2, 右类型=rax%2
    test al, 1
    jnz .aex_rhs_const
    ; 右变量: op=rax/2
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
    ; 右常量: op=rax/2
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
    ; 结果在 rax，存入目标变量 [rcx+8]
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
    ; 无 import 注释: .cf 已内联进源码, .dll/.so 由 DLL_LOAD 运行时加载
.imp_e_done:
    ; DLL_LOAD stub: 运行时加载 .dll/.so 库
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
    ; LoadLibraryA 调用后必须 ret 返回 entry (无论是否有 dll)
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
    ; func_<idx>:
    lea rdi, [rel c_func_lbl]
    call emit_cstr
    mov rax, r13
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
    ; prologue
    lea rdi, [rel c_prologue]
    call emit_cstr
    ; sub rsp, locals*8
    mov rax, [rcx+48]
    test rax, rax
    jz .func_no_sub
    lea rdi, [rel c_sub_rsp]
    call emit_cstr
    mov rax, [rcx+48]
    imul rax, rax, 8
    add rax, 15
    and rax, -16
    call emit_num
    lea rdi, [rel c_nl]
    call emit_cstr
.func_no_sub:
    ; body
    mov rsi, [rcx+24]
    mov rdx, [rcx+32]
    add rdx, rsi
    call emit_stmt_range
    ; Lret_<idx>:
    lea rdi, [rel c_lret_lbl]
    call emit_cstr
    mov rax, r13
    call emit_num
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
    jne .str_next
    cmp qword [rcx+16], 1
    jne .str_next
.str_emit_ok:
    ; offset/len by type
    mov rax, [rcx]
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
.empty_str:
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
stmts: times 256*32 db 0
func_cnt: dq 0
func_table: times 64*56 db 0
var_cnt: dq 0
var_table: times 64*48 db 0
cur_func: dq -1
cur_local_cnt: dq 0
cur_param_slot: dq 0
cur_param_cnt: dq 0
main_start: dq 0
main_len: dq 0
main_locals: dq 0
tmp_name: times 16 db 0
tmp_name_bak: times 16 db 0
import_cnt: dq 0
import_libs: times 8*64 db 0
src_len_orig: dq 0
cur_op: dq 0
expr_lhs: dq 0
expr_ltype: dq 0
expr_rhs: dq 0
expr_sub: dq 0
lib_path_buf: times 96 db 0
nt_hfile: dq 0
nt_oa: times 48 db 0
nt_io: times 16 db 0
nt_us: times 16 db 0
lib_wbuf: times 200 db 0
src_extra: times 65536 db 0
src_extra_len: dq 0
cf_pending: dq 0
dll_cnt: dq 0
dll_list: times 8*64 db 0
num_tmp: times 32 db 0
kw_def: db 'def', 0
kw_import: db 'import', 0
kw_int: db 'int', 0
kw_main: db 'main', 0
kw_print: db 'print', 0
kw_ret: db 'ret', 0
kw_bigint: db 'bigint', 0
kw_char: db 'char', 0
kw_str: db 'str', 0
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
err_msg_buf: times 128 db 0
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
msg_expect_char: db 'unexpected character ', 0
msg_expect_eof: db '<EOF>', 0
dbg_enter: db 'DBG_ENTER', 0
dbg_nostar: db 'DBG_NOSTAR', 0
dbg_fvok: db 'DBG_FVOK', 0
dbg_fvfail: db 'DBG_FVFAIL', 0
dbg_pnfail: db 'DBG_PNFAIL', 0
dbg_kwf: db 'DBG_KWF', 0
dbg_ta: db 'DBG_TA', 0
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
c_nl: db 13, 10, 0
c_dll_lbl: db 'DLL_LOAD:', 13, 10, 0
c_dll_mov: db '    mov rcx, dll_path_', 0
c_dll_call: db '    call [rel iat_LoadLibraryA]', 13, 10, 0
c_ret: db '    mov rsp, rbx', 13, 10, '    pop rbx', 13, 10, '    ret', 13, 10, 0
c_dll_pro: db '    push rbx', 13, 10, '    mov rbx, rsp', 13, 10, '    and rsp, -16', 13, 10, '    sub rsp, 0x20', 13, 10, 0
c_dll_path_lbl: db 'dll_path_', 0
c_dll_path_val: db ': db ', 0x27, 0
c_dll_path_end: db 0x27, ', 0', 13, 10, 0
c_main_lbl: db 'main:', 13, 10, 0
c_func_lbl: db 'func_', 0
c_prologue: db '    push rbp', 13, 10, '    mov rbp, rsp', 13, 10, 0
c_and_rsp: db '    and rsp, -16', 13, 10, 0
c_sub_rsp8: db '    sub rsp, 8', 13, 10, 0
c_sub_rsp: db '    sub rsp, ', 0
c_epilogue: db '    mov rsp, rbp', 13, 10, '    pop rbp', 13, 10, '    ret', 13, 10, 0
c_push_rax: db '    push rax', 13, 10, 0
c_add_rsp: db '    add rsp, ', 0
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
c_mov_rbp_sub_rsi: db '], rsi', 13, 10, 0
c_mov_rbp_sub_rdx: db '], rdx', 13, 10, 0

; ---- generated template fragments ----
tpl_hdr:
db `bits 64\nsection .hdr start=0 vstart=0\ndos:\n    db 'M', 'Z'\n    times 0x3a db 0\n    dd pe_sig - dos\npe_sig:\n    db 'P', 'E', 0, 0\ncoff:\n    dw 0x8664\n    dw 3\n    dd 0\n    dd 0\n    dd 0\n    dw 0xF0\n    dw 0x0022\nopthdr:\n    dw 0x20B\n    db 0, 0\n    dd text_file_size\n    dd idata_file_size + data_file_size\n    dd 0\n    dd entry - 0x140000000\n    dd text_start - 0x140000000\n    dq 0x140000000\n    dd 0x1000\n    dd 0x200\n    dw 6, 0\n    dw 0, 0\n    dw 6, 0\n    dd 0\n    dd (data_va + data_vsize + 0xFFF) & ~0xFFF\n    dd 0x200\n    dd 0\n    dw 3\n    dw 0\n    dq 0x100000\n    dq 0x1000\n    dq 0x100000\n    dq 0x1000\n    dd 0\n    dd 16\n    dd 0, 0\n    dd idata_va, idata_vsize\n    times 14*8 db 0\nsectab:\n    db '.', 't', 'e', 'x', 't', 0, 0, 0\n    dd text_vsize\n    dd 0x1000\n    dd text_file_size\n    dd 0x200\n    dd 0, 0\n    dw 0, 0\n    dd 0x60000020\n    db '.', 'i', 'd', 'a', 't', 'a', 0, 0\n    dd idata_vsize\n    dd idata_va\n    dd idata_file_size\n    dd idata_off\n    dd 0, 0\n    dw 0, 0\n    dd 0xC0000040\n    db '.', 'd', 'a', 't', 'a', 0, 0, 0\n    dd data_vsize\n    dd data_va\n    dd data_file_size\n    dd data_off\n    dd 0, 0\n    dw 0, 0\n    dd 0xC0000040\n    times (0x200 - ($ - dos)) db 0\n\nsection .text start=0x200 vstart=0x140001000\ntext_start:\nentry:\n    sub rsp, 0x58\n    mov ecx, -11\n    call [rel iat_GetStdHandle]\n    mov r12, rax\n    call DLL_LOAD\n    jmp main\n`, 0

tpl_rt:
db `\n; ---- runtime ----\nrt_print_str:\n    push rsi\n    push rdx\n    sub rsp, 0x58\n    mov rcx, r12\n    mov rdx, rsi\n    mov r8d, [rsp+0x58]\n    lea r9, [rsp+0x28]\n    mov qword [rsp+0x20], 0\n    call [rel iat_WriteFile]\n    add rsp, 0x58\n    pop rdx\n    pop rsi\n    ret\n\nrt_print_num:\n    push rbx\n    push r12\n    sub rsp, 0x58\n    lea rdi, [rel num_buf+31]\n    mov byte [rdi], 0\n    mov rbx, 10\n.l1:\n    xor edx, edx\n    div rbx\n    add dl, '0'\n    dec rdi\n    mov [rdi], dl\n    test rax, rax\n    jnz .l1\n    mov rcx, r12\n    mov rdx, rdi\n    lea rax, [rel num_buf+31]\n    sub rax, rdi\n    mov r8d, eax\n    lea r9, [rsp+0x28]\n    mov qword [rsp+0x20], 0\n    call [rel iat_WriteFile]\n    add rsp, 0x58\n    pop r12\n    pop rbx\n    ret\n\nrt_print_hex:\n    push rbx\n    push r12\n    sub rsp, 0x58\n    lea rdi, [rel num_buf+31]\n    mov byte [rdi], 0\n    mov rbx, 16\n    mov rcx, rax\n.lh:\n    mov rax, rcx\n    xor edx, edx\n    div rbx\n    mov rcx, rax\n    mov al, dl\n    cmp al, 10\n    jb .lhd\n    add al, 'a'-10\n    jmp .lhst\n.lhd:\n    add al, '0'\n.lhst:\n    dec rdi\n    mov [rdi], al\n    test rcx, rcx\n    jnz .lh\n    mov rcx, r12\n    mov rdx, rdi\n    lea rax, [rel num_buf+31]\n    sub rax, rdi\n    mov r8d, eax\n    lea r9, [rsp+0x28]\n    mov qword [rsp+0x20], 0\n    call [rel iat_WriteFile]\n    add rsp, 0x58\n    pop r12\n    pop rbx\n    ret\n\nread_int_stdin:\n    push rbx\n    xor ebx, ebx\n.skip:\n    mov ecx, -10\n    call [rel iat_GetStdHandle]\n    mov rcx, rax\n    lea rdx, [rel stdin_ch]\n    mov r8d, 1\n    lea r9, [rsp+0x28]\n    mov qword [rsp+0x20], 0\n    call [rel iat_ReadFile]\n    test rax, rax\n    jz .done\n    movzx ecx, byte [rel stdin_ch]\n    cmp ecx, ' '\n    je .skip\n    cmp ecx, 0x0a\n    je .skip\n    cmp ecx, 0x0d\n    je .skip\n    cmp ecx, '0'\n    jb .done\n    cmp ecx, '9'\n    ja .done\n.digits:\n    lea rax, [rbx+rbx*4]\n    lea rax, [rax+rax]\n    movzx rcx, byte [rel stdin_ch]\n    sub rcx, '0'\n    add rax, rcx\n    mov rbx, rax\n    mov ecx, -10\n    call [rel iat_GetStdHandle]\n    mov rcx, rax\n    lea rdx, [rel stdin_ch]\n    mov r8d, 1\n    lea r9, [rsp+0x28]\n    mov qword [rsp+0x20], 0\n    call [rel iat_ReadFile]\n    test rax, rax\n    jz .done\n    movzx rcx, byte [rel stdin_ch]\n    cmp rcx, '0'\n    jb .done\n    cmp rcx, '9'\n    ja .done\n    jmp .digits\n.done:\n    mov rax, rbx\n    pop rbx\n    ret\n\ngetchar_stdin:\n.skip:\n    mov ecx, -10\n    call [rel iat_GetStdHandle]\n    mov rcx, rax\n    lea rdx, [rel stdin_ch]\n    mov r8d, 1\n    lea r9, [rsp+0x28]\n    mov qword [rsp+0x20], 0\n    call [rel iat_ReadFile]\n    test rax, rax\n    jz .eof\n    movzx eax, byte [rel stdin_ch]\n    cmp eax, ' '\n    je .skip\n    cmp eax, 0x0a\n    je .skip\n    cmp eax, 0x0d\n    je .skip\n    ret\n.eof:\n    xor eax, eax\n    ret\n\ntime_ms:\n    call [rel iat_GetTickCount64]\n    ret\n\nrandom_next:\n    mov rax, [rel rng_state]\n    test rax, rax\n    jnz .seed_ok\n    call time_ms\n    mov [rel rng_state], rax\n.seed_ok:\n    mov rax, [rel rng_state]\n    mov rbx, rax\n    shl rbx, 13\n    xor rax, rbx\n    mov rbx, rax\n    shr rbx, 7\n    xor rax, rbx\n    mov rbx, rax\n    shl rbx, 17\n    xor rax, rbx\n    mov [rel rng_state], rax\n    ret\n\nrandom_rand:\n    push rdi\n    call random_next\n    pop rcx\n    xor edx, edx\n    div rcx\n    mov rax, rdx\n    ret\n`, 0

tpl_text_end:
db `text_vsize equ ($ - text_start)\n    align 0x200, db 0\ntext_file_size equ ($ - text_start)\nidata_off equ (0x200 + text_file_size + 0x1FF) & ~0x1FF\nidata_va equ 0x1000 + ((text_vsize + 0xFFF) & ~0xFFF)\n\nsection .idata start=idata_off vstart=0x140001000+((text_vsize+0xFFF)&~0xFFF)\nidata_start:\n    dd oft - 0x140000000\n    dd 0\n    dd 0\n    dd dllname - 0x140000000\n    dd iat - 0x140000000\n    dd 0, 0, 0, 0, 0\n    align 8, db 0\noft:\n    dq hint_GetStdHandle - 0x140000000\n    dq hint_WriteFile - 0x140000000\n    dq hint_ExitProcess - 0x140000000\n    dq hint_GetCurrentProcessId - 0x140000000\n    dq hint_GetTickCount64 - 0x140000000\n    dq hint_Sleep - 0x140000000\n    dq hint_ReadFile - 0x140000000\n    dq hint_CreateFileA - 0x140000000\n    dq hint_GetFileSize - 0x140000000\n    dq hint_CreateProcessA - 0x140000000\n    dq hint_WaitForSingleObject - 0x140000000\n    dq hint_GetExitCodeProcess - 0x140000000\n    dq hint_CloseHandle - 0x140000000\n    dq hint_LoadLibraryA - 0x140000000\n    dq 0\niat:\niat_GetStdHandle: dq hint_GetStdHandle - 0x140000000\niat_WriteFile:    dq hint_WriteFile - 0x140000000\niat_ExitProcess:  dq hint_ExitProcess - 0x140000000\niat_GetCurrentProcessId: dq hint_GetCurrentProcessId - 0x140000000\niat_GetTickCount64: dq hint_GetTickCount64 - 0x140000000\niat_Sleep:        dq hint_Sleep - 0x140000000\niat_ReadFile:     dq hint_ReadFile - 0x140000000\niat_CreateFileA:  dq hint_CreateFileA - 0x140000000\niat_GetFileSize:  dq hint_GetFileSize - 0x140000000\niat_CreateProcessA: dq hint_CreateProcessA - 0x140000000\niat_WaitForSingleObject: dq hint_WaitForSingleObject - 0x140000000\niat_GetExitCodeProcess: dq hint_GetExitCodeProcess - 0x140000000\niat_CloseHandle:  dq hint_CloseHandle - 0x140000000\niat_LoadLibraryA: dq hint_LoadLibraryA - 0x140000000\n    dq 0\ndllname:\n    db 'kernel32.dll', 0\n    align 2, db 0\nhint_GetStdHandle:\n    dw 0\n    db 'GetStdHandle', 0\nhint_WriteFile:\n    dw 0\n    db 'WriteFile', 0\nhint_ExitProcess:\n    dw 0\n    db 'ExitProcess', 0\nhint_GetCurrentProcessId:\n    dw 0\n    db 'GetCurrentProcessId', 0\nhint_GetTickCount64:\n    dw 0\n    db 'GetTickCount64', 0\nhint_Sleep:\n    dw 0\n    db 'Sleep', 0\nhint_ReadFile:\n    dw 0\n    db 'ReadFile', 0\nhint_CreateFileA:\n    dw 0\n    db 'CreateFileA', 0\nhint_GetFileSize:\n    dw 0\n    db 'GetFileSize', 0\nhint_CreateProcessA:\n    dw 0\n    db 'CreateProcessA', 0\nhint_WaitForSingleObject:\n    dw 0\n    db 'WaitForSingleObject', 0\nhint_GetExitCodeProcess:\n    dw 0\n    db 'GetExitCodeProcess', 0\nhint_CloseHandle:\n    dw 0\n    db 'CloseHandle', 0\nhint_LoadLibraryA:\n    dw 0\n    db 'LoadLibraryA', 0\nidata_vsize equ ($ - idata_start)\n    align 0x200, db 0\nidata_file_size equ ($ - idata_start)\ndata_off equ (idata_off + idata_file_size + 0x1FF) & ~0x1FF\ndata_va equ idata_va + ((idata_vsize + 0xFFF) & ~0xFFF)\n\nsection .data start=data_off vstart=0x140001000+((text_vsize+0xFFF)&~0xFFF)+((idata_vsize+0xFFF)&~0xFFF)\ndata_start:\n`, 0

tpl_data_hdr:
db ``, 0

tpl_data_tail:
db `\nnum_buf: times 32 db 0\ntv_buf: dq 0, 0\nrng_state: dq 0\nstdin_ch: db 0\ndata_vsize equ ($ - data_start)\n    align 0x200, db 0\ndata_file_size equ ($ - data_start)\n`, 0

data_vsize equ ($ - data_start)
    align 0x200, db 0
data_file_size equ ($ - data_start)

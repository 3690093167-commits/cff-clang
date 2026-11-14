#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gff - CFF 语言编译器 (阶段2: CF 0.2)
====================================
支持: imp / namesp / int main(){} / print / ret
      int/str 变量定义与赋值 / while / if-else / for-in(字符串) / 二元运算
目标: x86_64 Linux ELF (纯 syscall) + ELF32 Multiboot (QEMU 验证)

用法:
    gff -elf  -filename 输出名 源码路径
    gff -qemu -filename 输出名 源码路径
"""
import struct
import sys


# ================= 词法 =================

class Lexer:
    KEYWORDS = {
        "imp", "namesp", "int", "str", "char", "bigint", "auto",
        "print", "ret", "for", "in", "while", "if", "else", "goto",
    }

    def __init__(self, src):
        self.src = src
        self.pos = 0
        self.toks = []
        self._tokenize()

    def _tokenize(self):
        s, n = self.src, len(self.src)
        i = 0
        while i < n:
            c = s[i]
            if c in " \t\r\n":
                i += 1
                continue
            if c == "/" and i + 1 < n and s[i + 1] == "/":
                while i < n and s[i] != "\n":
                    i += 1
                continue
            if c == '"':
                j = i + 1
                while j < n and s[j] != '"':
                    if s[j] == "\\":
                        j += 1
                    j += 1
                if j >= n:
                    raise SyntaxError(f"未闭合字符串 at {i}")
                self.toks.append(("str", s[i + 1:j], i))
                i = j + 1
                continue
            if c == "'":
                if i + 3 < n and s[i + 2] == "'":
                    self.toks.append(("num", ord(s[i + 1]), i))
                    i += 3
                    continue
                raise SyntaxError(f"非法字符字面量 at {i}")
            if c.isalpha() or c == "_":
                j = i
                while j < n and (s[j].isalnum() or s[j] == "_"):
                    j += 1
                w = s[i:j]
                self.toks.append((w if w in self.KEYWORDS else "id", w, i))
                i = j
                continue
            if c.isdigit():
                j = i
                if c == "0" and i + 1 < n and s[i + 1] in ("x", "X"):
                    j = i + 2
                    while j < n and (s[j] in "0123456789abcdefABCDEF"):
                        j += 1
                    self.toks.append(("num", int(s[i + 2:j], 16), i))
                    i = j
                    continue
                while j < n and s[j].isdigit():
                    j += 1
                self.toks.append(("num", int(s[i:j]), i))
                i = j
                continue
            for op in ("==", "!=", "<=", ">=", "{", "}", "(", ")", ",", ";", "<", ">", "=", "+", "-", "*", "/", "."):
                if s.startswith(op, i):
                    self.toks.append((op, op, i))
                    i += len(op)
                    break
            else:
                raise SyntaxError(f"非法字符 {c!r} at {i}")
        self.toks.append(("eof", "", n))

    def peek(self):
        return self.toks[self.pos]

    def next(self):
        t = self.toks[self.pos]
        self.pos += 1
        return t

    def expect(self, k):
        t = self.next()
        if t[0] != k:
            raise SyntaxError(f"期望 {k}, 得到 {t[1]!r} at {t[2]}")
        return t


# ================= 语法分析 (AST) =================

class CFCompiler:
    def __init__(self, src):
        self.lex = Lexer(src)
        self.imports = []
        self.namespaces = []
        self.ast = []          # 顶层语句列表
        self.vars = {}         # name -> slot 偏移 (仅统计)
        self.char_vars = set() # char 类型变量名
        self.bigint_vars = set() # bigint 类型变量名

    def parse_program(self):
        while True:
            t = self.lex.peek()
            if t[0] == "eof":
                break
            if t[0] == "imp":
                self.lex.next()
                self.lex.expect("<")
                name = self.lex.expect("id")[1]
                self.lex.expect(">")
                self.lex.expect(";")
                self.imports.append(name)
            elif t[0] == "namesp":
                self.lex.next()
                names = []
                while True:
                    names.append(self.lex.expect("id")[1])
                    if self.lex.peek()[0] == ",":
                        self.lex.next()
                        continue
                    break
                self.lex.expect(";")
                self.namespaces.extend(names)
            elif t[0] == "int":
                self.lex.next()
                fname = self.lex.expect("id")[1]
                self.lex.expect("(")
                self.lex.expect(")")
                self.lex.expect("{")
                self.ast = self.parse_block()
                self.lex.expect("}")
            else:
                raise SyntaxError(f"顶层非法 token {t[1]!r} at {t[2]}")

    def parse_block(self):
        stmts = []
        while True:
            t = self.lex.peek()
            if t[0] == "}":
                return stmts
            if t[0] == "eof":
                raise SyntaxError("代码块未闭合")
            stmts.append(self.parse_stmt())
        return stmts

    def parse_stmt(self):
        t = self.lex.peek()
        if t[0] == "print":
            self.lex.next()
            self.lex.expect("(")
            e = self.parse_expr()
            if self.lex.peek()[0] == ",":
                self.lex.next()
                self.lex.next()      # 跳过类型参数
            self.lex.expect(")")
            self.lex.expect(";")
            return ("print", e)
        if t[0] == "ret":
            self.lex.next()
            e = self.parse_expr()
            self.lex.expect(";")
            return ("ret", e)
        if t[0] in ("int", "str", "char", "bigint", "auto"):
            ty = self.lex.next()[1]
            name = self.lex.expect("id")[1]
            e = ("num", 0)
            if self.lex.peek()[0] == "=":
                self.lex.next()
                e = self.parse_expr()
            self.lex.expect(";")
            self.vars.setdefault(name, None)
            if ty == "char":
                self.char_vars.add(name)
            if ty == "bigint":
                self.bigint_vars.add(name)
            return ("decl", ty, name, e)
        if t[0] == "id":
            name = self.lex.next()[1]
            if self.lex.peek()[0] == ".":
                self.lex.next()
                attr = self.lex.expect("id")[1]
                args = []
                if self.lex.peek()[0] == "(":
                    self.lex.next()
                    if self.lex.peek()[0] != ")":
                        while True:
                            args.append(self.parse_expr())
                            if self.lex.peek()[0] == ",":
                                self.lex.next()
                                continue
                            break
                    self.lex.expect(")")
                self.lex.expect(";")
                return ("callstmt", name + "." + attr, args)
            if self.lex.peek()[0] == "(":
                self.lex.next()
                args = []
                if self.lex.peek()[0] != ")":
                    while True:
                        args.append(self.parse_expr())
                        if self.lex.peek()[0] == ",":
                            self.lex.next()
                            continue
                        break
                self.lex.expect(")")
                self.lex.expect(";")
                return ("callstmt", name, args)
            if self.lex.peek()[0] == "=":
                self.lex.next()
                e = self.parse_expr()
                self.lex.expect(";")
                return ("assign", name, e)
            raise SyntaxError(f"语句非法: 变量 {name!r} 后非 '=' at {t[2]}")
        if t[0] == "while":
            self.lex.next()
            self.lex.expect("(")
            cond = self.parse_expr()
            self.lex.expect(")")
            self.lex.expect("{")
            body = self.parse_block()
            self.lex.expect("}")
            return ("while", cond, body)
        if t[0] == "if":
            self.lex.next()
            self.lex.expect("(")
            cond = self.parse_expr()
            self.lex.expect(")")
            self.lex.expect("{")
            then_b = self.parse_block()
            self.lex.expect("}")
            else_b = []
            if self.lex.peek()[0] == "else":
                self.lex.next()
                self.lex.expect("{")
                else_b = self.parse_block()
                self.lex.expect("}")
            return ("if", cond, then_b, else_b)
        if t[0] == "for":
            self.lex.next()
            self.lex.expect("(")
            var = self.lex.expect("id")[1]
            self.lex.expect("in")
            coll = self.parse_expr()
            self.lex.expect(")")
            self.lex.expect("{")
            body = self.parse_block()
            self.lex.expect("}")
            self.vars.setdefault(var, None)
            return ("for", var, coll, body)
        raise SyntaxError(f"语句非法 token {t[1]!r} at {t[2]}")

    def parse_expr(self):
        lhs = self.parse_primary()
        while self.lex.peek()[0] in ("==", "!=", "<", ">", "<=", ">=", "+", "-", "*", "/"):
            op = self.lex.next()[0]
            rhs = self.parse_primary()
            lhs = ("binop", op, lhs, rhs)
        return lhs

    def parse_primary(self):
        t = self.lex.next()
        if t[0] == "num":
            return ("num", t[1])
        if t[0] == "str":
            return ("str", t[1])
        if t[0] == "id":
            name = t[1]
            if self.lex.peek()[0] == ".":
                self.lex.next()
                attr = self.lex.expect("id")[1]
                if self.lex.peek()[0] == "(":
                    self.lex.next()
                    args = []
                    if self.lex.peek()[0] != ")":
                        while True:
                            args.append(self.parse_expr())
                            if self.lex.peek()[0] == ",":
                                self.lex.next()
                                continue
                            break
                    self.lex.expect(")")
                    return ("call", name + "." + attr, args)
                return ("member", name, attr)
            if self.lex.peek()[0] == "(":
                self.lex.next()
                args = []
                if self.lex.peek()[0] != ")":
                    while True:
                        args.append(self.parse_expr())
                        if self.lex.peek()[0] == ",":
                            self.lex.next()
                            continue
                        break
                self.lex.expect(")")
                return ("call", name, args)
            return ("var", name)
        if t[0] == "(":
            e = self.parse_expr()
            self.lex.expect(")")
            return e
        raise SyntaxError(f"表达式非法 token {t[1]!r} at {t[2]}")


# ================= ELF64 (x86_64 Linux) 代码生成 =================
# 布局: [ehdr 64][phdr 56x2][code][data]
# 栈: 变量槽从 rbp-8 起; 表达式求值在 rax

class ELF64Gen:
    def __init__(self, c):
        self.c = c
        self.str_pool = {}     # bytes -> data offset
        self.data = bytearray()
        self.code = bytearray()
        self.slots = {}        # var -> rbp 偏移 (负)
        self.slot_next = 8
        self.jumps = []        # (code_pos_of_disp, target_key, kind)
        self.labels = {}       # target_key -> code offset
        self.cond_n = 0

    def get_str_off(self, s):
        b = s.encode()
        if b not in self.str_pool:
            self.str_pool[b] = len(self.data)
            self.data += b
        return self.str_pool[b]

    def slot(self, name):
        if name not in self.slots:
            self.slots[name] = -self.slot_next
            self.slot_next += 8
        return self.slots[name]

    def collect_expr(self, e):
        if e[0] == "var":
            self.slot(e[1])
        elif e[0] == "binop":
            self.collect_expr(e[2])
            self.collect_expr(e[3])
        elif e[0] == "call":
            for a in e[2]:
                self.collect_expr(a)

    def collect_stmt(self, st):
        k = st[0]
        if k == "print":
            self.collect_expr(st[1])
        elif k == "ret":
            self.collect_expr(st[1])
        elif k == "decl":
            self.slot(st[2])
            self.collect_expr(st[3])
        elif k == "assign":
            self.slot(st[1])
            self.collect_expr(st[2])
        elif k == "callstmt":
            for a in st[2]:
                self.collect_expr(a)
        elif k == "while":
            self.collect_expr(st[1])
            for s in st[2]:
                self.collect_stmt(s)
        elif k == "if":
            self.collect_expr(st[1])
            for s in st[2]:
                self.collect_stmt(s)
            for s in st[3]:
                self.collect_stmt(s)
        elif k == "for":
            self.slot(st[1])
            self.collect_expr(st[2])
            for s in st[3]:
                self.collect_stmt(s)

    def emit(self, b):
        self.code += b

    # ---- 表达式 -> rax ----
    def emit_expr(self, e):
        k = e[0]
        if k == "num":
            v = e[1]
            if v < -0x80000000 or v > 0x7FFFFFFF:
                self.emit(b"\x48\xb8" + struct.pack("<q", v))  # movabs rax, imm64
            else:
                self.emit(b"\x48\xc7\xc0" + struct.pack("<I", v & 0xFFFFFFFF))  # mov rax, imm32
        elif k == "str":
            off = self.get_str_off(e[1])
            # lea rax, [rip+disp]; 回填
            self.emit(b"\x48\x8d\x05\x00\x00\x00\x00")
            self.jumps.append((len(self.code) - 4, ("str", off), "disp"))
        elif k == "var":
            off = self.slot(e[1])
            # mov rax, [rbp+off]
            if off == -8:
                self.emit(b"\x48\x8b\x45\xf8")
            else:
                self.emit(b"\x48\x8b\x45" + struct.pack("b", off))
        elif k == "binop":
            op, a, b = e[1], e[2], e[3]
            # 先求 a -> rax, 压栈; 求 b -> rcx; rax = a op b
            self.emit_expr(a)
            self.emit(b"\x50")                    # push rax
            self.emit_expr(b)
            self.emit(b"\x48\x89\xc1")            # mov rcx, rax (b)
            self.emit(b"\x58")                    # pop rax (a)
            self.emit(b"\x48\x89\xc2")            # mov rdx, rax (a)
            if op == "+":
                self.emit(b"\x48\x01\xca")        # rdx = a+b
            elif op == "-":
                self.emit(b"\x48\x29\xca")        # rdx = a-b
            elif op == "*":
                self.emit(b"\x48\x0f\xaf\xd1")    # rdx = a*b (imul rdx, rcx)
            elif op == "/":
                # 需要 rax=a, rcx=b: idiv
                self.emit(b"\x48\x89\xc8")        # rax = a
                self.emit(b"\x48\x99")            # cqo (rdx = sign)
                self.emit(b"\x48\xf7\xf9")        # idiv rcx
                self.emit(b"\x48\x89\xc2")        # rdx = rax (quot)
            elif op in ("==", "!=", "<", ">", "<=", ">="):
                self.emit(b"\x48\x39\xca")        # cmp rdx, rcx
                set_op = {"==": b"\x94", "!=": b"\x95", "<": b"\x9c",
                          ">": b"\x9f", "<=": b"\x9e", ">=": b"\x9d"}[op]
                self.emit(b"\x0f" + set_op + b"\xc0")          # setcc al
                self.emit(b"\x48\x0f\xb6\xc0")                 # movzx rax, al
                return
            self.emit(b"\x48\x89\xd0")            # rax = rdx
        elif k == "call":
            self.emit_call_expr(e[1], e[2])
        else:
            raise RuntimeError(f"表达式不支持 {k}")

    def emit_call_expr(self, fname, args):
        """表达式级函数调用 (Linux 后端)"""
        if fname == "crdso.peek":
            if len(args) != 1:
                raise RuntimeError("crdso.peek 需要 1 个参数")
            self.emit_expr(args[0])                        # addr -> rax
            self.emit(b"\x0f\xb6\x00")                     # movzx eax, byte [rax]
        elif fname == "time.now":
            if len(args) != 0:
                raise RuntimeError("time.now 无参数")
            # syscall 201: time(NULL) -> 秒 (Linux 用户态)
            self.emit(b"\x48\xc7\xc0\xc9\x00\x00\x00")     # mov rax, 201
            self.emit(b"\x48\x31\xff")                     # xor rdi, rdi
            self.emit(b"\x0f\x05")                         # syscall
        elif fname == "random.next":
            if len(args) != 0:
                raise RuntimeError("random.next 无参数")
            sl = self.slot("__rand_seed")
            # xorshift64: seed ^= seed<<13; seed ^= seed>>17; seed ^= seed<<5
            self.emit(b"\x48\x8b\x45" + struct.pack("b", sl))  # mov rax,[seed]
            self.emit(b"\x48\x89\xc1")                     # mov rcx,rax
            self.emit(b"\x48\xc1\xe1\x0d")                 # shl rcx,13
            self.emit(b"\x48\x31\xc8")                     # xor rax,rcx
            self.emit(b"\x48\x89\xc1")                     # mov rcx,rax
            self.emit(b"\x48\xc1\xe9\x11")                 # shr rcx,17
            self.emit(b"\x48\x31\xc8")                     # xor rax,rcx
            self.emit(b"\x48\x89\xc1")                     # mov rcx,rax
            self.emit(b"\x48\xc1\xe1\x05")                 # shl rcx,5
            self.emit(b"\x48\x31\xc8")                     # xor rax,rcx
            self.emit(b"\x48\x89\x45" + struct.pack("b", sl))  # mov [seed],rax
            self.emit(b"\x48\x31\xd2")                     # xor rdx,rdx
            self.emit(b"\x48\xc7\xc1\x64\x00\x00\x00")     # mov rcx,100
            self.emit(b"\x48\xf7\xf1")                     # div rcx
            self.emit(b"\x48\x89\xd0")                     # rax = rdx (0..99)
        else:
            raise RuntimeError(f"阶段3 不支持函数 {fname}")

    def emit_stmt(self, st):
        k = st[0]
        if k == "print":
            e = st[1]
            if e[0] == "str":
                off = self.get_str_off(e[1])
                # write(1, str, len): rax=1, rdi=1, rsi=ptr, rdx=len
                self.emit(b"\x48\xc7\xc0\x01\x00\x00\x00")
                self.emit(b"\x48\xc7\xc7\x01\x00\x00\x00")
                self.emit(b"\x48\x8d\x35\x00\x00\x00\x00")   # lea rsi,[rip+disp]
                self.jumps.append((len(self.code) - 4, ("str", off), "disp"))
                self.emit(b"\xba" + struct.pack("<I", len(e[1].encode())))
                self.emit(b"\x0f\x05")
            elif e[0] == "var" and e[1] in self.c.char_vars:
                self.emit_expr(e)
                self.emit(b"\x48\x89\xc7")        # rdi = char
                self.emit(b"\xe8" + b"\x00\x00\x00\x00")   # call print_char
                self.jumps.append((len(self.code) - 4, ("call_printchar",), "call"))
            else:
                # 数值打印: 先转字符串 (简单实现: 十进制定点)
                # 复用子过程: 在代码末尾放 print_num 例程
                self.emit_expr(e)
                self.emit(b"\x48\x89\xc7")        # rdi = value
                self.emit(b"\xe8" + b"\x00\x00\x00\x00")   # call print_num
                self.jumps.append((len(self.code) - 4, ("call_printnum",), "call"))
        elif k == "ret":
            e = st[1]
            self.emit_expr(e)
            self.emit(b"\x48\x89\xc7")            # rdi = value
            self.emit(b"\x48\xc7\xc0\x3c\x00\x00\x00")   # rax=60
            self.emit(b"\x0f\x05")
        elif k == "decl":
            _, ty, name, e = st
            self.emit_expr(e)
            off = self.slot(name)
            self.emit(b"\x48\x89\x45" + struct.pack("b", off))
        elif k == "assign":
            _, name, e = st
            self.emit_expr(e)
            off = self.slot(name)
            self.emit(b"\x48\x89\x45" + struct.pack("b", off))
        elif k == "while":
            _, cond, body = st
            self.cond_n += 1
            top = ("while_top", self.cond_n)
            end = ("while_end", self.cond_n)
            self.labels[top] = len(self.code)
            # 条件 -> rax
            self.emit_expr(cond)
            self.emit(b"\x48\x85\xc0")            # test rax,rax
            self.emit(b"\x0f\x84\x00\x00\x00\x00")  # jz end
            self.jumps.append((len(self.code) - 4, end, "jz"))
            for s in body:
                self.emit_stmt(s)
            # jmp top
            self.emit(b"\xe9\x00\x00\x00\x00")
            self.jumps.append((len(self.code) - 4, top, "jmp"))
            self.labels[end] = len(self.code)
        elif k == "if":
            _, cond, then_b, else_b = st
            self.cond_n += 1
            end = ("if_end", self.cond_n)
            else_l = ("if_else", self.cond_n)
            self.emit_expr(cond)
            self.emit(b"\x48\x85\xc0")
            if else_b:
                self.emit(b"\x0f\x84\x00\x00\x00\x00")
                self.jumps.append((len(self.code) - 4, else_l, "jz"))
                for s in then_b:
                    self.emit_stmt(s)
                self.emit(b"\xe9\x00\x00\x00\x00")
                self.jumps.append((len(self.code) - 4, end, "jmp"))
                self.labels[else_l] = len(self.code)
                for s in else_b:
                    self.emit_stmt(s)
                self.labels[end] = len(self.code)
            else:
                self.emit(b"\x0f\x84\x00\x00\x00\x00")
                self.jumps.append((len(self.code) - 4, end, "jz"))
                for s in then_b:
                    self.emit_stmt(s)
                self.labels[end] = len(self.code)
        elif k == "callstmt":
            fname, args = st[1], st[2]
            if fname == "crdso.poke":
                if len(args) != 2:
                    raise RuntimeError("crdso.poke 需要 2 个参数")
                self.emit_expr(args[0])                        # addr -> rax
                self.emit(b"\x50")                             # push rax
                self.emit_expr(args[1])                        # val -> rax
                self.emit(b"\x48\x89\xc1")                     # rcx = val
                self.emit(b"\x58")                             # pop rax (addr)
                self.emit(b"\x88\x08")                         # mov [rax], cl
            else:
                raise RuntimeError(f"阶段3 不支持语句函数 {fname}")
        elif k == "for":
            _, var, coll, body = st
            if coll[0] != "str":
                raise RuntimeError("阶段2 for-in 仅支持字符串遍历")
            s = coll[1]
            off = self.get_str_off(s)
            sl = self.slot(var)
            self.cond_n += 1
            top = ("for_top", self.cond_n)
            end = ("for_end", self.cond_n)
            # 初始化: rbx = 索引0
            self.emit(b"\x48\xc7\xc3\x00\x00\x00\x00")   # mov rbx,0
            self.labels[top] = len(self.code)
            # 比较 rbx < len
            self.emit(b"\x48\x81\xfb" + struct.pack("<I", len(s)))  # cmp rbx,len
            self.emit(b"\x0f\x8d\x00\x00\x00\x00")       # jge end
            self.jumps.append((len(self.code) - 4, end, "jge"))
            # 取字符: al = data[rbx]; 存入 var 槽 (低字节)
            self.emit(b"\x48\x8d\x05\x00\x00\x00\x00")   # lea rax,[rip+str]
            self.jumps.append((len(self.code) - 4, ("str", off), "disp"))
            self.emit(b"\x0f\xb6\x04\x18")               # movzx eax, byte [rax+rbx]
            self.emit(b"\x48\x89\x45" + struct.pack("b", sl))  # var = 字符值
            for s2 in body:
                self.emit_stmt(s2)
            self.emit(b"\x48\xff\xc3")                   # inc rbx
            self.emit(b"\xe9\x00\x00\x00\x00")           # jmp top
            self.jumps.append((len(self.code) - 4, top, "jmp"))
            self.labels[end] = len(self.code)
        else:
            raise RuntimeError(f"语句不支持 {k}")

    def emit_printnum_routine(self):
        """子过程: print_num(rdi=有符号64位值), 输出十进制+换行. 保存 clobber 寄存器."""
        start = len(self.code)
        self.printnum_addr = start
        # 保存 rbx (被调用者保存)
        self.emit(b"\x53")                            # push rbx
        # rbx = 缓冲区指针 (栈上 32 字节)
        self.emit(b"\x48\x81\xec\x20\x00\x00\x00")    # sub rsp, 32
        # r12 = rsp (buffer end)
        self.emit(b"\x49\x89\xe4")                    # mov r12, rsp
        # 符号: r13 = 1 (正)
        self.emit(b"\x49\xc7\xc5\x01\x00\x00\x00")    # mov r13, 1
        self.emit(b"\x48\x85\xff")                    # test rdi,rdi
        self.emit(b"\x0f\x8d\x0a\x00\x00\x00")        # jge 跳过
        self.emit(b"\x49\xc7\xc5\xff\xff\xff\xff")    # mov r13, -1
        self.emit(b"\x48\xf7\xdf")                    # neg rdi
        # 循环: 除10取余
        loop = len(self.code)
        self.labels[("pn_loop",)] = loop
        self.emit(b"\x48\x89\xf8")                    # mov rax, rdi
        self.emit(b"\x48\x99")                        # cqo
        self.emit(b"\x48\xc7\xc1\x0a\x00\x00\x00")    # mov rcx, 10
        self.emit(b"\x48\xf7\xf9")                    # idiv rcx
        self.emit(b"\x48\x89\xc7")                    # rdi = rax (商)
        self.emit(b"\x48\x89\xd0")                    # rax = rdx (余)
        self.emit(b"\x48\x83\xc0\x30")                # add rax, '0'
        self.emit(b"\x49\x89\xe1")                    # mov r9, r12
        self.emit(b"\x48\x89\x04\x24")                # mov [rsp], rax
        self.emit(b"\x49\x8d\x64\x24\x01")            # lea r12, [r12+1]
        self.emit(b"\x48\x85\xff")                    # test rdi,rdi
        self.emit(b"\x0f\x85" + struct.pack("<i", loop - (len(self.code) + 6)))  # jnz loop
        # 负号
        self.emit(b"\x49\x83\xfd\x01")                # cmp r13,1
        self.emit(b"\x0f\x84\x0f\x00\x00\x00")        # je 跳过负号
        self.emit(b"\x49\x89\xe1")                    # mov r9, r12
        self.emit(b"\x48\xc7\x04\x24\x2d\x00\x00\x00")  # mov [rsp], '-'
        self.emit(b"\x49\x8d\x64\x24\x01")            # lea r12,[r12+1]
        # 换行
        self.emit(b"\x49\x89\xe1")
        self.emit(b"\x48\xc7\x04\x24\x0a\x00\x00\x00")  # '\n'
        self.emit(b"\x49\x8d\x64\x24\x01")
        # 计算长度: r13 = r12 - rsp
        self.emit(b"\x4c\x89\xe6")                    # mov rsi, r12 (长度)
        self.emit(b"\x48\x29\xe6")                    # rsi -= rsp
        # write(1, rsp, rsi)
        self.emit(b"\x48\xc7\xc0\x01\x00\x00\x00")
        self.emit(b"\x48\xc7\xc7\x01\x00\x00\x00")
        self.emit(b"\x48\x89\xe6")                    # rsi = rsp
        self.emit(b"\x0f\x05")
        self.emit(b"\x48\x81\xc4\x20\x00\x00\x00")    # add rsp, 32
        self.emit(b"\x5b")                            # pop rbx
        self.emit(b"\xc3")                            # ret
        return start

    def emit_printchar_routine(self):
        """子过程: print_char(rdi=字符), write(1, &c, 1) 无换行"""
        start = len(self.code)
        self.printchar_addr = start
        self.emit(b"\x48\x83\xec\x18")                # sub rsp, 24 (对齐16 + 1字节缓冲)
        self.emit(b"\x48\x89\x7c\x24\x10")            # mov [rsp+16], rdi (低字节=字符)
        self.emit(b"\x48\xc7\xc0\x01\x00\x00\x00")    # mov rax, 1
        self.emit(b"\x48\xc7\xc7\x01\x00\x00\x00")    # mov rdi, 1
        self.emit(b"\x48\x8d\x74\x24\x10")            # lea rsi, [rsp+16]
        self.emit(b"\xba\x01\x00\x00\x00")            # mov edx, 1
        self.emit(b"\x0f\x05")                        # syscall
        self.emit(b"\x48\x83\xc4\x18")                # add rsp, 24
        self.emit(b"\xc3")                            # ret
        return start

    def assemble(self):
        # 0. 预扫描分配所有变量槽位 (保证 frame 大小正确)
        for st in self.c.ast:
            self.collect_stmt(st)
        seed_off = self.slot("__rand_seed")   # random 种子槽 (必须在 frame 计算前分配)
        # 1. 生成代码 (入口)
        self.emit(b"\x55")                            # push rbp
        self.emit(b"\x48\x89\xe5")                    # mov rbp, rsp
        # 栈帧分配 (对齐16)
        frame = self.slot_next - 8
        if frame:
            self.emit(b"\x48\x81\xec" + struct.pack("<I", frame))
        # random 种子初始化 (rdtsc | 1, 保证非零)
        self.emit(b"\x0f\x31")                        # rdtsc -> edx:eax
        self.emit(b"\x48\xc1\xe2\x20")                # rdx <<= 32
        self.emit(b"\x48\x09\xc2")                    # rdx |= rax
        self.emit(b"\x48\x83\xca\x01")                # or rdx, 1
        self.emit(b"\x48\x89\x55" + struct.pack("b", seed_off))  # mov [seed], rdx
        for st in self.c.ast:
            self.emit_stmt(st)
        # 默认 ret 0
        self.emit(b"\x48\xc7\xc7\x00\x00\x00\x00")    # rdi=0
        self.emit(b"\x48\xc7\xc0\x3c\x00\x00\x00")
        self.emit(b"\x0f\x05")
        # 2. print_num 例程 (先记录地址)
        self.emit_printnum_routine()
        self.emit_printchar_routine()
        # 3. 回填
        code = bytearray(self.code)
        code_start = 0x400078
        data_start = code_start + len(code)
        for pos, key, kind in self.jumps:
            if kind == "disp":
                _, off = key
                target = data_start + off
                disp = target - (code_start + pos + 4)
                code[pos:pos+4] = struct.pack("<i", disp)
            elif kind == "call":
                if key == ("call_printchar",):
                    target = self.printchar_addr
                else:
                    target = self.printnum_addr
                disp = target - pos - 4
                code[pos:pos+4] = struct.pack("<i", disp)
            elif kind == "jz":
                target = self.labels[key]
                disp = target - pos - 4
                code[pos:pos+4] = struct.pack("<i", disp)
            elif kind == "jnz":
                target = self.labels[key]
                disp = target - pos - 4
                code[pos:pos+4] = struct.pack("<i", disp)
            elif kind == "jl":
                target = self.labels[key]
                disp = target - pos - 4
                code[pos:pos+4] = struct.pack("<i", disp)
            elif kind == "jg":
                target = self.labels[key]
                disp = target - pos - 4
                code[pos:pos+4] = struct.pack("<i", disp)
            elif kind == "jle":
                target = self.labels[key]
                disp = target - pos - 4
                code[pos:pos+4] = struct.pack("<i", disp)
            elif kind == "jge":
                target = self.labels[key]
                disp = target - pos - 4
                code[pos:pos+4] = struct.pack("<i", disp)
            elif kind == "jmp":
                target = self.labels[key]
                disp = target - pos - 4
                code[pos:pos+4] = struct.pack("<i", disp)
        code = bytes(code)
        data = bytes(self.data)
        # ELF64
        e_ident = b"\x7fELF" + bytes([2, 1, 1, 0]) + b"\x00" * 8
        ph_off = 64
        code_vaddr = 0x400000
        data_vaddr = (code_vaddr + len(code) + 0xFFF) & ~0xFFF
        entry = code_start
        eh = struct.pack("<16sHHIIIIIHHHHHH", e_ident, 2, 0x3e, 1, entry,
                         ph_off, 0, 0, 64, 56, 2, 0, 0, 0)
        ph1 = struct.pack("<IIQQQQQQ", 1, 0, code_vaddr, code_vaddr,
                          len(code), len(code), 5, 0x1000)
        ph2 = struct.pack("<IIQQQQQQ", 1, len(code), data_vaddr, data_vaddr,
                          len(data), len(data), 6, 0x1000)
        elf = eh + ph1 + ph2 + code + data
        return elf, {"code_len": len(code), "data_len": len(data),
                     "entry": entry, "str_pool": self.str_pool}


# ================= QEMU 模式: ELF32 Multiboot (完整 32 位后端) =================
# 支持: 变量/赋值/while/if-else/for-in(字符串)/print(字符串+数值) + 串口输出 + QEMU 关机

class QEMU32Gen:
    def __init__(self, c):
        self.c = c
        self.data = bytearray()
        self.code = bytearray()
        self.str_pool = {}     # bytes -> data offset
        self.slots = {}        # var -> ebp 偏移 (负)
        self.slot_next = 4
        self.jumps = []        # (code_pos_of_disp, key, kind)
        self.labels = {}
        self.cond_n = 0
        self.printnum_addr = None
        self.printchar_addr = None
        self.printbig_addr = None
        self.big_off = {}      # bigint var -> (low_off, high_off)

    def get_str_off(self, s):
        b = s.encode()
        if b not in self.str_pool:
            self.str_pool[b] = len(self.data)
            self.data += b
        return self.str_pool[b]

    def slot(self, name):
        if name not in self.slots:
            self.slots[name] = -self.slot_next
            self.slot_next += 4
        return self.slots[name]

    def collect_expr(self, e):
        if e[0] == "var":
            self.slot(e[1])
        elif e[0] == "binop":
            self.collect_expr(e[2])
            self.collect_expr(e[3])
        elif e[0] == "call":
            for a in e[2]:
                self.collect_expr(a)

    def collect_stmt(self, st):
        k = st[0]
        if k == "print":
            self.collect_expr(st[1])
        elif k == "ret":
            self.collect_expr(st[1])
        elif k == "decl":
            if st[1] == "bigint":
                # bigint 占 2 个 4 字节槽: low 在 slots[name], high = low-4
                self.slot(st[2])
                self.slot_next += 4
                self.collect_expr(st[3])
            else:
                self.slot(st[2])
                self.collect_expr(st[3])
        elif k == "assign":
            self.slot(st[1])
            self.collect_expr(st[2])
        elif k == "callstmt":
            for a in st[2]:
                self.collect_expr(a)
        elif k == "while":
            self.collect_expr(st[1])
            for s in st[2]:
                self.collect_stmt(s)
        elif k == "if":
            self.collect_expr(st[1])
            for s in st[2]:
                self.collect_stmt(s)
            for s in st[3]:
                self.collect_stmt(s)
        elif k == "for":
            self.slot(st[1])
            self.collect_expr(st[2])
            for s in st[3]:
                self.collect_stmt(s)

    def emit(self, b):
        self.code += b

    def emit_jcc(self, opcode, key):
        """opcode: 'jz'/'jnz'/'jge' 等, 生成 rel32 跳转并登记回填"""
        self.emit(b"\x0f" + opcode + b"\x00\x00\x00\x00")
        self.jumps.append((len(self.code) - 4, key, opcode))

    def emit_jmp(self, key):
        self.emit(b"\xe9\x00\x00\x00\x00")
        self.jumps.append((len(self.code) - 4, key, "jmp"))

    def is_big(self, e):
        """表达式是否为 64 位 bigint 值"""
        if e[0] == "num":
            return e[1] < -0x80000000 or e[1] > 0x7FFFFFFF
        if e[0] == "var":
            return e[1] in self.c.bigint_vars
        if e[0] == "binop":
            return self.is_big(e[2]) or self.is_big(e[3])
        return False

    def emit_expr(self, e):
        """表达式 -> eax (bigint 时 edx:eax 为 64 位值)"""
        k = e[0]
        if k == "num":
            v = e[1]
            if v < -0x80000000 or v > 0x7FFFFFFF:
                low = v & 0xFFFFFFFF
                high = (v >> 32) & 0xFFFFFFFF if v >= 0 else 0xFFFFFFFF
                self.emit(b"\xb8" + struct.pack("<I", low))     # mov eax,low32
                self.emit(b"\xba" + struct.pack("<I", high))    # mov edx,high32
            else:
                self.emit(b"\xb8" + struct.pack("<i", v))       # mov eax,imm32
                self.emit(b"\x31\xd2")                         # xor edx,edx (32 位约定)
        elif k == "str":
            off = self.get_str_off(e[1])
            self.emit(b"\xb8\x00\x00\x00\x00")                 # mov eax, imm32(地址,回填)
            self.jumps.append((len(self.code) - 4, ("str", off), "addr"))
        elif k == "var":
            off = self.slot(e[1])
            if e[1] in self.big_off:
                lo, hi = self.big_off[e[1]]
                self.emit(b"\x8b\x45" + struct.pack("b", lo))  # mov eax,[ebp+lo]
                self.emit(b"\x8b\x55" + struct.pack("b", hi))  # mov edx,[ebp+hi]
            else:
                self.emit(b"\x8b\x45" + struct.pack("b", off)) # mov eax,[ebp+off]
                self.emit(b"\x31\xd2")                         # xor edx,edx (32 位约定)
        elif k == "binop":
            op, a, b = e[1], e[2], e[3]
            if op == "+" and (self.is_big(a) or self.is_big(b)):
                # bigint 64 位加法
                self.emit_expr(a)                              # edx:eax = a
                if not self.is_big(a):
                    self.emit(b"\x31\xd2")                     # xor edx,edx (a 高 32 位 = 0)
                self.emit(b"\x52")                             # push edx (a.high)
                self.emit(b"\x50")                             # push eax (a.low)
                self.emit_expr(b)                              # edx:eax = b
                if not self.is_big(b):
                    self.emit(b"\x31\xd2")                     # xor edx,edx (b 高 32 位 = 0)
                self.emit(b"\x59")                             # pop ecx (a.low)
                self.emit(b"\x5f")                             # pop edi (a.high)
                self.emit(b"\x01\xc8")                         # add eax,ecx
                self.emit(b"\x11\xfa")                         # adc edx,edi
                return
            if self.is_big(a) or self.is_big(b):
                raise RuntimeError("bigint 暂只支持 + 运算")
            self.emit_expr(a)
            self.emit(b"\x50")                                 # push eax (a)
            self.emit_expr(b)
            self.emit(b"\x89\xc1")                             # mov ecx,eax (b)
            self.emit(b"\x58")                                 # pop eax (a)
            self.emit(b"\x89\xc2")                             # mov edx,eax (a)
            if op == "+":
                self.emit(b"\x01\xca")                         # edx=a+b
            elif op == "-":
                self.emit(b"\x29\xca")                         # edx=a-b
            elif op == "*":
                self.emit(b"\x0f\xaf\xd1")                     # edx=a*b
            elif op == "/":
                self.emit(b"\x99")                             # cdq
                self.emit(b"\xf7\xf9")                         # idiv ecx -> eax
                self.emit(b"\x89\xc2")                         # edx=eax
            else:
                self.emit(b"\x39\xca")                         # cmp edx,ecx
                set_op = {"==": b"\x94", "!=": b"\x95", "<": b"\x9c",
                          ">": b"\x9f", "<=": b"\x9e", ">=": b"\x9d"}[op]
                self.emit(b"\x0f" + set_op + b"\xc0")          # setcc al
                self.emit(b"\x0f\xb6\xc0")                     # movzx eax,al
                self.emit(b"\x31\xd2")                         # xor edx,edx (32 位约定)
                return
            self.emit(b"\x89\xd0")                             # eax=edx
            self.emit(b"\x31\xd2")                             # xor edx,edx (32 位约定)
        elif k == "call":
            fname = e[1]
            args = e[2]
            if fname == "crdso.peek":
                if len(args) != 1:
                    raise RuntimeError("crdso.peek 需要 1 个参数")
                self.emit_expr(args[0])                        # addr -> eax
                self.emit(b"\x8a\x00")                         # mov al,[eax]
                self.emit(b"\x0f\xb6\xc0")                     # movzx eax,al
                self.emit(b"\x31\xd2")                         # xor edx,edx (32 位约定)
            elif fname == "time.now":
                if len(args) != 0:
                    raise RuntimeError("time.now 无参数")
                # 读 CMOS RTC 秒寄存器 (0x70=0x00, 0x71=BCD)
                self.emit(b"\xb0\x00")                         # mov al,0
                self.emit(b"\xe6\x70")                         # out 0x70,al
                self.emit(b"\xe4\x71")                         # in al,0x71 (BCD)
                self.emit(b"\x89\xc1")                         # mov ecx,eax
                self.emit(b"\xc0\xe8\x04")                     # shr al,4
                self.emit(b"\x0f\xb6\xc0")                     # movzx eax,al
                self.emit(b"\x6b\xc0\x0a")                     # imul eax,eax,10
                self.emit(b"\x83\xe1\x0f")                     # and ecx,0xF
                self.emit(b"\x01\xc8")                         # add eax,ecx (秒, 十进制)
                self.emit(b"\x31\xd2")                         # xor edx,edx (32 位约定)
            elif fname == "random.next":
                if len(args) != 0:
                    raise RuntimeError("random.next 无参数")
                sl = self.slot("__rand_seed")
                # xorshift32: seed ^= seed<<13; seed ^= seed>>17; seed ^= seed<<5
                self.emit(b"\x8b\x45" + struct.pack("b", sl))  # mov eax,[seed]
                self.emit(b"\x89\xc1")                         # mov ecx,eax
                self.emit(b"\xc1\xe1\x0d")                     # shl ecx,13
                self.emit(b"\x31\xc8")                         # xor eax,ecx
                self.emit(b"\x89\xc1")                         # mov ecx,eax
                self.emit(b"\xc1\xe9\x11")                     # shr ecx,17
                self.emit(b"\x31\xc8")                         # xor eax,ecx
                self.emit(b"\x89\xc1")                         # mov ecx,eax
                self.emit(b"\xc1\xe1\x05")                     # shl ecx,5
                self.emit(b"\x31\xc8")                         # xor eax,ecx
                self.emit(b"\x89\x45" + struct.pack("b", sl))  # mov [seed],eax
                self.emit(b"\x31\xd2")                         # xor edx,edx
                self.emit(b"\xb9\x64\x00\x00\x00")             # mov ecx,100
                self.emit(b"\xf7\xf1")                         # div ecx
                self.emit(b"\x89\xd0")                         # eax = edx (0..99)
                self.emit(b"\x31\xd2")                         # xor edx,edx (32 位约定)
            else:
                raise RuntimeError(f"阶段3 不支持函数 {fname}")
        else:
            raise RuntimeError(f"表达式不支持 {k}")

    def emit_print_str(self, s):
        off = self.get_str_off(s)
        n = len(s.encode())
        # mov esi, addr(回填)
        self.emit(b"\xbe\x00\x00\x00\x00")
        self.jumps.append((len(self.code) - 4, ("str", off), "addr"))
        self.emit(b"\xb9" + struct.pack("<I", n))              # mov ecx,n
        loop = len(self.code)
        self.emit(b"\x8a\x06")                                 # mov al,[esi]
        self.emit(b"\x66\xba\xf8\x03")                             # mov dx,0x3f8 (66 前缀防解码为 mov edx,imm32)
        self.emit(b"\xee")                                     # out dx,al
        self.emit(b"\x46")                                     # inc esi
        self.emit(b"\x49")                                     # dec ecx
        self.emit(b"\x75" + struct.pack("b", loop - (len(self.code) + 2)))  # jnz loop

    def emit_print_num(self):
        """子过程 print_num: eax=有符号32位值, 串口输出十进制 + '\n'"""
        start = len(self.code)
        self.printnum_addr = start
        self.emit(b"\x55")                                     # push ebp
        self.emit(b"\x89\xe5")                                 # mov ebp,esp
        self.emit(b"\x53")                                     # push ebx
        self.emit(b"\x56")                                     # push esi
        # 符号处理: edi=1 正, 0 负
        self.emit(b"\xbf\x01\x00\x00\x00")                     # mov edi,1
        self.emit(b"\x85\xc0")                                 # test eax,eax
        self.emit(b"\x0f\x8d\x07\x00\x00\x00")                 # jge skip_neg
        self.emit(b"\xbf\x00\x00\x00\x00")                     # mov edi,0
        self.emit(b"\xf7\xd8")                                 # neg eax
        self.emit(b"\x31\xdb")                                 # xor ebx,ebx (计数)
        loop = len(self.code)
        self.emit(b"\x99")                                     # cdq
        self.emit(b"\xb9\x0a\x00\x00\x00")                     # mov ecx,10
        self.emit(b"\xf7\xf9")                                 # idiv ecx (eax=商 edx=余)
        self.emit(b"\x52")                                     # push edx (余)
        self.emit(b"\x43")                                     # inc ebx
        self.emit(b"\x85\xc0")                                 # test eax,eax
        self.emit(b"\x75" + struct.pack("b", loop - (len(self.code) + 2)))  # jnz loop
        # 负号
        self.emit(b"\x85\xff")                                 # test edi,edi
        self.emit(b"\x0f\x85\x07\x00\x00\x00")                 # jnz skip_minus
        self.emit(b"\x66\xba\xf8\x03")                         # mov dx,0x3f8
        self.emit(b"\xb0\x2d")                                 # mov al,'-'
        self.emit(b"\xee")                                     # out dx,al
        # 输出
        self.emit(b"\x66\xba\xf8\x03")                             # mov dx,0x3f8 (66 前缀防解码为 mov edx,imm32)
        out_loop = len(self.code)
        self.emit(b"\x58")                                     # pop eax
        self.emit(b"\x04\x30")                                 # add al,'0'
        self.emit(b"\xee")                                     # out dx,al
        self.emit(b"\x4b")                                     # dec ebx
        self.emit(b"\x75" + struct.pack("b", out_loop - (len(self.code) + 2)))  # jnz out_loop
        self.emit(b"\xb0\x0a")                                 # mov al,'\n'
        self.emit(b"\xee")                                     # out dx,al
        self.emit(b"\x5e")                                     # pop esi
        self.emit(b"\x5b")                                     # pop ebx
        self.emit(b"\x5d")                                     # pop ebp
        self.emit(b"\xc3")                                     # ret
        return start

    def emit_print_char(self):
        """子过程 print_char: al=字符, 串口输出 1 字节 (无换行)"""
        start = len(self.code)
        self.printchar_addr = start
        self.emit(b"\x66\xba\xf8\x03")                 # mov dx,0x3f8
        self.emit(b"\xee")                             # out dx,al
        self.emit(b"\xc3")                             # ret
        return start

    def emit_print_bigint(self):
        """子过程 print_bigint: edx:eax=64位无符号值, 串口输出十进制 + '\n'
        64 位除法拆两阶段: 每轮先 high/10 再 (r1<<32|low)/10, 保证 div 不溢出"""
        start = len(self.code)
        self.printbig_addr = start
        self.emit(b"\x55")                                     # push ebp
        self.emit(b"\x89\xe5")                                 # mov ebp,esp
        self.emit(b"\x53")                                     # push ebx
        self.emit(b"\x56")                                     # push esi
        self.emit(b"\x57")                                     # push edi
        self.emit(b"\x89\xd6")                                 # mov esi,edx (high)
        self.emit(b"\x89\xc7")                                 # mov edi,eax (low)
        self.emit(b"\x31\xdb")                                 # xor ebx,ebx (位数计数)
        loop = len(self.code)
        # 阶段1: high/10 -> esi 新high, edx = r1
        self.emit(b"\x89\xf0")                                 # mov eax,esi
        self.emit(b"\x31\xd2")                                 # xor edx,edx
        self.emit(b"\xb9\x0a\x00\x00\x00")                 # mov ecx,10
        self.emit(b"\xf7\xf1")                                 # div ecx (eax=high/10, edx=r1)
        self.emit(b"\x89\xc6")                                 # mov esi,eax
        # 阶段2: (r1<<32|low)/10 -> edi 新low, edx=余数
        self.emit(b"\x89\xf8")                                 # mov eax,edi
        self.emit(b"\xf7\xf1")                                 # div ecx (edx:eax / 10)
        self.emit(b"\x89\xc7")                                 # mov edi,eax
        self.emit(b"\x52")                                     # push edx (余数)
        self.emit(b"\x43")                                     # inc ebx
        # 终止: esi==0 && edi==0
        self.emit(b"\x89\xf0")                                 # mov eax,esi
        self.emit(b"\x09\xf8")                                 # or eax,edi
        self.emit(b"\x75" + struct.pack("b", loop - (len(self.code) + 2)))  # jnz loop
        # 输出
        self.emit(b"\x66\xba\xf8\x03")                     # mov dx,0x3f8
        out_loop = len(self.code)
        self.emit(b"\x58")                                     # pop eax
        self.emit(b"\x04\x30")                                 # add al,'0'
        self.emit(b"\xee")                                     # out dx,al
        self.emit(b"\x4b")                                     # dec ebx
        self.emit(b"\x75" + struct.pack("b", out_loop - (len(self.code) + 2)))  # jnz out_loop
        self.emit(b"\xb0\x0a")                                 # mov al,'\n'
        self.emit(b"\xee")                                     # out dx,al
        self.emit(b"\x5f")                                     # pop edi
        self.emit(b"\x5e")                                     # pop esi
        self.emit(b"\x5b")                                     # pop ebx
        self.emit(b"\x5d")                                     # pop ebp
        self.emit(b"\xc3")                                     # ret
        return start

    def emit_stmt(self, st):
        k = st[0]
        if k == "print":
            e = st[1]
            if e[0] == "str":
                self.emit_print_str(e[1])
            elif e[0] == "var" and e[1] in self.c.char_vars:
                self.emit_expr(e)
                self.emit(b"\xe8\x00\x00\x00\x00")             # call print_char
                self.jumps.append((len(self.code) - 4, ("call_printchar",), "call"))
            elif self.is_big(e):
                self.emit_expr(e)                              # edx:eax = 64 位值
                self.emit(b"\xe8\x00\x00\x00\x00")             # call print_bigint
                self.jumps.append((len(self.code) - 4, ("call_printbig",), "call"))
            else:
                self.emit_expr(e)
                self.emit(b"\xe8\x00\x00\x00\x00")             # call print_num
                self.jumps.append((len(self.code) - 4, ("call_printnum",), "call"))
        elif k == "ret":
            pass
        elif k == "decl":
            _, ty, name, e = st
            self.emit_expr(e)
            if ty == "bigint":
                low = self.slot(name)
                hi = low - 4
                self.big_off[name] = (low, hi)
                self.emit(b"\x89\x45" + struct.pack("b", low))  # mov [ebp+low],eax
                self.emit(b"\x89\x55" + struct.pack("b", hi))   # mov [ebp+hi],edx
            else:
                off = self.slot(name)
                self.emit(b"\x89\x45" + struct.pack("b", off)) # mov [ebp+off],eax
        elif k == "assign":
            _, name, e = st
            self.emit_expr(e)
            if name in self.big_off:
                low, hi = self.big_off[name]
                self.emit(b"\x89\x45" + struct.pack("b", low))  # mov [low],eax
                self.emit(b"\x89\x55" + struct.pack("b", hi))   # mov [high],edx
            else:
                off = self.slot(name)
                self.emit(b"\x89\x45" + struct.pack("b", off)) # mov [ebp+off],eax
        elif k == "callstmt":
            fname, args = st[1], st[2]
            if fname == "crdso.poke":
                if len(args) != 2:
                    raise RuntimeError("crdso.poke 需要 2 个参数")
                self.emit_expr(args[0])                        # addr -> eax
                self.emit(b"\x50")                             # push eax
                self.emit_expr(args[1])                        # val -> eax
                self.emit(b"\x89\xc1")                         # ecx = val
                self.emit(b"\x58")                             # pop eax (addr)
                self.emit(b"\x88\x08")                         # mov [eax], cl
            else:
                raise RuntimeError(f"阶段3 不支持语句函数 {fname}")
        elif k == "while":
            _, cond, body = st
            self.cond_n += 1
            top = ("w_top", self.cond_n)
            end = ("w_end", self.cond_n)
            self.labels[top] = len(self.code)
            self.emit_expr(cond)
            self.emit(b"\x85\xc0")                             # test eax,eax
            self.emit_jcc(b"\x84", end)                        # jz end
            for s in body:
                self.emit_stmt(s)
            self.emit_jmp(top)
            self.labels[end] = len(self.code)
        elif k == "if":
            _, cond, then_b, else_b = st
            self.cond_n += 1
            end = ("i_end", self.cond_n)
            else_l = ("i_else", self.cond_n)
            self.emit_expr(cond)
            self.emit(b"\x85\xc0")
            if else_b:
                self.emit_jcc(b"\x84", else_l)                 # jz else
                for s in then_b:
                    self.emit_stmt(s)
                self.emit_jmp(end)
                self.labels[else_l] = len(self.code)
                for s in else_b:
                    self.emit_stmt(s)
                self.labels[end] = len(self.code)
            else:
                self.emit_jcc(b"\x84", end)
                for s in then_b:
                    self.emit_stmt(s)
                self.labels[end] = len(self.code)
        elif k == "for":
            _, var, coll, body = st
            if coll[0] == "member" and coll[1] == "OS" and coll[2] == "RAM":
                # 阶段3: 遍历物理 RAM 页地址 (0x100000 起, 步进 0x1000, 至 0x200000)
                sl = self.slot(var)
                self.cond_n += 1
                top = ("f_top", self.cond_n)
                end = ("f_end", self.cond_n)
                self.emit(b"\xbb\x00\x00\x10\x00")             # mov ebx,0x100000
                self.labels[top] = len(self.code)
                self.emit(b"\x81\xfb\x00\x00\x20\x00")         # cmp ebx,0x200000
                self.emit_jcc(b"\x8d", end)                    # jge end
                self.emit(b"\x89\x5d" + struct.pack("b", sl))  # var = ebx
                for s2 in body:
                    self.emit_stmt(s2)
                self.emit(b"\x81\xc3\x00\x10\x00\x00")         # add ebx,0x1000
                self.emit_jmp(top)
                self.labels[end] = len(self.code)
            elif coll[0] != "str":
                raise RuntimeError("阶段3 for-in 支持 字符串 或 OS.RAM")
            s = coll[1]
            off = self.get_str_off(s)
            sl = self.slot(var)
            self.cond_n += 1
            top = ("f_top", self.cond_n)
            end = ("f_end", self.cond_n)
            self.emit(b"\x31\xdb")                             # xor ebx,ebx (索引)
            self.labels[top] = len(self.code)
            self.emit(b"\x81\xfb" + struct.pack("<I", len(s)))  # cmp ebx,len
            self.emit_jcc(b"\x8d", end)                        # jge end
            # var = data[ebx]
            self.emit(b"\xbe\x00\x00\x00\x00")                 # mov esi,addr(回填)
            self.jumps.append((len(self.code) - 4, ("str", off), "addr"))
            self.emit(b"\x8a\x04\x1e")                         # mov al,[esi+ebx]
            self.emit(b"\x0f\xb6\xc0")                         # movzx eax,al
            self.emit(b"\x89\x45" + struct.pack("b", sl))      # var = eax
            for s2 in body:
                self.emit_stmt(s2)
            self.emit(b"\x43")                                 # inc ebx
            self.emit_jmp(top)
            self.labels[end] = len(self.code)
        else:
            raise RuntimeError(f"语句不支持 {k}")

    def assemble(self):
        self.code_off = 96   # ehdr52 + phdr32 + mb12
        # 0. 预扫描分配所有变量槽位 (保证 frame 大小正确)
        for st in self.c.ast:
            self.collect_stmt(st)
        # 入口: 建立帧 (先初始化栈, Multiboot 直启时 ESP 未定义)
        self.emit(b"\xbc\x00\x00\x20\x00")                     # mov esp,0x200000
        self.emit(b"\x55")                                     # push ebp
        self.emit(b"\x89\xe5")                                 # mov ebp,esp
        frame = self.slot_next - 4
        if frame:
            self.emit(b"\x83\xec" + struct.pack("b", frame))   # sub esp,frame
        # 阶段4: random 种子初始化 (RTC 秒 + 固定常数, xorshift 种子非零)
        seed_off = self.slot("__rand_seed")
        self.emit(b"\xb0\x00")                                 # mov al,0 (RTC 秒)
        self.emit(b"\xe6\x70")                                 # out 0x70,al
        self.emit(b"\xe4\x71")                                 # in al,0x71
        self.emit(b"\x0f\xb6\xc0")                             # movzx eax,al
        self.emit(b"\x69\xc0\x1d\x84\x53\x21")                 # imul eax,eax,0x2153841D
        self.emit(b"\x83\xc0\x01")                             # add eax,1
        self.emit(b"\x89\x45" + struct.pack("b", seed_off))    # mov [seed],eax
        for st in self.c.ast:
            self.emit_stmt(st)
        self.emit_jmp(("shutdown",))                           # 跳过 printnum routine
        self.emit_print_num()
        self.emit_print_char()
        self.emit_print_bigint()
        # 关机
        self.labels[("shutdown",)] = len(self.code)
        # 关机: 多端口轮询 (ACPI S5 / isa-debug-exit)
        for port in (0x604, 0xf4, 0x501, 0x404):
            self.emit(b"\x66\xba" + struct.pack("<H", port))   # mov dx,port
            self.emit(b"\xb8\x00\x34\x00\x00")                 # mov eax,0x3400 (SLP_EN|SLP_TYP5=S5)
            self.emit(b"\xef")                                 # out dx,eax
            self.emit(b"\xb8\x01\x20\x00\x00")                 # mov eax,0x2001
            self.emit(b"\xef")                                 # out dx,eax
        self.emit(b"\xf4")                                     # hlt 兜底
        code = bytes(self.code)
        data = bytes(self.data)
        code_start = 0x100060
        data_addr = code_start + len(code)
        # 回填
        cb = bytearray(code)
        for pos, key, kind in self.jumps:
            if kind == "addr":
                _, off = key
                target = data_addr + off
                cb[pos:pos+4] = struct.pack("<I", target)
            elif kind == "call":
                if key == ("call_printchar",):
                    target = self.printchar_addr
                elif key == ("call_printbig",):
                    target = self.printbig_addr
                else:
                    target = self.printnum_addr
                disp = target - pos - 4
                cb[pos:pos+4] = struct.pack("<i", disp)
            else:
                target = self.labels[key]
                disp = target - pos - 4
                cb[pos:pos+4] = struct.pack("<i", disp)
        code = bytes(cb)
        e_ident = b"\x7fELF" + bytes([1, 1, 1, 0]) + b"\x00" * 8
        entry = 0x100060
        eh = struct.pack("<16sHHIIIIIHHHHHH", e_ident, 1, 3, 1, entry,
                         52, 0, 0, 52, 32, 1, 0, 0, 0)
        ph = struct.pack("<IIIIIIII", 1, 0, 0x100000, 0x100000,
                         self.code_off + len(code) + len(data),
                         self.code_off + len(code) + len(data), 7, 0x1000)
        mb = struct.pack("<III", 0x1BADB002, 0x0, -(0x1BADB002 + 0x0) & 0xFFFFFFFF)
        elf = eh + ph + mb + code + data
        return elf, {"code_len": len(code), "data_len": len(data),
                     "entry": entry, "str_pool": self.str_pool}


# ================= PEGen: Windows PE32+ (x64) 后端 =================

class PEGen(ELF64Gen):
    """Windows x64 最小 PE 后端: 导入 kernel32 GetStdHandle/WriteFile/ExitProcess/GetTickCount.
    继承 ELF64Gen 的表达式/语句生成逻辑, 覆写输出例程与容器组装."""

    IMPORTS = ["GetStdHandle", "WriteFile", "ExitProcess", "GetTickCount"]

    def __init__(self, c):
        super().__init__(c)
        self.printstr_addr = None
        self.hout_off = None      # data 区句柄槽偏移
        self.iat_rva = {}         # 函数名 -> IAT RVA

    # ---- 表达式级调用 (Windows) ----
    def emit_call_expr(self, fname, args):
        if fname == "crdso.peek":
            if len(args) != 1:
                raise RuntimeError("crdso.peek 需要 1 个参数")
            self.emit_expr(args[0])
            self.emit(b"\x0f\xb6\x00")                     # movzx eax, byte [rax]
        elif fname == "time.now":
            if len(args) != 0:
                raise RuntimeError("time.now 无参数")
            self.emit_import_call("GetTickCount")          # 毫秒 (Windows)
        elif fname == "random.next":
            if len(args) != 0:
                raise RuntimeError("random.next 无参数")
            sl = self.slot("__rand_seed")
            self.emit(b"\x48\x8b\x45" + struct.pack("b", sl))
            self.emit(b"\x48\x89\xc1")
            self.emit(b"\x48\xc1\xe1\x0d")
            self.emit(b"\x48\x31\xc8")
            self.emit(b"\x48\x89\xc1")
            self.emit(b"\x48\xc1\xe9\x11")
            self.emit(b"\x48\x31\xc8")
            self.emit(b"\x48\x89\xc1")
            self.emit(b"\x48\xc1\xe1\x05")
            self.emit(b"\x48\x31\xc8")
            self.emit(b"\x48\x89\x45" + struct.pack("b", sl))
            self.emit(b"\x48\x31\xd2")
            self.emit(b"\x48\xc7\xc1\x64\x00\x00\x00")
            self.emit(b"\x48\xf7\xf1")
            self.emit(b"\x48\x89\xd0")
        else:
            raise RuntimeError(f"阶段3 不支持函数 {fname}")

    def emit_import_call(self, name):
        """call qword ptr [rip+disp32] -> IAT[name]; 回填 kind=import"""
        self.emit(b"\xff\x15\x00\x00\x00\x00")
        self.jumps.append((len(self.code) - 4, name, "import"))

    def emit_hout_load(self, reg):
        """mov reg, [rip+disp32] -> hout 槽; 回填 kind=hout"""
        mod = {"rax": b"\x48\x8b\x05", "rcx": b"\x48\x8b\x0d"}[reg]
        self.emit(mod + b"\x00\x00\x00\x00")
        self.jumps.append((len(self.code) - 4, "hout", "hout"))

    # ---- 语句生成 (Windows: print/ret 走 WinAPI) ----
    def emit_stmt(self, st):
        k = st[0]
        if k == "print":
            e = st[1]
            if e[0] == "str":
                off = self.get_str_off(e[1])
                self.emit(b"\x48\x8d\x3d\x00\x00\x00\x00")   # lea rdi,[rip+str]
                self.jumps.append((len(self.code) - 4, ("str", off), "disp"))
                self.emit(b"\xbe" + struct.pack("<I", len(e[1].encode())))  # mov esi,len
                self.emit(b"\xe8\x00\x00\x00\x00")           # call print_str
                self.jumps.append((len(self.code) - 4, ("call_printstr",), "call"))
            elif e[0] == "var" and e[1] in self.c.char_vars:
                self.emit_expr(e)
                self.emit(b"\x48\x89\xc7")                   # rdi = char
                self.emit(b"\xe8\x00\x00\x00\x00")           # call print_char
                self.jumps.append((len(self.code) - 4, ("call_printchar",), "call"))
            else:
                self.emit_expr(e)
                self.emit(b"\x48\x89\xc7")
                self.emit(b"\xe8\x00\x00\x00\x00")           # call print_num
                self.jumps.append((len(self.code) - 4, ("call_printnum",), "call"))
        elif k == "ret":
            e = st[1]
            self.emit_expr(e)
            self.emit(b"\x89\xc1")                           # ecx = exit code (低32)
            self.emit_import_call("ExitProcess")
        elif k == "decl":
            _, ty, name, e = st
            self.emit_expr(e)
            off = self.slot(name)
            self.emit(b"\x48\x89\x45" + struct.pack("b", off))
        elif k == "assign":
            _, name, e = st
            self.emit_expr(e)
            off = self.slot(name)
            self.emit(b"\x48\x89\x45" + struct.pack("b", off))
        elif k == "while":
            _, cond, body = st
            self.cond_n += 1
            top = ("while_top", self.cond_n)
            end = ("while_end", self.cond_n)
            self.labels[top] = len(self.code)
            self.emit_expr(cond)
            self.emit(b"\x48\x85\xc0")
            self.emit(b"\x0f\x84\x00\x00\x00\x00")
            self.jumps.append((len(self.code) - 4, end, "jz"))
            for s in body:
                self.emit_stmt(s)
            self.emit(b"\xe9\x00\x00\x00\x00")
            self.jumps.append((len(self.code) - 4, top, "jmp"))
            self.labels[end] = len(self.code)
        elif k == "if":
            _, cond, then_b, else_b = st
            self.cond_n += 1
            end = ("if_end", self.cond_n)
            else_l = ("if_else", self.cond_n)
            self.emit_expr(cond)
            self.emit(b"\x48\x85\xc0")
            if else_b:
                self.emit(b"\x0f\x84\x00\x00\x00\x00")
                self.jumps.append((len(self.code) - 4, else_l, "jz"))
                for s in then_b:
                    self.emit_stmt(s)
                self.emit(b"\xe9\x00\x00\x00\x00")
                self.jumps.append((len(self.code) - 4, end, "jmp"))
                self.labels[else_l] = len(self.code)
                for s in else_b:
                    self.emit_stmt(s)
                self.labels[end] = len(self.code)
            else:
                self.emit(b"\x0f\x84\x00\x00\x00\x00")
                self.jumps.append((len(self.code) - 4, end, "jz"))
                for s in then_b:
                    self.emit_stmt(s)
                self.labels[end] = len(self.code)
        elif k == "for":
            _, var, coll, body = st
            if coll[0] != "str":
                raise RuntimeError("阶段2 for-in 仅支持字符串遍历")
            s = coll[1]
            off = self.get_str_off(s)
            sl = self.slot(var)
            self.cond_n += 1
            top = ("for_top", self.cond_n)
            end = ("for_end", self.cond_n)
            self.emit(b"\x48\xc7\xc3\x00\x00\x00\x00")
            self.labels[top] = len(self.code)
            self.emit(b"\x48\x81\xfb" + struct.pack("<I", len(s)))
            self.emit(b"\x0f\x8d\x00\x00\x00\x00")
            self.jumps.append((len(self.code) - 4, end, "jge"))
            self.emit(b"\x48\x8d\x05\x00\x00\x00\x00")
            self.jumps.append((len(self.code) - 4, ("str", off), "disp"))
            self.emit(b"\x0f\xb6\x04\x18")
            self.emit(b"\x48\x89\x45" + struct.pack("b", sl))
            for s2 in body:
                self.emit_stmt(s2)
            self.emit(b"\x48\xff\xc3")
            self.emit(b"\xe9\x00\x00\x00\x00")
            self.jumps.append((len(self.code) - 4, top, "jmp"))
            self.labels[end] = len(self.code)
        elif k == "callstmt":
            fname, args = st[1], st[2]
            if fname == "crdso.poke":
                if len(args) != 2:
                    raise RuntimeError("crdso.poke 需要 2 个参数")
                self.emit_expr(args[0])
                self.emit(b"\x50")
                self.emit_expr(args[1])
                self.emit(b"\x48\x89\xc1")
                self.emit(b"\x58")
                self.emit(b"\x88\x08")
            else:
                raise RuntimeError(f"阶段3 不支持语句函数 {fname}")
        else:
            raise RuntimeError(f"语句不支持 {k}")

    # ---- 输出例程 (Win64) ----
    def emit_print_str_routine(self):
        """print_str(rdi=ptr, rsi=len): WriteFile(stdout)"""
        start = len(self.code)
        self.printstr_addr = start
        self.emit(b"\x48\x83\xec\x38")                       # sub rsp, 56
        self.emit(b"\x48\xc7\x44\x24\x20\x00\x00\x00\x00")   # [rsp+32]=0 lpOverlapped
        self.emit(b"\x48\x89\x74\x24\x28")                   # [rsp+40]=len
        self.emit(b"\x48\xc7\x44\x24\x30\x00\x00\x00\x00")   # [rsp+48]=0 written
        self.emit(b"\x48\x8d\x4c\x24\x30")                   # lea r9,[rsp+48]
        self.emit(b"\x49\x89\xf0")                           # mov r8,rsi
        self.emit(b"\x48\x89\xfa")                           # mov rdx,rdi
        self.emit_hout_load("rcx")                           # mov rcx,hout
        self.emit_import_call("WriteFile")
        self.emit(b"\x48\x83\xc4\x38")                       # add rsp, 56
        self.emit(b"\xc3")
        return start

    def emit_printnum_routine(self):
        """print_num(rdi=有符号64位值): WriteFile 十进制 + 换行"""
        start = len(self.code)
        self.printnum_addr = start
        self.emit(b"\x53")                                   # push rbx
        self.emit(b"\x56")                                   # push rsi
        self.emit(b"\x57")                                   # push rdi (原值)
        self.emit(b"\x41\x54")                               # push r12
        self.emit(b"\x48\x83\xec\x38")                       # sub rsp, 56
        self.emit(b"\x48\x8b\x44\x24\x38")                   # rax = [rsp+56] 原值
        self.emit(b"\xbb\x01\x00\x00\x00")                   # ebx = 1 (正)
        self.emit(b"\x48\x85\xc0")
        self.emit(b"\x79\x05")                               # jns cnv
        self.emit(b"\x31\xdb")                               # ebx = 0 (负)
        self.emit(b"\x48\xf7\xd8")                           # neg rax
        cnv = len(self.code)
        self.emit(b"\x31\xf6")                               # esi = 位数 0
        loop = len(self.code)
        self.emit(b"\x31\xd2")                               # xor edx,edx
        self.emit(b"\xb9\x0a\x00\x00\x00")                   # ecx = 10
        self.emit(b"\x48\xf7\xf1")                           # div rcx
        self.emit(b"\x52")                                   # push rdx
        self.emit(b"\x46")                                   # inc esi
        self.emit(b"\x48\x85\xc0")
        self.emit(b"\x75" + struct.pack("b", loop - (len(self.code) + 2)))  # jnz loop
        self.emit(b"\x4c\x8d\x64\x24\x10")                   # r12 = rsp+16 缓冲
        out_loop = len(self.code)
        self.emit(b"\x58")                                   # pop rax
        self.emit(b"\x04\x30")                               # add al,'0'
        self.emit(b"\x41\x88\x04\x24")                       # mov [r12],al
        self.emit(b"\x49\xff\xc4")                           # inc r12
        self.emit(b"\x4e")                                   # dec esi
        self.emit(b"\x75" + struct.pack("b", out_loop - (len(self.code) + 2)))  # jnz out_loop
        self.emit(b"\x48\x89\x74\x24\x30")                   # [rsp+48]=len
        self.emit(b"\x48\xc7\x44\x24\x20\x00\x00\x00\x00")   # [rsp+32]=0 lpOverlapped
        self.emit(b"\x48\xc7\x44\x24\x28\x00\x00\x00\x00")   # [rsp+40]=0 written
        # 负号
        self.emit(b"\x85\xdb")                               # test ebx,ebx
        self.emit(b"\x75\x1b")                               # jnz no_minus
        self.emit(b"\xc6\x44\x24\x10\x2d")                   # byte [rsp+16]='-'
        self.emit(b"\x48\x8d\x54\x24\x10")                   # rdx=[rsp+16]
        self.emit(b"\x41\xb8\x01\x00\x00\x00")               # r8d=1
        self.emit(b"\x48\x8d\x4c\x24\x28")                   # r9=[rsp+40]
        self.emit_hout_load("rcx")
        self.emit_import_call("WriteFile")
        no_minus = len(self.code)
        # 数字
        self.emit(b"\x44\x8b\x44\x24\x30")                   # r8d = len
        self.emit(b"\x48\x8d\x54\x24\x10")                   # rdx=[rsp+16]
        self.emit(b"\x48\x8d\x4c\x24\x28")                   # r9=[rsp+40]
        self.emit_hout_load("rcx")
        self.emit_import_call("WriteFile")
        # 换行
        self.emit(b"\xc6\x44\x24\x10\x0a")                   # byte [rsp+16]=10
        self.emit(b"\x41\xb8\x01\x00\x00\x00")               # r8d=1
        self.emit(b"\x48\x8d\x54\x24\x10")                   # rdx=[rsp+16]
        self.emit(b"\x48\x8d\x4c\x24\x28")                   # r9=[rsp+40]
        self.emit_hout_load("rcx")
        self.emit_import_call("WriteFile")
        self.emit(b"\x48\x83\xc4\x38")                       # add rsp, 56
        self.emit(b"\x41\x5c")                               # pop r12
        self.emit(b"\x5f")                                   # pop rdi
        self.emit(b"\x5e")                                   # pop rsi
        self.emit(b"\x5b")                                   # pop rbx
        self.emit(b"\xc3")
        return start

    def emit_printchar_routine(self):
        """print_char(rdi=字符): WriteFile 1 字节, 无换行"""
        start = len(self.code)
        self.printchar_addr = start
        self.emit(b"\x48\x83\xec\x38")                       # sub rsp, 56
        self.emit(b"\x40\x88\x7c\x24\x30")                   # [rsp+48]=dil
        self.emit(b"\x48\xc7\x44\x24\x20\x00\x00\x00\x00")   # [rsp+32]=0
        self.emit(b"\x48\xc7\x44\x24\x28\x00\x00\x00\x00")   # [rsp+40]=0
        self.emit(b"\x48\x8d\x54\x24\x30")                   # rdx=[rsp+48]
        self.emit(b"\x41\xb8\x01\x00\x00\x00")               # r8d=1
        self.emit(b"\x48\x8d\x4c\x24\x28")                   # r9=[rsp+40]
        self.emit_hout_load("rcx")
        self.emit_import_call("WriteFile")
        self.emit(b"\x48\x83\xc4\x38")
        self.emit(b"\xc3")
        return start

    # ---- 组装: PE32+ ----
    def assemble(self):
        for st in self.c.ast:
            self.collect_stmt(st)
        seed_off = self.slot("__rand_seed")
        # hout 槽: data 区开头 8 字节
        self.hout_off = len(self.data)
        self.data += b"\x00" * 8
        # 入口
        self.emit(b"\x55")                                 # push rbp
        self.emit(b"\x48\x89\xe5")                         # mov rbp, rsp
        frame = self.slot_next - 8
        total = ((0x28 + max(frame, 0) + 15) & ~15)        # shadow 32 + 对齐16
        if total:
            self.emit(b"\x48\x81\xec" + struct.pack("<I", total))
        self.emit(b"\xb9\xf5\xff\xff\xff")                   # mov ecx, -11
        self.emit_import_call("GetStdHandle")
        self.emit(b"\x48\x89\x05\x00\x00\x00\x00")           # mov [rip+hout],rax
        self.jumps.append((len(self.code) - 4, "hout", "hout"))
        # random 种子: GetTickCount | 1
        self.emit_import_call("GetTickCount")
        self.emit(b"\x48\x83\xc8\x01")                       # or rax,1
        self.emit(b"\x48\x89\x45" + struct.pack("b", seed_off))
        for st in self.c.ast:
            self.emit_stmt(st)
        # 默认 ret 0
        self.emit(b"\x31\xc9")                               # xor ecx,ecx
        self.emit_import_call("ExitProcess")
        # 例程
        self.emit_print_str_routine()
        self.emit_printnum_routine()
        self.emit_printchar_routine()
        # 导入段构造 (先计算 IAT RVA, 供回填使用)
        names = self.IMPORTS
        code_len = len(self.code)
        seg = bytearray()
        seg += struct.pack("<IIIII", 0, 0, 0, 0, 0)           # import descriptor 占位
        seg += struct.pack("<IIIII", 0, 0, 0, 0, 0)           # NULL 结束描述符
        dll_pos = 40
        seg += b"kernel32.dll\x00"
        hint_off = {}
        for n in names:
            hint_off[n] = len(seg)
            seg += b"\x00\x00" + n.encode() + b"\x00"
            if len(seg) % 2:
                seg += b"\x00"
        ilt_pos = len(seg)
        for n in names:
            seg += struct.pack("<Q", 0)
        seg += struct.pack("<Q", 0)                           # ILT NULL 终止
        iat_pos = len(seg)
        for n in names:
            seg += struct.pack("<Q", 0)
        seg += struct.pack("<Q", 0)                           # IAT NULL 终止
        seg_start = code_len + len(self.data)
        def rva_of(raw_off):
            return 0x1000 + raw_off
        for i, n in enumerate(names):
            struct.pack_into("<Q", seg, ilt_pos + i * 8, rva_of(seg_start + hint_off[n]))
            struct.pack_into("<Q", seg, iat_pos + i * 8, rva_of(seg_start + hint_off[n]))
        struct.pack_into("<IIIII", seg, 0,
                         rva_of(seg_start + ilt_pos), 0, 0,
                         rva_of(seg_start + dll_pos), rva_of(seg_start + iat_pos))
        self.iat_rva = {n: rva_of(seg_start + iat_pos + i * 8) for i, n in enumerate(names)}
        # 回填
        code = bytearray(self.code)
        code_len = len(code)
        data_rva = 0x1000 + code_len
        hout_rva = data_rva + self.hout_off
        for pos, key, kind in self.jumps:
            if kind == "disp":
                _, off = key
                target = data_rva + off
                code[pos:pos+4] = struct.pack("<I", target - (pos + 4 + 0x1000))
            elif kind == "hout":
                code[pos:pos+4] = struct.pack("<i", hout_rva - (pos + 4 + 0x1000))
            elif kind == "import":
                iat_rva = self.iat_rva[key]
                code[pos:pos+4] = struct.pack("<i", iat_rva - (pos + 4 + 0x1000))
            elif kind == "call":
                if key == ("call_printstr",):
                    target = self.printstr_addr
                elif key == ("call_printchar",):
                    target = self.printchar_addr
                else:
                    target = self.printnum_addr
                code[pos:pos+4] = struct.pack("<i", target - pos - 4)
            else:
                target = self.labels[key]
                code[pos:pos+4] = struct.pack("<i", target - pos - 4)
        code = bytes(code)
        raw = code + bytes(self.data) + bytes(seg)
        raw_total = len(raw)
        raw_size = (0x200 + raw_total + 0x1FF) & ~0x1FF
        size_image = 0x1000 + ((raw_total + 0xFFF) & ~0xFFF)
        import_rva = rva_of(seg_start)
        import_size = len(seg)
        # DOS header
        dos = bytearray(0x80)
        dos[0:2] = b"MZ"
        dos[0x3C:0x40] = struct.pack("<I", 0x80)
        # PE headers
        cof = struct.pack("<HHIIIHH", 0x8664, 1, 0, 0, 0, 0xF0, 0x0022)
        opt = bytearray()
        opt += struct.pack("<H", 0x20B)
        opt += struct.pack("<BB", 0, 0)
        opt += struct.pack("<I", 0x200 + raw_total)            # size of code
        opt += struct.pack("<I", 0)                            # init data
        opt += struct.pack("<I", 0)                            # uninit
        opt += struct.pack("<I", 0x1000)                       # entry RVA
        opt += struct.pack("<I", 0x1000)                       # base of code
        opt += struct.pack("<Q", 0x140000000)                  # image base
        opt += struct.pack("<I", 0x1000)                       # section align
        opt += struct.pack("<I", 0x200)                        # file align
        opt += struct.pack("<HHHHHH", 6, 0, 6, 0, 6, 0)
        opt += struct.pack("<I", 0)
        opt += struct.pack("<I", size_image)
        opt += struct.pack("<I", 0x200)
        opt += struct.pack("<I", 0)
        opt += struct.pack("<H", 3)                            # console
        opt += struct.pack("<H", 0x8160)
        opt += struct.pack("<QQQQ", 0x100000, 0x1000, 0x100000, 0x1000)
        opt += struct.pack("<I", 0)
        opt += struct.pack("<I", 16)
        dd = [struct.pack("<II", 0, 0) for _ in range(16)]
        dd[1] = struct.pack("<II", import_rva, import_size)
        dd[12] = struct.pack("<II", rva_of(seg_start + iat_pos), 8 * (len(names) + 1))
        for d in dd:
            opt += d
        sec = struct.pack("<8sIIIIIIHHI", b".text\x00\x00\x00", raw_total, 0x1000,
                          raw_size, 0x200, 0, 0, 0, 0, 0xE0000020)
        image = dos + b"PE\x00\x00" + cof + bytes(opt) + sec
        image += b"\x00" * (0x200 - len(image))
        image += raw
        image += b"\x00" * (raw_size - len(raw))
        return image, {"code_len": len(code), "data_len": len(self.data),
                       "entry": 0x1000, "str_pool": self.str_pool}


# ================= 命令行 =================

def main(argv):
    args = argv[1:]
    target = None
    filename = None
    src_path = None
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-elf", "-exe", "-qemu"):
            target = a[1:]
        elif a == "-filename":
            i += 1
            filename = args[i]
        else:
            src_path = a
        i += 1
    if target is None:
        sys.stderr.write("gff: 缺少目标参数 (-elf / -exe / -qemu)\n")
        return 1
    if filename is None:
        sys.stderr.write("gff: 缺少 -filename 输出名\n")
        return 1
    if src_path is None:
        sys.stderr.write("gff: 缺少源码路径\n")
        return 1
    if target not in ("elf", "exe", "qemu"):
        sys.stderr.write(f"gff: 当前支持 -elf / -exe / -qemu, 收到 -{target}\n")
        return 1
    with open(src_path, "r", encoding="utf-8") as f:
        src = f.read()
    try:
        c = CFCompiler(src)
        c.parse_program()
        if target == "elf":
            g = ELF64Gen(c)
            elf, info = g.assemble()
        elif target == "exe":
            g = PEGen(c)
            elf, info = g.assemble()
        else:
            g = QEMU32Gen(c)
            elf, info = g.assemble()
    except (SyntaxError, RuntimeError, NotImplementedError) as e:
        sys.stderr.write(f"gff: {type(e).__name__}: {e}\n")
        return 1
    out_path = filename
    with open(out_path, "wb") as f:
        f.write(elf)
    sys.stderr.write(
        f"gff: {target} OK -> {out_path} ({len(elf)} bytes, "
        f"entry=0x{info['entry']:x}, code={info['code_len']}B, data={info['data_len']}B)\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

# cff —— CF 语言与 gffc 编译器

CF 是一门语法接近 C 与 Python 混合风格的轻量语言。`gffc` 是用 NASM 手写 PE/COFF 头、零第三方依赖实现的 CF 编译器：读入 `.cf` 源码，输出 NASM 汇编，再调用 NASM 生成 Windows x64 可执行文件。

```
gffc.exe hello.cf   →   hello.asm + hello.exe
```

编译器本体不含任何 C 运行时，入口、IAT 回填、系统调用全部由汇编直接构造。

## 目录结构

| 目录 | 内容 |
|---|---|
| `src/gffc.asm` | 编译器主体（NASM，手写 PE 结构、词法/语法分析、代码生成） |
| `src/old/` | 历史版本编译器快照 |
| `lib/` | 纯 CF 标准库，按 Python 包方式组织 |
| `examples/` | 示例源码 |
| `tests/` | 语法与回归测试用例 |
| `old/` | 早期 Python 版编译器 `gff.py` 及更早的汇编实现 |
| `bin/` | 构建输出目录（可执行文件不入库） |

## 标准库 iostrpm

`lib/iostrpm/` 下按模块拆分，`__init__.cf` 汇总导出：

```
import <iostrpm>;
```

| 模块 | 提供 |
|---|---|
| `print.cf` | `print` / `puts` / `putnum` / `putln` / `puterr` / `nl` / `outch` / `next` / `getch` / `strlen` |
| `math.cf` | `add` / `sub` / `mul` / `div` / `mod` |
| `io.cf` | 输入输出辅助 |
| `time.cf` | `delay_ms` / `tick_ms` / `sec_to_min` / `day_to_hour` |
| `random.cf` | `rand_between` / `next` |

库文件自身是 CF 源码，不包含汇编，写库不需要碰 NASM。

## 语法速览

```c
import <iostrpm>;

def add(int x, int y) {
    int s = x + y;
    ret s;
}

int main() {
    int i = 0;
    while (i < 3) {
        puts("hello cff");
        i = i + 1;
    }
    print(add(3, 4));
    ret 0;
}
```

支持的类型：`int`、`bigint`、`char`、`str` / `string`、`bool`，以及指针声明与取址 `&var`、解引用 `*p`。

支持的语句：变量声明、赋值、`if` / `else`、`while`、`for`、`break`、`continue`、`ret`、函数定义与调用、`import <pkg>`、`namesp <lib>`。

## 构建

需要 NASM（默认路径 `C:\Program Files\NASM\nasm.exe`）：

```
nasm -f bin src/gffc.asm -o bin/gffc.exe
```

## 已知限制

- 函数实参暂不支持二元表达式，需先算入变量再传：`int c = a + b; putnum(c);`
- `ret` 只接受变量或常量，`ret x + y` 会报错
- `print` 的字符分支只接受单字符字面量
- 报错行号按库展开后的源码计数，引入库时报错行号可能大于实际文件行数

## 致谢

`old/gff.py` 是 CF 的首版 Python 原型，现行 `gffc` 为其汇编重写。

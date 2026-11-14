# cff —— CF 语言与 gffc 编译器

> A small programming language whose compiler is written in pure NASM.
> No libc, no runtime, no linker — it builds PE/COFF headers itself. A hello-world binary is about 4 KB.
>
> 开发方式：**与 AI 结对完成**，详见文末「关于这个项目」。

CF 是一门语法接近 C 与 Python 混合风格的轻量语言。`gffc` 是一个完全用 NASM 汇编实现、不经链接器、不依赖 C 运行时和任何第三方库的 CF 编译器：读入 `.cf` 源码，自行构造 PE/COFF 结构，再调用 NASM 生成 Windows x64 可执行文件。

```
gffc.exe hello.cf   →   hello.asm + hello.exe
```

编译器本体不含任何 C 运行时，入口、IAT 回填、系统调用全部由汇编直接构造。

## 目录结构

| 目录 | 内容 |
|---|---|
| `src/gffc.asm` | 编译器主体（NASM，自行构造 PE 结构、词法/语法分析、代码生成） |
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

## 关于这个项目

先说清楚一件事：**这个仓库的代码绝大部分由 AI 辅助编写，人负责定方向、做判断、扛结果。**

具体分工是这样的：

- 语言要长什么样、编译器要实现什么、什么算"能用"，由作者决定；
- `src/gffc.asm`（约 9900 行 x86-64 汇编）与 `lib/` 标准库的代码，主要由 AI 生成；人负责提需求、读代码、跑测试、复现崩溃、定位异常并反馈修正；
- 架构取舍、调试思路和踩到的坑，是在人与 AI 反复讨论、试错中定下来的。

把这些写在 README 里，是因为"纯手写汇编""零第三方依赖"这类描述太容易被读成炫技。它真实的形态是一次认真的人机协作实践：AI 大幅压低了实现成本，但决定做什么、判断做得对不对、对最终质量负责的仍然是人。

如果你也在用 AI 写底层代码，`old/` 里保留了从 Python 原型到汇编重写的全过程快照，可以对照着看这条路是怎么一步步走出来的。

## 致谢

`old/gff.py` 是 CF 的首版 Python 原型，现行 `gffc` 为其汇编重写。

# devsweep 风险分类规则 (Risk Classification)

devsweep 把所有清理目标分成四级。脚本默认只动 Low,Medium 需用户显式开启,High 必须逐项确认,Forbidden 永不触碰。

## 🟢 Low — 删了自动重建/重下,默认可清

这些是真正意义上的"缓存":删除后程序下次运行会自动重建,零数据损失。

| 类型 | 例子 | 重建方式 |
|---|---|---|
| 浏览器缓存 | Edge/Chrome/Firefox `Cache`, `Code Cache` | 浏览时自动重建 |
| 包管理器缓存 | npm-cache, pip cache, yarn cache, pnpm store, NuGet http-cache | 下次 install 重新下载 |
| 依赖产物 | `node_modules`, `target`, `.next`, `.turbo`, `.angular`, `.gradle` | install / build 重建 |
| Python 缓存 | `__pycache__`, `.pytest_cache` | 运行时自动重建 |
| 系统临时 | `%TEMP%`, 崩溃转储 CrashDumps, 缩略图缓存 | 自动重建 |
| .NET 中间产物 | `obj` | dotnet build 重建 |

## 🟡 Medium — 重建较慢但安全,需用户开启 (-IncludeMedium)

删除安全(不丢源码),但重建成本较高,或可能是用户有意保留的产物。

| 类型 | 例子 | 注意 |
|---|---|---|
| 通用构建输出 | `dist`, `build`, `out` | 可能是已发布产物,重建需重新打包 |
| Python 虚拟环境 | `.venv`, `venv` | 重建需重新 pip install 全部依赖,较慢 |
| .NET 输出 | `bin` | 可能含已编译可执行文件 |

## 🟠 High — 必须逐项确认,绝不自动删

体积可能很大,但删除有真实代价或不可逆。devsweep 只"报告 + 建议",绝不自动清理。

| 类型 | 例子 | 为什么危险 |
|---|---|---|
| 设计源文件 | `.psd`, `.psb`, `.ai`, `.blend`, `.3dm` | 创作原稿,不可重建 |
| 模型权重 | `.safetensors`, `.ckpt`, `.onnx`, `.gguf`, `.pt` | 下载/训练成本极高 |
| 版本库 | `.git` 目录 | 删了丢失全部历史 |
| 大型媒体 | 视频、课程、素材库 | 可能是唯一副本 |
| 文档终稿 | 论文、作品集 PDF | 可能无备份 |
| 数据库文件 | `.mdf`, `.sqlite`, `.db`(非缓存) | 用户数据 |

## 🔴 Forbidden — 永不触碰(任何模式、任何参数都不删)

详见 `safe-paths.md`。包括 Windows 系统目录、Program Files、用户文档根、Maven 本地仓库本体、pagefile/hiberfil、WinSxS、还原点等。

## 与竞品的关键区别

这套分级专门修正了现有同类工具的危险行为:

- **Maven `.m2\repository` 不是缓存**,是本地仓库本体 → 列为 Forbidden,绝不当 Low 删(某竞品的错误)。
- **Windows 事件日志不清空** → 不在任何清理目标里(某竞品会全清,破坏排障历史)。
- **vhdx 永远只压缩不删除** → 压缩是无损操作,删除会毁掉整个 Docker/WSL 环境。
- **构建产物默认只删 Low** → `dist`/`venv`/`bin` 这类 Medium 必须用户显式 `-IncludeMedium`,避免误删已发布产物。

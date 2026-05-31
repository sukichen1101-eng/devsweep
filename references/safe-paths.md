# devsweep 永不触碰清单 (Never-Touch Paths)

devsweep 的安全底线。以下路径/类型在**任何模式、任何参数**下都不会被删除或修改。clean 脚本只针对白名单内的已知缓存/产物目录名,绝不递归删除下列位置。

## 系统关键目录(删了系统崩溃)

- `C:\Windows\` 及其全部子目录(System32, WinSxS, etc.)
- `C:\Program Files\` 和 `C:\Program Files (x86)\`
- `C:\ProgramData\`(除明确的缓存子目录外)
- `$Recycle.Bin`、`System Volume Information`、`Config.Msi`、`Recovery`
- 引导/系统文件:`pagefile.sys`, `hiberfil.sys`, `swapfile.sys`

> 注:devsweep 不像某些"优化器"那样去关休眠(`powercfg /h off`)、清 WinSxS(`DISM /ResetBase`)或删还原点(`vssadmin delete shadows`)。这些操作有真实副作用,超出"安全清理"范畴,留给用户自行决定。

## 用户数据(不可重建)

- 用户文档根:`Documents`, `Desktop`, `Pictures`, `Videos`, `Music`, `Downloads`
  (这些目录**整体**永不碰;即便里面有大文件,也只在 High 级别报告、由用户决定)
- 任何源代码目录本身(只删其中已知的产物子目录如 node_modules,绝不删源码)
- `.git` 目录(版本历史)

## 看起来像缓存、其实不是的陷阱(竞品踩过的雷)

| 路径 | 为什么不能删 |
|---|---|
| `~\.m2\repository` | Maven **本地仓库本体**,不是缓存。删了所有项目依赖要重下,且离线环境直接崩。 |
| `~\.nuget\packages` | NuGet 全局包**安装目录**(非 http-cache),多项目共享。 |
| `~\.cargo\registry\src` | Cargo 源码缓存,删可以但 devsweep 默认不碰(只在用户明确要求时) |
| `~\go\pkg\mod` | Go module 本体缓存,删后需重新下载全部依赖 |
| Windows 事件日志 | 排障历史,清空会丢失系统问题线索 |
| `vhdx` 文件 | 只压缩(无损),永不删除——删 = 毁掉整个 WSL/Docker 环境 |

## vhdx 特殊规则

- devsweep **只对 vhdx 做压缩**(`Optimize-VHD` / `diskpart compact`),这是无损操作,只回收内部未使用块。
- **永不删除 vhdx 文件本身**。
- 压缩前必须 `wsl --shutdown`(释放占用),脚本会显式警告这会中断容器/WSL 会话。

## 实现层面的保护

- 所有 clean 脚本只删**已知产物目录名白名单**(node_modules / target / 各类 cache 等),即便输入 JSON 被篡改也不会删到白名单外的路径。
- `clean-builds.ps1` 对每个待删项做 `allowedKinds` 二次校验,Kind 不在白名单内直接跳过。
- 删除前后做实际大小差值统计,只报告真正释放的字节,绝不虚报。

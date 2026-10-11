# RayGit

参考 SmartGit 工作布局的原生 macOS Git 客户端。当前首版重点为工作区操作、代码对比与提交历史。

## 本地运行

要求 macOS 14+、Swift 6 / Xcode Command Line Tools、系统 Git。

```sh
swift test
./scripts/build-app.sh
```

构建成功后会正常退出正在运行的本地 RayGit，并替换 `/Applications/RayGit.app`；退出失败时停止替换。使用 `./scripts/build-app.sh --no-install` 可仅生成构建产物。

双击 `/Applications/RayGit.app`，点击“打开仓库”。也可从终端运行：

```sh
swift run RayGit --repo /absolute/path/to/repository
```

构建产物使用本机 ad-hoc 签名，尚未进行 Developer ID 签名或公证。

## 已有功能

- 打开/切换/最近仓库；文件状态、过滤、多选、暂存和取消暂存。
- 提交及确认修订，分支创建/切换，Fetch、Pull、Push，stash保存/应用。
- 工作区、索引、历史提交的并排/统一差异，行号、增删颜色、hunk导航、忽略空白。
- 拓扑历史图、提交说明/正文搜索、每页200条、提交详情与文件差异联动。
- 后台Git执行、加载和错误状态、过期异步结果保护。

`⌘O` 打开，`⌘R` 刷新，`⌘T` 暂存所选。Pull只允许fast-forward；Push使用已有上游配置。远端认证使用本机Git凭据与SSH agent，不弹出终端密码提示。

## 界面语言

工具栏的“语言 / Language”菜单或应用设置支持：跟随系统、简体中文、繁體中文、English、日本語。切换即时生效并记住选择，不改变当前仓库、文件选择和提交草稿。

历史、差异、操作提示、确认框及应用自有错误文案均已翻译；代码、提交内容、路径和 Git 原始错误保持原样。macOS 原生菜单和系统对话框的部分文案由系统语言控制。

新增语言时，在 `Sources/RayGitLocalization/Resources/<locale>.lproj/` 补齐四个 `.strings` 表，并更新 `AppLanguage` 和打包声明。运行 `python3 scripts/check-localizations.py` 及 `swift test` 检查键、占位符和语言回退。翻译资源随 `.app` 一同打包。

## 验收仓库

```sh
python3 scripts/make-demo.py
```

脚本会输出新建临时仓库路径，包含合并历史、已暂存/未暂存/未跟踪文件，可安全用于界面验收。

完整计划、功能矩阵及后续边界见 [docs/ROADMAP.md](docs/ROADMAP.md)。此版本尚无逐块暂存、语法高亮、Blame、自动三方合并、交互式Rebase或托管平台集成。

## SmartGit 风格交互

工作区采用左侧仓库/分支、右侧文件/差异/日志与提交的可调整分区。文件双击或 Enter 打开独立比较窗口；提交双击或 Enter 打开含文件差异的独立详情。右键菜单按点击对象或多选集合操作，不误用旧选择。

支持文件历史、分支历史、从提交创建分支/标签、分支重命名/安全删除、检出提交、摘取/还原、贮藏查看/应用/删除。写操作有状态检查和必要确认；丢弃仅覆盖已跟踪文件的未暂存内容。合并提交摘取/还原暂不支持。完整对应关系见 [交互清单](docs/SMARTGIT_INTERACTIONS.md)。

## 可编辑文件比较器

工作区文件双击或点击“编辑／三栏对比”，支持 HEAD／索引／工作区三栏、工作区编辑与保存、撤销重做、搜索、同步滚动、行号及自动换行。冲突文件显示 Ours／编辑结果／Theirs，可保存并显式标记解决。单独保存不会改变索引；外部修改会阻止覆盖，关闭时保护未保存草稿。

完整行为、限制和测试仓库入口见 [文件比较器说明](docs/FILE_COMPARE.md)。

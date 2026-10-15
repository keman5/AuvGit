# AuvGit 复刻计划与功能清单

参考：2026-10-03 本机 SmartGit 26.1。观察工作区的仓库/分支侧栏、文件状态表、并排/统一差异、日志、提交说明与修订入口，以及本地操作菜单。采用独立原生实现，不复制 SmartGit 的私有代码或资源。

## 产品目标

面向 macOS 的高密度 Git 图形客户端。优先保证日常操作、代码对比和历史追溯的正确性。SwiftUI 负责窗口与列表，AppKit NSTextView 负责可选择的等宽代码文本，系统 Git 负责仓库语义。macOS 14+；首个构建验证平台为 Apple Silicon。

## 阶段与详细清单

| 功能域 | 已有可用实现与入口 | 外部依赖或明确限制 |
| --- | --- | --- |
| 仓库 | 打开/初始化/克隆、最近仓库、组名、security-scoped书签、跨重启仓库标签/commit草稿/历史与文件状态恢复、FSEvents递归事件与3秒轮询兜底 | 500ms保存与退出flush；不可访问仓库回退并保留草稿；损坏session恢复有效备份 |
| 工作区 | 状态列表、多选/过滤、完整目录树、ignore规则编辑/忽略列表、rename、系统废纸篓/持久化恢复、Finder与丢弃确认 | 详细入口及恢复限制见REMAINING_FEATURES和工作区验证 |
| 暂存 | 全部/所选、hunk/逐行暂存取消、索引文本编辑器、冲突屏蔽 | 任意复杂diff编辑仍须真实临时repo验证；不改未选路径 |
| 提交 | 模板加载/配置、Signed-off-by、签名key/开关、amend空说明填充、hooks | 真实签名依赖有效GPG/SSH工具与密钥；amend不覆盖已有草稿 |
| 差异 | 并排/统一/三栏、同步/搜索/换行/字体、字符高亮、语法高亮、外部工具、任意两个引用差异、图片比较和编码解码 | 任意引用固定两个commit hash，结构化文件列表联动并保持一致基准；超大文件另有流式分页只读窗口，编辑器保留明确展示上限 |
| 历史 | 拓扑图/ref、分页、正文/作者筛选、hash跳转、文件rename-follow、详情、Blame/Reflog选中打开提交 | Blame结构化作者/日期/hash/行号/代码，Reflog结构化引用/作者/日期/hash/操作；深页选择可恢复 |
| 分支/标签 | 本地操作、remote tracking创建、upstream设置、标签列表/附注创建/删除 | 标签专属管理表格；远程推送/删除先dry-run后确认；签名标签需真实密钥 |
| 同步 | Fetch/prune、FF-only Pull、Push、ahead/behind、remote增删、dry-run preview、force-with-lease；网络面板进度/取消/凭据配置 | 实际私有远端认证沿用系统；取消网络操作不撤销已经完成的远端写入 |
| 贮藏 | 全部/指定路径stash、应用/查看/删除、指定记录rename | rename保留OID/order/date，非UTF8 reflog明确拒绝 |
| 合并/重写 | merge入口、自动三方合并/结果编辑、reset三个模式、merge/rebase/cherry/revert继续/中止、交互式rebase计划编辑 | Git原生--rebase-merges计划保留拓扑；支持label/reset/merge/break/update-ref及提交指令，完整多行消息编辑；exec仅显式计划、可滚动预览和确认后执行 |
| 扩展 | submodule状态/add/init-update、LFS状态/install/track、GitFlow feature/release/hotfix start/finish、GitHub/GitLab网页入口、自定义快捷键、HTTPS更新manifest配置/检查 | LFS依赖本地git-lfs；PR/MR仅打开网页不代提交；本地签名公证脚本已提供，执行依赖Developer ID/Apple凭据；可信签名更新分发基础设施尚未提供 |

以上“实现”表示代码及真实Git工作流入口；编译通过不等同于原生UI、真实远端、签名或发布验收。每项的当前入口、未完成内容与外部前提见[REMAINING_FEATURES.md](REMAINING_FEATURES.md)。

## 实施拆分

- 主代理：窗口、RepositoryStore、工作区/提交、侧栏与操作入口、打包和端到端验收。
- GPT-6.1-sol / git_engine：GitRepository、GitProcess、真实临时仓库集成测试。
- GPT-6.1-sol / diff_ui：unified diff解析、AppKit差异展示、解析测试。
- GPT-6.1-sol / history_ui：历史列表、提交关系图、分页与详情、图算法测试。

共用当前 checkout；无额外 worktree。构建完全本地完成。

## 交互与正确性标准

1. 所有耗时Git命令在后台执行；UI呈现加载态并阻止重复写操作。
2. 快速切换仓库/文件/历史项后，旧异步结果不得覆盖新选择。
3. Git命令使用参数数组和literal pathspec，兼容空格、换行和通配符形状文件名。
4. stdout/stderr并行读取，输出上限32MB；大差异明确标出截断。
5. 对比与历史文件列表使用一致的父提交基准；根提交相对空树。
6. 提交只写索引；保留Git hooks，不强行覆盖脏工作区。写操作失败展示Git错误。
7. 凭据沿用系统现有配置；此版本不提供登录对话框。真实生产远端不作为自动验收目标。
8. 用临时仓库验证读取、暂存、提交、分支、stash及本地bare remote同步。实际.app验证布局和工作流。

## 交付边界

当前已补充本清单后续工作流，不宣称与 SmartGit 全功能等价。尚未实现的明确限制保留在上表与REMAINING_FEATURES，不移到范围外。真实远端认证、签名提交、复杂hooks、百万级提交性能、Intel硬件及公证分发需专项验收。

本轮文件/提交/分支的右键菜单与双击交互矩阵见 [SMARTGIT_INTERACTIONS.md](SMARTGIT_INTERACTIONS.md)，已验收路径见 [VALIDATION.md](VALIDATION.md)。

文件比较器本轮增量详情见 [FILE_COMPARE.md](FILE_COMPARE.md)。

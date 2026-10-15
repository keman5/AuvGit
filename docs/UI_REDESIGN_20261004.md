# 2026-10-04 原生 UI 设计稿实现与验收记录

本轮依据用户提供的七张设计图调整原生 macOS 界面。下列“已实现”指源码中的布局和入口变化，不表示安装版 GUI、外部服务或截图相似度已经验收。上一轮严格行对齐的验收记录保留在 `VALIDATION.md`；不能直接作为本轮新增界面的验收证据。

## 设计图与实际页面映射

设计图保留为用户本机文件，不复制到仓库，不将其中示例数据写进产品。

| 用户设计文件 | 实际页面 / 入口 | 对应实现 |
| --- | --- | --- |
| `/Users/kevin/Downloads/3d021ac9-b134-42f5-832b-d2adc537a4f9.png` | 主窗口工作区、仓库 / 分支侧栏、文件列表、差异和提交面板 | `Sources/AuvGit/MainWindow.swift`、`RepositorySidebar.swift`、`WorkspaceFilesPane.swift`、`HistoryPane.swift`、`DiffPane.swift`、`WorkspaceStyle.swift` |
| `/Users/kevin/Downloads/76c797b7-3755-4a5b-97d4-bd1d812160f6.png` | 文件双击 / 比较操作打开的独立普通编辑对比窗口 | `Sources/AuvGit/CompareWindow.swift`、`ComparisonEditor.swift`、`DesignComparisonUI.swift`、`ComparisonExtrasMenu.swift` |
| `/Users/kevin/Downloads/ed57d6a5-7dd6-41ea-8314-ce4e0a8a8fbe.png` | 冲突文件独立解决窗口；工作区使用共享只读预览 | `Sources/AuvGit/CompareWindow.swift`、`ComparisonResolver.swift`、`ComparisonEditor.swift`、`WorkspaceConflictPreview.swift`、`DesignComparisonUI.swift` |
| `/Users/kevin/Downloads/683ab669-7df7-40d7-b9d6-88ec30635e18.png` | 应用设置及编辑器设置 | `Sources/AuvGit/PreferencesWindow.swift`、`EditorPreferencesView.swift` |
| `/Users/kevin/Downloads/1ff00d40-d8a0-4a7a-b3a1-382c2bda15ca.png` | Fetch / Pull / Push 网络操作面板 | `Sources/AuvGit/NetworkOperationsView.swift` |
| `/Users/kevin/Downloads/40b87c88-a6ea-428d-9562-475f2a095ae2.png` | 标签管理面板 | `Sources/AuvGit/TagManagementView.swift` |
| `/Users/kevin/Downloads/ac16ba35-29ba-4f02-9889-7f65c6877837.png` | 交互式 Rebase 工作流面板 | `Sources/AuvGit/RebaseWorkflowView.swift` |

## 本轮源码变化

- 主窗口及共享视觉样式按设计整理仓库导航、状态筛选、文件表格、工作区分区和提交表单。设置、网络、标签与 Rebase 使用各自的现有任务模型，视觉实现由对应页面负责；最终交互验收见下表，当前仍待补。
- 普通比较三栏顺序调整为 **HEAD / Index / Worktree**，保持 `head`、`index`、`worktree` 原模型 ID；只有工作区可编辑。冲突比较仍为 **Ours / Result / Theirs**，编辑结果位于中间。
- 比较窗口增加仓库与文件路径、路径复制、未保存状态、版本关系条；搜索、匹配 / 改动导航、同步滚动、换行、行号和保存操作集中到工具栏。
- 普通工具栏使用 `ViewThatFits`，窄窗口可横向滚动访问全部工具，不依赖截断按钮。真实窗口宽度及四语言长文本仍需 GUI 验收。
- 原生来源标题栏显示真实内容对象短 ID 或可编辑 / 只读状态；行号字体弱化，gutter 使用浅灰背景。底部展示当前编码、换行格式、加载版本数和真实光标 / 选区信息。
- 冲突工具栏直接提供当前块 Ours、Theirs、Ours 后 Theirs、Theirs 后 Ours 操作，保留 Base 与既有菜单；底部提供保存并标记解决。
- **Base（共同祖先）**作为独立的可折叠底部只读面板显示真实 Stage 1 内容，可复制。展开 Base 不替换 Ours，也不改变中间结果草稿。工作区冲突预览仍只读，不显示接受块操作。
- 编码转换、外部工具待应用结果、完整版本替换确认、重新加载确认及关闭窗口草稿保护保留。新增比较界面文案独立放在四语言 `DesignCompare.strings`。
- 严格行对齐继续使用显示布局留白，不向原文插入空行，不生成假行号，不修改复制、保存和撤销的文本。此次标题栏高度变化后仍由现有布局回调重算；需要重新执行换行、拖动分栏、空侧和滚动到底验收。

## 真实数据原则

- 仓库、路径、分支、对象 ID、差异、冲突数量、已暂存数均来自当前仓库及当前草稿；不复制设计稿里的示例 hash、示例行数、示例分支名或固定进度。
- 来源栏短 ID 为文件内容的 Git blob ID，不伪称提交 ID，也不补写不存在的提交时间。
- 编码与换行格式来自已加载文件；光标 / 选区来自原生文本选择；虚拟对齐空间不计为文本。
- 保存只写工作区；标记解决 / 暂存是显式动作；提交消息生成不代表执行提交。错误、未登录、缺少 CLI 或远端失败不能呈现成功状态。

## AI 提交消息入口与待验收边界

当前源码在工作区提交表单标题提供星形“生成提交消息”按钮，并提供 AI 设置入口（`MainWindow.swift`、`AICommit.swift`）。默认提供方为本地 **Codex CLI**，默认模型为 `gpt-6.1-sol`；也可配置 OpenAI 兼容 API。本轮已用真实 Codex CLI 对合成输入完成生成：首次调用因提供方路由失败，修正白名单传输配置后成功。该证据只证明此机器这次合成调用可用，安装版 GUI 已连续两次生成并填入合成仓库提交草稿；OpenAI 兼容 API 未测试。

生成以真实已暂存差异为依据，结果进入提交消息草稿；请求期间可取消。源码保护仓库、暂存内容或消息草稿在生成期间变化的情况，不能用旧结果覆盖新草稿。是否按预期生效，必须通过实际登录状态、成功 / 失败 / 取消和并发修改验收。不得将 API 密钥、CLI 登录凭据或原始敏感 diff 写入截图、日志或提交文档。

## 本轮验证记录

本表只在取得对应证据后更新，未填写项不得视为通过。

| 项目 | 当前状态 / 待补证据 |
| --- | --- |
| 比较界面 Swift 语法解析 | 已执行 `swiftc -frontend -parse`；仅证明语法，不证明类型检查、链接或运行 |
| 比较四语言资源格式 | 四个 `DesignCompare.strings` 已执行 `plutil -lint` |
| 修改空白检查 | 已执行 `git diff --check`；最终整仓库结果由主代理补充 |
| 最终本地构建、完整测试 | 本机最终应用构建通过；`swift test --build-system native` 全量118项通过 |
| 四语完整资源检查 | 四语言26表981键检查通过；不等于四语逐页 GUI 验收 |
| 普通比较 | 安装版确认 HEAD / Index / Worktree 顺序；输入 `QA` 后 Undo 恢复干净草稿；换行开关有效。新版分栏拖动 / 空侧 / EOF / 同步滚动专项仍待补 |
| 冲突比较 | 真实 fixture 第二块导航、Base 展开真实内容、采用 Theirs 从3块变2块、Cmd-Z 恢复3块干净草稿通过；本轮未保存 / 暂存，其他接受顺序及 Base 复制仍待专项 |
| 主窗口 / 设置 | 主窗口已原生查看；编辑器设置卡片和开关实时可见；未执行恢复默认 |
| 网络 | fixture 的真实 `origin/main`、ahead 0 / behind 0 显示正确；从本地 bare origin Fetch 成功。不代表互联网远端 Pull / Push 已验收 |
| 标签 | 两个真实标签与创建表单的轻量 / 注释 / 签名类型已查看；未创建标签 |
| Rebase | 脏 fixture 加载时正确拒绝；干净副本以 HEAD~3 成功加载3个提交及作者/时间，pick改reword同步更新预览；未执行变基 |
| 1100pt 窄窗口、长路径、四语言、深浅主题 | 待截图和交互；语法解析不能证明没有截断 |
| AI Codex CLI 默认入口 | 安装版两次点击成功填入草稿；HEAD和暂存差异不变。4项草稿保护/子进程成功、取消、超时测试通过；GUI取消未完成（点击前请求已结束），API、未登录、缺少CLI未测 |
| 设计截图视觉对比 | 初始基线测量值65.04，覆盖率100%；首轮改版测量值74，覆盖率89.31%。工具栏修正后测量71.37/覆盖99.14%；恢复无换行状态最终73.39/覆盖99.31%。差异包括原生控件、间距、窗口比例及真实内容；未达到95%目标，不能当成七页整体还原度 |
| 安装 / 签名 / 提交 | 已用 `ditto` 更新 `/Applications/AuvGit.app`；严格签名检查和安装可执行文件 `cmp` 通过。Git 提交结果仍待主代理补充 |


## 本轮原生截图与磁盘边界

本轮截图目录为 `/tmp/auvgit-design-review/`：`network.png`、`tags.png`、`tag-create.png`、`editor-settings.png`、`compare.png`、`compare-wrapped.png`、`conflict-base.png`。这些截图是当前局部原生界面证据，不代表所有交互、四语言、深色或最终工具栏相似度都通过。

冲突测试位于 `/tmp/auvgit-visual-polish-20261004`，仅更改内存草稿并撤销；未保存或暂存。`resolver-demo.txt` 的 SHA1 仍为 `c923f59cbe92dfad1567c93214cf5d0cbd925766`，磁盘内容保持原样。上述新增 GUI 验证不替代此前完整保存并解决工作流，也不宣称本轮重测了保存流程。

最终补充截图：`ai-result.png`、`rebase-clean.png`、`rebase-reword.png`、`workspace-final-nowrap.png`，视觉报告 `after-3/report.md`。最终工具栏刷新/网络/标签/更多/搜索无障碍名称经重装运行确认，Cmd-K搜索ThreePane正确筛出文件。换行设置已恢复原值。完整四语逐页、深色、API、真实互联网远端推送、缺少CLI仍未验证。

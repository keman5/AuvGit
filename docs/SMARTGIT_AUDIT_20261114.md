# AuvGit 功能审查与 SmartGit 差异清单

审查日期：2026-11-14。源码基线：`cef95a8`；本机 SmartGit：**26.1.045（261045）**。

本次检查覆盖文件比较的加载、编辑、保存、冲突解决、搜索替换、部分暂存，以及历史的分支身份、拓扑顺序、分页、筛选和图谱呈现。通过临时本地仓库和不显示的 AppKit 组件验证；没有激活应用或抢占前台。这里不代表整个应用不存在其他 bug，也不代表完成了两个应用的逐像素视觉验收。

SmartGit 参照依据包括本机 `Info.plist`、`smartgit.jar` 内的 `i18n/messages.pot` 菜单资源以及官方手册。仅见于官方 Latest 手册、未在本机资源核实的条目单独注明；26.2 的新增功能不作为 26.1 已有功能。

## 已复现并修复的问题

| 问题 | 触发条件及影响 | 修复行为 | 回归证据 |
| --- | --- | --- | --- |
| 冲突结果保存错栏 | 已编辑合并结果，再编辑 Ours／Theirs 等源副本，点击“保存并标记解决”，会将最后活动的源副本写入磁盘及索引 | 暂存／标记解决明确保存工作区结果；普通“保存”仍允许显式保存活动副本，其他副本草稿保留 | `FileCompareSessionTests.testResolvingSavesMergeResultInsteadOfActiveSourceCopy` |
| 同名本地／远程分支混淆 | 本地 `origin/topic` 与远程 `origin/topic` 同时存在，短引用无法区分，颜色及远程标签筛选可能误处理本地分支 | 日志使用完整引用；样式以完整本地／远程身份区分，明确的本地引用不按远程前缀猜测 | `HistoryBranchUnionTests.testCheckedRefsUnionDeduplicatesAndPreservesCollidingFullNames`、`HistoryGraphColorsTests.testQualifiedLocalRemoteNamesKeepIndependentStylesAndVisibility` |
| 贮藏／可回收提交混入日志后拓扑顺序错误 | 父提交时间比子提交晚时，原先按时间合并，可能把父提交放在子提交前，破坏图谱连接 | 合并范围先进行拓扑排序，再保留选定集合并分页；不引入贮藏的索引／未跟踪辅助提交 | `HistoryBranchUnionTests.testUnionKeepsChildrenBeforeParentsWithClockSkewAndPagination` |
| 当前路径妨碍历史文件预览 | 历史文件所在目录在当前工作区变成符号链接时，即使旧 Git blob 存在，也无法查看 | 历史读取仅验证仓库相对路径；无法取得安全当前快照时只读显示历史内容，禁用写入 | `FileCompareSessionTests.testHistoricalComparisonSurvivesCurrentSymlinkAncestorWithoutEnablingWrites` |
| 单次替换后光标跳到文件尾 | 在文件中部替换一个搜索命中，整篇缓冲区被重写，下一次替换可能回绕到文件头 | 单次替换只修改命中范围，光标留在替换内容之后；保留原生独立撤销；全部替换仍为一次撤销 | `ComparisonSearchTests.testSingleReplacementContinuesAfterMatchAndPreservesNativeUndo` |

## 文件比较：已有能力与差异

优先级：P1 为日常比较／暂存／合并最常用的缺口，P2 为布局、配置或特殊场景增强。表中“缺少”指本次源码中没有找到完整用户入口，不等同底层完全没有相关代码。

| 功能 | AuvGit 当前实现 | SmartGit 参照及实际差异 | 建议 |
| --- | --- | --- | --- |
| 完整文件与二／三栏 | 已有 HEAD、Index、工作区及冲突 Ours／结果／Theirs；状态自动布局 | 基础能力已有，不需要从零重做 | 保留 |
| 索引独立编辑 | 索引栏是可编辑的**副本**，普通保存写工作区；`GitCore.saveIndex` 存在但未接入比较编辑器保存入口 | SmartGit Index Editor 可独立编辑并保存索引，而不修改工作区 | **P1**：清楚区分“保存工作区”和“保存索引” |
| 行内／选区接受 | 已有整块接受、完整版本采用，字符级着色 | SmartGit 本机菜单有 `Apply Inner-line Difference`、`Apply Selection`、`Apply Line`；AuvGit 缺少相应粒度的转移入口 | **P1**：补行、选区、字符变化接受与撤销 |
| 部分暂存 | 补丁页支持逐块及选中增删行暂存／取消暂存 | SmartGit 可在比较／Index Editor 中直接 Stage Line、Stage Inner-line Change，减少切换补丁页；AuvGit 没有字符级暂存 | **P1**：先统一编辑器内逐行暂存，再考虑字符级 |
| 忽略差异规则 | 普通文本对齐和差异计算采用精确文本；独立补丁查看器有忽略空白 | SmartGit 本机有 Ignore Whitespace、Ignore Case Change for Line Comparison、Ignore Line-Ending Changes；AuvGit 未将这些规则贯穿完整编辑器、导航和缩略图 | **P1**：统一差异计算设置，搜索大小写选项不能代替比较规则 |
| 搜索与替换 | 已有文本／大小写／正则、单个及全部替换、撤销；本轮修正连续替换 | 基础能力已有；不能笼统列为缺失 | 持续回归 Unicode、正则及大文件 |
| 冲突选择 | 已有采用左／右／Base、双方顺序、自动合并、单独保存及标记解决 | 基础解决流程已有；本轮修正结果保存目标 | 保留并回归 |
| 冲突布局 | 已有左＋结果、三栏、结果＋右；Base 是下方可展开面板 | SmartGit 本机提供 **Merge Below**，可将结果独占下方以阅读长行；Base Changes 可单独窗口比较 | **P1**：结果下置；P2：独立 Base 比较 |
| 紧凑模式 | 已有只显示变化的投影；普通文本的紧凑投影是只读视图，需返回完整编辑器修改 | 不能视为完整编辑模式；本轮没有实际验证 SmartGit 26.1 紧凑模式能否直接编辑 | **P2**：保持编辑／搜索／光标状态一致，避免模式切换跳动 |
| 行号、对齐、同步、缩略图 | 已有差异行号底色、占位对齐、曲线区域、双轴同步、点击／拖动缩略图定位 | 核心能力已有；曲率、色阶、自动换行时连接位置是否逐像素一致尚需同文件双应用视觉验收 | **P1**：用插入、删除、长行、三处冲突的固定样本验收 |
| 语法与显示设置 | 有按扩展名的基础词法高亮、制表宽度、空白显示、字体与差异颜色设置 | SmartGit 官方 Changes View 提供手动切换 Syntax Highlighting language；AuvGit 缺少当前文件语言覆盖入口 | **P2**：语言选择器，无扩展名／模板文件手动覆盖 |
| 编码与换行 | 已有多种编码解释、转换、BOM／换行保留；混合换行保护 | 不属于功能空白；应区分“忽略换行差异”和“重写文件换行” | 保留保护行为 |
| 大文件 | 2 MB 以上只读分页，32 MB 以上按可流式文本处理；二进制显示摘要 | SmartGit 本机有 Force Compare，可临时覆盖比较大小限制；AuvGit 没有同等的逐文件强制比较开关 | **P2**：按文件显式放宽限制，提供取消和资源上限 |
| 图片与静态文档 | 已有图片、SVG、PDF 等预览及专用版本选择；不是所有格式都可编辑 | 本轮未核实 SmartGit 的各媒体格式覆盖，不能声称某方全面领先 | 另做格式矩阵验收 |
| 外部工具 | 已有可执行工具及参数模板、受控结果返回草稿 | 基础能力已有，不应再次列为未实现 | 保留 |

代码入口：`Sources/AuvGit/CompareWindow.swift`、`ComparisonEditor.swift`、`ComparisonSearch.swift`、`ComparisonExtrasMenu.swift`、`PartialStagingPane.swift`、`CompactComparisonView.swift`；底层 `Sources/GitCore/FileComparison.swift`、`PartialStaging.swift`。

## 提交图：已有能力与差异

| 功能 | AuvGit 当前实现 | SmartGit 参照及实际差异 | 建议 |
| --- | --- | --- | --- |
| 基础图谱与加载 | 已有父子／合并连线、第一父链、分页追加、缓存及当前 HEAD 标识 | 基础能力已有；本轮修正混合范围拓扑错误及分支身份混淆 | 保留并持续回归 |
| 分支勾选与范围记忆 | 已有各本地／远程分支、标签、贮藏和可回收提交范围，持久化选择 | 并非只有“全部分支”，核心能力已具备 | 保留 |
| 两提交直接比较 | 已有列表多选，但比较内容仍基于主选中的一个提交及父提交 | SmartGit 可选两个提交直接展示二者差异；AuvGit 缺少与多选联动的文件集合及双端内容 | **P1**：真正的两提交比较，并处理方向和重命名 |
| 工作区／索引图节点 | 本地修改在工作区页，提交图仅由真实 GitCommit 生成 | SmartGit Log 有 Working Tree／Index 节点，可与任意提交比较 | **P1**：加入虚拟节点并接通比较，不伪造 Git 提交 |
| 过滤后的连线与引用 | 消息／作者过滤读取匹配提交，图谱仍使用实际父 hash；标签仅来自可见提交自身 | 官方 Graph View 会把 ref 映射到仍可见的祖先并用 `~` 表示；AuvGit 缺少隐藏路径桥接和引用投影 | **P1**：筛选／文件历史仍能辨认分支归属 |
| 节点和分支状态 | 已有普通、合并、远程独有节点以及未推送配色、虚线 | 官方 Graph View 另有工作区状态、已签名、上游相同／领先落后等专用标识；AuvGit 图标签缺少完整上游状态表达 | **P2**：状态不只依赖颜色，增加可读图例和标识 |
| 折叠合并路径 | 第一父链开关可隐藏侧链 | 官方 Graph View 有可点击展开的折叠节点；AuvGit 没有逐段折叠／展开 | **P2**：与“只看第一父链”分开实现 |
| 拖动引用与提交 | 已有右键 checkout、reset、cherry-pick、revert、交互式 rebase 等命令入口 | SmartGit 官方支持图中拖动 refs／HEAD 等操作；AuvGit 没有图内拖放工作流 | **P2**：先补拖动预览和明确操作确认 |
| 作者／提交者显示 | 可控制作者头像、作者名字、远程标签、tag；详情包含提交者信息 | SmartGit 本机菜单含 Committer Avatar、Author／Committer with Full Name and Email；AuvGit 图列表无法切换身份维度 | **P2**：作者／提交者、名字／邮箱独立设置 |
| 图列配置 | 普通日志有信息列与宽度控制，紧凑列表采用固定组合；更多菜单未开放所有列开关 | 官方 Graph View 支持 SHA、日期、身份等列开关；AuvGit 当前配置粒度较少 | **P2**：持久化可见列，并保留紧凑布局 |
| Overlap 依赖分析 | 没有对应数据及图列 | 官方 Overlap 描述提交间文件／位置重叠与重排风险，且有 Git-Flow 等上下文约束；本机资源未独立确认完整入口 | **P2，待 26.1 实机核实**：作为高级功能，不影响基础图谱 |
| 主窗口辅助分支 | 主窗口有当前／所有历史及合并提交控制 | SmartGit 本机有 Show Auxiliary Branch，可在 Journal 单独叠加一个参考分支；AuvGit 未提供同等入口 | **P2**：主分支＋一个辅助分支的轻量比较 |
| 头像与滚动 | 已有共享头像缓存、原生紧凑列表复用、图谱缓存、分页预取 | 已有相应优化；本轮没有同一大型仓库的 SmartGit／AuvGit 公平耗时比较 | 用同仓库冷／热加载与滚动指标比较 |

代码入口：`Sources/GitCore/GitRepository.swift`、`CommitGraph.swift`；`Sources/AuvGit/HistoryPane.swift`、`HistoryGraphColors.swift`、`NativeCompactHistoryTable.swift`、`HistoryRefinement.swift`、`LogWindow.swift`、`HistoryBranchScope.swift`。

## 后续实施次序

1. 比较器明确区分工作区与索引的保存目标，提供编辑器内逐行／选区接受、暂存与撤销。
2. 两提交比较及 Working Tree／Index 虚拟节点，贯通图谱、文件列表和比较器。
3. 统一忽略差异规则，再补过滤历史的图路径和引用投影。
4. 冲突结果下置布局，以固定复杂样本验收曲线、占位、同步和深浅色。
5. 补语言覆盖、列与身份设置、可展开路径、辅助分支和高级图操作。

这些是差异清单与建议，未宣称本轮已经实施。

## 参照资料

- 本机菜单资源：`/Applications/SmartGit.app/Contents/Resources/Java/smartgit.jar` → `i18n/messages.pot`。本次只读取菜单文字，没有启动 SmartGit 窗口。
- [SmartGit Conflict Solver（24.1，含结果下置布局）](https://docs.syntevo.com/SmartGit/24.1/Manual/GUI/Branch/Conflict-Solver)
- [SmartGit Index 概念与编辑器（24.1）](https://docs.syntevo.com/SmartGit/24.1/Manual/GitConcepts/The-Index)
- [Changes View（官方 Latest）](https://docs.syntevo.com/SmartGit/Latest/Manual/GUI/Changes-View)
- [Graph View（官方 Latest）](https://docs.syntevo.com/SmartGit/Latest/Manual/GUI/Graph-View)
- [Log（官方 Latest）](https://docs.syntevo.com/SmartGit/Latest/Manual/GUI/Log)
- [Overlap（官方 Latest）](https://docs.syntevo.com/SmartGit/Latest/Manual/GUI/Overlap)
- [两分支／提交比较](https://docs.syntevo.com/SmartGit/Latest/HowTos/Workflows/How-to-compare-two-branches-commits)

## 验证记录

- 修复前：原有定向基线 52 项通过；新增／增强用例复现了上述五类问题。
- 第一轮修复：68 项后台定向测试通过，包含旧回归、冲突保存、历史预览、分支身份和时间偏差分页。
- 扩大回归运行 344 项 XCTest，其中 329 项首次通过，15 项因本机 `safe.bareRepository=explicit` 设置暴露了旧测试夹具的隐式裸仓库调用。夹具改为显式 `--git-dir`，未修改应用安全策略或用户 Git 配置；受影响的五个测试类共 55 项重跑全部通过，先前 15 项失败均已消除。
- 另有 2 项 Swift Testing 参数化测试通过，覆盖 7 个冲突选择参数场景。单次替换、原生撤销、旧文件预览、防止符号链接写入、分支身份及拓扑分页的新增回归均通过。
- 构建入口为 `scripts/build.sh`；设置 `AUVGIT_LAUNCH_AFTER_BUILD=0` 可在替换应用后保持关闭，避免后台验证期间启动应用。
- 已构建并替换 `/Applications/AuvGit.app`，版本 **0.1.19（21）**；替换后清理了 `.artifacts`，没有自动启动应用。
- 大型历史混合贮藏／可回收范围现在需要一次额外拓扑遍历；本轮验证了正确性及分页，没有宣称所有大型仓库的加载耗时均已改善。
- 未运行会激活窗口的键盘／视觉测试；未进行真实远程服务认证、SmartGit 同场景耗时或逐像素比较。

扩大回归的可复现命令（后台运行并将输出重定向到日志）：

```sh
AUVGIT_REVIEW_TEST_FILTER='GitCoreTests|FileCompareSessionTests|ComparisonSearchTests|ComparisonReviewTests|ComparisonUndoTests|ComparisonBandNavigationTests|ComparisonInitialNavigationTests|ComparisonOverviewTests|ComparisonActionRailTests|ComparisonDocumentGeometryTests|HistoryGraphColorsTests|HistoryPaginationTests|HistoryBranch|HistoryRemoteScopeTests|HistoryScopeAndDateTests|WorkspaceCommitTests|AuvGitLocalizationTests' ./scripts/build.sh --test-performance-review
```

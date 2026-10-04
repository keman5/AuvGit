# 当前验收记录

日期：2026-10-03。平台：本机 Apple Silicon macOS，Swift 6.4；部署目标 macOS 14。所有构建在本机完成。功能入口和实现限制见 [ROADMAP.md](ROADMAP.md) 与 [REMAINING_FEATURES.md](REMAINING_FEATURES.md)。

## 自动验证

最新完整测试日志：`/tmp/raygit-completion-tests.log`，结束时间 13:30:45。

- `swift test --build-system native`：共92项通过，0失败；日志中的 `RayGitPackageTests.xctest` 与 `All tests` 汇总一致。
- 核心测试包含 GitRepository、CommitGraph、DiffParser、TextLineDiff、FileComparison、PartialStaging、FileManagement、RepositoryWorkflow、GitExtensions、AdvancedDiff、StreamingComparison、GitProcess，以及 SessionPersistence、InteractiveRebase、HistoryInspection 等新增测试。
- 真实临时仓库覆盖暂存/取消暂存、逐行与hunk操作、索引保存隔离、特殊路径、文件管理、分支/标签/贮藏、合并冲突继续/中止、保留merge拓扑的交互式rebase、多行提交信息、空提交与上游等价补丁保留、exec显式确认，以及会话恢复/损坏主记录备份恢复、结构化Blame/Reflog。测试不使用生产仓库作为fixture。
- 本地bare remote覆盖同步、标签推送与删除的dry-run/实际执行，以及保护条件。未读写生产远端。
- 最新本地化检查：四语言、17个资源表、640个文案键；资源语法、键齐全性、静态调用键及占位符检查通过。
- 最新Release本机构建成功，日志 `/tmp/raygit-completion-release.log`，产物 `.artifacts/RayGit.app`。
- 最新Release的 `codesign --verify --deep --strict` 本机签名验证通过；这不代表Developer ID签名或Apple公证已完成。
- 最终本地化640键复核、`git diff --check` 及公证脚本 `zsh -n scripts/notarize-app.sh` 通过。

自动测试与Release构建不代替下面的实际窗口验收。

## 当前原生界面与Git独立读回

实际启动Release应用，使用原生窗口控件完成下列操作。比较器及文件管理交互使用 `/tmp/raygit-compare-sv0whiq5`；最后一轮真实冲突解决使用新fixture `/tmp/raygit-compare-36kihtn_`。写操作没有触及生产远端。

| 工作流 | 已验证结果 |
|---|---|
| 三栏比较与动态布局 | 最新Release重启后实际切换三栏→双栏→三栏；重新构建的三列均分，HEAD、索引、工作区代码及高亮均可读。 |
| 撤销/重做 | 编辑器 `Cmd-Z` 与 `Shift-Cmd-Z` 实际生效。 |
| 编辑保存 | 修改工作区文本并保存成功；Git独立读回确认索引内容保持不变。 |
| 关闭保存保护 | 关闭有编辑内容的比较窗口，保存保护流程生效；保存后工作区改变，索引保持不变。 |
| 逐行暂存 | 选中删除的 `count2` 与新增的 `count3` 两行后执行所选暂存；索引仅将 `count2` 改成 `count3`，其他标题/输出修改仍留在工作区。 |
| 自动三方合并 | 冲突文件生成带base内容的diff3冲突标记，编辑器展示合并结果。 |
| 解决冲突保护 | 残留冲突标记时，“保存并标记解决”拒绝执行；清理后保存并暂存成功，`git ls-files -u` 读回为空。 |
| 最新冲突解决与动态重建 | 在 `/tmp/raygit-compare-36kihtn_` 的真实冲突中，将结果编辑为 `Shared heading\nLayout verified result\nShared footer\n` 并点击“保存并标记解决”。动态重建后HEAD/索引/工作区三栏等宽，内容与高亮均可见；`git ls-files -u` 为空，索引独立读回与编辑结果一致。 |
| 文件自动刷新 | 在应用外新增文件后，FSEvents自动刷新使文件出现在界面。 |
| 文件重命名 | 通过原生菜单重命名，磁盘独立读回确认目标名称和内容。 |
| 任意refs比较 | 输入 `HEAD~1` → `HEAD`，变更列表联动 `Conflict.txt` 差异；实际截图显示 `Original value` → `Our value`。 |
| 附注标签创建 | 在标签管理原生界面创建 `ui-validation` 成功；Git磁盘读回确认对象类型为annotated tag。最新Release重启后，标签表实际显示提交hash `d7739ea57aac8450810a41a63ca99c624ab6eead`，与Git解引用结果一致；模型另保留tag对象OID。标签列修正的原生界面复核通过。 |
| 历史hash跳转 | 在hash栏输入 `7dbb2666` 并回车，实际打开根提交独立详情；完整hash、作者、日期及新增 `Conflict.txt` / `Editor.swift` 正确，自动联动根提交diff正确。 |
| 网络面板 | 打开和关闭成功，凭据助手说明可读；未执行网络写入或更改凭据。 |

最新工作流原生验收使用独立fixture `/var/folders/p9/706zy1rn35l9bjl5jq98b3m40000gn/T/raygit-final-workflows-ksrpnxt0`，包含 `Project One` / `Project Two`；以下结果由原生交互和独立文件/Git读回确认。

| 工作流 | 已验证结果 |
|---|---|
| 底部终端 | `Cmd-\`` 打开底部PTY，cwd正确；隐藏后重开保留shell环境；执行sleep后Ctrl-C可中断。 |
| 仓库独立终端 | 两个项目各自保留cwd与shell环境，通过独立文件读回核验。 |
| 跨重启会话 | 重启恢复两个仓库标签、活动 `Project One` 及多行提交草稿。 |
| 切换语言保留终端 | 从英语切回系统简中，界面文案即时更新；同一shell环境中的语言核验值保留。 |
| UTF-16编辑保存 | 比较编辑器保存中文文本后，磁盘仍保留 `fffe` BOM及CRLF；索引保持不变。 |
| 删除文件恢复 | 对已删除可执行文件使用“更多→从索引恢复”，磁盘内容逐字节一致，权限恢复为755。 |
| 外部JSON四参数工具 | 独立fixture运行后结果进入待应用状态；“更多→应用”经过显式确认后仅生成未保存草稿，Save前磁盘与索引均保持不变。显式Save后，独立读回确认磁盘为带换行的 `External result verified`，索引仍为原始内容。 |
| 结构化Blame | `README.txt` 原生表格正确显示作者 `RayGit Fixture`、日期、hash `04e604952f`，第1行 `Project One`、第2行 `Initial text`。 |
| 结构化Reflog | 原生表格正确显示 `refs/heads/main` 和 `HEAD`、作者、日期时间13:12:43、提交hash及initial commit操作。 |
| 交互式rebase计划与取消 | 在干净的临时 `Project Two` 中新增两项测试提交，以 `HEAD~2` 原生生成 `label onto` / `reset onto` / `pick d0b1d22` / `pick 84d1a23`。确认预览完整展示仓库、解析后base `eb887d1`、原HEAD `84d1a23`、完整todo及无exec；取消后Git独立读回HEAD仍为 `84d1a23a7c0366ac3ece36112047124003a514fd`。 |
| 最新窗口布局 | 最终构建实际截图确认终端打开时主窗口控件无重叠，提交区可滚动。既有比较窗口动态布局证据如下保留。 |

动态三栏布局修复已按上述切换流程和实际截图验收。未由此推定所有窗口宽度或全部复杂diff场景均已视觉回归。

## 已实现功能的验收边界

- 仓库创建/克隆、分组/会话标签/书签、refs比较、作者/hash/Blame/Reflog、标签管理、stash路径与重命名、merge/reset/继续/中止、交互式rebase、子模块/LFS、GitFlow、PR网页入口、快捷键和更新配置已有入口。核心测试通过不表示这些入口均完成原生UI逐项回归。
- 当前不宣称与SmartGit全功能或像素级等价。交互式rebase已保留原生merge拓扑并支持完整todo、多行消息与exec显式确认；Blame/Reflog已改为结构化表格。结构化表格及rebase生成/预览/取消已通过本轮原生验收；保留merge拓扑的实际执行、exec与多行reword以自动测试为当前证据，本轮未在原生UI执行。会话标签和多行草稿的跨重启恢复已实际验证；不可访问仓库回退、完整筛选/选择恢复及损坏记录恢复仍以核心测试为当前证据。
- 私有远端认证、真实签名提交/标签、复杂hooks、真实LFS服务器/子模块网络操作、Intel硬件及大规模仓库性能仍需专项验收。
- 更新检查接口已有实现，可信manifest/签名发行服务器尚未提供；公证脚本已提供，正式Developer ID签名及Apple公证仍依赖有效身份和凭据。
- 快速切换读取结果通过版本token隔离，但未完成自动UI压力测试。
- Git原始输出、代码、路径和用户提交内容不翻译；系统菜单/对话框的部分系统控件由macOS管理。新增入口未做完整四语言视觉回归。

## 历史验收摘要

以下是早期迭代的既有证据；测试数量和资源数量仅描述当时版本，以当前结果为准。

- 首版：11项自动测试通过，Release构建和当时的ad-hoc签名验证通过。原生界面验证打开临时仓库、状态区分、双栏diff、暂存、提交及Git读回、历史文件联动、分支/合并图和正文搜索。
- 多语言迭代：15项测试通过；当时四语言/四表/141键。实际切换简中、英语、日语、繁中，主窗口/状态栏/历史/日期/差异工具栏更新；同一次运行内提交草稿和选择保留，语言偏好重启后保留。
- SmartGit交互迭代：19项测试通过；当时四语言/七表/221键。实际验证未选中行的右键目标、多选暂存、文件双击/Enter、提交详情、分支切换确认取消及文件日志。详细矩阵见 [SMARTGIT_INTERACTIONS.md](SMARTGIT_INTERACTIONS.md)。
- 文件比较器初次增量：当时32项测试通过，四语言/九表/290键。那次窗口验收因用户同时操作而中断，不能将其构建结果认定为当时编辑/撤销/关闭保护/冲突流程已通过；这些流程现已按上面的当前证据补验。比较器说明见 [FILE_COMPARE.md](FILE_COMPARE.md)。

历史记录中的“未实现逐块暂存/语法高亮/Blame/交互式rebase”等声明已被当前实现取代，不再作为当前功能状态。

## 2026-10-03 原生 macOS UI 布局优化验收

本轮在本机完成多次 Release 构建，均通过；4项 Localization 测试通过。`scripts/check-localizations.py` 检查四语言、18个资源表、650个文案键通过，`git diff --check` 通过。本轮没有重复运行完整 Git 核心测试；上文完整测试记录仍作为其对应版本的证据。

原生界面实测使用隔离应用 bundle `dev.raygit.visualqa` 和临时仓库 `/tmp/raygit-compare-3f13v1r_`，仅检查 UI 和读取仓库内容，未向真实仓库或远端执行写操作。

| 界面范围 | 本轮实际验证 |
|---|---|
| 主窗口与文件工具栏 | 默认窗口 1280×820，以及最小约1000宽、680高内容区均完成布局检查；文件列表和暂存操作工具栏可读。此项仅验证暂存入口布局。 |
| 代码差异与搜索 | 差异元数据默认隐藏，搜索展开后输入栏自动获得焦点；搜索 `title` 显示4处匹配，Esc可收起搜索。 |
| 三列比较 | 约1050宽窗口中三列代码和工具栏可读。 |
| 历史与独立详情 | 完整历史视图可读；双击提交打开独立详情，约260宽文件侧栏和差异区域可用。 |
| 标签管理 | 创建、同步和删除分区可读，640高 sheet无溢出；空标签与加载状态使用独立无条纹区域，无remote时显示静态说明。 |
| 网络、创建及仓库工具 | 网络面板、创建/克隆表单与仓库工具的标签、空状态和底部动作区可读；refs比较显示读取结果。未执行真实remote操作、克隆或凭据变更。 |
| 设置 | 语言页内容尺寸520×180，扩展页640×600，窗口随当前标签页内容调整；扩展页底部可滚动到达，语言与更新清单字段没有重复标签。英文界面也完成检查。 |
| 底部终端最小尺寸 | 最终原生截图复核通过：1000宽、680高内容区开启终端后，窗口自动增高到750高内容区；终端开启时最低内容高度为750，不能保持680。截图为2000×1604像素，含52pt标题栏；顶部仓库标签和底部状态栏完整显示，文件区约100、差异区约160、底部区域约165高，可见文件首行、3行代码与提交按钮。 |

本轮没有完成全量深色模式或日语视觉回归；没有重复验证全部复杂diff、Git工作流或真实网络认证。构建与本地化通过不代替这些专项验收。

## 2026-10-03 标题栏工具栏调整验收

本轮最终本机 Release 构建通过，日志为 `/tmp/raygit-toolbar-release.log`；`codesign --verify --deep --strict`、四语言18表651键本地化检查及 `git diff --check` 均通过。此次仅调整 UI，未重复运行全量 Git 核心测试。

原生 UI 实测确认主窗口标题下的仓库标签行与操作栏已移除，原有11个操作项均进入标题栏工具栏。右键标题可打开系统“自定工具栏”面板，包含全部11项、默认工具组及显示模式；右键“新建分支”移除按钮后，重启仍保持隐藏；随后通过面板将其插回工具栏末尾，再移至语言按钮之前，添加和排序均验证通过。仓库切换继续使用侧栏；本轮未重复验证 Git 写操作或远端网络行为。

## 2026-10-03 首选项扩展验收

首选项主框架、编辑器、外部工具、Git 和网络设置详见 [PREFERENCES.md](PREFERENCES.md) 与 [EDITOR_PREFERENCES.md](EDITOR_PREFERENCES.md)。最终 `swift test --build-system native` 全集 96 项通过，日志 `/tmp/raygit-preferences-tests-final.log`。首次全集终端 Ctrl-C 用例 timeout/running 两断言失败，旧用例独立重跑两次成功；仅调整测试就绪判定，要求前台进程组为正数且不是 shell 组，未就绪直接失败并返回。未改终端实现或扩大超时，修后全集通过；不据此认定唯一根因。

| 首选项范围 | 本轮原生 UI 实测 |
|---|---|
| 分类框架 | 12 分类布局正常、无截断。 |
| 编辑器热更新与草稿 | 字号 12→14、行号关闭即时影响已打开三栏；草稿保留，Cmd-Z 准确撤销临时注释，未写文件。 |
| 外观与持久化 | 深色主题实际截图确认生效；重启后深色、字号 14 与关闭行号均保留。结束后恢复字号 12、开启行号、跟随系统外观与语言。 |
| 外部工具校验 | `not-json` 应用被拒绝；切换分类回来，已保存模板仍原样。最终新包错误提示为中文，测试草稿已丢弃。 |
| 搜索与本地化 | 最终新包中“字体”“超时”“代理”“主题”搜索均显示对应分类；无匹配词显示中文空结果。Git 页标签无错位，无效 Git 路径显示中文错误且不保存。四语共 21 张表、837 个键静态检查通过。 |

最终 Release 构建通过，日志 `/tmp/raygit-preferences-release-verified.log`；构建产物通过 `codesign --verify --deep --strict`。正常退出应用后更新 `/Applications/RayGit.app`，安装副本签名通过且与产物内容一致。本轮没有执行真实全局身份写入、签名提交、代理认证、远端网络写操作或更新下载。

### 2026-10-03 工具栏布局项

- 原生自定义面板已显示弹性空白与竖向分隔线，并已验证原生插入。分隔线呈细线，无文字及按钮背景。
- 前一版新增布局项已验证正常退出、重启后恢复。
- 最新自定义空白 ID 与动态宽度版本仅完成本地构建、四语言资源及应用签名验证；实际伸缩、多空白分配和窗口 resize 尚未验收。本机 Mac 锁屏，等待用户解锁后继续原生 UI 验证。

### 2026-10-03 可调间距自动伸缩修复

最新版本改用原生 `NSToolbarFlexibleSpaceItem`，移除手工宽度估算；通过 SwiftUI 移除默认标题，并将仓库标题与按钮放在同一工具栏布局区域。本机 Release 构建通过。

原生 UI 验收补齐上节尚未验证的伸缩行为：旧配置末尾的3个可调间距恢复后，按钮靠左排列，剩余空间位于末尾。将“新建分支”移过其中1个间距后，“贮藏”与“新建分支”之间出现约150pt空白，其余2份位于末尾；窗口 Zoom 放大时中间间距明显增长，缩回后正确收缩。结束前已将按钮恢复原位置。此项验证了多间距分配和窗口尺寸变化；macOS 14 的标题隐藏兼容路径未完成运行验收。`.artifacts/RayGit.app` 与已更新的 `/Applications/RayGit.app` 均通过 `codesign --verify --deep --strict`，两包可执行文件 `cmp` 一致，`git diff --check` 通过。

## 2026-10-03 晚间工具栏崩溃与仓库刷新修复

21:13 的3份 `.ips` 崩溃报告均指向工具栏 SwiftUI `applyItemCustomizations` 的 `SIGTRAP`。本轮移除自定义工具栏代理，由 SwiftUI 管理工具栏项，并版本化 toolbar ID，隔离旧工具栏自定义配置；其他设置保留。此修复取代上节使用 AppKit 注入工具栏布局项的实现。

仓库侧栏移除分组，直接按已有 `recentPaths` 顺序平铺；切换仓库不再将条目置顶。紧凑日志的搜索框移到“日志”标题同行，保留清除按钮，输入框不显示 loading 图标。FSEvents 刷新改为比较仓库语义 `changeState`，只有 refs/HEAD 变化才重载历史，避免仅由文件事件反复刷新提交列表。

| 验证范围 | 已确认结果 |
|---|---|
| 定向测试 | `RepositoryChangeStateTests` 使用 native build system 的 filter 集成测试1项通过。 |
| 本地化 | 四语言、21张资源表、839个文案键检查通过。 |
| 构建与安装 | 本机 Release 构建通过，日志 `/tmp/raygit-fix-release.log`；产物 `codesign --verify --deep --strict` 通过，已通过 `ditto` 更新 `/Applications/RayGit.app`。 |
| 新包原生运行 | 新包成功启动并打开 `giftdock`；点击展开历史成功，未发生崩溃。 |
| 仓库列表顺序 | 切换到临时仓库后其条目未置顶，再切回 `giftdock`，列表顺序保持。 |

最终原生验收已补齐：`giftdock` 历史视图空闲15秒后，AX提交列表、选择与状态保持稳定，未观察到历史反复 loading。随后 `Cmd-Q` 正常退出，确认进程消失；重新启动 `/Applications/RayGit.app` 后直接恢复 `giftdock` 历史视图，未发生崩溃。回到工作区的实际截图确认“日志”、搜索框和放大按钮位于同一行，仓库列表平铺。搜索 `Add amount-based` 只匹配提交 `5ec6d6e2`，清除搜索后恢复完整列表。本轮未对 `giftdock` 执行写操作。

最终 `codesign --verify --deep --strict`、四语言21表839键检查及 `git diff --check` 再次通过。进程采样未抓到短命 Git 子进程，因此空闲验收仅证明上述 GUI 观测稳定，不据此保证零 Git 命令调用。本节仍不代表全部工具栏自定义流程或 Git 工作流已回归。

## 2026-10-03 冲突选择与差异视觉验收

本轮实际查看 SmartGit 26.1 Conflict Solver 的采用左右版本及按顺序保留双方交互，并在本机实现对应入口。`ConflictDraftTests` 使用 native build system 的 4 项测试通过，四语言／21 张资源表／860 个文案键检查通过。本机 Release 构建通过，日志 `/tmp/raygit-conflict-visual-build.log`；本节不代表全量 Git 核心测试重跑。

原生 UI 实测使用临时仓库 `/tmp/raygit-conflict-choices-kexsrkpn`，文件含两处真实 diff3 冲突。

| 验证范围 | 本轮实际结果 |
|---|---|
| 全文件选择 | 分别采用 Ours、Theirs、Base，草稿均与对应完整版本一致；Cmd-Z 恢复原冲突草稿。 |
| 未保存草稿保护 | 完整版本替换触发确认；取消后保留当前未保存草稿。 |
| 按块保留双方 | 第二块选择先 Ours 再 Theirs，结果按顺序包含 `count2`、`count3`，第一块保持不变；Cmd-Z 恢复原冲突草稿。 |
| 磁盘与索引边界 | 测试仅操作内存草稿；磁盘仍保留两处冲突，`git ls-files -u` 仍有三个冲突阶段。保留原始冲突供后续交互测试。 |
| 浅色视觉 | 最终原生截图确认行号较代码小 2pt、灰色弱化；完整冲突块红底，普通修改橙色行底与更强字符底色可读。 |

深色配色与外观切换后的刷新已在代码中支持，本轮尚未通过系统外观切换完成深色原生视觉检查。以上临时仓库结果不代替用户真实仓库的保存、暂存或完整合并工作流验收。

安装验收已完成：退出旧进程后，通过 `ditto` 将验证产物更新至 `/Applications/RayGit.app`；安装副本通过 `codesign --verify --deep --strict`，其可执行文件与 `.artifacts/RayGit.app` 经 `cmp` 确认一致，随后从 `/Applications/RayGit.app` 成功启动。

## 2026-10-03 冲突 Resolver 与新图标增量验收

本轮在原有比较编辑器中补齐逐块版本选择、双方顺序组合、基线选择、冲突导航、结果 gutter 箭头和双／三栏布局。内置 `image_gen` 生成的新应用图标已转换为标准 iconset 与 icns，并包含在最终应用资源中；最终应用的签名检查通过。设计来源与打包说明见 [AppIcon.md](../Resources/AppIcon.md)，交互说明见 [CONFLICT_RESOLVER.md](CONFLICT_RESOLVER.md)。

`swift test --build-system native` 全集108项、0失败，日志 `/tmp/raygit-resolver-tests.log`。本机 Release 构建成功，日志 `/tmp/raygit-resolver-release.log`。`codesign --verify --deep --strict`、四语言22表878键本地化检查及 `git diff --check` 均通过。

原生 GUI 使用含三块真实冲突的隔离 fixture `/var/folders/p9/706zy1rn35l9bjl5jq98b3m40000gn/T/raygit-resolver-j8g5ibze`，完成以下验收：

| 验证范围 | 实际结果 |
|---|---|
| 单块采用对方、撤销与重做 | 第二块采用对方仅替换第二块；Cmd-Z 完整恢复，Shift-Cmd-Z 正确重做。 |
| 双方组合与基线 | 第三块我方→对方得到正确四行；第一块采用 Base 正确，撤销后对方→我方得到正确两行顺序。 |
| 布局与 gutter | 切换我方+结果保留草稿；点击第一块 gutter 左箭头成功采用我方。 |
| 损坏标记 | 人工插入不完整 marker 后显示“冲突标记不完整，请手工修复合并结果”，禁用 choices；撤销后恢复。 |
| 未保存边界 | 选择期间磁盘仍保留三块标记，索引仍有三个 stage 条目，证明选择只改变草稿。 |
| 保存与解决 | Save & Mark Resolved 成功；独立 Git 断言确认 index 与 worktree 一致、`git ls-files -u` 为空；最终第一块我方、第二块对方、第三块我方后对方的内容完全符合预期。 |

另建只读检查 fixture `/tmp/raygit-resolver-layout-20261003` 验证布局。约1052pt宽的英文原生窗口截图确认所有 Resolver 工具栏文字可读；日文仅在默认窗口宽度确认可读，日文窄窗口尚未验证。用户随后将 UI 切回简体中文，停止更改语言及窗口，尊重用户当前操作。

本次验证产物为 `.artifacts/RayGit.app`，未更新 `/Applications/RayGit.app` 安装副本。本轮结果不等于完整 SmartGit parity：尚无合并结果位于来源窗格下方的布局，也未证明用户真实仓库工作流、深色视觉或全部滚动对齐已验证。

## 2026-10-04 阶段 1：冲突视觉与现有变更统一验收

本轮原生全量 `swift test --build-system native` 共108项、0失败，日志 `/tmp/raygit-conflict-polish-tests.log`；独立插件 `npm test` 共29项通过，日志 `/tmp/raygit-allchanges-plugin-tests.log`。四语言资源检查通过，共22表878键。本机 Release 构建通过，日志 `/tmp/raygit-conflict-polish-build.log`；构建产物和安装副本均通过签名验证，`cmp` 检查确认安装内容与构建产物一致。

真实原生 UI 验收使用三块冲突 fixture `/tmp/raygit-visual-polish-20261004`：

| 验证范围 | 实际结果 |
|---|---|
| 冲突视觉 | 截图确认完整冲突块橙色底、侧轨、当前块边框，以及 Ours 蓝色、Theirs 紫色标识和接受箭头清晰显示。 |
| 导航与单块选择 | 进入下一块并采用对方后，未解决块从3变为2；仅第二块被替换，其他块保留。 |
| 撤销与干净状态 | Cmd-Z 恢复原始3块冲突；普通保存按钮回到禁用状态，草稿恢复干净。本次未点击保存并标记解决。 |
| 深色主题 | 通过实际设置切换深色，确认文本、冲突背景与接受箭头仍可读。 |
| 草稿边界 | 本轮未保存 fixture，未提交合并；上述选择与撤销仅用于内存草稿验收。 |

本轮补充了深色主题和当前冲突视觉的原生证据；不代表全部窗口尺寸、四语视觉、滚动对齐或真实远端操作已经验收。插件测试是独立插件证据，不将其视为原生 UI 页面验收。

## 2026-10-04 阶段 2：原生 UI polish 验收

本轮统一共享语义颜色、34pt 分区标题、文件状态 chip、搜索框、设置分类图标与历史选中反差，并将冲突工具栏调整为两行，保留既有操作。

本机 Release 构建通过，日志 `/tmp/raygit-ui-polish-build.log`；四语言资源检查通过，共22表878键；`git diff --check` 通过。退出旧应用进程后使用 `ditto` 安装到 `/Applications/RayGit.app`，严格 `codesign` 验证与二进制 `cmp` 均通过。

实际 CUA 原生界面验收如下：

| 验证范围 | 实际结果 |
|---|---|
| 工作区 | 临时仓库 `raygit-ui-0afh7eyy` 的浅色工作区确认文件选中状态、状态 chip、差异预览及提交区布局。 |
| 完整历史 | 浅色与深色均确认选中行的引用标记、日期和 hash 清晰可读。 |
| 设置 | 确认通用分类布局与设置分类导航。 |
| 冲突工具栏 | `raygit-visual-polish-20261004` fixture 的深色三栏确认新工具栏完整显示；两种顺序的组合接受入口及 Base 菜单可访问。 |
| 冲突说明 | info popover 完整显示 Stage 2/3、rebase 角色及保存/暂存说明。 |
| 状态恢复与草稿边界 | 验收后恢复原浅色主题；阶段 2 未对 fixture 执行保存或暂存。 |

本次为 UI 调整，没有重复阶段 1 的原生108项与插件29项全量测试。窄窗口与所有语言未重新逐页验收；上述局部原生证据不代表全部页面和状态已验证。

## 2026-10-04 阶段 3：严格差异对齐与共享冲突预览验收

双栏与三栏原生编辑器使用仅用于显示的段后留白与开头留白，保留原文和各版本真实行号；普通三栏保留各对版本的共同锚点，冲突段来源首行对齐结果的开始标记，较短侧补足段后高度。换行与拖动分隔重新计算高度。工作区冲突预览共享三栏彩色阶段视图，所有栏只读且不提供接受操作，编辑与接受仍在独立窗口中完成。

最新定向原生测试 `ComparisonAlignmentTests|TextLineDiffTests|ConflictDraftTests` 共23项全部通过，日志 `/tmp/raygit-alignment-final-tests.log`，包括原生 TextKit 几何验证。本轮较早全量112项通过，日志 `/tmp/raygit-alignment-tests.log`；最终变更后执行的是上述定向测试。本机最终 Release 构建通过，日志 `/tmp/raygit-alignment-final-build.log`。四语言22表879键检查通过。安装副本 `/Applications/RayGit.app` 通过严格签名检查，其可执行文件与构建产物经 `cmp` 确认一致。

| 原生 GUI 范围 | 实际结果 |
|---|---|
| 工作区冲突预览 | `/tmp/raygit-visual-polish-20261004` 确认只读三栏、彩色阶段内容及对齐。 |
| 独立冲突对齐 | 同 fixture 的右栏第14行与结果冲突开始标记第20行同高；空 Ours 保留虚拟留白，块后的上下文对齐。 |
| 采用与撤销 | 第二块采用对方后冲突从3块变为2块；Cmd-Z 恢复3块，保存按钮恢复禁用。插入换行后 Undo 恢复草稿。 |
| 工作区双栏自动换行 | 新 fixture `/var/folders/p9/706zy1rn35l9bjl5jq98b3m40000gn/T/raygit-alignment-_tmmynsf` 的 `TwoPane.txt` 中 `anchor C` 来源第9行与结果第12行同高。 |
| 普通三栏对应锚点 | 同 fixture 的 `ThreePane.txt` 中 HEAD/结果/索引开始行1/3/2、`anchor B` 6/9/6、Unicode 行8/11/9、`anchor C` 9/12/10 均同高。 |
| 分隔调整与滚动到底 | 两次拖动分隔后，结果栏窄至259.5pt；三栏滚动条值均为1，`anchor C` 仍同高。 |

本轮没有保存或提交这些 GUI 测试草稿。最终字节校验确认新 fixture 的 `ThreePane.txt`、`TwoPane.txt`、`Conflict.txt` 三个文件 SHA256 均与原始 manifest 完全相同；原 fixture 的 `resolver-demo.txt` SHA1 保持 `c923f59cbe92dfad1567c93214cf5d0cbd925766`，磁盘内容未改变。验收后已恢复自动换行关闭，分栏接近等宽。以上证据不代表所有语言、主题、大文件性能或用户真实仓库完整工作流已全面验收。

随后工作区普通替换块的行配对改为复用 `ComparisonAlignment`，修复长 Unicode 内容被直接按序配对到错误行的问题；同时修复关闭自动换行时，空白 gutter 小字号造成的行高漂移，高度均衡不再仅在开启自动换行时执行。追加变更重新通过本机 Release 构建，安装副本通过 `codesign` 与可执行文件 `cmp` 检查。

最新版安装包的原生 GUI 确认 `ThreePane.txt` 工作区双栏在关闭自动换行时，`first original` 第2/3行、`anchor B` 第6/9行、Unicode 第9/11行、`anchor C` 第10/12行均像素同高；新增绿、删除红、修改橙及字符级颜色正确。开启自动换行并滚到底后，两栏滚动条值均为1，`anchor C` 第10/12行仍同高。验收后已关闭自动换行。

## 2026-10-04 阶段 4：七张设计稿还原与 AI 提交入口验收

设计路径与原生页面源码映射见 [UI_REDESIGN_20261004.md](UI_REDESIGN_20261004.md)。本机最终应用构建通过；`swift test --build-system native` 全量118项通过。四语言26表981键资源检查通过。使用 `ditto` 更新 `/Applications/RayGit.app`，安装副本通过严格 `codesign` 验证，其可执行文件与本地构建产物经 `cmp` 确认一致。此处不记录尚未完成的 Git 提交为成功。

本轮局部原生 GUI 和 Git 操作证据如下：

| 验证范围 | 实际结果及边界 |
| --- | --- |
| 主窗口 | 已查看新的工作区布局；不等于所有空态、错误态或完整历史操作已重测。 |
| 网络页面 | fixture 真实 `upstream/main` 与 ahead 0 / behind 0 正确显示；本地 bare origin 的 Fetch 成功。未据此宣称互联网远端 Pull / Push 可用。 |
| 标签页面 | 两个真实标签可见；创建表单展示轻量 / 注释 / 签名类型。未创建、签名或推送标签。 |
| 编辑器设置 | 卡片与开关实时可见；未点击恢复默认。 |
| Rebase 脏状态 | 脏 fixture 加载正确提示需要干净工作区；干净 fixture 加载及执行尚待补充。 |
| 普通比较 | 实际三栏顺序为 HEAD / Index / Worktree；输入 `QA` 后 Undo 恢复干净草稿；换行开关有效。 |
| 冲突与 Base | `/tmp/raygit-visual-polish-20261004` 中导航第二块成功；展开 Base 显示真实祖先内容。采用 Theirs 后3块变2块，Cmd-Z 恢复3块且草稿干净。 |
| 内存 / 磁盘边界 | 本轮未保存或暂存冲突测试草稿。`resolver-demo.txt` SHA1 保持 `c923f59cbe92dfad1567c93214cf5d0cbd925766`，磁盘内容未变。 |
| AI CLI 合成调用 | 首次实际调用因提供方路由失败；修正白名单传输配置后，真实 Codex CLI 的合成输入调用成功。安装版最终 AI GUI 仍待验收，不等于真实已暂存内容到 GUI 草稿的全流程已证明。 |

截图目录 `/tmp/raygit-design-review/` 中保存 `network.png`、`tags.png`、`tag-create.png`、`editor-settings.png`、`compare.png`、`compare-wrapped.png`、`conflict-base.png`。初始视觉基线测量值65.04、覆盖率100%；首轮改版测量值74、覆盖率89.31%。之后工具栏几何已修订，最终截图及测量尚待补；不同覆盖率的局部比较不能当作最终整体还原度，不宣称95%还原。

本轮仍未完成：干净 fixture 的 Rebase、安装版最终 AI 生成、最终工具栏截图与相似度、完整四语言逐页与深色主题、OpenAI 兼容 API、真实互联网远端推送、缺少 CLI 等失败情形，以及取消 / 超时与并发草稿变化的安装版专项。早期阶段的行对齐和保存解决证据继续有效，但不能据此声称本轮全部新增界面与操作已重测。

### 2026-10-04 设计稿还原最终补充

- 安装版AI按钮连续两次成功：`Describe RayGit features in README`、`Describe RayGit capabilities in README`。仅合成fixture暂存README送入当前Codex提供方，HEAD仍为85914f028ba1bac70eae9bd691c74ef430af3be7，暂存仍README两行新增；没有自动提交。
- `swift test --build-system native --filter 'AICommitDraftGuardTests|BoundedProcessTests'` 4项通过，涵盖草稿拒绝条件与进程成功/取消/超时；GUI取消尝试时请求已结束，不能算GUI取消验证。
- 干净副本Rebase读取HEAD~3显示3个真实提交、作者和时间，修改pick为reword后预览同步；未执行历史重写。Cmd-K文件搜索有效。
- 最终本地打包、严格签名、安装二进制cmp通过，重新启动确认工具栏独立无障碍名称。测试开启的换行已恢复关闭。
- 最终主窗口视觉比较73.39%，可比覆盖99.31%，未达95%。报告`/tmp/raygit-design-review/after-3/report.md`；内容/视口和原生控件仍有差异，不将该值宣称为七张设计图的整体还原度。

### 2026-10-04 差异符号和栏间采用按钮

- 工作区并排差异增加红色 `−` / 绿色 `+` 固定标记列，替换行分别显示删除/新增底色；上下文、hunk和虚拟占位没有符号。标准复制排除并排显示装饰；统一视图保留原有复制/搜索语义（源码复核，未单独执行剪贴板验收）。
- 原生编辑器显示独立符号列，符号与行底色跟随用户差异颜色配置；关闭行号仍保留符号。冲突结果保留其分段颜色。
- 原生32pt栏间按钮：结果左边蓝色右箭头采用Ours，右边绿色左箭头采用Theirs；普通比较支持相邻来源版本采用到可编辑工作区。按钮带无障碍名称，按块几何定位并随滚动刷新。
- 本机 `swift test --build-system native --filter 'ComparisonAlignmentTests|AdvancedDiffTests|FileComparisonTests|ComparisonPresentationTests|DiffParserTests'` 28项通过；本地打包、`git diff --check`、安装签名严格校验和二进制cmp通过。
- 安装版GUI验证：工作区实际出现红删绿增符号；普通Index→Worktree按钮替换对应块，Cmd-Z恢复干净草稿；冲突Theirs左箭头使3块变2块，Cmd-Z恢复3块；关闭行号时Ours右箭头也可用，并可撤销。行号恢复开启，4个fixture文件SHA256均保持原样，未保存/暂存测试草稿。
- 最终截图目录 `/tmp/raygit-markers-review/`：`workspace.png`、`ordinary.png`、`ordinary-no-numbers.png`、`conflict-final.png`。后者来自最终颜色修正安装版；早期ordinary截图尚有后续修复的HEAD跨栏颜色差异。不声称像素级还原或已穷尽深色/自定义颜色/超长文件滚动验收。

- 最终长行检查发现一次真实回归：新增箭头栏后，自动换行的测量容器宽度与 TextKit 最终宽度相差水平内边距16pt，导致 Worktree 的 `anchor C` 提前一行。修复统一以实际 clip 宽度减去内边距设置容器，在测量前落实栏间按钮约束，`sizeToFit` 后保持栏宽；几何再变更时重新对齐。
- 新增同一组 AppKit 视图重复调整栏宽、36pt箭头占宽、换行开关和 Unicode 内容的回归测试，检查尾部锚点同高、容器宽度稳定和原文不变。修复后的28项相关测试全部通过。
- 最终安装版 GUI 再验：三栏打开、两次分隔调整、关闭/恢复行号后，HEAD第9行、Index第10行、Worktree第12行的 `anchor C` 均同高；蓝色箭头采用后撤销恢复干净草稿。冲突绿色箭头采用使3块变2块，撤销恢复3块且保存禁用，冲突后的共同上下文仍同高。换行和行号均保留开启，4个fixture文件最终SHA256均不变。
- 最终有效截图：`/tmp/raygit-markers-review/ordinary-aligned-final.png`、`/tmp/raygit-markers-review/conflict-aligned-final.png`。`ordinary-final.png` 保留作为修复前的一行偏移证据。

### 2026-10-04 保存解决后保留比较来源与编辑撤销

- 比较窗口保留打开时的 HEAD / Index / Ours / Theirs / Base；保存、暂存及标记解决只更新磁盘与索引操作的预期状态，不自动重新加载比较来源。手动重新加载仍可更新来源。历史保留范围为当前打开的比较窗口，不跨关闭或应用重启。
- 结果编辑器使用独立原生 UndoManager；键入、粘贴、冲突块选择、栏间采用、整份版本替换共用撤销历史。临时忙碌和切换补丁视图不销毁编辑器历史，独立窗口处理 Cmd-Z / Shift-Cmd-Z，增加撤销/重做按钮。
- 全量127项测试通过（`/tmp/raygit-undo-tests.log`）；最终快捷键修正后8项定向 AppKit / 会话测试通过（`/tmp/raygit-undo-final-tests.log`）。覆盖独立撤销分组、Unicode、临时只读，以及真实 Git 保存解决后来源保留、再次保存、外部磁盘/索引变更拒绝。
- 安装版真实 fixture `raygit-undo-nw6mag0i`：第一块采用我方、第二块采用对方，保存并标记解决后，两次 Cmd-Z 恢复两块原始冲突，两次 Shift-Cmd-Z 恢复已保存结果；来源仍为 Ours `3d17a6b5`、Theirs `2440ad64`、Base `4b4d5930`。
- GUI 另验粘贴的撤销与重做、整份我方替换的撤销、补丁→自动布局后继续快捷键撤销。搜索框获得焦点时 Cmd-Z 未改动结果草稿；本次没有证明搜索框自身的文本撤销有效。
- 撤销只更新草稿：草稿恢复冲突期间，磁盘和索引均保持已解决内容，`git status --short` 为 `M  Undo.txt`。写回仍需显式保存/暂存。此次 Git 写操作仅用于新建的可丢弃 fixture。
- 最终截图检查发现 ZStack 可能把正文压缩为零，已补齐剩余高度和最小高度约束。本地再次 Release 打包通过（`/tmp/raygit-undo-layout-build.log`），安装副本严格签名及二进制 `cmp` 通过。最终安装版再次用两侧栏间箭头解决两块、保存暂存、连续快捷键撤销/重做，正文完整可见，原始来源不变。最终有效截图：`/tmp/raygit-undo-review/final-restored-conflicts.png`、`/tmp/raygit-undo-review/final-resolved-with-history.png`；较早 `resolved-with-history.png` 是高度修复前证据。

### 2026-10-04 对比工具首次自动定位差异

- 独立原生文本对比窗口显式开启首次定位；等待窗口挂载、各栏视口有效和严格对齐布局稳定后，直接读取最早实际差异范围，统一滚动各栏并保留24pt上文。首次处理一次，无差异也消费标记；后续编辑、布局及搜索/手动导航不重复触发。共享工作区与Base只读面板保持原行为。
- `swift test --build-system native --filter 'ComparisonInitialNavigationTests|ComparisonUndoTests|FileCompareSessionTests'` 共12项通过。新增4项覆盖首个差异在长文件中、首行差异不跳第二块、无差异后的来源刷新不重跳、仅删除与默认关闭。首次测试窗口生命周期/分栏几何问题已修复，最终无失败。
- 本地release打包通过；更新`/Applications/RayGit.app`后严格签名和二进制cmp通过。真实GUI fixture `raygit-first-change-8epcvg05`：双栏打开LongCompare.txt直接显示160行首个差异，切换三栏三侧滚动值均0.7875664893617021；ConflictLater.txt直接显示140行冲突，三侧滚动值均0.7963818321785989。无保存/暂存操作。
- 截图：`/tmp/raygit-first-change-three.png`、`/tmp/raygit-first-change-conflict.png`。本轮覆盖普通原生双/三栏及冲突编辑器；未更改大文件分页/流式、媒体或历史补丁的展示逻辑。

### 2026-10-04 对比窗口紧凑布局

- 普通对比顶部合并为两行32pt工具栏，冲突对比仅增加一行32pt冲突操作；移除独立关系说明条，帮助保留在图标提示/弹出内容中，组合采用收进更多菜单。布局切换改为菜单，显示开关改为带辅助功能标签的图标按钮；保存/暂存保持可见。
- 行号栏从固定72pt改为按行号位数与字体测量，文本水平inset由8pt缩为3pt、lineFragmentPadding由5pt缩为2pt，箭头栏36→28pt、点击区域24×32pt，分栏标题44→28pt。工作区共享编辑器同步受益。
- GUI发现长文本的NSTextView在初始赋值/sizeToFit后可留下负frame.origin，导致正文与gutter/箭头坐标不一致；在挂载文档前及fitDocument后归零。新增真实AppKit长文件四次resize回归，移除修复可复现24处断言失败。最终16项坐标、首次导航、撤销、核心对齐测试通过；四语言983键检查与git diff --check通过。
- 本地release构建及安装至`/Applications/RayGit.app`完成，严格签名与可执行文件cmp通过。日志：`/tmp/raygit-compact-final-tests.log`、`/tmp/raygit-compact-final-build.log`。
- 最终安装版GUI：LongCompare首次显示第160行，双栏/三栏滚动值均0.8121565934065934；三栏窗口1400→1050pt仍保持第160行及后续上下文同高。ConflictLater首次显示第140行，三侧滚动值均0.8421696574225123；栏间我方箭头采用后冲突清零，Cmd-Z恢复1块且保存禁用；窄窗口仍保持三栏共同上下文对齐及顶部控件完整。未保存/暂存，两个fixture文件SHA256均与验证前一致。换行/行号/同步滚动保持开启。
- 同尺寸冲突截图比较，正文顶部从约284pt缩至158pt，新增约126pt代码显示高度。有效截图：`/tmp/raygit-compact-before.png`、`/tmp/raygit-compact-after.png`、`/tmp/raygit-compact-ordinary.png`、`/tmp/raygit-compact-three-narrow.png`、`/tmp/raygit-compact-conflict-narrow.png`。未穷尽大字号、六位行号、所有语言和媒体/分页比较的GUI验证。

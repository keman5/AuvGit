# 当前验收记录

## 2026-10-13 至 14 历史及贮藏版本副本编辑

- 历史提交和贮藏的单文件比较接入 `FileCompareSession`。HEAD、索引、父版本、选中版本、工作区及冲突源列分别保留草稿；历史三栏布局增加当前工作区副本。编辑、撤销、重做、搜索替换针对当前列，布局切换保留主编辑器各列的草稿及撤销记录。
- 保存只将选中的已修改副本写入当前工作区；其余草稿留在窗口中，Git 历史、贮藏及索引不会被普通保存修改。关闭提供保存、放弃草稿、取消；多列未保存时明确说明保存哪列及其余副本将被放弃。已从工作区删除的历史文件可安全创建，保留 Git 执行模式，拒绝覆盖后来创建的文件及穿过符号链接的路径。
- `./scripts/validate-project-switch.sh revision-edit`：37 项专项测试全部通过、0 失败。包括新六项历史/贮藏/多副本/原生撤销和搜索/外部变化/历史执行文件恢复回归，以及原有冲突保存、文件比较、搜索、初始导航、滚动对齐、本地化测试。未重跑全套测试；测试中的离屏 Environment 和既有 SDK 警告不作为实机证据。
- 四语言、43 表、1434 个文案键的静态本地化检查通过，`git diff --check` 与脚本语法检查通过。本地 `./scripts/build-app.sh --no-install` release 构建通过，随后 `./scripts/install-local-app.sh` 签名与安装二进制一致性校验通过，已启动 `/Applications/RayGit.app`。
- `python3 scripts/prepare-response-qa.py --revision-edit` 创建独立应用与临时仓库。CUA 实测历史左右列输入、关闭取消保留、三栏切换、保存父版本副本且另一草稿仍在、保存后撤销/重做、放弃剩余草稿关闭；贮藏未跟踪文件输入后通过关闭提示保存并创建工作区文件。独立 Git 读回确认只有一项未暂存修改和一个未跟踪文件，HEAD、索引、历史内容、贮藏原内容及贮藏 OID 均保持不变。业务仓库未用于保存测试，QA 应用已正常退出，正式应用恢复用户当前仓库。
- 边界：二进制、混合行尾、只读权限和超过 2 MiB 的文本仍保留既有编辑保护；历史窗口不提供针对当前索引的部分暂存补丁布局。原生实际点击没有覆盖全部冲突源列或外部比较器往返，相关会话与原生编辑行为由上述回归覆盖。隔离日志窗口曾显示 Git 辅助程序输出流提示，比较草稿加载及保存成功，未在本轮扩展排查该提示。

本轮未暂存、提交、推送或创建 worktree。测试和构建日志：`/tmp/raygit-revision-edit-tests.log`、`/tmp/raygit-revision-edit-build.log`；隔离仓库根路径记录于 `/tmp/raygit-response-qa-path`。

最后仅修正历史窗口版本菜单的显示标签，使用提交版本号而非 HEAD/索引；随后 release 重构建并重新安装启动成功。最终构建与安装程序 SHA-256 均为 `b55945ffaa9339ae0ed620edae8d7cf52a91e947b1dd24e79b118b06c22cf200`。37 项测试与隔离 GUI 验收在这次标签修正前完成，最后的标签修正通过 release 编译及本地化检查，未重复整个 GUI 流程。

## 早期验收记录

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

### 2026-10-04 单行对比、状态图标与独立日志窗口

- 对比顶部合并为单行主工具栏，完整文件路径移到原生标题栏。两栏/三栏在切换和窗口缩放时等宽；栏间箭头缩为20×24pt，预留24pt栏位，不因接受全部变化或忙碌状态收缩。关闭确认返回后先显式移除确认窗口，再关闭对比窗口。
- 工作区删除工作区/提交历史切换整行，将范围、忽略空白和编辑入口移入差异区现有三点菜单；所有省略号更多菜单隐藏下拉标记。文件状态采用8种图标筛选，新增点路径隐藏文件显示与真实Git忽略文件只读列表。树形视图支持状态/搜索/隐藏筛选，显示忽略文件时切换到列表。
- 实际检查本机SmartGit 26.1日志窗口后新增Cmd-L独立日志：左引用/分支/标签、上部提交图与右侧提交详情/文件、底部跨宽差异。每仓库复用窗口，独立RepositoryStore不写主会话；关闭释放监听和安全作用域访问；日志置前时Cmd-R刷新日志，主工作区暂存/提交快捷键禁用。
- 首轮完整测试发现旧divider约束在resize后恢复手动拖动比例；改为AppKit布局后更新divider位置。最终全量137项测试0失败（`/tmp/raygit-compact-ui-final-tests.log`），22项定向测试0失败（`/tmp/raygit-compact-ui-focused.log`）。本地Release构建、安装至`/Applications/RayGit.app`、严格签名检查和二进制cmp通过（`/tmp/raygit-compact-ui-build.log`）。
- 已安装应用GUI验证使用新建可丢弃fixture `raygit-compact-ui-2tmxuwii`：隐藏开关移除`.hidden-demo.txt`；忽略开关显示`ignored-demo.log`且菜单仅Finder显示/复制；已修改筛选在树中仅显示`long-compare.txt`。Cmd-L显示6个提交，选中提交联动Config.swift及真实补丁；标签v0.1.0范围缩为2个提交；再次Cmd-L保留同窗和选择，关闭后工作区仍为原3个变化。
- 对比GUI验证：标题栏为完整路径、主控件单行、双栏699.5pt、三栏466pt均分；首次定位160行。采用索引块后点击关闭→放弃草稿，随后AX直接返回工作区，确认框和比较窗均无残留；磁盘逐字验证仍保留原`Changed line 160`，没有保存或暂存。布局缩放和接受全部后固定栏宽另由AppKit回归测试覆盖。
- 截图：`/tmp/raygit-compact-log.png`、`/tmp/raygit-compact-three.png`。未在GUI穷尽日志写操作、所有语言和所有极端窗口尺寸；隐藏文件开关按路径中的点文件/点目录判断，未扩展Finder隐藏属性。

### 2026-10-04 主工具栏、设置点击区域与网络认证

- 主工具栏移除仓库切换，默认 Pull / Push、弹性间距、暂存 / 取消暂存 / 丢弃 / 贮藏 / 应用贮藏、弹性间距、刷新 / 创建仓库。自定义面板暴露原生普通和可调间距；文件操作按有效选择启用，应用贮藏主操作与 Cmd-Shift-S 应用最新记录并保留确认，菜单可选其他记录。
- 设置侧栏图标由18pt改为14pt，完整padding后的矩形作为点击区域。安装版点击编辑器分类最右侧空白后成功切换页面。
- 实际报错为 GitHub HTTPS 无法取得用户名且 askpass 被禁用。本机gh已有登录，而默认钥匙串helper未返回凭据；网络命令以仅github.com生效的命令级helper回退复用gh，原有helper优先，不写仓库或全局Git配置。显式askpass不再被覆盖；失败时保留stderr与stdout的完整诊断。
- 全量139项测试0失败（`/tmp/raygit-toolbar-test.log`）；四语言28表1011键检查及git diff --check通过。Release构建、安装、严格签名验证与二进制cmp通过（`/tmp/raygit-toolbar-build.log`）。
- 安装版使用独立本地`raygit-toolbar-hxlo35cd/Toolbar QA`及裸仓库：暂存0→1→取消暂存0；丢弃仅测试文件恢复干净；Cmd-Shift-S确认后恢复stash.txt且贮藏记录保留；工具栏贮藏后工作区干净。Pull得到Incoming测试提交和实际文件，Push后裸仓库HEAD与本地新提交相同。Rayon仅执行相同认证回退的只读ls-remote并成功，未实际推送真实仓库。
- 自定义面板已显示原生间距选项；添加一次后偏好文件记录三个NSToolbarFlexibleSpaceItem（含两个默认项）。继续添加及重启恢复验证时Mac锁屏，剩余GUI验收待解锁；不将已保存配置视为重启恢复证据。

### 2026-10-04 紧凑操作、表格排序与失败日志

- 顶部操作使用紧凑图标加文字，应用贮藏默认合入更多菜单；提交选项移至右上，底部提交与修订复选框同行。应用自绘圆角不超过10pt，主界面、比较、日志及设置按钮边框统一6pt；系统原生窗口和菜单外框由macOS控制。
- 文件表五列接入原生排序及箭头；无选择时暂存/取消暂存/丢弃解析全部符合条件文件，已有选择则限定选择。丢弃仍确认且排除未跟踪、忽略及冲突文件。仓库按钮使用无额外顶部inset的ScrollView，点击与右键区域同宽；同步图标使用本地upstream计数及冲突状态，不主动fetch。
- Git命令日志包含实际argv（敏感配置脱敏）、目录、输出、退出码、时间和耗时，保留最近300条，详情默认收起。无变化轮询和可选upstream探测不刷日志；常见失败摘要支持四语言。专用弹窗失败也桥接到底部状态栏，无CLI的校验失败单独记录，不伪造命令。
- 最终逻辑版本全量146项测试0失败（`/tmp/raygit-polish-final-tests.log`）；四语言31表1045键检查通过。随后仅按钮形状及仓库列表容器调整，经Release构建及安装版检查。最终本地Release、安装`/Applications/RayGit.app`、严格签名及二进制cmp通过（`/tmp/raygit-polish-build.log`）。
- 安装版临时仓库`raygit-polish-qa-zs5d8pok`中无选中项暂存1→4、取消暂存4→0；丢弃确认准确列出3个tracked文件并排除New.txt，随后取消。名称表头切换升降序及箭头已观察。实际模拟本地tracking refs分别验证可推送1、可拉取1、推送1且拉取1图标；既有冲突fixture显示冲突图标；右键仓库无延长的外围选中框。
- 打开非仓库目录后底部显示“此目录不是 Git 仓库”，点击日志初始全部折叠，展开可见`git --no-pager rev-parse --show-toplevel`、退出128与原始fatal文本。历史窗口alternate→main均自动选择首条，选中文字和标签白色可读；“合并”名称已生效。截图：`/tmp/raygit-polish-operation-log.png`、`/tmp/raygit-polish-history.png`。未穷尽各语言GUI和所有专用弹窗的失败路径；丢弃实际写入沿用核心回归覆盖，本轮GUI仅确认范围。

### 2026-10-04 图标、贮藏日志与静态文件预览

- 本机 SmartGit 26.1 只读参考后重新设计主工具栏图标：24×23pt 轮廓加彩色操作角标，遵循原生“仅图标 / 图标和文本”模式。应用贮藏采用独立主操作与下拉列表的合并按钮，无记录禁用，长记录名称截断；修复原生 split Menu 仅抽取首个 SF Symbol 导致角标丢失的问题，使用完整图像桥接。
- 文件状态筛选去除背景及额外padding，隐藏与忽略图标区分，移除重命名筛选入口；文件行按状态显示角标，仓库保留文件夹并叠加同步/冲突指示。默认名称、状态、相对目录三列，表头原生右键菜单可开启工作区/索引列，首屏文件区300pt。修订勾选不显示内联警告，搜索占位符不浮动，干净文案更新。
- 贮藏“显示变更”打开独立日志并固定选择实际stash提交，包含第三父提交中的未跟踪文件；历史右键首项查看日志、第二项提交详情。设置提交模板使用原生文件选择器，配置只写当前仓库。操作日志默认折叠，详情使用可选择的原生文本视图，最后展开/点击详情获得Cmd-A/C响应。
- 工作区、历史及独立比较支持直接显示常见栅格图片；工作区明确索引→磁盘、已暂存明确HEAD→索引。超过32MiB的二进制仅采样4096字节并显示实际字节数，不执行文本差异；二进制无定义的字符数不作虚构。已支持的大型UTF-8文本流式比较保留。图片解码限制源像素和缩略图尺寸，HTML/SVG不执行。
- 完整153项测试通过（`/tmp/raygit-refine-tests.log`）；此前定向15项通过（`/tmp/raygit-refine-focused.log`），覆盖stash固定引用/未跟踪、索引及历史版本映射、超大文件采样、UTF-8边界及Git进程有界终止。采样读满后Git辅助进程未退出的超时误判由真实回归测试发现并修复。完整测试后仅工具栏图像桥接和翻译调整，经最终Release构建验证。四语言32表1061键及git diff --check通过；本地构建安装`/Applications/RayGit.app`，严格签名与二进制cmp通过（`/tmp/raygit-refine-final-build.log`）。
- 安装版临时仓库`raygit-refine-qa-6n9n7lp3`实测：原生图标/文字两种模式、贮藏截断列表、300pt分隔位置、右键显示/隐藏工作区列、修订无警告；设置LocalTemplate.txt后仓库config与提交框均为模板内容。工作区Preview.png显示橙色索引/紫色磁盘，暂存范围显示绿色HEAD/橙色索引；独立图片窗口正常渲染。40MiB Large.bin在主窗口及独立窗口均显示41,943,040字节摘要，无全文比较错误。
- 旧贮藏50d5cc28自动选中并显示Notes.txt及StashOnly.txt，未跟踪补丁为`untracked stash payload`；搜索框获得焦点后占位符位置稳定。日志两条依次展开后Cmd-A各自选择最新详情，Cmd-C粘贴回测试提交框验证完整命令/退出码/输出，随后清空输入。干净fixture`raygit-design-rebase-clean`显示“工作区很干净”且应用贮藏禁用。未操作业务仓库、未提交fixture内容。
- 截图：`/tmp/raygit-refine-final-main.png`、`/tmp/raygit-refine-image-worktree.png`、`/tmp/raygit-refine-stash-history.png`。GUI以PNG及40MiB二进制为代表，未逐一实测全部图片编码、深色模式及所有语言。


### 2026-10-04 差异行号、搜索替换、紧凑模式与安静刷新

- 主差异视图按解析后的行类型隐藏文件模式、补丁头及hunk元数据，真实文件中的`@@`文本保留；并排/合并保留原始行号、对齐占位，变更背景覆盖行号。首次定位以文件及版本身份标识区分，同一文件安静刷新保留滚动。独立比较和冲突预览同样覆盖行号并定位首个变更。
- 主窗口及独立比较采用搜索弹窗，支持大小写、正则、前后匹配、替换及全部替换；只读预览可携带查询、选项和替换模板打开编辑器。替换仅修改可编辑工作区草稿，原生一次Undo/Redo；正则保留完整匹配上下文及捕获组。完整测试发现groupsByEvent=false时关闭Undo组后设置actionName会触发AppKit异常，已将命名移至组关闭前并增加具名冲突撤销断言。
- 紧凑模式仅显示差异并保持真实行号及各栏占位。独立比较的紧凑视图是只读投影，完整编辑器保留挂载以保留草稿和撤销，可返回编辑；任一版本超过2MiB进入分页/流式路径时，本轮搜索与紧凑功能禁用并说明限制。
- 日志显示菜单支持作者头像/姓名、远程分支及标签；详情分别显示作者和提交者姓名、邮箱及时间。GitHub noreply身份使用真实用户名头像，其他有效邮箱使用Gravatar，失败显示默认图标；不会凭时间差断言某次操作为amend。自绘圆角最大8pt，系统窗口外框及系统弹出容器由macOS管理。
- 重复点击同一仓库（含符号链接规范化路径）只读文件状态；不重开历史，不切isBusy，不重扫近期仓库；状态相同但正文改变仍刷新差异。并发打开/修改使旧刷新结果失效，防止覆盖新状态。
- 完整165项测试0失败（`/tmp/raygit-search-final-tests.log`）；定向搜索/撤销9项通过。完整测试后仅搜索上下按钮热区改为24×24，最终Release构建覆盖该调整。四语言35表1094键及git diff --check通过。本地Release构建并安装`/Applications/RayGit.app`，严格签名验证与二进制cmp通过（`/tmp/raygit-search-build.log`）。
- 安装版`raygit-search-qa-2pm37fpz`实测：主工作区索引→工作区标题、81/160行红绿背景包含行号，紧凑模式只显示81/160/161行及空占位；Added.txt无补丁元数据且真实`@@ literal content must stay`仍显示。大小写ALPHA匹配1处，无效`[`正则显示错误且禁用替换入口；query `item-(\d+)`与replacement `token-$1`及两个选项完整传入独立编辑器，工作区显示4处匹配。
- 独立三栏初始显示首变更80行，HEAD/索引/工作区标题明确；全部替换得到token-124/457/790/999，Cmd-Z一次还原、Cmd-Shift-Z一次重做，切换紧凑再返回仍能一次撤销。测试未保存草稿，文件SHA256保持原值。主窗口重复点击当前仓库保留Example筛选及Example.swift选择；临时将item-457改为458（仍为M状态）后正文及时更新，再恢复并验证SHA256。
- 独立日志合成提交实际显示作者Octocat、GitHub noreply邮箱、作者时间2026/9/1 12:00和提交者RayGit Search QA、提交时间2026/10/4 10:00；GitHub头像已实际加载，远程分支显示选项可切换。`raygit-first-change-8epcvg05`主冲突预览打开即显示140行及三栏高亮行号。未穷尽所有语言、深色模式和全部平台头像来源的GUI。
- 截图：`/tmp/raygit-search-main.png`、`/tmp/raygit-search-main-compact.png`、`/tmp/raygit-search-editor-compact.png`、`/tmp/raygit-search-history.png`、`/tmp/raygit-search-conflict-first.png`。本轮未创建提交。


### 2026-10-04 完整差异导航、大文件搜索与日志输出 QA（待最终安装验收）

- 本轮 GUI 使用独立 bundle ID `dev.raygit.qa` 与可丢弃 fixture `/tmp/raygit-complete-qa-path`。以下是独立 QA 应用证据，不代表当前 `/Applications/RayGit.app` 官方安装版已包含或验收这些修改；最终安装结果待补。Mac 随后锁定，阻止了剩余 GUI 复测与安装。
- 全量183项测试0失败（`/tmp/raygit-complete-all-tests.log`）。后续分页/媒体修复另有22项回归测试通过（`/tmp/raygit-paging-media-regressions.log`）；不将后续定向通过表述为修改后再次全量通过。
- 独立原生三栏关闭手动同步滚动后，下一处变化仍主动定位全部栏：两次观察到三栏滚动值分别完全一致为 `0.542137`、`0.857180`，其中覆盖纯删除变更。主预览下一处变化时两侧滚动值同为 `0.427884`。
- 原生查找 `NEW INSERT` 显示2项匹配；Return 导航后三栏滚动值同为 `1`。鼠标可点击替换框并输入 `QA INSERT`；全部替换后 Escape 返回编辑器，Cmd-Z一次恢复原草稿且 Save 禁用。紧凑视图点击工作区第140行后返回完整编辑器并精确选中第140行，三栏滚动值同为 `0.542137`，Redo 仍保留。
- 本地与远程同名 `origin/main` 的碰撞 fixture 实测选择远程 `origin/main`，首个提交为 `f85a848a`，未误选同名本地分支。
- 3.4 MB 分页文本及43 MB流式文本查找 `ALPHA` 均得到2项结果；跳转第20000行后仍保留真实 `020000` 行前缀。流式紧凑视图显示2个hunk。分页下一页的 GUI 验证发现错误，随后已修复并由上述22项回归测试覆盖；该修复后的下一页 GUI 尚待复测。本轮大文件搜索/只读紧凑能力替代上一轮超过2 MiB时禁用这些功能的限制。
- ASCII PDF 的 GUI 验证发现其误入文本编辑器。随后已修复 core 静态文档识别与 `CompareWindow` 的 PDF/SVG 大文件分支条件，并由后续定向测试覆盖；修复后 GUI 尚待复测，不声称已在窗口确认正确渲染。
- 操作日志默认收起。展开长日志显示32K预览截断提示，完整查看窗口可见末尾 `END_OF_COMPLETE_LOG_OUTPUT`，原生 Cmd-A全选通过。导出至 fixture 内 `RayGit-operation.txt`，文件大小88,384字节，末尾标记完整保留。完整脱敏输出与预览边界明确，存档有有限预算及生命周期；进程输出超过32 MiB时明确提示未捕获完整输出。
- 主窗口 shell 的全屏进入/退出、标题、自定义“图标和文字”及间距、关闭/重开已进行 GUI 验证。CUA 坐标拖动因 `noWindowsAvailable` 未能验证；仅补有窗口几何回归覆盖，不将其视为实际鼠标拖动通过。
- 最终合并分页、静态文档识别、默认8pt外壳、正常窗口位置持久化及八边缩放几何后，重新执行 `swift test --build-system native`：189项全部通过（`/tmp/raygit-final-all-tests.log`）。四语言37表1128键检查及 `git diff --check` 通过。首次三栏测试布局仍记录一次约束告警，具体约束被系统隐藏；最终几何断言与现有三栏GUI证据通过，未将此告警视作已彻底消除。
- 最终本地 Release 构建成功（`/tmp/raygit-complete-release.log`），产物 `.artifacts/RayGit.app` 严格签名检查通过。打包签名会改变可执行文件，不能与 linker-signed 构建直接逐字比较；另行解析 Mach-O，全部40个实际落盘代码和数据 section 的长度及 SHA256 均与本次 native Release 构建一致。打包脚本使用 `--show-bin-path` 的真实 native 输出目录，避免 `.build/release` 指向旧构建。锁屏仍阻止最终 GUI 复测与正式应用替换，本轮没有安装至 `/Applications` 或创建 Git 提交。

### 2026-10-04 分支切换、主日志范围与搜索框基线

- 只读检查真实 `team-mind` 与本机 SmartGit 26.1：SmartGit 主窗口 Kevin 日志可见顺序为 `7af1d0e7 / dd9ca0a5 / 1b8c4cdc / 6f0c2b1c / 51794302`，与 `git log --first-parent Kevin` 一致；旧 RayGit 主窗口使用所有引用，首两项为无关分支 `3fb142de / 4b01ea2d`。快照计数：所有引用224，Kevin完整可达205/主线138，dev完整可达76/主线5。
- 主日志默认跟随HEAD并仅显示第一父链，切换分支或HEAD改变后清除过期选择、自动选择首条并滚到顶部，不注入旧分支提交。日志更多菜单的“显示合并进来的提交”可切换当前HEAD完整图并保存偏好；独立日志窗口仍保留所有引用及完整图。图形仅绘制实际可见父链，原始父提交元数据保留。
- 分支切换在操作锁内读取最新状态；干净直接切换，有暂存、未暂存或未跟踪变化时才确认，确认后再次读取状态。取消无失败提示；不使用强制切换，保留Git覆盖保护。搜索输入使用原生单行NSTextField，绑定和250ms搜索节流保持原状。
- 全量196项测试0失败（`/tmp/raygit-history-final-tests.log`），四语言37表1129键及 `git diff --check` 通过。覆盖陈旧状态缓存、确认期间新变更、取消、覆盖保护、外部切换后的主日志更新、空HEAD及完整/主线范围。首次测试编译发现断言访问private属性，改为断言已有公开错误状态后完成全量通过。
- 独立QA使用真实仓库的本地副本 `/tmp/raygit-history-qa-path`，Kevin→dev→Kevin均不弹确认；dev显示上述5条主线并选中 `2aaa743a`，开启合并选项后显示76条完整历史。新增测试文件后切换弹确认，取消保留Kevin及文件，随后清理该自建文件。真实team-mind始终处于Kevin且干净，未切换或写入其内容。
- 搜索 `main` 在dev主线只显示 `78acaab4`，清除恢复5条。激活前后截图 `/tmp/raygit-history-placeholder-unfocused.png` 与 `/tmp/raygit-history-placeholder-focused.png` 中，占位文字内区 `(700,1230)..<(960,1273)` 共11180像素逐点一致；排除插入光标区域，验证没有向上位移。
- 本地Release成功（`/tmp/raygit-history-release.log`），正常退出正式应用后安装 `/Applications/RayGit.app`，严格签名及包内二进制cmp通过。重新启动的正式版在真实team-mind显示与SmartGit一致的Kevin前5条，并自动选中首条。本轮未创建Git提交。上一轮PDF识别修复也在新QA主窗口观察到PDF第1页图像及页数信息；独立PDF窗口、分页下一页和物理八边缩放仍未在本轮重测。

### 2026-10-04 贮藏取消、变更概览、解码预览与读取优化

- 使用独立 `dev.raygit.qa` 和合成仓库 `/tmp/raygit-density-qa-path`，包含6000行导航文件（第80/3000/5800行变化）、Vue、Gradle、Dockerfile、自定义扩展及UTF-16文件。全量209项0失败（`/tmp/raygit-density-final-tests.log`）发生在最后UTF-16调用集成及EOF修正之前；随后相关15项定向测试0失败（`/tmp/raygit-density-decoded-tests.log`），不表述为这些后续修改再次全量通过。
- 贮藏确认的取消按钮已在外部AX中启用，点击取消及Escape均实际关闭弹窗；未执行贮藏。Apply主操作与下拉为无内部分隔线的整体样式，列表可选实际记录，长记录名称截断。提交详情已实测QACommitter / QAOriginalAuthor身份显示，已移除文件历史入口。
- 主预览两处概览标记点击后两侧滚动值同为1；独立原生三栏第三标记定位第5800行，关闭手动同步后仍主动移动全部栏，三栏滚动值同为 `0.9740812509`。紧凑投影显示三处变化；自定义 `.raycode` 与UTF-16独立比较实际渲染。概览重复tile/resize及滚动条隐藏切换、标记端点映射、保留的真实原生AX按钮及点击动作有回归覆盖。
- 3.4MB分页文件点击第二标记从第20000行开始，下一页从20500开始。43MB流式文件点击第二标记已加载19997附近上下文；精确选中实际变更行及过期状态文案仍由后续修正处理，尚不声称该最终行为通过GUI。
- 读取优化以实际命令数验证：相同HEAD/索引blob仅一次 `cat-file blob` 和一次 `cat-file -s`；复用快照的部分暂存预览只新增一次diff读取，文件随后改变仍拒绝应用过期快照。头像并发请求共用一次加载及同一解码对象，另测有界LRU、失败重试到期与过大响应拒绝。稀疏导航测试覆盖第9002行的精确UTF-8字节位置、多字节长行、起止钳制及文件变动后的缓存失效。
- 首次打开的CUA观察为旧版4664ms、新版4281ms，各仅一次且包含AX获取和自动等待；这是操作观察，不是性能基准或稳定加速结论。最终构建、安装与验收结果见下列补充。
- 最终合并全部修复后重新全量测试：213项、0失败（`/tmp/raygit-density-release-tests.log`）。四语言37表1131键及 `git diff --check` 通过。新增页面安装后再消费定位请求的回归，防止把新页面行号应用到旧内容；真实变更行定位不再使用Git上下文起点。
- 最终QA复测43MB文本第二色块：内容从 `020000 alpha item-20000` 开始，字节位置2,459,877，底部明确“从第20,000行开始”且光标“行20,000，列1”。主窗口UTF-16显示 `- variable = "before"` / `+ variable = "after"` 和1个变更；独立历史窗口 `cd3d14bd / Custom.raycode` 显示完整真实代码，不再误入静态预览空态。
- 本地Release成功（`/tmp/raygit-density-release-build.log`），正常退出正式应用后更新 `/Applications/RayGit.app`，严格签名与包内可执行文件逐字比较通过。安装版启动保持原测试仓库，贮藏取消按钮可用且Escape关闭；Notes.txt主预览显示可点击“变更1”总览，随后恢复更新前选中的Preview.png。正式版未执行贮藏或其他仓库写操作。本轮没有创建Git提交。

### 2026-10-04 日志勾选范围、相对日期与连续对比导航

- 只读观察本机 SmartGit 26.1：提交图使用灰色连线和空心节点，日期显示 Yesterday / weekday / yyyy-MM-dd 加 HH:mm；分支区域有 HEAD 与独立分支复选框。RayGit 保留自己的布局，借鉴这些显示与筛选行为。
- 独立 `dev.raygit.qa` 使用 `/tmp/raygit-navigation-qa-path` 指向的合成仓库，含合并图、未合并分支、同名本地/远程引用、不同日期和 600 行长文本；没有写入业务仓库。
- GUI 右键 unmerged → 日志后，unmerged 行自动选中且只有该分支勾选，首条为 Unmerged branch only；额外勾选 main 后 5 条增至 6 条并去重，取消 unmerged 恢复 5 条，全部取消显示 0 条。关闭日志后从主窗口重新打开，所有复选框仍为 0，空列表被记住。详情实测显示“前天 12:34”和“今天 13:25”。完整引用区分本地与远程同名分支。
- 普通双栏对比关闭纵向同步和换行，初始定位第 30 行；点击总览 25% 附近定位无变更的第 150 行，连续拖动到第 399 行，两栏纵向滚动值同为 0.6772540983606558，未吸附到变更起点。移动一栏横向滚动条后两栏代码内容对齐；不同文本宽度的滚动条比例可以不同。下一个变更将两栏定位第 550 行，滚动值同为 0.9902362584378014，行号及变更范围带明显高亮与细边框。
- 验收发现并修复普通日志复用旧标签筛选、窄日志隐藏日期、程序定位后 footer 保留旧行号；紧凑模式保持固定等宽栏框架并独立同步代码横向位置。分页/流式总览使用正常鼠标事件与最新位置节流，避免嵌套事件循环阻塞异步读取。
- 最终全量 223 项测试 0 失败（`/tmp/raygit-navigation-verified-tests.log`），四语言 37 表 1131 键和 `git diff --check` 通过。测试包含日界线、仓库独立勾选持久化、空范围、引用并集/分页、标签上下文清除、游离提交、比例连续定位、对齐空白映射、原生及紧凑横向同步、footer 更新。
- 最终 QA 中双击同名远程 origin/topic，准确选中 `refs/remotes/origin/topic` 且本地 `refs/heads/origin/topic` 未勾选；窄日志列表可见“星期四 13:25”和“2026-09-24 13:25”。下一变更实测两栏滚动值 0.5382111861137898，footer 为“行 300，列 1，选择 253 个字符”。紧凑两侧横向滚动值约 0.5，栏标题/框架位置固定。
- 3.4MB 分页总览点击无变更区域到第 14,207 行，拖动到第 18,942 行；43MB 流式总览点击到第 175,525 行（字节 21,589,454），拖动到第 110,031 行（字节 13,533,692），footer 与页面起点一致。未将一次拖动操作描述为持续性能基准；大量全变更文本的紧凑视图仍需完整布局以保证总览几何准确。
- 本地 Release 成功（`/tmp/raygit-navigation-release.log`），正常退出后更新 `/Applications/RayGit.app`，严格签名和可执行文件逐字比较通过。安装版正常启动，保留 giftdock / codex/ios-customer-chat 及 GiftDockChatApp.swift 的原选择和 14 个变更状态；未对该业务仓库执行写操作。本轮未创建 Git 提交。


### 2026-10-05 远端分叉时确认强制推送

- 主工具栏 Push 和网络推送面板使用只读预检；普通非快进拒绝及配置中的强制 refspec 进入显式确认。仅明确的 `notRequired` 结果允许普通推送，鉴权、目标歧义或准备失败均停止。弹窗列出远端、完整分支和可获得的远端独有提交数，Return 默认取消。
- 确认固定仓库、分支、本地 SHA、单一 push endpoint 及远端 OID；执行使用精确 `--force-with-lease=<ref>:<OID>`、显式 SHA:ref，并关闭附带 tag 和子模块推送。执行前重验 HEAD/配置；成功后使用 compare-and-swap 更新跟踪引用。
- 最终全量 230 项测试、0 失败（`/tmp/raygit-force-push-final-tests.log`）；包含 7 项本地 bare remote 测试，覆盖远端再次更新、fetch 后 lease 仍拒绝、HEAD/配置变化、pushRemote 优先级、多目标/多 endpoint、显式 refspec 和拒绝分类。四语言 38 表 1140 键及 diff 检查通过。
- 独立 QA 使用 `/tmp/raygit-force-push-qa-root` 指向的本地临时 bare remote。界面初始显示远端独有 1 个提交，Return 取消后远端未变；最终构建打开弹窗后由 peer 增加提交并 fetch，再点击强推显示“远端已更新，请重新预览并确认强制推送”，远端仍为 `84c93b7d6a5a1f37e14970ce6b07af8915d7c07f`。
- 重新预览显示远端独有 2 个提交，确认后 remote/main、origin/main 与本地 HEAD 同为 `bf828d493de3e23a9a1870f8dec3bb0df458e469`；操作日志默认折叠，展开后可见精确 lease 和 SHA:ref 命令、退出状态 0 与 forced update。随后新增测试提交，普通 Push 显示原确认并成功快进至 `478f68dfe7430e70c4412e56a6d04c4b8507f2ac`。所有推送仅针对本机临时仓库。
- 本地 Release 构建成功（`/tmp/raygit-force-push-release.log`）；正常退出后更新 `/Applications/RayGit.app`，严格签名及可执行文件逐字比较通过。安装版正常启动并保持当前 rayfinder / main 选择及干净工作区；没有操作业务仓库远端。本轮未创建 RayGit 源码提交。

### 2026-10-05 Clone 自动目录与父目录记忆

- 只读参考 SmartGit 克隆向导的 Parent Directory、Directory Name 和 Clone Into；未执行参考应用克隆。RayGit 预填可编辑完整目录，按 HTTPS/SSH/scp/file URL 或本地源名称去除 `.git`，默认使用上次成功克隆的父目录；首次优先已有 `~/Git-projects`。手动改过的路径在源地址变化后保留。
- CloneDestinationTests 与 RepositoryWorkflowTests 共 12 项通过（`/tmp/raygit-clone-tests.log`），覆盖名称解析、路径验证、手动覆盖、父目录记忆和实际克隆时创建缺失多级目录。四语言 38 表 1141 键与 `git diff --check` 通过。
- 独立 QA 输入 HTTPS 示例时预填 `/Users/kevin/Git-projects/clone-demo`；随后真实克隆 `/tmp/raygit-clone-qa-path` 指向合成仓库的 file URL，到原本不存在的 `new parent/nested/custom-name`，成功打开并显示 Clone fixture 提交。再次打开创建窗口，输入 scp SSH 示例，自动填 `new parent/nested/next-project`；取消后未创建 next-project。首次 AX 改值未提交到源输入框，实际误用旧 HTTPS 示例并返回仓库不存在；正常输入并离焦后克隆成功，不将该自动化问题当作远程连接成功证据。
- 本地 Release 构建成功（`/tmp/raygit-clone-release.log`），正常退出后更新 `/Applications/RayGit.app`，严格签名和可执行文件 cmp 通过。正式版启动保留 rayfinder；创建窗口输入 HTTPS 示例实际预填 `/Users/kevin/Git-projects/sample`，随后取消，无业务仓库写操作。没有创建 Git 提交。

### 2026-10-05 浮窗提醒、紧凑表格与日志引用范围

- 限制/失败提示迁移至工具栏浮窗，包含可选择的方案文字及适用的只读命令复制按钮。独立 QA 使用约360KB暂存补丁触发“暂存差异过大”，自动弹出说明，明确仍可手动提交；复制结果确认为 `git diff --cached --stat`，未调用外部 AI。
- 文件表格缓存筛选/排序结果、状态计数及路径组成；原生自动行高曾覆盖设定值，最终关闭自动行高并设置22pt行/23pt表头。相同高度区域可见行由7增至10，选中行仍保留语义颜色标签。仓库添加按钮18pt；应用贮藏菜单230pt并显示省略号，Escape关闭正常。
- 日志分支行点击仅改变选中行，复选框才改变显示范围。QA勾选“可回收提交”和贮藏后可见 Recyclable QA commit 与 stash记录；重开窗口勾选保持。贮藏范围以提交hash保存，避免stash序号移动改变原选择。提交图/说明/作者/日期/hash分割线可拖动；实际拖动说明分割线使作者和日期列同步移动。主面板作者固定宽度，提交说明预留220pt，窄面板可横向滚动。
- 单行文本输入改用共享原生文本控件。作者/hash聚焦前后截图未观察到placeholder位移；原生绘制矩形及Return/binding测试通过。API密钥SecureField保留安全遮罩，未完成其聚焦基线实测。
- 全量237项测试0失败（`/tmp/raygit-density2-final-tests.log`）；最后补充修改后10项输入/历史日期范围测试通过（`/tmp/raygit-density2-last-check.log`）。四语言39表1152键检查及diff检查通过。
- 性能验证限制：6501项合成文件列表加载成功，但自动化设置滚动条至底部反复超时。采样 `/tmp/raygit-density2-hang.sample.txt` 主要显示辅助功能读取离屏NSTableView行并创建hosting cell；不足以证明实际鼠标滚动流畅度。结束无编辑内容的QA进程恢复工具，保留合成测试数据；不将极端滚动性能列为验收通过。
- 本地Release成功（`/tmp/raygit-density2-release-final.log`），正常退出正式应用后更新 `/Applications/RayGit.app`，严格签名与可执行文件cmp通过。安装版正常启动并保留 giftdock / codex/ios-customer-chat / project.pbxproj 与13个已暂存变更；未修改业务仓库。未创建Git提交。

### 2026-10-05 AI 输入限制与日志列布局

- AI 提交设置增加 30–4000KB 暂存补丁限制，默认120KB；超限浮窗可打开设置或明确选择根据暂存摘要生成。完整补丁超限时不发送截断内容；摘要只包含暂存文件名、状态及变更统计，并明确不推断代码行为。
- 独立 QA 使用 `/tmp/raygit-limits-qa-path` 指向的合成仓库，包含约340KB已暂存 Large.txt 和未暂存 Small.txt。120KB下自动显示超限浮窗；摘要按钮通过本地模拟 CLI 填充提交草稿，捕获请求704字节，包含 Large.txt、不含代码补丁或 Small.txt。界面将限制改为500KB并保存后重新生成，捕获请求340523字节，完整包含 git diff --cached 补丁、不含 Small.txt。仓库仍为13个提交；无外部AI调用。退出QA后恢复原AI配置键。
- 主日志头像限制18×18pt，作者名称按内容计算且上限72pt，隐藏字段不占位。各比较/搜索/冲突视图变更箭头统一22×24pt、成对间距2pt。
- 日志列增加最小宽度和内容裁切：提交图28、说明220、作者55、日期105、哈希65pt。拖动时仅更新表头指示线，松手后提交列宽。QA实际拖窄说明和作者列，长文本省略且不覆盖相邻列；截图 `/tmp/raygit-limits-history-narrow.png`。未进行拖动帧率基准测量。
- 全量243项测试0失败（`/tmp/raygit-limits-columns-tests.log`）；最终作者宽度/裁切调整后7项AI及列宽测试通过（`/tmp/raygit-limits-columns-focused.log`）。四语言39表1157键检查与diff检查通过。
- 本地Release成功（`/tmp/raygit-limits-columns-release.log`）；正常退出正式应用后更新 `/Applications/RayGit.app`，严格签名与可执行文件cmp通过。安装版启动显示 giftdock / codex/ios-customer-chat / Info.plist，13个已暂存变更；没有修改业务仓库或正式AI配置。未创建Git提交。


### 2026-10-05 紧凑作者列、原生列宽拖动与文件菜单

- 主面板头像与作者合并为单个裁切区域，总宽不超过100pt；作者名称测量按作者序列缓存。变更及搜索上下箭头使用独立固定尺寸样式，每个22×24pt、间距2pt，不再被外层工具栏最小宽度撑大。
- 日志列宽使用原生 mouseDown/mouseDragged/mouseUp；拖动只移动指示线，释放时才更新列宽，不进入嵌套事件循环。Escape取消并恢复焦点。保持提交图28、说明220、作者55、日期105、哈希65pt的最小宽度与单元格裁切。
- 工作区、文件树和日志变更文件菜单移除复制路径等复制入口，打开文件/在Finder中显示位于末尾。历史文件已不存在于工作区时禁用这两项。
- 独立QA在合成仓库使用长作者及长提交说明，实际拖窄说明和作者列后文字省略且未覆盖邻列；主面板作者名称被限制在紧凑区域，箭头紧邻排列。截图：`/tmp/raygit-menu-history-minimum.png`、`/tmp/raygit-menu-main-identity.png`。工作区右键菜单末尾确认为打开文件、在Finder中显示，无复制路径。拖动交互已验证，未测量连续拖动帧率。
- 最终全量247项测试0失败（`/tmp/raygit-menu-columns-final-tests.log`），包括真实SwiftUI承载下46×24pt箭头组尺寸、拖动期间不写入/释放只写入一次、最小宽度反向拖动和取消恢复焦点。四语言39表1157键与diff检查通过。
- 最终本地Release成功（`/tmp/raygit-menu-final-release.log`）；正常退出后更新`/Applications/RayGit.app`，严格签名及可执行文件cmp通过。安装版启动保留giftdock / codex/ios-customer-chat / MerchantWorkbench.swift、11个变更及0个已暂存；未修改业务仓库。本轮未创建Git提交。

- 最终本地化检查发现动态拼接列名导致静态查键失败，已改为复用表头现有本地化标题。修复后四语言检查通过，9项列宽/原生拖动/按钮几何测试再次通过（`/tmp/raygit-menu-final-focused.log`）。

### 2026-10-05 紧凑日期、复制路径与实时列宽

- 主面板日志日期按显示文字测量并缓存，宽度限制48–110pt且左对齐，收紧与作者之间的空白；缓存包含日期、语言、时区及日界线。
- 工作区普通/忽略文件、文件树和日志变更文件菜单恢复“复制路径”，复制完整绝对路径，多选以换行分隔。工作区直接使用所选路径，避免忽略文件未进入状态数组而复制为空；日志中已不存在于工作区的文件仍可复制路径。
- 日志表头分割线改为1pt、保留9pt拖动热区，移除最右侧哈希列的多余分割线。原生mouseDragged实时提交列宽，松手不重复更新，Escape恢复原宽度；替代上轮的松手更新行为。
- 10项列宽、原生拖动和比较按钮几何测试通过（`/tmp/raygit-live-columns-tests.log`），覆盖拖动期间连续更新、取消恢复及日期宽度边界。四语言39表1157键与diff检查通过。最终忽略文件复制回调补充修复已通过Debug和Release编译。
- 独立QA合成仓库中右键Small.txt复制路径后粘贴到筛选框，确认为该文件完整绝对路径，随后清空筛选。主面板日期紧邻作者；日志仅有提交图/说明/作者/日期四个拖动热区，无哈希末尾热区。实际拖窄说明列后作者/日期同步移动，长文字仍正确裁切；连续更新由原生事件测试验证，未测量拖动帧率。截图：`/tmp/raygit-live-columns-main.png`、`/tmp/raygit-live-columns-log-before.png`、`/tmp/raygit-live-columns-log-after.png`。
- 本地Release成功（`/tmp/raygit-live-columns-release.log`），正常退出后更新`/Applications/RayGit.app`，严格签名和可执行文件逐字比较通过。安装版启动保留giftdock / codex/ios-customer-chat / MerchantWorkbench.swift，显示13个变更、0个已暂存。没有执行业务仓库写操作，本轮未创建Git提交。


### 2026-10-05 文件状态、焦点操作范围、全部贮藏及滚动边界

- 文件状态按 Git 索引/工作区组合显示：已暂存、已暂存 · 已修改、已移除、已暂存 · 已移除等；文件行图标16pt，筛选图标约17–18pt并保留24pt热区。创建图标缩至20×19pt。
- 顶部暂存/取消暂存/丢弃在文件列表有焦点时使用选择，离开列表后作用于所有符合条件的文件。普通表格、树形列表共享选择；目录选择仅覆盖其变更后代。原生鼠标按下立即记录范围，在默认RunLoop延后通知界面，避免在表格跟踪鼠标时重建视图；不依赖可能被NSTableView消费的mouseUp。背景探针不接受点击。
- 主面板与独立日志默认包含全部贮藏条目，不显示贮藏的索引/未跟踪辅助提交；旧范围迁移补入全部贮藏，新版显式取消选择保留。日志表头固定28pt单行，提交图最小列宽55pt。
- 主面板对比关闭弹性滚动，同步前分别约束源和目标边界，跳过无变化的同步，防止端点反复回传。回归覆盖不等高面板和20次重复边界通知。
- 隔离QA仓库 raygit-status-focus-qa-xakmxaxm 实测：普通列表单击Modified.txt后暂存仅1项；点击提交框后暂存全部6项，取消暂存全部6项；全局丢弃确认列出5个受跟踪文件，取消执行。树形列表单击OnlyStaged.txt后暂存仅1项。Git status核对操作结果。业务仓库未执行Git写入。
- 主面板和独立日志显示3条贮藏及基础提交；表头单行正常。长文件开启同步滚动后两侧滚动条在顶部均为0、底部均为1，继续向边界滚动位置稳定；未测量连续帧率。截图：/tmp/raygit-status-final-main.png、/tmp/raygit-status-log.png、/tmp/raygit-status-scroll-bottom.png。
- 最终265项测试0失败（/tmp/raygit-status-final-all-tests.log），含真实托管Table/窗口外壳鼠标选择及操作目标测试。四语言39表1158键检查和git diff --check通过。
- 本地Release成功（/tmp/raygit-status-final-release.log），正常退出后更新/Applications/RayGit.app；严格签名校验与可执行文件cmp通过。启动保留giftdock / codex/ios-customer-chat / ChatAPI.swift，18个变更、3个已暂存，状态正确显示“已暂存 · 已修改”。本轮未创建Git提交。

### 2026-10-05 筛选框高度与工具栏显示稳定性

- 筛选文件输入框外层高度由28缩至24pt，原生输入控件固定20pt。独立QA对比聚焦/离焦截图，排除插入光标后的占位文字区域像素差为0；截图为 `/tmp/raygit-filter-blurred-final.png` 与 `/tmp/raygit-filter-focused-final.png`。
- 创建右侧更多按钮改为11pt省略号，居中于20×23pt区域；原生及自定义窗口工具栏菜单均移除最近项目列表。QA实测菜单仅包含仓库工具、网络、标签管理、搜索、打开及AI提交设置。
- 自定义工具栏在仅图标和图标加文字模式下均固定36pt高。QA切换显示文字后，抽查Pull图标的垂直像素范围和工具栏底边位置均保持一致，随后恢复仅图标模式。
- Debug与本地Release构建通过（`/tmp/raygit-filter-toolbar-build.log`、`/tmp/raygit-filter-toolbar-release.log`）；StableInputNoticeTests共2项通过（`/tmp/raygit-filter-toolbar-tests.log`），四语言39表1158键及diff检查通过。
- 正常退出后更新 `/Applications/RayGit.app`，严格签名校验及可执行文件cmp通过。安装版正常启动，保留giftdock / codex/ios-customer-chat，显示4个变更、0个已暂存；本轮没有业务仓库Git写入，也未创建源码Git提交。

### 2026-10-05 Finder入口、紧凑分支与只读光标

- 创建右侧更多菜单的“打开”改成“在 Finder 中打开”，原生与自定义工具栏入口一致，四语言补齐；QA实际打开当前合成仓库目录，并核对Finder文件列表。仓库变更数量仅在大于0时显示。
- 本地分支、远程分支和贮藏改成可折叠分组并持久化展开状态。采用plain列表、清除垂直内容边距、原生紧凑行高及隐藏分隔线，实测消除原sidebar风格的多余间距。QA折叠贮藏后重启仍保持折叠，再恢复展开。截图：`/tmp/raygit-sidebar-final.png`。
- 主面板和独立比较的只读NSTextView保持不可编辑，点击时用AppKit真实插入点几何绘制稳定光标。仅覆盖shouldDrawInsertionPoint在实机上不足以绘制，最终改为draw阶段绘制。实测主面板与独立窗口行首插入线可见，点击独立左窗格更新为行32列36；输入ReadonlyProbe未改变只读内容或产生保存状态。截图：`/tmp/raygit-main-final-caret.png`、`/tmp/raygit-standalone-final-caret.png`。
- 全量267项测试0失败（`/tmp/raygit-sidebar-final-tests.log`）；最终只读绘制补丁后2项定向测试通过（`/tmp/raygit-caret-draw-tests.log`），覆盖真实文本系统几何、字符位移和输入/粘贴保护。四语言39表1159键及git diff --check通过。
- 本地最终Release成功（`/tmp/raygit-caret-sidebar-final-release.log`）。正常退出正式应用后更新`/Applications/RayGit.app`，严格签名及可执行文件cmp通过。重启保留giftdock、codex/ios-customer-chat及ManagementModelChecks.swift选择；只读检查新分组正常显示。本轮未对业务仓库执行Git写入，未创建Git提交。


### 2026-10-05 用户操作日志保留与底部常驻结果

- 用户操作摘要与实际命令通过操作 UUID 关联；成功、失败、取消均记录。摘要与用户命令各保留最近1000条，常规读取命令最多300条；本轮为应用会话内保留，未增加跨重启磁盘日志。
- 最近用户操作状态独立于刷新状态，主窗口与日志窗口底部显示操作及失败原因，点击打开操作日志。记录默认折叠，展开用户摘要可查看对应完整命令与输出，支持完整查看、复制、导出和已有脱敏/缓存过期保护。
- 专项12项与全量270项测试均0失败（`/tmp/raygit-operation-focused.log`、`/tmp/raygit-operation-alltests.log`），覆盖310次常规读取后的保留、刷新状态稳定、命令关联隔离、失败/取消及脱敏。四语言39表1162键与diff检查通过。
- 独立QA使用本地bare remote和Operations QA合成仓库：实际Pull快进及Push成功后分别显示“拉取完成”“推送完成”，手动刷新和文件变化不覆盖结果；点击底部日志按最新用户操作优先显示Push/Pull，默认折叠；展开Pull含git pull --ff-only --progress与Fast-forward输出。
- 将测试remote临时改为不存在路径，Pull失败后底部保留操作名称和原始错误，刷新后不消失；日志同时保留失败Pull、成功Push、成功Pull。此未匹配错误仍显示Git英文原因，未声称全部错误已翻译。验证后恢复测试remote。
- 本地Release构建通过（`/tmp/raygit-operation-release.log`）。正常退出后更新`/Applications/RayGit.app`，严格签名和可执行文件cmp通过；重启保留giftdock / codex/ios-customer-chat，12个变更、8个已暂存。未对业务仓库执行Git写入，本轮未创建源码提交。

## 2026-10-05 — Compact repository items and common context actions

- Inspected SmartGit 26.1 Repository, Local and Remote menus; selected remote properties, ignore-file editing, rename, ignore and deletion-to-Trash instead of attempting the full menu set.
- Repository items reduced from 34pt to 26pt, retaining folder/status overlays. Clicked-repository menus add log, refresh, remote URL and `.gitignore` editing. Targeted operations preserve the active repository and retain operation summaries/command details.
- Table and tree share file context actions: rename, ignore eligible untracked files, confirmed Trash, copy name/relative/absolute path, plus existing comparison, history, staging and Finder actions. Clean tree files retain history access; invalid/mixed mutation selections are disabled.
- Automated: 276 tests passed (`/tmp/raygit-menu-tests-final.log`); four languages / 41 tables / 1192 localization keys passed; `git diff --check` passed. New tests cover remote URL/refspec preservation and stale configuration, ignore-file stale/symlink protection, clicked-repository isolation and context eligibility.
- GUI fixture: `/var/folders/p9/706zy1rn35l9bjl5jq98b3m40000gn/T/raygit-menu-qa-o82q8t8g`, independent `Active Repo` and `Context Repo`. Edited the inactive repository's fetch URL and ignore file without switching active repository; CLI verified explicit push URL/upstream preservation and correct file target. Escape after editing remote URL caused no write.
- GUI: right-clicked unselected `rename me.txt` while `tracked.txt` remained selected; renamed only the clicked file. Ignored `scratch[1].tmp`; verified literal escaping does not ignore `scratch1.tmp`. Moved `trash me.txt` to Trash with confirmation, then restored it through the tree toolbar. Verified file contents and unchanged index. Operation log showed collapsed summaries and expandable remote configuration commands. Visually checked compact repository rows.
- Release build passed (`/tmp/raygit-menu-release.log`), installed to `/Applications/RayGit.app`, strict signature and executable equality verified. Relaunch preserved the user's rayfinder repository, selected Resources/Info.plist, 32/37 staged count and existing commit draft; installed repository menu verified without running mutations in the user's repository.
- No Git commit or push performed. Backend regression tests cover additional edge cases; not every menu permutation was exercised manually.

## 2026-10-05 — Clone form text clipping and retained drafts

- Rounded native fields reserve 24pt while plain toolbar fields remain 20pt. Fixed the focused field editor receiving an already-inset drawing rectangle, which caused AppKit to apply the bezel inset twice and crop Chinese glyphs and descenders. Increasing height alone was tested and found insufficient before the editor geometry fix.
- Creation form persists clone mode, source, destination, chosen parent and automatic/custom destination ownership. Cancel/reopen and app restart retain the draft; changing source preserves an explicitly edited destination.
- Nine focused tests passed (`/tmp/raygit-clone-input-final-tests.log`), including actual focused AppKit editor geometry for Chinese and gyp text, draft reload, corrupt-data fallback and automatic/custom destination behavior. Localization parity (4 languages, 41 tables, 1192 keys) and `git diff --check` passed.
- Independent QA verified focused text rendering (`/tmp/raygit-clone-qa-fixed.png`), cancel/reopen, source editing without custom destination replacement, and restoration after normal quit/relaunch. No QA network clone was executed.
- Release passed (`/tmp/raygit-clone-input-final-release.log`); updated `/Applications/RayGit.app` after normal quit, strict signature and executable equality passed. Restored the user's existing clone URL and destination, verified cancel/reopen retains them, and left that form open. Did not start the user's clone, commit, or push.

## 2026-10-05 — Preserve the actual remote push rejection

- Shared failure classification prioritizes remote rejection over the generic hook category. Status-bar and collapsed operation-log summaries include sanitized remote diagnostics, prioritize error lines, and omit transfer progress; local hook failures retain their existing category. Four localizations cover the remote-rejection title.
- 23 focused GitCommandLog, GitProcess, GuardedForcePush and OperationFailure tests passed (`/tmp/raygit-remote-reject-tests.log`); localization parity passed (4 languages, 41 tables, 1193 keys), as did `git diff --check`.
- QA used the disposable local `raygit-remote-reject-qa-1nxys59c/client` and divergent bare `remote.git`, whose pre-receive hook rejects with `ERROR: Protected branch main does not allow force pushes.` Invoked the actual force-push confirmation in the app. The footer and collapsed log showed that precise cause; expanded details retained `--force-with-lease`, `[remote rejected]`, and `(pre-receive hook declined)`. The remote ref remained unchanged. Evidence: `/tmp/raygit-remote-reject-ui.txt` and `/tmp/raygit-remote-reject-ui.png`.
- Release build passed (`/tmp/raygit-remote-reject-release.log`). Normally quit and updated `/Applications/RayGit.app`; strict signature and executable equality passed. Relaunch retained rayfinder/main with three untracked files and no staged files. No push to an actual server and no source commit were performed.

## 2026-10-06 — SmartGit-style history keyboard commands

- Observed SmartGit 26.1 in its Log window: CmdR opens a hard-reset confirmation; CmdShiftR opens advanced reset with mixed selected and soft/hard/keep/merge options. Canceled reference dialogs without executing Git mutations. Settings confirmed CmdF filter, CmdL log, F7 branch and ShiftF7 tag; Copy Message has no default accelerator.
- Main and independent history lists now route CmdR/CmdShiftR to a shared confirmation, CmdF to their search field, CmdC to copy the selected hash, Return to commit details, CmdL to the selected commit's log, and F7/ShiftF7 to existing branch/tag dialogs. F5 refreshes; CmdR retains configured refresh behavior outside history lists. Text editors and attached sheets do not receive history commands. Reserved-key validation now protects CmdL.
- Reset supports all five native flags, freezes the selected commit hash, rejects changed repository/HEAD/branch or an active Git operation, and presents localized consequences and errors. Hard-reset text includes Git's possible removal of obstructing untracked files. External Git processes can still race after the context check; this uses the existing mutation model.
- Full native test run passed: 284 tests, zero failures (`/tmp/raygit-shortcuts-tests.log`); localization parity passed: 4 languages, 42 tables, 1209 keys. Native event tests cover modifier matching, text/other-pane focus and sheet isolation. Git tests cover all reset modes and stale context/active merge refusal. `git diff --check` passed.
- GUI fixture: `/var/folders/p9/706zy1rn35l9bjl5jq98b3m40000gn/T/raygit-shortcuts-qa-qpzuvf6q`. Verified hard-confirmation Escape preserves HEAD and working file; main-window mixed reset moved HEAD/index to checkpoint 2 and preserved local edits. Independent-log soft reset moved HEAD to checkpoint 1 while preserving index and working file, independently checked via Git CLI. Verified F7/ShiftF7 dialogs and Escape, Return details, CmdL selected commit, CmdC hash pasted into CmdF search, native text copy/paste, and F5 without a reset sheet.
- Local Release passed (`/tmp/raygit-shortcuts-release.log`), normally quit and updated `/Applications/RayGit.app`; strict signature and binary equality checks passed. Relaunch retained giftdock / codex/ios-customer-chat and 56/83 staged count; restored the prior selected commit and verified installed CmdF. No Git mutation was performed in business repositories; no source commit or push was made.

## 2026-10-06 — History shortcuts no longer require list focus

- Removed the list-bounds/first-responder restriction in the shared window event handler. History commands now work from other panes, buttons and text editors in the same window. Native text CmdC and Return remain intact; sheets, other windows and hidden history views stay isolated. Mounted the handler outside the nonempty list so CmdF also works with zero search results.
- Updated native event regression passed (`/tmp/raygit-window-shortcuts-tests.log`, 1 test / zero failures); localization parity (4 languages / 42 tables / 1209 keys) and diff checks passed. Reused the existing test and command actions.
- Independent QA: file-table focus → CmdR opened hard-reset confirmation; commit-editor focus → CmdShiftR opened advanced reset; both canceled. File-filter focus → CmdF focused history search even with zero results; file-filter focus → CmdL opened selected commit log; reference-filter focus in independent Log → F7 opened branch dialog, canceled. No Git mutation performed.
- Local Release passed (`/tmp/raygit-window-shortcuts-release.log`); normally quit and updated `/Applications/RayGit.app`, strict signature and binary equality verified. Existing staged changes were preserved; no commit/push.

## 2026-10-06 — Configurable history keyboard shortcuts

- Committed all preceding changes first as `12e0dc0` (`Add SmartGit-style history shortcuts and guarded reset dialogs`). The shortcut-settings changes described here remain uncommitted; no push was performed.
- Preferences now expose 14 actions with Command/Shift/Option/Control and letter/function/Return keys. Shared persisted bindings drive actual history commands, app menus and context-menu hints. Legacy settings migrate; duplicate/reserved shortcuts are rejected; native text copy/Return and reset confirmations remain protected.
- Focused native tests passed: 5 tests, zero failures (`/tmp/raygit-shortcut-settings-tests.log`). Localization parity passed: four languages, 43 tables, 1232 keys. Release build passed (`/tmp/raygit-shortcut-settings-release.log`).
- Independent QA on the existing `raygit-shortcuts-qa-qpzuvf6q` fixture: changed Create Branch F7 to F8, observed F8 open the correct selected-commit dialog and F7 do nothing, then canceled. Duplicate F8 for Create Tag was rejected with a Chinese conflict message. Normal quit/relaunch retained F8 and its actual action; Restore Defaults restored F7 and its action. Visually inspected the settings layout and all 14 accessibility-labelled rows. No Git mutation was executed in this verification.
- Normally quit and updated `/Applications/RayGit.app`; strict signature and executable equality checks passed. Relaunch retained raygit/main and selected commit `12e0dc0`; verified all 14 settings in the installed release and left its keyboard settings open. No business repository mutation was performed.

## 2026-10-06 — Separate reset and refresh shortcuts

- Hard reset retains CmdR; refresh now uses CmdOptionR with F5 as its alternate. Removed the reset/refresh duplicate exception, migrated old refresh CmdR bindings, and normalized saved collisions while preserving valid custom swaps. Added native editing/window/system shortcut reservations and dynamic shortcut hints.
- Audited configurable commands and fixed app shortcuts (comparison save/undo, apply stash, terminal, sheet actions). Native text copy/Return remain scoped exceptions. Three focused shortcut tests passed (`/tmp/raygit-shortcut-conflicts-tests.log`); localization parity passed (4 languages, 43 tables, 1232 keys), and `git diff --check` passed.
- Independent QA: CmdR opened the hard-reset confirmation and Escape canceled; CmdOptionR and F5 refreshed without opening reset. Attempting to assign refresh CmdR showed the conflict message and retained Option. Fixture HEAD, index tree and working-file hash remained unchanged.
- Local Release passed (`/tmp/raygit-shortcut-conflicts-release.log`). Normally quit and updated `/Applications/RayGit.app`; strict signature and executable equality passed. Installed settings verified refresh CmdOptionR, hard reset CmdR, advanced reset CmdShiftR and alternate F5. Relaunch retained raygit/main and selected commit `12e0dc0`. No source commit, push or business-repository mutation performed.

## 2026-10-07 — Shortcut enable switches and direct key recording

- All registered shortcuts have a persisted enable flag (legacy bindings default to enabled). Disabled shortcuts retain their chord, stop dispatching, and release overlapping combinations. Explicit new refresh overrides survive restart. Native Cmd+C and similar combinations are permitted; actual overlapping enabled actions still conflict.
- Settings use a native multi-select modifier segment group and a rightmost key recorder. Recording intercepts Command combinations before menus, exits on capture/Escape, and stays within its own window. Rejected drafts show an inline warning below their row without changing the effective binding or adding a footer error.
- All 297 tests passed (`/tmp/raygit-shortcuts-final-tests.log`), including binding persistence, disable/reenable dispatch, native text-copy preservation and recording before menu dispatch. Four-language localization parity/static lookups passed (43 tables, 1301 keys); `git diff --check` passed.
- Independent QA on the existing disposable `raygit-shortcuts-qa-qpzuvf6q` fixture: typed a bare T into Open Repository and observed its inline conflict; disabled Open and assigned its Cmd+O to Refresh; confirmed reenable conflicts and Cmd+O refresh without the Open dialog. Assigned Cmd+C to Filter Files, verified it focuses file search from a file row, and verified copy/paste inside the text field remains native. Normal quit/relaunch retained disabled Open, Refresh Cmd+O and Filter Files Cmd+C. Restored QA bindings afterward. Visual evidence: `/tmp/raygit-shortcut-controls.png`. No Git mutation performed by these UI checks.
- Local Release succeeded (`/tmp/raygit-shortcuts-release.log`). Normally quit and updated `/Applications/RayGit.app`; strict signature and executable equality checks passed. Installed release reopened raygit/main with commit `936849b3` selected and no staged files, and exposed all 66 shortcut recorder rows and enable switches in Settings. Left the keyboard settings open. No source commit or push was made.

## 2026-10-07 — Compact shortcut settings columns

- Shortcut rows now align command, modifiers, an 88 pt recorder, adjacent clear button, and a separate rightmost small enable switch. Native modifier controls also use small sizing. Moved both footer hints into the keyboard page subtitle.
- All 13 focused recorder/binding tests passed (`/tmp/raygit-shortcut-layout-tests.log`); four-language parity and static lookups passed (43 tables, 1301 keys). Local Release succeeded (`/tmp/raygit-shortcut-layout-release.log`).
- Visually checked QA and installed settings: hint lines are fully visible and row controls align. Normally quit and updated `/Applications/RayGit.app`; strict signature and executable equality checks passed. Preserved custom bindings and left installed keyboard settings open. Evidence: `/tmp/raygit-shortcut-layout-installed.png`. No commit or push was made.

## 2026-10-07 — Mini shortcut switches and inset clear controls

- All shortcut rows use mini enable switches with increased leading spacing, restore 13 pt command labels, and place clear controls inside the recorder's right edge. Native modifier controls use their intrinsic width so the 3 pt gap before the recorder remains visible.
- All 13 focused shortcut/recorder tests passed (`/tmp/raygit-mini-shortcuts-tests.log`); localization parity passed (4 languages, 43 tables, 1301 keys). Final local Release passed (`/tmp/raygit-mini-shortcuts-final-release.log`); `git diff --check` passed.
- Normally quit and updated `/Applications/RayGit.app`; strict signature and executable equality checks passed. Visually verified the installed shortcut settings, including the corrected modifier gap, mini switches and inset clear controls. Evidence: `/tmp/raygit-mini-shortcut-final.png`. Existing bindings and raygit/main selection were retained. No commit or push was made.

## 2026-10-07 — Untracked color and file-status latency

- Untracked badges and optional status columns now use blue, consistent with their question-mark file icon. Status refresh publishes files as soon as Git status returns, before branch/stash/upstream metadata; repository/read guards reject stale reads. Removed the extra 350 ms filesystem debounce and reduced native event latency from 350 ms to 50 ms while retaining refresh coalescing.
- All 9 focused quiet-refresh, file-status, repository-targeting and branch-switch tests passed (`/tmp/raygit-status-verified-tests.log`). The regression blocks branch metadata until staged files publish, checking ordering without a timing threshold. Localization checks passed (4 languages, 43 tables, 1301 keys); local Release succeeded (`/tmp/raygit-status-release.log`).
- Disposable QA fixture `raygit-status-qa-2z1w0orb`: visually verified blue untracked badges/icons (`/tmp/raygit-status-color.png`); Stage All changed both rows and count to 2/2, Unstage restored modified/untracked and 0/2. External Git add/reset automatically changed the untracked row and count without manual refresh. These UI checks establish correct updates, not a measured latency guarantee.
- Normally quit and installed Release at `/Applications/RayGit.app`; strict signature and executable equality passed. Relaunch retained giftdock, branch `codex/ios-customer-chat`, selected `style.scss` and commit `84bc7a31`, with the existing 2/68 staged count. No business-repository mutation, source commit or push performed.

### 2026-10-07 AI commit button availability

- Reproduced the installed app with 0 staged files: the AI button was disabled by the cached staged count. Removed that UI condition and the controller's redundant cache guard; the controller still reads the actual cached diff and reports the existing localized empty-index error before contacting AI. Busy/missing-repository and draft/index race protections remain intact.
- Five focused AI input/policy/draft-guard tests passed (`/tmp/raygit-ai-button-tests.log`), including an empty-index regression preserving the draft and leaving an unstaged file unmodified. Localization parity and `git diff --check` passed.
- Independent QA with 0/2 staged files exposed an enabled AI button; clicking displayed “没有已暂存更改”. No AI request was sent. Release built (`/tmp/raygit-ai-button-release.log`), installed after normal quit, and passed strict signature and executable equality checks. Installed RayGit reopened raygit/main with the original selected file and an enabled AI button at 0/40 staged. No Git staging, commit, or push was performed in the user's repository.


## 2026-10-07 — Live network progress and immediate push confirmation

- Toolbar push now opens its confirmation before remote preparation. Ordinary preparation returns an optional force preview, removing the network panel's duplicate dry run while retaining configured-force validation and atomic force-with-lease safeguards. Git stderr is consumed as available bytes so small progress updates arrive before process exit.
- Existing user-operation context streams safe command phases and Git progress into the footer and network panel. Known stages are localized in four languages; counts/rates remain intact. Completion, repository identity and operation tokens reject stale callbacks. Footer still opens the detailed command log.
- Full native regression passed: 301 tests, zero failures (`/tmp/raygit-network-all-tests-verified.log`). After the final progress-localization/panel refinement, all 30 targeted tests passed (`/tmp/raygit-network-final-tests.log`). Fixed a stale UTF-16 stash-preview test to enter through `loadCommitFiles()` and prevent filesystem refresh racing direct fixture writes. Four-language parity passed: 43 tables, 1329 keys; `git diff --check` passed.
- Independent QA used only disposable local bare remote `raygit-network-progress-qa-bpydkr06`, with receive/upload wrappers that pause six seconds. Push confirmation was observed in 0.908 seconds including UI automation overhead, with zero remote calls before confirmation; cancel did not contact the remote. Confirmed push made exactly two connections (one safety dry run plus actual push), displayed live 50% footer progress, completed, and produced matching local/remote refs. This checks UI responsiveness, not Internet transfer speed.
- Pull displayed live 50% progress and completed; final localized footer read `拉取… · 正在接收对象: 50% (1/2)`. The network push preview made one connection and became ready; the final panel showed localized `正在统计对象: 50% (1/2)` during preflight. Clicking the footer opened collapsed command-log rows; expanding the preflight showed the dry-run command and actual details.
- Final local Release succeeded (`/tmp/raygit-network-final-release.log`). Normally quit and updated `/Applications/RayGit.app`; strict signature and executable equality checks passed. Relaunch retained raygit/main and selected commit `b95b7c6c`, with no selected file. No business-repository network mutation, source commit or push performed.

### 2026-10-07 Terminal theme readability

- Reproduced dark terminal text on a dark background in the installed app. SwiftTerm resolves dynamic native colors immediately; the shared terminal view now resolves foreground/background under its effective appearance on initialization, window attachment and appearance changes.
- All 5 focused `TerminalAppearanceTests|TerminalTests` passed with the native build system (`/tmp/raygit-terminal-tests.log`), including Aqua-created terminal attachment to Dark Aqua and repeated dark/light changes. Release built successfully (`/tmp/raygit-terminal-release.log`).
- Disposable QA verified readable text and cursor in explicit dark and light themes, including the existing shell session; restored Follow System afterward. Screenshots: `/tmp/raygit-terminal-dark.png`, `/tmp/raygit-terminal-light.png`.
- Normally quit and updated `/Applications/RayGit.app`; strict signature and executable equality checks passed. Relaunch retained giftdock and `codex/ios-customer-chat`, with 0/65 staged and no selected file. Opening the terminal now shows readable dark text on a light background (`/tmp/raygit-terminal-installed.png`). No shell commands or Git mutations were performed in the business repository; no source commit or push.

### 2026-10-07 主界面文件列表默认高度

- 修复启动时临时小布局被保存为最终分栏高度的问题；只有文件区实际达到300pt才完成初始分配，之后保留用户拖动。单项回归覆盖432→700pt布局恢复300pt及手动220pt后缩放保留（`/tmp/raygit-file-height-tests.log`，1项通过）。
- 本地Release成功（`/tmp/raygit-file-height-release.log`），正常退出后更新 `/Applications/RayGit.app`，严格签名和二进制比较通过。安装版同一raygit窗口实测文件区分隔值由122pt变为300pt，原仓库/选择状态保留；未执行Git提交。


## 2026-10-07 — File-selection preview latency

- Ordinary working-text `displayDiff` now runs Git diff without serial snapshot reads; binary, UTF-16, PDF/SVG, oversized output and invalid-byte replacement characters retain snapshot fallback. File selection avoids duplicate scope-change loads and cancels obsolete workers. Unwrapped preview layout stops writing paragraph attributes for every row.
- Local microbenchmarks: 10,000 rows across two coordinators improved from 733.63 ms / 40,000 attribute edits to 154.19 ms / zero edits; ten repeated updates took about 0.016 ms. Native Git diff median was 17.64 ms versus 41.65 ms for the additional prior preview I/O. These are component measurements, not end-to-end selection or SmartGit timings.
- Full native suite passed 307 tests before the final invalid-byte guard (`/tmp/raygit-preview-latency-full.log`); all 12 focused tests passed after that guard (`/tmp/raygit-preview-latency-focused-final.log`). Local Release succeeded (`/tmp/raygit-preview-latency-release.log`).
- Disposable QA checked UTF-16 before/after content and the first 3,000-line `Navigation.tsx` diff. SVG rendered on both sides; final `Broken.png` fallback displayed 15-byte metadata without garbled text. The complete 43 MB Huge fixture was skipped.
- Normally quit and updated `/Applications/RayGit.app`; strict signature and executable equality checks passed. Installed selection switched from staged `DiffPane` to working-tree `FileComparison` and back to staged `DiffPreviewLayoutTests`, showing the latest patch correctly. Retained raygit/main and 24/24 staged files (the user staged during the session; the agent did not stage). Screenshot: `/tmp/raygit-preview-latency-installed.png`. No commit or push.


## 2026-10-07 — Repository-switch latency

- Replaced the Git runner's fixed 20 ms exit polling sleep with a native process-exit notification wakeup, retaining cancellation/timeout polling and unreaped-leader PID safety. Independent repository metadata reads now overlap; workspace diff starts after status instead of waiting for history, and workspace history selection skips invisible commit-file details.
- Repository-list clicks can replace an in-flight opening. The previous task is canceled; version guards prevent stale results/errors, and cancellation releases only the opening's busy state. Active writes still block switching. Re-selecting the current repository keeps the existing quiet-refresh path.
- Same small local fixture, before/after data-layer timings: files 96.4 → 32.7 ms; diff 341.3 → 44.4 ms; complete open 367.4 → 104.2 ms. Twenty serial git version commands took 476.8 → 222.6 ms. Intermediate focused run measured 43.4 / 58.5 / 140.7 ms and 195.6 ms respectively. These are local component samples, not end-to-end GUI latency or a SmartGit benchmark. Baseline: `/tmp/raygit-switch-baseline.log`; final: `/tmp/raygit-switch-full.log`.
- Full native suite passed 310 tests, zero failures, including latest-click wins, canceled-open cleanup, hidden-detail avoidance, Git process cancellation/timeouts, and quiet refresh. Four-language localization checks passed (43 tables, 1329 keys). Release built successfully (`/tmp/raygit-switch-release.log`).
- Independent QA switched complete → navigation → complete → navigation and restored Broken.png / Long.customcode selections and previews. The code fixture displayed all three changes and aligned panes; screenshot `/tmp/raygit-switch-qa.png`. Opening the separate Log window still loaded the selected commit's file and text diff. No fixture Git mutation was needed.
- Normally quit and updated `/Applications/RayGit.app`; strict signature and executable equality against the signed release bundle passed. Relaunch restored raymenu/main, commit df24aa3e and 0/73 staged. Subsequent automation stopped when CUA detected user interaction; a read-only snapshot showed the user's auto-shipping selection with refreshed 0/0 staged. No source staging, commit, push, or business-repository Git mutation performed.


### 2026-10-07 — Immediate project selection and independent panel loading

- Follow-up to the reported one-second project highlight delay: the shared open entry now publishes the clicked path before Git root validation. Sidebar and window titles use that pending target; old actionable content clears before the first Git await while the workspace layout remains mounted. Same-repository clicks retain quiet refresh, and active writes still reject switching.
- Initial refresh overlaps watcher-path reads; selected workspace diff and upstream-count reads no longer gate branch/history publication. Latest-click tokens suppress old results and cancellation errors. Existing session state captures drafts before switching, including failed/canceled opens. A visible terminal remains enabled across the temporary missing-repository state.
- Native full suite passed 310 tests, zero failures (`/tmp/raygit-project-switch-tests.log`). After final store/session refinements, 9 focused switch/quiet-refresh/history tests passed (`/tmp/raygit-project-switch-final-tests.log`). The blocked-Git tests assert pending highlight before root validation, branches/history before diff/upstream release, latest-click wins, and draft recovery after canceled/failed switches. These ordering checks do not claim a fixed real-repository latency. Four-language parity passed: 43 tables, 1329 keys.
- Final Release built successfully (`/tmp/raygit-project-switch-release.log`); normal quit, local replacement of `/Applications/RayGit.app`, strict signature verification and executable equality all passed. Relaunch restored the user's latest giftdock/codex/ios-customer-chat state, 0/65 staged, selected e65151b3, and populated file/branch/history lists.
- Automated post-install switching stopped when CUA detected the user changing the application. A read-only snapshot showed their vibe-island selection with an existing Git index-format error. No further automatic clicks or restoration over the user's choice were attempted; end-to-end GUI click latency was not measured. No source staging, commit, push, or business-repository Git mutations were performed.

### 2026-10-08 — Project feedback, stable file rows, atomic preview replacement

- Sidebar buttons show native pressed feedback and synchronously publish the pending project before asynchronous opening. Table density resolves the current NSTableView during layout and after SwiftUI updates, keeping populated rows at 22 pt through repository/empty-list replacements.
- File preview keeps the previous text/static/conflict result and revision titles until the latest result succeeds. Loading placeholders are removed; stale preview editing is guarded. Canonical repository comparison uses normalized paths, so clicking the same repository through a directory alias does not strand a running preview.
- Final native focused suite passed all 16 tests with zero failures (`/tmp/raygit-selection-stability-tests.log`). Coverage includes immediate selection publication, obsolete-worker cancellation, blocked-read content retention, failure retention, same-repository re-click, alias refresh, and first populated row geometry. Four-language parity passed (43 tables, 1329 keys); `git diff --check` passed. Release built successfully (`/tmp/raygit-selection-stability-release.log`).
- Disposable QA switched complete/density/navigation repositories and selected Navigation.txt, Navigation.tsx and Encoded.custom. Final build verified same-repository re-click, preview replacement and restored Long.customcode. Screenshots: `/tmp/raygit-selection-stability-qa.png`, `/tmp/raygit-selection-stability-final-qa.png`. Blocked loading retention is verified by regression tests; no end-to-end mouse-down latency measurement is claimed.
- Normally quit and updated `/Applications/RayGit.app`; strict signature and executable equality checks passed. Relaunch restored raymenu/main, selected screens-v3/01-action-library.png, commit df24aa3e and 0/77 staged. Existing staged/unstaged source work preserved; no source commit/push or business-repository Git mutation.

### 2026-10-08 — Keep selected-file differences after staging

- Resolve workspace comparison scope from current file status: staged-only files compare HEAD to Index; unstaged-only files compare Index to Working Tree; mixed changes retain the selected scope. Preview identity, scope menu, comparison window and editable search use the same resolution without publishing scope changes during an in-flight load.
- All 13 native focused tests passed (`RepositoryDecodedDiffTests|RepositoryQuietRefreshTests|StaticComparisonPreviewTests`, `/tmp/raygit-staged-preview-tests.log`). The new regression preserves selected paths through stage/unstage, checks stale scope preferences and verifies both mixed-change versions. Four-language parity (43 tables, 1329 keys) and `git diff --check` passed.
- Disposable QA repository `raygit-staged-preview-brynn65f`: selected Preview.txt showed previous/latest versions; clicking Stage retained selection and both diff sides with HEAD → Index and 1/1 staged; Unstage retained the same diff with Index → Working Tree and 0/1 staged. No business-repository Git writes.
- Release built successfully (`/tmp/raygit-staged-preview-release.log`). Normally quit and updated `/Applications/RayGit.app`; strict signature verification and executable equality passed. Relaunch restored giftdock/codex/ios-customer-chat, selected commit 5e7471de and 0/65 staged. Existing source staging and other changes preserved; no source commit or push.

### 2026-10-08 — Prompt network advisories and quiet-refresh latency

- Push/pull entry points now read local tracking history before contacting the remote. Warnings explicitly describe the last fetched state, not live server truth. Push mapping honors pushRemote/pushDefault and declines ambiguous or custom mappings. The known non-fast-forward path verifies the exact remote branch with fresh ls-remote and avoids a redundant dry-run; force confirmation still pins HEAD/configuration and an explicit fresh remote lease.
- Operation failure callbacks run before repository refresh. Filesystem-triggered refresh reuses its captured status/state snapshot; refs/HEAD/index state reads run concurrently. No new dependency or periodic remote polling was added.
- Native full suite passed 317 tests, zero failures (`/tmp/raygit-latency-all-tests.log`), including stale force leases, changed HEAD/config, differing push URLs/refspecs, remote precedence and one-read-only quiet refresh. Four-language parity passed (43 tables, 1333 keys); `git diff --check` passed.
- Disposable local bare remote and two diverged clones: `/tmp/raygit-network-latency-path` records the fixture. QA Git wrapper delays each online command by 3 seconds and records it. Main Push displayed the last-fetched warning before any online command (click through AX observation took 1.288 s, including automation overhead; not a pure UI latency benchmark). Continue performed exactly one ls-remote, then showed the separate guarded-force confirmation; canceled without changing the remote. Main Pull and Network > Push Preview also showed the correct advisory without additional online commands. Remote OID remained unchanged. No business repository Git write was performed.
- Remaining audit candidates: history detail requests can overlap; staged/history preview still takes the guarded snapshot path; stashed history can traverse commits before pagination. These were not changed in this pass. Local tracking refs cannot detect server changes that have never been fetched; final network verification remains necessary.
- Release build succeeded (`/tmp/raygit-latency-release.log`). Normally quit and updated `/Applications/RayGit.app`; strict signature and executable equality checks passed. Relaunch restored giftdock/codex/ios-customer-chat, selected commit 5e7471de and 0/65 staged. Existing source staged/unstaged changes preserved; no source commit or push.

### 2026-10-08 — Direct normal push and pull method choice

- Normal Push now proceeds without the generic confirmation in the toolbar and network panel. Known remote-history advisories and guarded force-push confirmation remain. Pull uses a shared Pull / Fetch / Cancel sheet; Pull is the default Return action and Escape cancels.
- Native focused suite passed 12 tests (`GuardedForcePushTests|OperationProgressTests`, `/tmp/raygit-pull-choice-tests.log`). Four-language parity passed (43 tables, 1333 keys). Release build succeeded (`/tmp/raygit-pull-choice-release.log`).
- Disposable QA fixture recorded by `/tmp/raygit-pull-choice-path`: toolbar Push ran directly and remote main advanced to `4cdd69f`; Escape left HEAD/tracking unchanged; Fetch advanced origin/main to `b563da1` while HEAD and file contents stayed unchanged; Return on the reopened choice sheet performed Pull and advanced HEAD/file contents to `b563da1`. No business repository writes.
- Normally quit and updated `/Applications/RayGit.app`; strict signature and executable equality passed. Relaunch restored Rayon/app, commit `7bd1c4f0` and 0/8 staged. Existing staged/unstaged source changes preserved; no source commit or push.

### 2026-10-08 — Initial workspace selection, branch switching and compact dialogs

- Project opening restores a valid file selection or selects the first visible row in the current ordering/filter and loads its diff. A per-project initial-status flag keeps ordinary refresh, clean repositories and later filter changes from reselecting deliberately cleared rows.
- Branch switching first uses Git's normal overwrite protection without prompting. Only a local overwrite refusal triggers an include-untracked auto-stash; its new object is verified and retained. Unresolved operations and unrelated failures stop safely. Full stash now omits inherited GIT_LITERAL_PATHSPECS because Git's internal cleanup otherwise left saved untracked files behind; regression verifies both cleanup and recovery of index, worktree and untracked contents.
- Branch menus expose merge, set upstream via a remote-branch picker, and stop tracking. Remote stop-tracking removes only local upstream associations to that exact remote ref; it does not delete any remote branch. Tracking dialog validates its captured repository before saving.
- Simple custom operation dialogs use compact widths (mostly 360 pt), with narrow-form layouts where necessary. Pull uses native default focus plus next-runloop assignment; Chinese action labels consistently use Pull = 拉取 and Fetch = 获取 (Traditional Chinese 取得), and the dialog explains their distinct behavior.
- Focused regression suite passed 28 tests (`BranchSwitchTests|RepositoryQuietRefreshTests|GitProcessTests|RepositoryWorkflowTests`, `/tmp/raygit-branch-actions-retest.log`). Four-language parity passed (43 tables, 1340 keys); Release build succeeded (`/tmp/raygit-branch-actions-release.log`).
- Disposable fixture path is recorded by `/tmp/raygit-branch-actions-path`. QA selected A-new.txt automatically on opening workspace, carried dirty work to clean without a dialog, then switched to feature after saving stash f96ed6a1dadf. Verified clean destination plus original staged, unstaged and untracked blobs in stash. Set noncurrent clean upstream to origin/main, then remote stop-tracking removed only matching associations and preserved feature tracking and remote refs. Context-menu merge advanced main to origin/feature c83c5efb. Opening second selected B-first.txt and displayed its diff. Pull showed initial keyboard focus/ring on 拉取 and Return completed Pull.
- Final full native suite passed 319 tests with zero failures (`/tmp/raygit-branch-actions-final-tests.log`). Normally quit and updated `/Applications/RayGit.app`; strict signature and binary equality checks passed. Relaunch preserved giftdock/codex/ios-customer-chat, selected Brand-amazon/brand.png, commit 5e7471de and 65/65 staged. No source commit/push or business-repository Git mutation.

### 2026-10-08 — Codex bearer authentication, compact workspace and external comparison

- The isolated Codex provider configuration now retains `experimental_bearer_token`; unselected providers and MCP/tool configuration remain excluded. The regression uses fake credentials. A synthetic staged Python patch generated “Add a reusable greeting function and use it in the example” using the installed local Codex CLI (0.155.1) and the existing selected provider. No credential value was logged and no business-repository patch was sent.
- Main window defaults to 1080 pt and the draggable history/commit divider initializes the history side at 550 pt. Toolbar/titlebar have distinct backgrounds; main diff header padding is compressed. Main image previews omit version-selection controls, while standalone comparison retains them. Both image paths were verified using a disposable 32 × 32 PNG fixture in the final Release executable.
- App-owned sheets and confirmation dialogs share the 8 pt frame radius and centered action groups. The main frame clips native sheet dimming; two AppKit tests check the sheet and main-frame masks. App confirmations use SwiftUI sheets instead of mutating NSAlert's private modal state; standard OS file pickers retain their native presentation. UI verification covered cancel/reload, Escape preserving an unsaved comparison draft, discard closing without saving, and Pull centered with initial keyboard focus. Final screenshot: `/tmp/raygit-side-pull-dialog.png`.
- Beyond Compare defaults use `Contents/MacOS/bcomp` with editable separate comparison and merge JSON templates. Installed-app selection resolves to the waiting launcher; two-way comparison is read-only and merge output returns through the existing draft-confirmation path. Settings validation and actual two-file launch were verified against installed Beyond Compare. Three-way argument ordering is regression-tested; interactive three-way result import was not separately exercised in this pass.
- Full native suite passed 323 tests with zero failures (`/tmp/raygit-side-refinement-final-tests.log`); the additional main-frame clipping regression and sheet-style check both passed (`/tmp/raygit-side-dialog-final-tests.log`). Four-language parity passed (43 tables, 1343 keys), and `git diff --check` passed. Release build succeeded (`/tmp/raygit-side-refinement-release.log`) and strict signature verification passed.
- Validation used `.artifacts/RayGitSideQA.app` (`dev.raygit.sideqa`) and the fixture recorded in `/tmp/raygit-side-ui-path`. The final QA app uses the Release executable and was normally quit. Deliverable: `.artifacts/RayGit.app`; `/Applications/RayGit.app` was not replaced in this side conversation. Existing source staging and unrelated changes were preserved; no source commit or push.

### 2026-10-08 — AI commit generation scope and remembered choice

- The first AI click opens a compact scope chooser, initially selecting staged files only and checking Remember my choice. Workspace scope includes staged, unstaged and untracked changes, excluding unchanged/ignored files. Confirming with Remember skips this dialog next time; Commit > More > AI generation scope reopens it. Unchecking Remember clears the saved choice; cancel does not persist changes.
- Inputs share one bounded byte budget across all sections. Untracked empty files remain represented; symlinks are diffed without reading their targets. Workspace requests retain repository/worktree state checks as well as the existing staged-index and draft guards. Summary fallback retains the selected scope. These reads never stage or commit files.
- Eight focused AI tests passed (`/tmp/raygit-ai-scope-tests.log`), including distinct staged/unstaged content in one file, untracked/empty/symlink files, excluded ignored/unchanged content, combined limits, unchanged index, and saved/forgotten choices. Four-language parity passed (43 tables, 1359 keys), `git diff --check` passed, and Release build succeeded (`/tmp/raygit-ai-scope-release.log`).
- Separate SideQA GUI verification confirmed initial radio/checkbox defaults, remembered direct generation, menu reopening with the remembered workspace option, and unchecking Remember restoring the prompt with default staged scope. Local Codex generated “Add personalized greeting and update preview image” from the synthetic workspace, and “Add a greeting function and use it for the hello message” from only its staged Python change. Screenshot: `/tmp/raygit-ai-scope-default.png`. Only the disposable fixture was used; no business-repository contents were sent.
- Updated deliverable `.artifacts/RayGit.app`; installed `/Applications/RayGit.app` was not replaced. SideQA was normally quit. Existing source staging and unrelated changes remain preserved; no source commit or push.

### 2026-10-08 — Background remote status for project list

- The existing workspace polling loop now schedules a serial background sweep across listed/open projects, including unselected repositories. Remote refreshes retry after 90–150 seconds on success (checked by the 30-second sweep) or 5 minutes on failure; unchanged list values are not republished. Existing Background refresh preference controls the work.
- Background fetch updates remote-tracking heads only, without pruning, tags, submodules, FETCH_HEAD, branch/HEAD changes or worktree merges. It retains normal SSH options with BatchMode forced first, suppresses interactive authentication, and bounds each fetch at 30 seconds. Unsupported custom SSH wrappers are skipped for background use; manual operations retain their existing behavior. Cross-window foreground operations cancel and join background tasks; application termination cancels them.
- Focused suite passed 17 tests (`BackgroundFetchTests|RepositoryRemoteSyncTests|RepositoryQuietRefreshTests|GitProcessTests`, `/tmp/raygit-background-focused-tests.log`). Coverage includes active/unselected repositories, dirty-file and HEAD retention, cooldown, failure backoff, continuing after a failed remote, cross-store busy/cancellation and SSH configuration precedence. Localization parity passed: 4 languages, 43 tables, 1377 keys. `git diff --check` passed.
- Full suite ran 373 tests, with 2 skipped and 1 failure: `NativeFocusBridgeTests.testRepositoryToolsCloseActionIsKeyboardReachable` expected two SwiftUI KeyViewProxy instances, observed one. Isolated rerun also failed. The view body, focus bridge and assertion are unchanged; no HEAD-baseline run was performed, so this is not claimed as a proven pre-existing failure. Logs: `/tmp/raygit-background-all-tests.log`, `/tmp/raygit-background-focus-recheck.log`.
- QA fixture recorded in `/tmp/raygit-background-sync-path`: launched with first selected and second unselected, then advanced a local bare remote from `a495423b` to `aae29ddb`. Without clicking refresh or switching projects, both sidebar rows automatically showed one incoming commit. Both HEADs remained at `a495423b` and both dirty sample.txt files retained their original local drafts. Screenshot: `/tmp/raygit-background-sync-qa.png`.
- Release build succeeded (`/tmp/raygit-background-release.log`). Normally quit and replaced `/Applications/RayGit.app`; strict signature and executable equality checks passed. Relaunch restored raygit/main and commit `eb60a791`, with 0/11 staged. The installed app now performs the authorized background fetches; no source commit/push or automatic pull was performed.

### 2026-10-09 — Resolve network merge conflicts and reduce remote-prompt latency

- Resolved the two unmerged index entries (`GitProcess.swift`, `NetworkOperationsView.swift`), preserving authentication environment overrides, bounded silent background execution, foreground cancellation joins and Pull's default choice. Only these conflict resolutions were staged; other staging remained intact. Also stopped inactive push-preview identities from blocking ordinary Push.
- Inspected local SmartGit 26.1 logs under `~/Library/Preferences/SmartGit/26.1/logs/`: background scheduling messages recur about every 10 seconds; actual `ls-remote --symref origin refs/heads/main* HEAD` commands had a median 310-second interval across 281 recorded queries in log.txt.1. Recorded normal pushes use direct porcelain push commands. The scheduling messages alone are not evidence of a network query every 10 seconds.
- RayGit now checks the project sweep on a 10-second threshold (serviced by its existing 3-second timer), prioritizes the selected project, and retains randomized 90–150-second successful remote deadlines and 5-minute failure backoff. Silent, bounded ls-remote polls compare branch OIDs first; only changed/new heads trigger the existing safe fetch. Unselected projects update too; HEAD/worktree/FETCH_HEAD are preserved and remote deletions are not pruned.
- Conservative cached push mappings open the actual force confirmation without contacting the server or awaiting background shutdown. The confirmation pins an exact cached remote OID, endpoint, branch, local HEAD and configuration; Git's atomic force-with-lease refuses a stale snapshot. Ambiguous/custom mappings retain remote inspection. Ordinary mapped pushes omit the extra network dry run; explicitly requested push preview retains it. Foreground writes still cancel and join background operations.
- Initial focused suite passed 20 tests. After the final ordinary-push optimization, all 14 remote/force tests passed (`BackgroundFetchTests`, `GuardedForcePushTests`, `RepositoryRemoteSyncTests`, `/tmp/raygit-remote-prompt-final-focused.log`). Regression covers zero-network cached preparation, stale lease rejection, changed HEAD/configuration, custom mappings, fresh recovery after an unfetched remote update, explicit remote preview, no-change polls, no pruning, unselected projects and read-only preflight before canceled process shutdown. Four-language parity passed (43 tables, 1388 keys); staged and unstaged diff checks passed; no unmerged entries remain.
- The full suite before that last optimization ran 388 tests, with 2 skips and 1 failure (`/tmp/raygit-remote-prompt-all-tests.log`). `NativeFocusBridgeTests.testRepositoryToolsCloseActionIsKeyboardReachable` again expected two native key-view proxies and found one; the focused rerun reproduced it. This is the same assertion recorded in the earlier background-sync validation; this pass did not modify its focus behavior or assert a proven HEAD baseline.
- Disposable fixture is recorded by `/tmp/raygit-remote-prompt-path`. With every online command artificially delayed 3 seconds, both selected `active` and unselected `unselected` rows automatically showed one incoming commit after remote main advanced from `1cc3e773` to `a7f7a1bf`; original HEADs and dirty sample.txt drafts remained unchanged. Final Release toolbar and network-window prompts executed zero network commands. Toolbar click through AX observation took 1.836 seconds including automation overhead, not a pure UI latency benchmark. Both confirmations were canceled. Ordinary Push executed exactly one online push, without a confirmation/dry-run, advancing the local bare remote to `d09917f3`. Screenshot: `/tmp/raygit-remote-prompt-release-qa.png`.
- Release build succeeded (`/tmp/raygit-remote-prompt-release.log`). Normally quit and replaced `/Applications/RayGit.app`; strict signature and executable equality passed. Relaunch preserved raygit/main, selected GitProcess.swift, stash commit `fc95cc48` and 11/19 staged. No source commit/push or business-repository push/pull was performed; installed background remote polls are authorized by this request.

### 2026-10-10 — Finder-style file selection and shortcuts

- File table explicitly supports multiple/empty selection. Added configurable Select All Files (Command-A) and Copy Files (Command-C); all selects the native visible rows and file copying writes file URLs consumable by Finder. Default file shortcuts now use Option-Command-C for paths, Return for rename, Command-Down for open and Command-Backspace for Trash. Saved custom bindings keep their precedence; text editors retain native editing commands. Return and keypad Enter are recognized by their key codes as well as characters.
- Fixed the embedded history panel consuming file-table Return/Copy/Find before workspace handling: compact history now handles keys only when its own pane owns focus. Standalone history retains its existing window command scope.
- Native focused suite passed 24 tests with zero failures (`/tmp/raygit-finder-files-final-tests.log`), covering Command click add/remove, Shift ranges, select-all, text editing, custom-binding collision repair, history-pane isolation and comparison/history shortcuts. Four-language parity passed (43 tables, 1398 keys); diff check passed. Full suite was not run.
- Disposable QA fixture is recorded in `/tmp/raygit-finder-files-path`. Verified select-all and Command toggle selection; Return showed rename, Escape canceled; Command-Backspace showed Trash confirmation and was canceled; path copying pasted the exact path into the QA text editor. Five selected files copied with Command-C pasted successfully into Finder (`/tmp/raygit-finder-paste-final-path`); all contents matched. Final Release separately verified Return rename and guarded Trash. No business repository files were renamed or deleted.
- Release build succeeded (`/tmp/raygit-finder-files-release.log`). Normally quit and updated `/Applications/RayGit.app`; strict signature and executable equality passed. Relaunch restored raygit/main and commit `0a137e27`, with 0/13 staged. No source commit or push.

### 2026-10-10 — Create local branches from remote sidebar entries

- Remote branch context menu adds localized Create Local Branch. Reuses the guarded name prompt, prefilled with the remote branch name without its remote prefix, and existing validated createBranch(startPoint:) with the full refs/remotes reference. Creates at the selected remote tip without switching the current branch or replacing an existing branch.
- Five GitRepositoryTests passed (`/tmp/raygit-remote-local-branch-tests.log`), including nested remote names, a local HEAD differing from the remote tip, dirty draft preservation and duplicate/option-shaped name rejection. Four-language parity passed (43 tables, 1399 keys); diff check passed. Full suite was not run.
- Disposable GUI fixture recorded by `/tmp/raygit-remote-local-branch-path`: right-click origin/feature/nested displayed Create Local Branch; prompt defaulted to feature/nested; Return created the local branch at remote OID dae3e243 while main and its working draft remained unchanged. A repeated creation failed in the status bar without replacing the branch.
- Release built (`/tmp/raygit-remote-local-branch-release.log`); normally quit and updated `/Applications/RayGit.app`. Strict signature and executable equality passed. Relaunch restored raygit/main, HistoryKeyboardShortcuts.swift and commit 0a137e27; installed remote context menu was verified and dismissed. No source commit/push or business-repository branch creation.

### 2026-10-10 — Copy selected project, reference and commit information

- Command-C copies the focused project name, local/remote branch name or stash subject. History Command-C copies the complete commit message; Copy Commit Hash defaults to Shift-Command-C, migrating the old Command-C hash assignment. Other custom hash bindings remain. Standalone log references copy their displayed branch/tag/stash names; history copy does not consume the reference list's command or native text selection.
- Native focused suite passed 13 tests with zero failures (`HistoryKeyboardShortcutsTests|KeyboardShortcutsTests`, `/tmp/raygit-selection-copy-tests.log`), including existing workspace tests matched by that filter, copy mapping/migration, pane focus and native editor isolation. Four-language parity passed (43 tables, 1400 keys); `git diff --check` passed. Full suite was not run.
- Disposable QA fixture is recorded in `/tmp/raygit-selection-copy-path`. Copied and pasted the exact project `Copy Project`, local `feature/copy-name`, remote `origin/feature/copy-name`, stash `On main: Copy stash description`, and a commit's subject plus separate body paragraph. Verified the same branch and message copying in the standalone log window and native copy/paste in the commit editor. Remote context menu shows Log first, then Create Local Branch. No business repository writes.
- Release built (`/tmp/raygit-selection-copy-release.log`). Normally quit and updated `/Applications/RayGit.app`; strict signature and executable equality passed. Relaunch restored the user's latest raydock/main project and commit `023bf63a`, 0/0 staged. No source commit or push.

### 2026-10-10 — Cached project switching and background file-row preparation

- Reuse bounded in-memory snapshots of visited repositories: files, branches, stashes and compatible history publish before fresh status validation. Cached data stays read-only while opening. Unchanged refs reuse branch/history reads; stash lists still validate to detect non-top reflog deletions. Worktree discovery runs after snapshot restoration. Cancellation and repository versions reject obsolete results.
- File filtering, counts, row construction and sorting run off the main actor, with coalesced requests, cancellation and a bounded prepared-row cache. Native Table retains its view during same-repository updates, preserving scrolling. Cross-repository rows and ignored paths cannot leak into the next project.
- All 38 focused tests passed (`/tmp/raygit-switch-render-final-tests.log`), including 10,000-row preparation, descending/status sorting, cancelled cache lookup, 2,000-file blocked-status warm restoration, changed files/history/branch/stashes, latest-click ownership, workspace comparison, history paging, remote sync, worktree registration and native table selection/density. In the final regression, cold open took 0.789 s and cached model publication took 0.024 s; these are test timings, not screen/frame rendering benchmarks. Full suite was not run. Four-language parity passed (43 tables, 1400 keys); diff check passed.
- Disposable QA fixture recorded by `/tmp/raygit-switch-render-path`: 6,001 file entries loaded, last-file filtering/comparison and project switching retained filter/selection. Final Release, with Git status blocked, displayed cached file/branch/history lists while Stage remained disabled; released status restored operations. External file addition updated count to 6,002 without moving the scrolled visible rows (file-00033 onward). Screenshot: `/tmp/raygit-switch-render-release-qa.png`. QA Git executable preference was restored afterward.
- Release built successfully (`/tmp/raygit-switch-render-release.log`); normally quit and replaced `/Applications/RayGit.app`. Strict signature and executable equality passed. Relaunch restored raydock/main, commit 023bf63a and 0/0 staged. No source commit/push or business-repository writes were performed.

### 2026-10-10 — Build script installs the local app

- `scripts/build-app.sh` now verifies the signed build, requests graceful termination of the installed RayGit with a 15-second timeout, copies to `/Applications/RayGit.app`, then checks the installed signature and executable equality. A failed termination prevents the copy. `--no-install` preserves artifact-only builds and is used by the notarization script; README documents both modes.
- `python3 scripts/test-build-app.py` passed all four scenarios: install ordering, artifact-only mode, termination failure and signature failure. Shell syntax and `git diff --check` passed. The real build/install run completed successfully (`/tmp/raygit-build-install.log`), after normal quit through the UI; installed signature and binary equality passed. Relaunch retained raydock/main and commit `023bf63a`. The native termination path while RayGit is running was not exercised; no notarization or full application suite was run for this script-only change.

### 2026-10-10 — Restore the main window before its first visible presentation

- The toolbar bridge now synchronously makes the SwiftUI placeholder window transparent before deferred shell installation. The eight-point shell restores its frame without drawing before it is ordered front. Native mode and the shell's own toolbar retain normal opacity; existing shell installation remains idempotent.
- All five native focused tests passed (`WindowShellStartupTests|WindowShellGeometryTests`, `/tmp/raygit-window-startup-tests.log`), covering synchronous placeholder hiding, restored shell frame/opacity, single installation, native/shell toolbar visibility, minimum sizing and disconnected-display geometry.
- Release built successfully (`/tmp/raygit-window-startup-release.log`). Normally quit and updated `/Applications/RayGit.app`; strict signature and executable equality passed. Two cold launches restored raydock/main and commit `023bf63a`, with the saved frame unchanged at `{{559, 233}, {1086, 820}}`. Screenshot: `/tmp/raygit-window-startup-installed.png`. Startup presentation ordering is verified by regression tests; no frame-by-frame launch video or physical multi-display test was performed.
- Existing unrelated source changes were preserved. No source commit/push or business-repository Git writes were performed.

### 2026-10-10 — Atomic project switching without empty panels

- Removed the opening-time clearing of files, branches, history, commit files and comparison content. Visited projects restore the complete bounded snapshot before Git root/status validation; uncached projects reuse the normal loaders in a transient store and publish the prepared panels together. The previous view stays visible during cold reads. Writes and commit editing are disabled during opening. Cancellation, fast repeated selection, invalid roots and parent-repository fallback retain the last valid project and reject obsolete completions.
- Prepared-file cache hits resolve synchronously during rendering. Cache misses retain the native file table and disable stale actions until background sorting finishes. Directory trees resolve cached nodes before first layout, refresh without recreating the same-project view, and render only expanded rows in a flat Table. This removes the recursive OutlineGroup diff that caused a real 6,000-file directory to monopolize the main thread. Directory disclosure, double-click, selection expansion, context menus, localized accessibility state and 22-point rows remain.
- Final focused native run passed 25 tests with zero failures (`RepositorySwitchLatencyTests|WorkspaceTableMouseTests|WorkspaceTreeCacheTests|WorkspaceTreeRenderingTests|WorkspaceFilePreparationTests|WorktreeRepositoryStoreTests|LocalizationTests`, `/tmp/raygit-atomic-switch-final-tests.log`). Covers blocked cold/warm opens, cancellation and root validation, cache bounds, table continuity through hits/misses, no tree-to-file-table intermediate frame, 6,000-descendant expansion/collapse and compact rows. Latest native file-table restoration to 6,001 rows was 0.122 s; warm model publication was 0.025 s and cold preparation 0.735 s. These are native-layout/model test timings, not mouse-to-screen video benchmarks. Four-language parity passed (43 tables, 1400 keys); diff check passed.
- Earlier full run executed 436 tests with 2 skips and 25 assertion failures across 12 NativeFocusAppearance/NativeFocusBridge cases (`/tmp/raygit-atomic-switch-all-tests.log`). Independently built HEAD 23e5b2b from a temporary git archive and reproduced exactly the same 12 cases/25 failures (`/tmp/raygit-atomic-switch-focus-baseline.log`). The full suite is therefore not green; final tree-renderer changes were validated by the focused run rather than repeating the entire suite.
- Disposable fixture path is recorded in `/tmp/raygit-atomic-switch-path`: Atlas has 6,001 changed files and Boreal has one. Final Release cold-switch validation blocked Boreal status: Atlas files, branches, history and comparison stayed visible with Stage disabled; releasing status replaced the panels with Boreal. Cached tree switches restored the target tree/history while status was blocked. Expanded, scrolled, double-clicked and collapsed the 6,000-file directory without the previous hang; its right-click menu remained. Screenshots: `/tmp/raygit-atomic-switch-cold-final.png`, `/tmp/raygit-atomic-switch-tree-final.png`. All fixture status blockers were released. Final QA exited normally; an earlier obsolete OutlineGroup QA had required SIGTERM after its hang was sampled.
- Release built with `./scripts/build-app.sh --no-install` (`/tmp/raygit-atomic-switch-release.log`). Normally quit and updated `/Applications/RayGit.app`; strict signature and executable equality passed. Relaunch restored giftdock/codex/ios-customer-chat, commit 7f8fcd95, 0/22 staged and the working-file comparison. No source commit/push or business-repository Git writes. First uncached projects still require real disk/Git reads; their old view now remains visible until the new view is ready.

### 2026-10-10 — Remove comparison waits from project switching and simplify deletion

- Routine read commands and detailed user command records now publish through a separate observable log model. The operation log still updates live, while individual internal Git completions no longer invalidate the entire workspace. The localization resource bundle is resolved once per process; language selection remains dynamic.
- Cold workspace opens publish prepared files, branches and history before reading the selected file comparison. Cached projects restore their snapshot first, validate fresh status, then update a changed comparison after enabling the loaded project. Unchanged cached comparisons skip the duplicate diff read. Existing root validation, cancellation and version guards continue to reject stale results and disable writes while validating cached repository data.
- File-table deletion defaults to unmodified Backspace, with a one-time migration from the former default Cmd-Backspace; custom and disabled shortcuts are preserved. The confirmation contains only the selected item count and Permanent Delete / Cancel / Move to Trash, with Return selecting Trash and Escape cancelling. Permanent deletion reuses the protected managed-path validation. Dialog action rows share native button styling with a minimum 80-point label width; native Clone/Create actions also keep their 80-point minimum without widening checkbox/icon controls.
- Final native focused run passed all 39 tests with zero failures (`/tmp/raygit-switch-delete-focused-final.log`), covering cold and changed cached projects with diff reads deliberately blocked, retained panels, latest-click ownership, root validation, unchanged-diff reuse, isolated log updates, keyboard/editing scope, permanent-delete path rejection, Trash/restore, native button widths, 6,000-file tree rendering and localization. Four-language parity passed (43 tables, 1404 keys); diff check passed. This turn did not repeat the full suite; the prior independently reproduced focus baseline failures remain documented above.
- A temporary read-only probe of real raydock/raymenu checkouts measured cold primary-data publication at 0.143/0.142 seconds and cached publication at 0.0021/0.0021 seconds (`/tmp/raygit-real-switch-model.log`). These are model timings, not mouse-to-screen frame measurements; the diagnostic test was removed afterward. Actual installed-app raydock → raymenu → raydock → raymenu → raydock transitions displayed the correct files/history and ended on raydock/main, commit 023bf63a, 0/0 staged. Final live sample: `/tmp/raygit-real-project-switch-final-sample.txt`; screenshot: `/tmp/raygit-switch-delete-installed-final.png`. Computer-use observation calls include their own settling/AX waits and were not reported as application switch latency.
- Disposable QA fixture from `/tmp/raygit-atomic-switch-path`: Backspace opened the count-only two-item confirmation; Cancel and Escape retained both files; Return moved both to Trash; both were restored through the directory-view recovery menu. Screenshot: `/tmp/raygit-delete-count-dialog.png`. Permanent deletion was covered by automated tests, not executed through the GUI. In the final Release, an actual blocked Git diff left Boreal files, branch, history and Stage available; switching back to cached Atlas remained possible. Releasing the blocker loaded Boreal's correct updated preview. Screenshots: `/tmp/raygit-switch-preview-blocked.png`, `/tmp/raygit-switch-preview-complete.png`. All blockers were released and the QA application exited normally.
- Final Release built locally with `./scripts/build-app.sh --no-install` (`/tmp/raygit-switch-delete-release-final.log`). Normally quit the installed application, copied the verified artifact to `/Applications/RayGit.app`, verified its strict signature and exact executable equality, then relaunched and checked the real project path. No source commit/push or business-repository Git writes were performed.

### 2026-10-11 — Project presentation within a 100 ms regression gate

- Known projects publish bounded memory snapshots synchronously. A bounded disk presentation cache and serial preparation of recent/open projects also retain files, branches, history and directory trees across application sessions. JSON work and filesystem alias/missing-root checks run off the main thread. Fresh Git validation runs after presentation; mutation remains disabled until validation completes. An entirely unprepared project retains the previous complete presentation until its real disk/Git reads finish.
- The main window reuses native virtualized file/tree tables and no longer registers a native toolbar in the custom shell. Its history/commit split is directly attached to the outer native split, removing an extra SwiftUI hosting/layout layer. File columns and the existing header menu update only changed properties. AppKit mouse tracking retains the actual clicked selection through stale SwiftUI binding updates; a previous repository's click completion cannot write the new repository's selection.
- Missing registered directories or `.git` metadata present Cancel / Remove from project list. Cancel retains the last valid project and draft; removal affects the catalog, tabs and presentation cache only. Security-scoped bookmarks are resolved before missing-root detection, and linked-worktree `.git` files remain supported. Automated coverage includes deletion of the current project, deletion during another pending switch, removed metadata inside a parent repository, moved directories and linked worktrees.
- The performance fixture renders the complete production-style main window with 6,001 files, 12 commits and 13 branches per project while Git status is blocked. Setup OCR verifies actual target labels; timed switches require target file/history/branch pixels, with an unchanged `XCTAssertLessThan(latency, 0.1)` gate. Six scenarios cover titled and borderless cached lists, cached trees, persisted first presentation with warm/cold row preparation, and persisted first tree presentation. Rapid switches include the previous validation's pending redraw; no settling wait is inserted between measured switches. This is an AppKit rendering regression, not a compositor/input-to-screen hardware benchmark or a guarantee for an entirely uncached filesystem read.
- Final Release functional gate passed 80 tests (`/tmp/raygit-mainwindow-four-host-functional.log`). After removing the intermediate footer host and redundant column assignments, both consecutive six-scenario performance rounds passed: 48 target presentations, 55.608–89.503 ms (`/tmp/raygit-mainwindow-four-host-six-run1.log`, `/tmp/raygit-mainwindow-four-host-six-run2.log`). Across eight switches per scenario, maxima were 71.362 ms titled list, 65.234 ms borderless memory list, 71.694 ms memory tree, 83.617 ms persisted list with prepared rows, 89.503 ms persisted list with cold row preparation, and 75.309 ms persisted tree with cold preparation. Earlier iterations exceeded the gate and remain failed evidence; they are not counted in these final two rounds.
- Separate focus checks ran 30 tests with 2 skips and the same 12 failing cases / 25 assertions as independently built HEAD 23e5b2b. Failed-case names were compared, with no additional failing case (`/tmp/raygit-mainwindow-four-host-focus.log`, `/tmp/raygit-atomic-switch-focus-baseline.log`). The full suite is not green and was not repeated after the final host change. Four-language static/parity checks passed (43 tables, 1407 keys), the build-script self-check passed (one test), and `git diff --check` passed.
- Final local artifact-only Release build succeeded (`/tmp/raygit-fast-project-release.log`); `.artifacts/RayGit.app` passed `codesign --verify --strict`. Computer use again reported that the Mac is locked and cannot be automatically unlocked. The final bundle has not replaced `/Applications/RayGit.app`; installed-app interaction, missing-project popup and physical screen/compositor acceptance remain pending manual unlock. No source commit/push or business-repository Git mutation was performed.


### 2026-10-11 — Large-change switching, native history/branches and unreadable-index isolation

- Main-window compact history and branch/stash lists now retain native virtualized tables. The standalone log retains its existing list. Native rows preserve selection, keyboard navigation, double-click actions, context menus, pagination and cached avatars. Empty history keeps the native table mounted. Materialized attributed strings avoid the observed CoreText first-draw exception; an independent cold text-draw test passed.
- First disk-cache switching decodes/prepares the target before publishing opening state, so the old project's busy presentation does not cause a separate full layout. Existing snapshots, guarded background validation, cancellation, missing-root checks and read-only cached state remain. Completely unprepared repositories still require real filesystem/Git reads and retain the prior presentation until ready.
- Status columns reserve the measured localized longest-label width, including combined staged/worktree states, and badge labels reserve their actual text width. Corrupt Git indexes retain the selected repository, show a localized file-pane/status-bar error and prevent mutations. Directory mode falls back to that error pane. The disposable corrupt-index fixture verifies usable history, cached revisit, blocked writes and recovery after an external index repair.
- The initial final-source functional run passed 98 related tests, including eight full-window performance scenarios (`/tmp/raygit-switch-coalesced-all.log`). Its 32 target presentations measured 57.502–92.409 ms. The separate repeat passed all nine selected performance/mouse tests, with 32 full-window target presentations at 53.968–91.209 ms (`/tmp/raygit-switch-coalesced-repeat.log`). All 64 target frames passed the unchanged 100 ms gate, including empty-to-6,001-file switching, 200-commit history, directory mode and first disk-cache presentation with cold row preparation. Target filename/history/branch pixels are checked against OCR-verified setup captures while Git status is blocked. This measures AppKit target rendering, not physical mouse-to-compositor latency or freshly validating an entirely uncached repository. Earlier >100 ms runs remain failed evidence and are excluded from these final rounds.
- `scripts/validate-project-switch.sh` provides the local release functional/performance/cold-text checks; `scripts/install-local-app.sh` verifies and installs the signed local artifact only after the app has quit. The standalone cold-text check passed one test (`/tmp/raygit-switch-cold-text-final.log`). Four-language checks passed 43 tables / 1,408 keys; build-script self-check passed one test, shell syntax and staged/unstaged diff checks passed. The full suite was not rerun; the independently reproduced HEAD focus baseline documented above is not claimed green.
- Local release packaging completed through `./scripts/build-app.sh --no-install` (`/tmp/raygit-switch-app-final-build.log`). Normally quit via the UI, installed through `./scripts/install-local-app.sh` (`/tmp/raygit-switch-install-final.log`), verified strict signature and exact executable equality, then relaunched `/Applications/RayGit.app`.
- Installed-app checks covered raydock's clean workspace → raymenu's 73 changes → raygit's 79 changes, repeated empty/changed switching, intact status labels, branch group folding/unfolding, remote branch selection and Command-C, remote double-click selecting origin/main in the standalone log, compact-history arrow selection/scrolling/context-menu details, Pull Cancel, Stash Cancel/Escape and name-prompt Escape. No Pull/Fetch/Stash/rename/commit action was submitted. Final project, file selection and history selection were restored to raygit/main, NativeCompactHistoryTable.swift and 23e5b2b9; the temporary verification draft was cleared. Screenshots: `/tmp/raygit-switch-installed-status.png`, `/tmp/raygit-switch-raymenu-installed.png`, `/tmp/raygit-switch-installed-final.png`.
- Actual vibe-island remains selected and can switch out normally; its Chinese index error opens the operation log, whose entries default to collapsed and expanded status details show the exact read-only Git command and raw failure (`/tmp/raygit-switch-vibe-installed.png`). The actual repository also has a corrupt HEAD loose object, confirmed by read-only `git log -1`, so its commit history cannot currently be displayed. Neither its index nor objects were repaired/reset/deleted. Index SHA256 stayed `e5f86b3775d6878f4aa1ae059c955752f152a1f5d15956db65dce1d83c392ab9` before and after runtime verification.
- Existing staged and unstaged source changes were preserved. No source commit/push or business-repository Git mutation was performed.

### 2026-10-11 — Production host, responsive file operations and foreground refresh

- The real borderless WindowGroup bootstrap no longer retains a second complete workspace. The new production-bootstrap regression checks that the hidden original host has no table, then renders the actual installed shell with 3,000 modified tracked files, 3,001 untracked files and 200 commits. Switching also avoids republishing already-idle AI/authentication/commit-request state. The latter removed an unnecessary follow-up layout observed on first disk-cache presentation.
- Stage, unstage and discard refresh files without rereading branches/history. Batch rename-origin and discard lookups use sets/dictionaries, preserving fresh-status preflight and path validation. Discard supports regular untracked files; ignored files, symlinks, directories and protected paths remain rejected. File-status columns preserve manual resizing and fit both localized badges. Local/remote branch folders support nested expansion and keyboard navigation while leaf actions retain full refs.
- Activation notifications manage all stores. Inactive stores cancel optional preparation/catalog/filesystem tasks and do no timer reads; foreground activation coalesces one refresh. Timers/catalog sweeps use at least 30 seconds, filesystem bursts coalesce at 300 ms, and automatic reads cannot overlap an explicit file refresh. Explicit operations still refresh immediately.
- Creation rereads the clipboard on every opening, replaces valid repository sources and automatic destinations, and announces successful creation to scroll/focus the new sidebar row. Only footer operation text opens its log. Sheets/alerts share the main window's eight-point outer clipping, and enabled default actions retain Return/highlight without stealing editor focus.
- Final functional run passed 133 tests (`/tmp/raygit-response100-all-final.log`); mutation/column/eligibility checks passed 29 tests (`/tmp/raygit-response100-mutations.log`). After the idle-state fix, both complete nine-scenario performance runs passed the unchanged 100 ms target-pixel gate: 72 presentations at 50.306–94.194 ms (`/tmp/raygit-response100-all-final.log`, `/tmp/raygit-response100-repeat.log`). Earlier 119/105 ms results remain failed evidence. The prior status-read assertion was corrected to count each existing mutation safety preflight plus its one file refresh, rather than incorrectly expecting only refresh reads.
- Opt-in `./scripts/validate-project-switch.sh real` read the actual raydock/raygit repositories with optional Git index writes disabled. Six cached full-window target-pixel checks passed at 35.376–59.437 ms; raydock had zero changed files and raygit had 99, with 12/24 commits and three branches (`/tmp/raygit-response100-real-final.log`). No business-repository mutation was performed. These are AppKit render/capture checks, not physical compositor timing or a guarantee for every application operation. An unprepared 6,001-row/5,000-selection file preparation measured 103 ms in the functional run and 95 ms in the repeat; that separate test does not claim a 100 ms cold-preparation guarantee. The full suite and its independently reproduced focus baseline were not rerun.
- Isolated Response QA (80 tracked `MM` files plus one untracked file) verified intact dual status labels, dragging the status column's right edge, stage/unstage-all with no selection, and unchanged history. Clicking footer blank space did not open a log; clicking its operation text did. Untracked discard opened the correct confirmation; Escape cancelled without deleting the fixture. Default action was highlighted. Screenshots: `/tmp/raygit-response100-qa-status.png`, `/tmp/raygit-response100-qa-resized-status.png`, `/tmp/raygit-response100-qa-discard-dialog.png`.
- Reopening Create with a newly copied `Empty` source replaced both the previous source and manually edited `Custom` destination. A local clone of the disposable source into `Cloned` completed via Return, selected/focused its row, scrolled the sidebar to the bottom, and displayed the clean worktree, five local/remote branches and fixture history. Read-only Git verification confirmed the clean clone and expected remote refs. Screenshot: `/tmp/raygit-response100-qa-cloned.png`. Business repositories were not modified.
- Initial sheet-layer radius checks missed the native larger corner mask. The first WindowServer capture regression also produced a false positive because `screencapture -l` returned a larger composite than the sheet frame. That candidate is not considered visual proof; actual-sheet bounds and keyboard/dismissal checks are required before final installation.
- Follow-up final-source comprehensive run executed 134 tests with one unchanged 100 ms gate failure: a cached tree target took 114.388 ms (AppKit layout 97.030 ms). The separate repeat had additional 107–208 ms outliers, including a 185.937 ms layout spike and cold scheduling gaps around 97 ms; subsequent frames returned to roughly 59–77 ms. Logs: `/tmp/raygit-response100-all-installed-source.log`, `/tmp/raygit-response100-performance-installed-source.log`. The earlier 72 passing frames remain useful evidence but are not a strict all-load 100 ms guarantee. No gate was relaxed. Concurrent system snapshots showed high WindowServer/Finder/ReportCrash CPU and heavy memory compression; this is context, not proof that every outlier is external.
- A corrected actual-xctest sample (`/tmp/raygit-switch-profile.txt`) identified repeated complete target-set construction in toolbar availability checks. Availability now short-circuits on the first eligible file and shares the existing eligibility predicate; actual mutations retain full target resolution. Tree-cache changes were not justified by the sample. `/tmp/raygit-profile-switch.sh` first matched a short-lived discovery helper and produced an empty sample; only the corrected xctest sample was used.
- Real QA confirmed the new visible eight-point sheet frame, blue default action, source-to-destination Tab navigation, and single-line destination Return cloning into `ClonedKeyboard`. Escape dismissed and repeated Create worked. Screenshots: `/tmp/raygit-response100-qa-create-8pt-active.png`. Native SwiftUI binding/dismiss remains on a transparent anchor while a key-capable child owns the existing content. A long 81-file alert exposed unconstrained fitting-size overflow; its message is now bounded and scrollable with actions outside scrolling, and shared frame sizing is capped to the visible screen.
- The adapted existing clone-focus test still reports the same three Tab assertions as the independently built HEAD baseline (`/tmp/raygit-clone-visible-focus.log`, compare `/tmp/raygit-atomic-switch-focus-baseline.log`). This inactive/non-running XCTest fixture is not claimed green; actual QA Tab and Return passed. New actual-key and screenshot regressions explicitly run an application event loop and activate the host, rather than hiding failures by forcing the visible panel key in assertions.
- Final sheet/keyboard/target-eligibility run passed 15 tests, zero failures (`/tmp/raygit-real-sheet-corner-tests.log`), including real eight-point WindowServer crops, a key-capable visible panel, Tab/Return/Escape and repeated dismissal, 1/81/1,000-line alerts with reachable actions, and toolbar availability equivalence to actual target resolution. Alert actions reuse the native focus button rather than relying on SwiftUI shortcut registration after moving the hosting content.
- After the toolbar availability optimization, the final nine-scenario performance/mouse run passed 18 tests and all 36 target presentations at 47.478–93.644 ms (`/tmp/raygit-response100-final-performance.log`). A real-repository check initially passed two target frames at 37.816/67.657 ms then failed exact pixel matching on its third switch (`/tmp/raygit-response100-final-real.log`). Added failure-only table/dimension/selection diagnostics and reference/target PNG capture without changing the timing/equality gates; its follow-up passed all six actual raydock/raygit target frames at 36.889–71.500 ms (`/tmp/raygit-response100-final-real-diagnostic.log`). The intermittent mismatch was not reproduced or attributed, and earlier 107–208 ms results remain failed evidence; these checks do not establish a universal application/compositor 100 ms guarantee.
- Updated isolated QA with the final release executable: the 81-file discard confirmation now fits the screen, retains its blue default and visible action row while scrolling the message, and Escape dismisses without changing its 81 files or staged count. Screenshot: `/tmp/raygit-response100-qa-long-alert-final.png`. No GUI permanent deletion was executed. The QA app exited normally after verification.
- Final local Release packaging completed through `./scripts/build-app.sh --no-install` (`/tmp/raygit-response100-final-build.log`, 95-second build). Quit the installed app normally, installed via `./scripts/install-local-app.sh` (`/tmp/raygit-response100-install.log`), and verified its strict signature and exact executable equality. Relaunch preserved the latest user state: sub2api/subapi, commit `34029132`, clean worktree and empty commit draft. Two installed-app raydock → raygit cycles showed the correct clean/100-change files, retained history/comparison and complete dual badges; restored sub2api/subapi and `34029132` afterward. Screenshots: `/tmp/raygit-response100-installed-raygit-final.png`, `/tmp/raygit-response100-installed-restored.png`. CUA observation includes its own settling waits and is not a physical 100 ms timing measurement.
- Final four-language checks passed 43 tables / 1,410 keys, build-script self-check passed, shell syntax and staged/unstaged diff checks passed. No source commit/push or business-repository Git write was performed. No full application suite, exhaustive every-view latency audit, or physical input-to-compositor benchmark was performed; the prior focus baseline failures and measured >100 ms outliers remain unresolved acceptance limits.

### 2026-10-11 — Dense HTML preview, amend-all, dialog count and text alignment

- The installed app's Rayon `design/website-astra/index.html` is approximately 56 KB / 77 source lines, including a 12,550-character line. A native sample (`/tmp/raygit-html-before-sample.txt`) identified `DiffTextSurface` / `alignWrappedRows` / TextKit full wrapping layout on the main thread. Alignment now waits for a usable pane width, and a bounded cache preserves four detached native text systems (at most two million UTF16 units) with their glyphs, paragraph alignment and scroll positions. Live windows never share a text view. Restoring a document also refreshes overview markers/navigation and search highlighting; complete content, line numbers and aligned rows remain.
- Amend without staged files now stages all currently unstaged workspace entries, including untracked files and deletions; ignored files remain excluded. Existing staged content still limits an amendment to the index. Fresh status/conflict validation remains, and message-only amendments do not stage an empty path list. Confirmations list at most 20 filenames and otherwise show a localized count. Native sheet anchors become transparent synchronously when the shared frame view attaches, before deferred shell installation, with native/visible window animations disabled. Native file status/name, branch/icon/check, directory and compact-history text now use measured text height for centering.
- `./scripts/validate-project-switch.sh preview-core` passed all 62 tests (`/tmp/raygit-preview-core-tests.log`), covering amendment safety, the 20/21-file boundary, synchronous frame hiding, text alignment, dense wrapping, independent live surfaces and existing comparison geometry/navigation/search. `RAYGIT_RESPONSE_HTML_PATH=/Users/kevin/Git-projects/Rayon/design/website-astra/index.html ./scripts/validate-project-switch.sh preview-html` passed two tests against the actual source (`/tmp/raygit-real-html-tests.log`): first native layout 163.909 ms, cached return 58.168 ms, ten unchanged layouts 5.840 ms. All 77 complete source lines and exact column row origins were checked. These native test timings are not physical mouse-to-screen measurements.
- `./scripts/validate-project-switch.sh performance` passed 18 tests (`/tmp/raygit-preview-switch-performance.log`), retaining the existing layout/pixel gates; all 36 target presentations were 41.602–85.301 ms. The two real-window activation tests in the initial 64-test `preview-ui` run failed while the Mac was locked. After the user unlocked it, all 12 dialog tests passed (`/tmp/raygit-dialog-unlocked-tests.log`), including actual visible-sheet geometry, keyboard activation and dismissal. Activation assertions were retained. Full-suite baseline focus failures from previous entries remain outside this run.
- Isolated Response QA verified the 81-file discard confirmation displays only “81 个文件”, with no filenames; Escape and repeated-open Cancel dismiss without deletion (`/tmp/raygit-preview-count-dialog.png`). With 0/81 staged, amendment showed no warning, prefilled the previous message and committed all 80 changed tracked files plus the untracked file. Independent Git checks confirmed a clean index/worktree, the new message, all expected contents in HEAD and one commit in history. Stash Cancel also dismissed without creating a stash. Dense HTML → PNG → HTML and clean-project switches retained all 77 source lines. No business repository was staged, committed or discarded.
- Installed-app HTML → image → HTML exposed an extra horizontal scrollbar on restoration: a fresh scroll view's default disagreed with the cached coordinator's wrap state. Scrollbar configuration now synchronizes independently of text-layout reconfiguration. The new regression dismantles the text surface for static preview, restores the same native documents and checks disabled horizontal scrollbars, width tracking, viewport widths and all 77 aligned row origins. The first final 65-test run had one unchanged 100 ms timing-gate failure (cached dense synthetic HTML 130.288 ms; `/tmp/raygit-preview-ui-final-tests.log`). The repeat passed all 65 tests, with 93.555 ms cached return (`/tmp/raygit-preview-ui-final-repeat.log`). The actual Rayon HTML run passed all three preview tests: first layout 218.380 ms, cached return 71.716 ms and ten unchanged layouts 7.216 ms (`/tmp/raygit-real-html-final-tests.log`). No timing gate was relaxed; the earlier outlier remains failed evidence, and cold/native timings do not guarantee physical input-to-compositor latency.
- Final Release built through `./scripts/build-app.sh --no-install` in 99.38 seconds (`/tmp/raygit-preview-ui-final-release.log`). Quit RayGit normally and installed through `./scripts/install-local-app.sh` (`/tmp/raygit-preview-ui-final-install.log`); strict installed signature and exact executable equality passed. Latest installed GUI validation confirmed giftdock → Rayon returns the selected `design/website-astra/index.html`, image `preview-desktop.jpg` → HTML restores wrapping without horizontal bars, all 77 source lines remain accessible, and Auto Wrap/Line Numbers/Synchronized Scroll remain checked. Screenshots: `/tmp/raygit-preview-installed-rayon-final.png`, `/tmp/raygit-preview-installed-html-restored-final.png`, `/tmp/raygit-preview-installed-wrap-menu-final.png`. Restored Rayon/app, commit `7bd1c4f0`, index.html, empty draft, amendment off and 0/8 staged.
- Final four-language parity passed (43 tables / 1,411 keys), build-script self-check and shell syntax passed, and staged/unstaged diff checks passed. Existing source/index changes were preserved; no source commit/push or business-repository Git write was performed. Full suite and frame-by-frame physical switching/corner-animation capture were not rerun; previous focus baseline failures and the measured timing outliers remain acceptance limits.

### 2026-10-11 — Compact panels and stable comparison scrolling

- The main file pane defaults to 340 points, and the sidebar branch pane defaults to 280 points. The native sidebar split retains its default or manually chosen branch height across window resizing. Remote trees start directly at each remote name (`origin`, `upstream`), without a generic remote group. Sidebar insets and the file filter bar are smaller; the operation toolbar has top/bottom borders; the main diff no longer repeats revision labels below its toolbar.
- Native scrollbar tiling temporarily expands the clip width before reserving the overview rail. Live QA and an added cached-document regression showed that this could reset the synchronized peer to y=0. Shared comparison scrolling now preserves the constrained viewport origin during tiling and wrapped-row reflow, ignores transient geometry notifications, and does not repeat a previous toolbar navigation after overview selection. Temporary diagnostic logging was removed.
- Final `./scripts/validate-project-switch.sh layout-scroll` passed all 70 tests, zero failures (`/tmp/raygit-layout-scroll-tile-fix-tests.log`), including cached-document scrolling, wrapped row alignment, overview navigation, sidebar resizing, branch targets, real sheets and localization. Actual Rayon HTML passed all five preview tests (`/tmp/raygit-layout-scroll-html-final-tests.log`): cold native layout 311.015 ms, cached return 66.428 ms, ten unchanged layouts 6.247 ms. Earlier runs retained performance-gate outliers and intermittently failed real-window activation assertions; the final gates were not relaxed. These timings are not physical input-to-compositor guarantees.
- Final isolated QA (`/tmp/raygit-layout-scroll-final-qa.json`) showed identical main-diff scrollbar positions through right-wheel down, left-wheel down and right-wheel up: 0.030996 / 0.061619 / 0.053963. Refresh and same-project selection retained the position. Independent editable comparison with full text on both sides also stayed synchronized (0.142843 then 0.285687). The two-sided fixture was prepared by staging only its disposable HTML and changing one phrase; no business files were staged, committed or discarded. Screenshots and AX observations verified the 340-point file divider, 280-point branch pane, remote roots, narrower insets, borders and removed duplicate labels.
- Release packaging completed locally via `./scripts/build-app.sh --no-install` in 90.37 seconds (`/tmp/raygit-layout-scroll-final-release.log`). The clean running application exited normally and was replaced using `./scripts/install-local-app.sh` (`/tmp/raygit-layout-scroll-final-install.log`); strict signature and exact executable equality passed. Installed UI retained sub2api/subapi, payment.ts and 0/24 staged, and the original payment.ts comparison was reopened at line 65, column 1, with wrapping/synchronization enabled and Save disabled. Four-language parity (43 tables / 1,411 keys), build-script self-check, shell syntax and diff checks passed. No source commit/push, full-suite rerun or physical latency benchmark was performed.

### 2026-10-11 — Fixed disclosure slots and insertion placeholders

- Branch disclosures use a fixed 14-point image slot and an independent title. The plain native table disables automatic content insets, reduces indentation, and routes the entire group row, including its text, to the disclosure button. Toolbar top/bottom borders remain visible. Recent commit messages appear directly in the commit options menu; choosing one restores its complete body.
- Both comparison surfaces reserve stable scrollbar geometry, disable elastic overscroll, and ignore transient scrollbar tiling during synchronization/reflow. Pure additions keep aligned empty space in the original pane with one red 1-point line. Editable target additions expose a red delete button, preserving validated edits and undo. Empty-file and terminal-insertion markers use actual glyph geometry, including Unicode source text. Navigation does not select missing placeholder text; the line draws after text selections so it remains visible.
- Final `./scripts/validate-project-switch.sh comparison-polish` passed all 49 targeted tests (`/tmp/raygit-comparison-polish-final-tests.log`). Dense synthetic HTML measured 116.262 ms cold, 35.238 ms cached, and 12.164 ms for ten unchanged layouts. The initial short-fixture test incorrectly inherited the long-document height assertion; the height gate was retained in the dense test and removed from the shared row-origin helper. Final four-language checks passed 43 tables / 1,412 keys; shell syntax and diff checks passed. The full suite was not rerun.
- Accepted isolated QA fixture: `/tmp/raygit-comparison-polish-accepted-qa.json`. Actual group-label clicks collapsed and reopened local branches, with stable icon/title positions. Main and independent comparison windows each passed 12 alternating wheel calls across both panes, including repeated calls at each endpoint: both scrollbar values remained exactly 0 or 1, with no observed reset. Records: `/tmp/raygit-polish-accepted-main-wheel.json`, `/tmp/raygit-polish-accepted-independent-wheel.json`. Screenshots verified the continuous thin red line and aligned blank space in the main preview and independent editor, including terminal additions; clicking delete removed only the first insertion and undo restored it with Save disabled. Read-only Git verification still reported exactly six added lines in the disposable file. Recent-menu entries appeared at the first level and their full body was visible after selection. Earlier candidates missed the text hit area and native selection overlay; only the accepted fixture is final evidence. No frame-by-frame compositor flicker measurement was performed.
- Final release packaging completed locally through `./scripts/build-app.sh --no-install` in 89.37 seconds (`/tmp/raygit-comparison-polish-final-build.log`). RayGit exited normally and installed through `./scripts/install-local-app.sh`; strict signature and exact executable equality passed (`/tmp/raygit-comparison-polish-install.log`). Installed GUI retained sub2api/subapi, `deploy/tests/deploy-all-test.sh`, amendment off, 0/24 staged, and the exact 228-character existing commit draft. Restored collapsed origin/upstream groups and confirmed their label clicks work. Screenshot: `/tmp/raygit-polish-installed-main.png`. Existing source changes were preserved; no source commit/push or business-repository Git mutation was performed.

### 2026-10-11 — Smaller branch disclosures and left inset

- Local/remote/stash group arrows shrink from 14 to 10 points; the tree gains six points of left inset. The fixed 14-point icon slot, hierarchy spacing, vertical centering and full-row disclosure hit area remain intact. Ordinary branch icons retain their 14-point size.
- `./scripts/validate-project-switch.sh branch-icons` passed all eight native branch tests (`/tmp/raygit-branch-icons-focused.log`). The broader `branches` run passed those eight tests but failed the existing `MainWindowSwitchPerformanceTests.testCompleteMainWindowCachedSwitchFirstTargetLayout` screenshot-region unwrap at line 236 (`/tmp/raygit-branch-icons-tests.log`); that check was not changed or claimed green. The full suite was not rerun.
- Local release build and installation ran through `./scripts/build-app.sh --no-install` and `./scripts/install-local-app.sh`; strict signature and installed/artifact executable equality passed (`/tmp/raygit-branch-icons-release.log`, `/tmp/raygit-branch-icons-install.log`).
- Installed-app inspection confirmed the smaller arrows and left inset, origin/upstream folding, and local-group folding by clicking its text. Local/codex groups were left expanded and origin/upstream/stash collapsed. Screenshots: `/tmp/raygit-branch-icons-collapsed.png`, `/tmp/raygit-branch-icons-expanded.png`. The current sub2api project, selected file and commit draft were preserved. No business-repository Git mutation or source commit/push was performed.

### 2026-10-11 — Compact branch titles and initial dialog focus

- Group disclosures now have a four-point visible gap between the arrow and title. Ordinary branch icons, tree indentation, vertical centering and full-row disclosure actions retain their existing behavior.
- Shared sheets, confirmation dialogs and popovers opt into initial keyboard focus. Explicit initial targets take priority, followed by editable input, the enabled default button and the native key-view loop. Inputs select prefilled text. Focus waits for a visible window and is restored after native popover presentation; ordinary updates do not reselect the input or steal focus. Main windows retain their existing Tab-entry behavior.
- Final `./scripts/validate-project-switch.sh dialog-presentation` passed all 33 tests, zero failures (`/tmp/raygit-dialog-focus-verified-tests.log`). Coverage includes hidden-window readiness, initial selection, retained user focus, disabled actions/default buttons, actual clone sheets and SwiftUI/native search popovers, and eight branch geometry/action tests. Actual key-window assertions use AppKit's running event loop; earlier async-only hosts failed activation or lost field editors, and those failed runs remain in `/tmp/raygit-dialog-focus-shipping-tests.log` and `/tmp/raygit-dialog-focus-clean-tests.log`. The earlier broader focus baseline was not rerun or claimed green.
- Isolated GUI QA verified direct input, visible blue search focus, Tab/Shift-Tab and Escape. The application must be activated before keyboard QA: background-only AX actions initially opened an inactive popover, and subsequent keyboard activation dismissed it. A diagnostic build confirmed this; its temporary runtime logging was removed before final packaging. Return executed the configured default stash action only in the disposable `raygit-response-qa-6w1pigxd/Changed` fixture. No business repository was staged, stashed, committed or discarded by this validation.
- Release packaging ran through `./scripts/build-app.sh --no-install` in 96.54 seconds (`/tmp/raygit-dialog-focus-shipping-build.log`). Installation through `./scripts/install-local-app.sh` passed strict signature verification and installed/artifact executable equality (`/tmp/raygit-dialog-focus-shipping-install.log`). Actual `/Applications/RayGit.app` inspection verified the narrower local/origin title spacing, automatic selection in the existing clone draft, keyboard traversal, and search opening ready for direct input with one matching result. Search was cleared and closed, the creation sheet was cancelled, and the current raygit/main project, clone draft and empty commit draft were preserved.
- Four-language parity passed 43 tables / 1,412 keys; script syntax and diff checks passed. The full suite and every individual dialog were not rerun. No source commit or push was invoked; subsequent test-host adjustments and this validation entry remain reviewable in the working tree.

### 2026-10-12 — Two-point branch spacing, tracking markers and alternating file rows

- Group titles and ordinary branch icons now have a two-point gap to their text. Local branches with an upstream show a link marker on the right with localized upstream help; the current-branch check remains alongside it. Git reads upstream metadata and includes local tracking configuration in the history refresh fingerprint, so config-only tracking changes refresh markers. Old cached branches without upstream metadata remain decodable.
- Both flat and tree file tables use AppKit's alternating row backgrounds. Shared sheets add a 20-percent black overlay above the native parent content, remove it on dismissal, and leave hit testing and accessibility traversal unchanged.
- Final `./scripts/validate-project-switch.sh sidebar-polish` passed 59 tests with zero failures (`/tmp/raygit-sidebar-polish-tests.log`). Coverage includes branch geometry, marker/current-check coexistence and reuse cleanup, old cache compatibility, setting/removing upstream without ref changes, both file table hosts, and actual key-capable sheets with overlay cleanup. Earlier candidates exposed a fingerprint compatibility failure and an inactive test host; both were resolved before this passing run. The overlay was moved out of NSHostingView into the native frame, and the unsupported-subview warning is absent from the final run.
- Isolated QA at `raygit-response-qa-o56ltl7k` visibly confirmed flat/tree stripes, compact branch titles and upstream link markers, deeper sheet dimming, repeated opening without accumulation, and restoration after Cancel. Screenshots: `/tmp/raygit-sidebar-polish-qa-main.png`, `/tmp/raygit-sidebar-polish-qa-tree.png`, `/tmp/raygit-sidebar-polish-qa-dialog.png`, `/tmp/raygit-sidebar-polish-qa-closed.png`. CUA keyboard attempts did not reliably dismiss the isolated sheet with Escape; Cancel was verified, and keyboard focus/key-window assertions passed in the native test host. No business repository Git operation was invoked.
- Local release packaging through `./scripts/build-app.sh --no-install` completed in 110.62 seconds (`/tmp/raygit-sidebar-polish-release.log`). RayGit exited normally, and `./scripts/install-local-app.sh` passed strict signature and executable-equality verification (`/tmp/raygit-sidebar-polish-install.log`). Installed GUI retained raymenu/main, `design/2026-10-07-website/export-preview.swift`, amendment off, an empty commit draft, and 0/35 staged. It displayed the link and current-branch check together, striped rows, compact local/origin/website titles, and a deeper creation-sheet overlay. Cancel restored the parent window, and the existing clone URL/destination draft was preserved. Screenshots: `/tmp/raygit-sidebar-polish-installed-main.png`, `/tmp/raygit-sidebar-polish-installed-dialog.png`, `/tmp/raygit-sidebar-polish-installed-final.png`.
- Four-language parity passed 43 tables / 1,413 keys. Script syntax and diff checks passed. The full suite, dark-mode visual acceptance and every individual dialog were not rerun. Changes remain uncommitted; no push was performed.
### 2026-10-12 — Stable sheet dimming and controlled fade removal

- Shared sheet dimming now draws its fixed 20-percent black background through `updateLayer`, and owns a 180 ms fade in/out. The view stays attached until fade-out completes; Reduce Motion disables the transition. Hit testing, accessibility, sizing, native modal ownership and the eight-point dialog frame remain unchanged.
- The original simple native/shell presentation fixture did not reproduce a fully transparent open-state mask (`/tmp/raygit-sheet-dimming-baseline.log`). The former dismissal did remove the overlay immediately. New tests verify the mask's rendered pixels at approximately 100/400/1,100 ms, parent redraw, restoration after dismissal, and retaining the view during fade-out. Final pixel validation via `./scripts/validate-project-switch.sh dimming` passed (`/tmp/raygit-dimming-pixels-final.log`): white parent baseline 1.000, opening sample 0.794, settled samples 0.771 in both window modes, and restored background after closing. The fade-removal test passed in the first combined run. Cleanup checks now wait at most 250 ms for the deliberate fade after the native sheet ends.
- The initial 37-test dialog-presentation run had cleanup/focus/key-window failures; the cleanup wait was corrected. The later 17-test dialog run was not green because the UI host could not activate, and CUA confirmed the Mac had auto-locked (`/tmp/raygit-dimming-dialogs-final.log`). These focus checks and installed-app GUI acceptance remain pending unlock; no full-suite success is claimed.
- Local release packaging succeeded through `./scripts/build-app.sh --no-install` (`/tmp/raygit-dimming-release.log`, 78.44-second build). The existing default build/install script then normally terminated RayGit and updated `/Applications/RayGit.app`, with strict signature and executable equality verified (`/tmp/raygit-dimming-install.log`). Build-script self-check, shell syntax, four-language parity (43 tables / 1,413 keys), and staged/unstaged diff checks passed. No source commit/push or business-repository Git write was performed.
### 2026-10-12 — Single native backdrop after opening/closing clarification

- The user confirmed the issue occurs on closing and also resembles two layers on opening. Measurements with the custom overlay hidden proved that the native sheet already supplies a stable backdrop: white-parent luminance was 0.837 with only the native backdrop, compared with 0.771 with the extra app overlay (`/tmp/raygit-dimming-native-owner.log`). Removed `DialogDimmingView` and all shell overlay ownership. Native sheet presentation now owns the only backdrop and its opening/closing animation; the earlier custom 180 ms fade attempt above is superseded. Existing modal bindings, keyboard focus and eight-point visible dialog frames remain.
- `./scripts/validate-project-switch.sh dimming` passed real WindowServer pixel checks in native and borderless hosts (`/tmp/raygit-single-dimming-tests.log`). Samples at approximately 100/400/1,100 ms consistently measured 0.837, with background restoration after dismissal and a 75 ms open/close/reopen sequence retaining a visible dialog and correct backdrop. `./scripts/validate-project-switch.sh dialogs` passed all 15 tests with zero failures (`/tmp/raygit-single-dimming-dialogs.log`), including actual presentation, input/default-button focus, Return/Escape, resizing and repeated dismissal. No background activation gate was relaxed.
- Local packaging via `./scripts/build-app.sh --no-install` completed in 87.83 seconds (`/tmp/raygit-single-dimming-release.log`). Normally exited RayGit and installed via `./scripts/install-local-app.sh` (`/tmp/raygit-single-dimming-install.log`); strict signature and executable equality passed. Installed GUI verified Create opening, Escape dismissal, reopening and Cancel, with no leftover backdrop. Screenshots: `/tmp/raygit-single-dimming-installed-open.png`, `/tmp/raygit-single-dimming-installed-closed.png`, `/tmp/raygit-single-dimming-installed-reopened.png`, `/tmp/raygit-single-dimming-installed-final.png`. Final state retained raydock/main, commit 023bf63a, empty commit draft, amendment off and 0/0 staged. No business repository mutation or source commit/push was invoked. Full suite and every individual dialog were not rerun.
### 2026-10-12 — Branch context menu and native name confirmation

- Removed the Log item from local/remote branch context menus. Remote menus now start with Create Local Branch; double-click/keyboard log navigation still exists. Tests continue to verify full remote references, busy permissions and rejecting stale menu payloads after repository replacement.
- Branch/tag/stash naming prompts now own their editing state inside `NamePromptSheet`, initialized from the request and reset by request identity. Native `KeyViewProxy` controls provide mouse targets, default Return and Escape cancellation. Confirm passes the edited name directly to the existing guarded action; empty-name validation and repository/busy checks remain. Git branch creation and checkout semantics were not changed.
- The original signed app showed the correct `website/app-store` default for `origin/website/app-store`. In disposable QA `raygit-response-qa-4aviftyu`, accessibility activation created that local branch at the remote OID while main and the 81 changed/staged entries remained; a subsequent coordinate mouse click on Continue reached Git's duplicate-branch error without overwriting it. That stable baseline did not reproduce the user's inability to click. The user clarified that Continue itself could not be clicked, so native controls and local form state address the reported interaction rather than changing valid Git ref syntax.
- `./scripts/validate-project-switch.sh branch-save-core` passed 12 tests (`/tmp/raygit-branch-save-core.log`), including remote-tip preservation, duplicate/option rejection, menu changes, stale action guards and button width. The new complete main-window prompt test checks native mouse hit testing and the created ref; its waiting condition now includes completed user operation records rather than assuming a native button's action is delivered synchronously. The final GUI attempt was blocked by Mac lock/host activation failure (`/tmp/raygit-branch-save-final-tests.log`), confirmed by CUA; installed-app mouse/Return/Cancel acceptance remains pending unlock. Full-suite success is not claimed.
- `./scripts/build-app.sh --no-install` built the signed release in 76.29 seconds (`/tmp/raygit-branch-save-release.log`). The existing default build script normally terminated RayGit and installed it into `/Applications/RayGit.app`, with strict signature and exact binary equality verified (`/tmp/raygit-branch-save-install.log`). Fresh isolated QA `raygit-response-qa-gy_d0td8` is prepared with an `origin/website/app-store` tip distinct from main. Existing working-tree dialog/validation changes were preserved. Four-language parity (43 tables / 1,413 keys), build-script self-check, Python/shell syntax and diff checks passed. No source commit/push or business-repository Git write was performed.

### 2026-10-12 — Pull merges diverged branches

- Shared native Pull now runs `git pull --no-rebase --ff --no-edit --progress`: fast-forward when possible, otherwise merge both histories without launching an editor. Explicit flags override `pull.ff=only` and `pull.rebase=true` for this operation without modifying repository configuration. Toolbar and network-panel callers share this path; Pull / Fetch / Cancel and the default Return action remain. Four-language regular/diverged explanations now describe merge behavior; Chinese divergence summaries no longer imply all such errors are fast-forward-only failures.
- `./scripts/validate-project-switch.sh pull-merge` passed 35 tests (`/tmp/raygit-pull-merge-tests.log`), including real local bare remote/two-clone fast-forward, two-parent divergence merge, retained local/remote files, unchanged pull configuration, editor refusal avoidance, overlapping uncommitted-change protection and content-conflict `MERGE_HEAD`/index/content preservation. Guarded force-push and authentication checks passed. The first attempt encountered a stale, nonexistent Git wrapper in the XCTest-only defaults domain; clearing that leftover test preference restored the normal `/usr/bin/git` fallback. Application preferences were not changed.
- Release packaging passed via `./scripts/build-app.sh --no-install` (`/tmp/raygit-pull-merge-build.log`). Isolated signed GUI fixture is recorded in `/tmp/raygit-pull-merge-qa-path`: toolbar Pull displayed the new divergence explanation, then completed with an actual two-parent merge and clean worktree. Return in the conflict fixture started Pull, refreshed the list to `shared.txt` conflict and displayed localized “请先解决冲突再继续”; filesystem checks confirmed `UU` and the remote merge parent. CUA occasionally returned a zero-size sheet capture error, but subsequent AX reads and actual Git results confirmed both actions.
- Normally quit and installed through `./scripts/install-local-app.sh` (`/tmp/raygit-pull-merge-install.log`); strict signature and executable equality passed. Relaunched `/Applications/RayGit.app` and verified the main workspace. No business-repository Pull/merge/push or source commit was performed. Full suite, independent network-panel interaction and internet-remote Pull were not rerun.

### 2026-10-13 — Recover unmerged index entries outside an active Git operation

- Workspace discard eligibility now includes conflicted rows in the toolbar, file actions and context eligibility. The shared tracked-path operation validates the complete batch before mutation, protects active merge/cherry-pick/revert/rebase/sequencer state, restores conflicted paths and their index from HEAD, and uses Git removal for conflicted paths absent from HEAD. Ordinary worktree discard still preserves staged index contents. Four-language conflict confirmations describe the HEAD/index treatment and deletion behavior.
- Workspace/file focus now routes Cmd+R and advanced reset to a freshly loaded HEAD commit, including when a history search returns no commits. Focused history still uses its selected commit. Existing native editor/terminal shortcut ownership and the guarded reset confirmation remain. No reset occurs merely by pressing the shortcut.
- `./scripts/validate-project-switch.sh conflict-recovery` passed 24 focused tests (`/tmp/raygit-conflict-recovery-final-tests.log`): real failed stash-apply UU/DU conflicts without MERGE_HEAD, HEAD-absent deletion, hard reset of an unmerged index, active-operation markers, full-batch rejection, ignored/untracked-path safety, preservation of normal staged contents and existing reset/shortcut behavior. Initial candidates failed on the deleted side of a conflict; final Git removal handling fixed that case. The source checkout initially contained 14 unmerged/missing files, so the first diagnostic run used a temporary HEAD source archive with the scoped patch; no worktree or reset of that checkout was performed. The merge state was subsequently cleared by an external operation, and the final passing run/build used the real checkout.
- Isolated signed GUI fixtures were generated by `scripts/prepare-conflict-recovery-qa.py`. In `raygit-conflict-qa-nyjk3_e7`, Command-click deselected the only selected row, and toolbar Discard included all three files, clearing both conflicts while retaining the normal staged file (1/1 staged). With history filtered to zero commits, file-focused Cmd+R showed the current HEAD; cancel retained both conflicts. History-focused Cmd+R showed the explicitly selected older commit; cancel retained the branch. Returning to file focus reset to HEAD, leaving a clean index/worktree without moving HEAD. Independent Git reads verified all outcomes. Final release fixture `raygit-conflict-qa-cfxil7ph` also showed the new localized conflict warning and successfully discarded all conflicts while preserving the normal staged content. Both QA apps exited normally.
- Final release packaging through `./scripts/build-app.sh --no-install` succeeded (`/tmp/raygit-conflict-recovery-final-release.log`, 58.35 seconds). The installed app exited normally; `./scripts/install-local-app.sh` installed and verified the strict signature and exact executable (`/tmp/raygit-conflict-recovery-install.log`). Relaunch retained raygit/main, the empty commit draft and amendment off. In the installed app, file-focused Cmd+R showed main HEAD `12d55243` rather than the selected commit from another history reference; Cancel left the actual repository unchanged. No real-repository reset/discard, source commit or push was invoked. Concurrent unrelated stash/date/branch changes were retained.
- Four-language parity passed (43 tables / 1,425 keys); shell syntax and diff checks passed. The full suite was not rerun. The passing focused run preceded the final focus-based reset target routing and confirmation wording; the built GUI separately verified both and retained the same tested Git recovery implementation.


### 2026-10-14 — Explicit conflict resolution before staging and commit

- Conflict files now offer Resolve Conflict in SwiftUI, flat native and tree native file menus. The action opens the existing three-pane editor. Use Ours, Use Theirs and Use Both act on the current conflict; the reverse Both order remains in More. Save and Mark Resolved validates the file/source snapshots and remaining markers before staging the result. Normal Stage refuses any selected unmerged file before modifying the batch, and existing commit guards continue to reject repositories with remaining conflicts. All four languages include the new labels.
- `./scripts/validate-project-switch.sh conflict-resolution` passed 50 XCTest cases plus 3 Swift Testing tests / 13 parameter cases (`/tmp/raygit-conflict-resolution-tests.log`). Coverage includes all seven conflict statuses, both native menus, stale-stage refusal, mixed-batch atomic rejection, marker-free edits still requiring explicit resolution, all four side/order choices, and preservation of an unrelated file's different staged/worktree contents. The tree menu test routes a synthetic native right-click through the table's menu override. `conflict-resolution-workflows` passed 59 Git workflow cases (`/tmp/raygit-conflict-resolution-workflows.log`), including merge, pull, rebase, partial staging and recovery. The existing stash-reapply test now explicitly marks its resolution instead of implicitly staging an unmerged file.
- In isolated signed QA `raygit-conflict-qa-4e_hsqzt`, right-click showed Resolve Conflict enabled and Stage disabled. Use Both changed only the editor draft until Save and Mark Resolved; one remaining deleted-side conflict kept a nonempty commit draft disabled. Resolving that file using its complete theirs version enabled Commit. The disposable GUI commit produced exactly one new commit with both conflict sides retained, the deleted file restored, and only the normal file's preexisting staged text included; its unstaged text remained unchanged. Independent Git assertions confirmed all contents and an empty unmerged index.
- Actual tree-mode right-click initially failed to present a menu despite its menu-construction tests passing. TreeTable now explicitly presents its native context menu on rightMouseDown. Final release QA `raygit-conflict-qa-l4uizrz8` verified the tree right-click menu, opening the resolver, Use Ours and Save and Mark Resolved. Independent Git assertions confirmed only that conflict was resolved and the other conflict plus staged/unstaged normal contents were preserved. Screenshot: `/tmp/raygit-conflict-resolution-ours.png`. Both QA apps exited normally.
- Final signed packaging used `./scripts/build-app.sh --no-install` (85.91 seconds, `/tmp/raygit-conflict-resolution-release.log`). The official app was normally quit, `./scripts/install-local-app.sh` installed and verified signature/executable equality (`/tmp/raygit-conflict-resolution-install.log`), and `/Applications/RayGit.app` relaunched on the user's latest stashx/main project with its empty commit draft and amendment off. No business-repository conflict resolution, stage, commit or push was performed. Existing revision-copy editing changes were preserved.
- Four-language parity previously passed 43 tables / 1,436 keys; build-script self-check and final diff/shell checks passed. Full suite and every binary/deletion conflict variant were not rerun; binary conflicts continue to use whole-version restoration rather than text concatenation.


### 2026-10-14 — Project switching with large conflict previews

- Reproduced stashx to raydock using the installed app and its real 117,817-byte conflicted implementation document. Main-thread samples identified rebuilding three text systems before meaningful geometry, repeated TextKit sizing/alignment, and canonical Unicode comparisons against mutable NSString-backed text. See `/tmp/raygit-stashx-raydock-switch.sample.txt` and `/tmp/raygit-real-switch-current.sample.txt`.
- Comparison panes now receive their first content after initial native setup, without creating an undo operation or selecting a pane. Detached panes and invalid narrow viewports do not trigger automatic document measurement. Logical text comparisons use contiguous UTF-8; unchanged column configuration and height-only changes do not rebuild wrapping/alignment. Document sizing is reused until text, paragraph geometry, width or font configuration changes. Internal sizing preserves viewport positions without broadcasting temporary shrinkage to other panes.
- Read-only workspace conflicts use a bounded detached native-view cache (four documents / two million UTF-16 units), keyed by repository, path and complete column content/metadata. Mounted views and editable comparison drafts cannot be shared. Returning restores scrolling and conflict selection and rebinds current commands. Workspace headers compute conflict blocks once per body evaluation; the coordinator reuses its current parsed blocks. Existing revision-copy and conflict-resolution changes remain intact.
- Final `./scripts/validate-project-switch.sh switch-responsive` passed 53 XCTest cases plus 2 Swift Testing tests / 9 parameter cases (`/tmp/raygit-switch-responsive-tests.log`). Coverage includes cache ownership, changed-source rejection, eviction/budget, selected conflict restoration, full text retention, resize/alignment, search/navigation, undo/edit copies, slow Git/preview cancellation, stale-root protection and native context actions. The 169,244-byte wrapped synthetic document measured cold 421.35 ms / cached return 30.51 ms. Timing-only intermediate candidates and the initial focus/viewport regressions were repaired or retained as failed evidence; no full-suite claim is made.
- Large-list validation passed 18 cases / zero failures (`/tmp/raygit-switch-large-lists.log`), with 36 measured switches at 47.06–90.96 ms for complete first target list/history/branch pixels. Cases include 6,001 files, 200 commits, tree layout, disk caches and real borderless bootstrap. The old fixture incorrectly recognized branches by an obsolete fixed row count; it now identifies the native branch table type, while retaining OCR, pixel parity and its 100 ms assertions. This passing stress run preceded the last document-sizing/detached-layout refinements.
- The initial final real-project runs passed 2 cases and measured 57–90 ms including the largest conflict preview. Subsequent verification added wrapping, excluded temporary avatar placeholders from reference images, and copied preview strings to contiguous UTF-8 so verification itself does not incur the NSString comparison slow path. The latest 3-case live-repository run (`/tmp/raygit-switch-real-tests.log`) failed the strict per-switch 100 ms timing assertions: 70–434 ms, with all target contents/pixels reached. Concurrent desktop sampling showed high Codex Renderer/WindowServer and other-app load; that is a measured limitation, not proof that all overruns come from external load. The failures remain visible; the suite is not reported green.
- An intermediate signed build was installed and CUA verified two real stashx/raydock round trips, complete three-pane document preview, unchanged 3 conflicts / 5 of 8 staged, empty commit draft and amendment off. Its sample `/tmp/raygit-switch-installed.sample.txt` exposed additional full-document sizing, which led to the final measurement cache and detached-window guards. Screenshot: `/tmp/raygit-switch-installed.png`. The user subsequently switched to giftdock; that latest project was preserved when normally quitting for final replacement. No business-repository stage, conflict resolution, commit, reset or push was invoked.
- Final release packaging passed through `./scripts/build-app.sh --no-install` (117.54 seconds, `/tmp/raygit-switch-responsive-release.log`). The first install refused to replace a reopened app. CUA normal-quit inspection subsequently timed out, while process sampling showed the existing app idle on its main run loop (`/tmp/raygit-switch-reopened.sample.txt`). The existing default `./scripts/build-app.sh` used NSRunningApplication normal termination and successfully installed the final bundle (`/tmp/raygit-switch-responsive-install.log`); no force termination was used. Strict signature and installed/artifact executable equality passed afterward. CUA getApp and inventory both then timed out and reset their kernels; final installed GUI switching acceptance remains incomplete. No final running RayGit process was found after the timed-out CUA launch attempts; the final bundle is installed but not confirmed launched.
- Four-language checks passed 43 tables / 1,436 keys, build-script self-check and shell/diff checks passed. Temporary geometry traces were removed from product source. Existing dirty work was preserved; no source stage/commit/push, worktree or VPS build was performed. Full suite and exhaustive switching across every repository were not run.

### 2026-10-14 — Direct conflict choices, recovery and immediate selection

- Resolve Conflict is now a submenu in flat, tree and SwiftUI file menus, offering Ours, Theirs, Both and the existing editor. Whole-side choices retain deletion semantics; Both replaces conflict blocks while retaining surrounding text. Save leaves the unmerged index and editor open; Save and Mark Resolved closes only after successful validation/staging. Resolved paths with Git resolve-undo data offer Recreate Conflict with a replacement confirmation. Delete/modify recovery uses the restored index stages instead of relying on checkout -m alone. Unresolved conflicts still block ordinary staging and commit.
- Native file/tree/branch/repository/history selections update icons, graph and text immediately. Full history uses the shared native graph painter and restores history-list focus after opening a requested commit, without taking a field editor's focus. Explicit content focus survives initial native focus cleanup without enabling keyboard rings. The regression host now activates after creating its window; the existing synthetic Tab test explicitly invokes the local monitor before direct window dispatch.
- Comparison rails connect actual text fragments with curved bands; aligned placeholder spacing is excluded from source/target geometry. Conflict previews reuse alignment bands instead of comparing the entire document for every block. Merge/Rebase banners offer Continue, disabled for unresolved conflicts, with operation/status revalidation before running Git.
- Final ./scripts/validate-project-switch.sh conflict-interactions passed 82 XCTest cases and 5 Swift Testing tests / 17 parameter cases with zero failures (/tmp/raygit-conflict-interactions-tests-final.log). Coverage includes native menus and immediate selection, save/resolve failure behavior, repeated restoration, deletion choices, preserving staged/worktree differences, curves with alignment gaps, history opening/focus, merge/rebase and four-language parity. Earlier focus candidates failed; the final combined run includes the repaired focus checks. The full suite was not run.
- Isolated GUI fixtures raygit-conflict-qa-muq4b6pg and raygit-conflict-qa-dm7copaa verified direct Both resolution, recreation, independent Save retaining UU, successful Save and Mark Resolved closing the editor, and merge/rebase continuation. Independent Git assertions passed (/tmp/raygit-conflict-interactions-git.json); unrelated staged and worktree contents remained separate. Final curve screenshot: /tmp/raygit-conflict-curves-final.png. No business-repository resolution, stage, continuation or commit was invoked.
- Final packaging through ./scripts/build-app.sh --no-install completed in 102.22 seconds (/tmp/raygit-conflict-interactions-release-final.log). The official app exited normally; ./scripts/install-local-app.sh verified the installed signature and executable equality (/tmp/raygit-conflict-interactions-install-final.log). The user switched to raygit before installation, so the latest raygit/main session was preserved with CompareWindow.swift selected, empty commit draft, amendment off and 0/58 staged. Installed double-click selected 3c509b36 immediately with a blue history row and white text/graph (/tmp/raygit-conflict-interactions-installed-log-final.png); the read-only log window was then closed. Four-language parity passed 43 tables / 1,443 keys; build-script self-check, shell syntax and diff checks passed. Changes remain uncommitted and unpushed.

### 2026-10-14 — Comparison drawing crash and SmartGit connector geometry

- Inspected the installed-app crash report RayGit-2026-10-14-150046.ips (incident B2B95EF4-AE5C-4505-8028-5EDD758172E8). Its main-thread Objective-C exception occurs in CoreText font attributes while LineGutter.draw calls ComparisonEditorMetrics.signWidth through NSString.sizeWithAttributes. Sign widths now use font size directly and the plus/minus marks draw as vector strokes, removing both repeated sign measurement and fallback-glyph drawing from the gutter repaint path. The exact old exception was not deterministically reproduced in the test host.
- Observed SmartGit 26.1's real Conflict Solver on disposable Merge/conflict.txt. Curved backgrounds follow both block edges with short horizontal shoulders; arrows stay next to the source block. RayGit now uses a wider 56-point connector slot that compresses before the code viewport does in a narrow window, source-side arrow positioning and change/conflict colors. Empty insertion edges use the preceding real line's bottom (or document start), before alignment padding, including EOF and leading placeholders. Both gutter/current-line and conflict backgrounds use the same real-fragment boundaries as the connectors, leaving trailing alignment padding neutral. Unlaid source geometry does not produce a misleading rectangle. Existing saved file contents and resolution semantics are unchanged.
- Final ./scripts/validate-project-switch.sh comparison-crash passed 24 XCTest cases with zero failures (/tmp/raygit-comparison-crash-tests.log). Checks cover 2,400 sign strokes across editor font sizes, 24 actual native comparison repaints with Chinese/emoji/Arabic text and resizing, neutral placeholder pixels, insertion/EOF placeholders, arrow geometry, wrapped fragments, narrow-window positioning, synchronized edge scrolling, acceptance/undo and cache ownership. The 169,244-byte conflict fixture measured cold 418.84 ms / warm 50.95 ms. Intermediate candidates failed pixel sampling or narrow-window position checks; those were fixed before this passing run. One otherwise functional run exceeded the existing 500 ms cold-layout gate at 1,691.17 ms; concurrent high desktop process load was observed, but it is not proof of attribution. The subsequent passing run retains the 500 ms / 100 ms gates, and timing variation remains a limitation.
- ./scripts/validate-project-switch.sh conflict-interactions also passed 87 XCTest cases plus 5 Swift Testing tests / 17 parameter cases (/tmp/raygit-comparison-conflict-regression-final.log). Four-language parity remains 43 tables / 1,443 keys. Full-suite and long-duration runtime checks were not run; no source stage, commit or push was performed by this task. Preexisting user-staged work was retained.
- Final ./scripts/build-app.sh completed packaging and normal-quit local installation in 106.53 seconds (/tmp/raygit-comparison-crash-release-final.log); strict signature and artifact/installed executable equality passed afterward. The CUA background launch initially timed out while process sampling showed an idle main run loop; opening through Finder successfully displayed raygit/main. Installed GUI opened the selected scripts/prepare-response-qa.py comparison, displayed curved insertion connectors and vector signs, navigated to the next change, and closed back to the original main-window selection with 58/58 staged, amendment off and an empty draft. No real file was accepted, saved or staged during verification, and no new RayGit crash report appeared.
- Disposable QA raygit-conflict-qa-kbp7tns0 validated a source-side arrow and Undo restoring the original conflict without disk changes. Final-bundle QA raygit-conflict-qa-fv8rv5vu visibly confirmed one-line source edges joining a five-line conflict, neutral alignment placeholders and source-side arrows; independent Git status retained UU conflict.txt, DU deleted.txt and MM normal.txt. Both QA apps exited normally. The official main window was restored to the foreground. Screenshot evidence is in the CUA transcript; this request did not export additional image files.

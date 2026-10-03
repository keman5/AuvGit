# 后续路线图实际状态（2026-10-03）

本表按实际入口登记。实现不是签名分发/真实远端/复杂仓库专项验收的替代品；统一测试与视觉验收由主代理记录。

| 项目 | 当前实现与入口 | 剩余/前提 |
|---|---|---|
| 初始化/克隆 | 工具栏“创建仓库”，目录选择、初始化/URL或本地路径克隆 | 真实私有远程认证由系统现有凭据提供 |
| 仓库分组 | 仓库侧栏右键设置组，持久化；可折叠分组树 | 默认展开未分组和已有组 |
| 安全书签 | 保存/恢复 security-scoped bookmark，仓库切换释放访问 | sandbox签名配置需专项验收 |
| 自动刷新 | FSEvents递归监听仓库/git-dir/common-dir，350ms debounce；3秒status/ref/HEAD/index/文件stamp兜底，窗口激活刷新 | debounce仅取消睡眠任务；处理中事件合并；成功刷新更新fingerprint；树跟随generation重新读取 |
| 仓库标签页 | 顶部仓库标签；跨重启保存打开顺序、活动仓库、每仓库提交草稿/amend、历史筛选/深提交选择及文件选择 | 500ms debounce与退出flush；不可访问活动仓库自动回退但保留其标签/草稿；损坏数据保留副本并恢复有效备份 |
| 目录树/ignore/rename/trash恢复 | 文件区域树/列表切换；节点菜单rename/废纸篓/恢复/ignore，工具栏编辑.gitignore及读取忽略列表 | 恢复记录按仓库持久化；目标已存在时拒绝覆盖；路径安全预检 |
| commit template/signoff/signing/amend | 提交面板加载模板/Signed-off-by/amend空说明填充；仓库工具设置模板/签名密钥/启用签名 | GPG/SSH工具、有效密钥、真实签名验证为外部前提 |
| 任意两引用比较 | 仓库工具“比较两个引用”；首次读取固定两个commit hash，结构化变更文件列表联动DiffPane | 标题保留输入refs名称；切文件使用同一hash快照，浮动HEAD不会导致列表/差异基准不一致；重命名包含原路径 |
| 作者筛选/hash跳转 | 历史作者字段由Git过滤后分页；hash Enter解析任意有效提交并打开详情 | 文件rename-follow历史先遍历后筛选，保持正确性 |
| Blame/Reflog | 仓库工具Blame作者/日期/hash/行号/代码表格，Reflog引用/作者/日期/hash/操作表格；选中、双击/右键打开提交、复制 | Blame基于固定提交读取；Reflog日期来自引用日志而非提交作者时间 |
| tracking/upstream/tag | 仓库工具创建跟踪分支/设置上游；标签管理表格、附注/签名创建、获取、删除；远程推送/删除先dry-run再确认 | 签名标签依赖真实密钥；远端凭据沿用系统 |
| ahead/behind/remote/push预览/lease | 仓库工具可读计数、remote增删、dry-run及lease确认 | 网络面板已实现进度/取消/凭据；真实认证需专项验收 |
| 部分stash/rename | 仓库工具逐行路径贮藏；stash改名锁住ref并原子只改指定reflog消息 | 日期、顺序、OID保留；特殊非UTF8 reflog拒绝 |
| merge/reset/continue/abort | 仓库工具专属引用字段，写操作确认；merge/rebase/cherry/revert继续和中止 | merge冲突继续需先解决所有冲突；自动三方合并由比较器入口提供 |
| 交互式rebase | 仓库工具基于Git原生--rebase-merges生成准确计划；编辑pick/drop/squash/fixup/reword/edit/break/label/reset/merge/update-ref/exec及顺序，reword/squash/merge -c完整多行说明编辑 | 完整可滚动预览仓库/base/HEAD/todo/说明及exec命令后确认；仅显式编辑计划中的exec获确认才执行；继续/中止可跨暂停保留消息编辑器；不静默丢merge拓扑 |
| submodule/LFS | 仓库工具状态/init-update/add与LFS status/install/track | 网络凭据、git-lfs本机binary和服务器支持为外部前提 |
| GitFlow/PR/快捷键/更新与公证 | 设置页GitFlow feature/release/hotfix start/finish、PR网页入口、快捷键、HTTPS更新manifest检查；scripts/notarize-app.sh提供本地签名/公证/装订流程 | Developer ID/Apple公证凭据与可信签名更新分发服务器尚未提供 |

## 无需真实远端或签名凭据的完成工作流

初始化/本地克隆、会话标签/可折叠分组/书签、递归文件监听、目录树/ignore/rename/废纸篓恢复、部分暂存/索引编辑、提交模板/signoff/amend、作者分页/hash/Blame/Reflog、任意refs变更文件联动、标签管理、本地merge/reset/continue/abort、部分stash和保序改名、保留merge拓扑的交互式rebase与完整消息编辑、结构化历史表格、GitFlow和快捷键配置均有实际入口。对应集成测试只操作临时仓库和本地bare remote；统一测试/原生UI结果由VALIDATION记录，不能由“已实现”推定全部UI验收。

## 已实现但依赖外部条件

私有远端克隆/同步/remote标签发布使用用户已有系统凭据；LFS操作需要本地git-lfs和服务器支持；提交/标签签名需要可用密钥及GPG/SSH配置；Developer ID公证需要Apple签名身份和凭据；HTTPS更新检查需要用户提供可信manifest和签名发行基础设施。PR/MR入口只打开本机默认浏览器页面，是否发布由用户在站点操作。

## 明确受限的实现

交互式rebase采用Git原生保留合并拓扑计划，禁止把原merge提交直接改成pick而静默压平；exec需要用户在计划中显式添加并完整预览确认。Blame/Reflog提供结构化列及提交入口。仓库标签、草稿、筛选和选择跨重启保存；无法访问路径保留以便重试。真实签名、公证和远程服务仍受上述外部条件约束。

# 后续路线图实际状态（2026-10-03）

本表按实际入口登记。实现不是签名分发/真实远端/复杂仓库专项验收的替代品；统一测试与视觉验收由主代理记录。

| 项目 | 当前实现与入口 | 剩余/前提 |
|---|---|---|
| 初始化/克隆 | 工具栏“创建仓库”，目录选择、初始化/URL或本地路径克隆 | 真实私有远程认证由系统现有凭据提供 |
| 仓库分组 | 仓库侧栏右键设置组，持久化显示组名 | 当前以组前缀显示，尚非可折叠分组树 |
| 安全书签 | 保存/恢复 security-scoped bookmark，仓库切换释放访问 | sandbox签名配置需专项验收 |
| 自动刷新 | 3秒轮询状态/ref与修改文件mtime/size，窗口激活刷新 | FSEvents事件驱动未完成；极端相同mtime/size覆盖存在限制 |
| 仓库标签页 | 顶部打开仓库标签，切换保留commit draft/amend，关闭同步下一仓库 | 历史选择、文件选择未按仓库完整保存 |
| 目录树/ignore/rename/trash恢复 | 文件区域树/列表切换；WorkspaceTree独立菜单 | 由文件工作流代理实现/验收 |
| commit template/signoff/signing/amend | 提交面板加载模板/Signed-off-by/amend空说明填充；仓库工具设置模板/签名密钥/启用签名 | GPG/SSH工具、有效密钥、真实签名验证为外部前提 |
| 任意两引用比较 | 仓库工具“比较两个引用”，专属引用字段，DiffPane渲染 | 当前是整个提交差异，尚无结构化文件列表联动 |
| 作者筛选/hash跳转 | 历史作者字段由Git过滤后分页；hash Enter解析任意有效提交并打开详情 | 文件rename-follow历史先遍历后筛选，保持正确性 |
| Blame/Reflog | 仓库工具，可选择记录，双击/右键打开提交，复制记录 | blame当前文本列式，尚无独立作者/行号列 |
| tracking/upstream/tag | 仓库工具创建跟踪分支、设置上游、标签列表/附注创建/本地删除 | 尚无专属refs管理列表窗口、远程标签同步 |
| ahead/behind/remote/push预览/lease | 仓库工具可读计数、remote增删、dry-run及lease确认 | 网络面板已实现进度/取消/凭据；真实认证需专项验收 |
| 部分stash/rename | 仓库工具逐行路径贮藏；stash改名锁住ref并原子只改指定reflog消息 | 日期、顺序、OID保留；特殊非UTF8 reflog拒绝 |
| merge/reset/continue/abort | 仓库工具专属引用字段，写操作确认；merge/rebase/cherry/revert继续和中止 | merge冲突继续需先解决所有冲突；自动三方合并由比较器入口提供 |
| 交互式rebase | 仓库工具加载完整计划，编辑pick/drop/squash/fixup与顺序，验证所有提交恰好一次，干净仓库要求 | reword/edit/exec及合并拓扑保留未完成；squash使用Git自动消息 |
| submodule/LFS | 仓库工具状态/init-update/add与LFS status/install/track | 网络凭据、git-lfs本机binary和服务器支持为外部前提 |
| GitFlow/PR/快捷键/更新与公证 | 设置页GitFlow feature/release/hotfix start/finish、PR网页入口、快捷键、HTTPS更新manifest检查；分发脚本另行提供 | Developer ID/Apple公证凭据与可信签名更新分发服务器尚未提供 |

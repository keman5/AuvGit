# 弹窗操作验收（2026-10-31）

源码目录：`/Users/kevin/Git-projects/AuvGit`。本轮在当前 checkout 内完成，未创建 worktree。

## 修复

- AI 提交范围、标签类型统一为原生单选控件。图标和整段标签均可点击，支持 Tab/Space，选项保持互斥。
- 只有确认按钮的提示框支持 Esc 关闭；Esc 不执行确认回调。按钮禁用时保持禁用，Return 仍用于确认。
- 外框重新挂载只恢复用户主动产生的焦点与选区，不再恢复 AppKit 自动选中的控件，防止偶发抢焦点。
- 完整操作日志打开时不主动聚焦文本；用户点击后仍可全选、复制，Esc 只关闭内层详情。
- 标签、远程设置、网络设置的有限初始化读取不再随弹窗重新挂载而取消，避免显示 CancellationError 或表单尚未加载就停住。
- 变基表单内容支持滚动，底部关闭/执行按钮固定，避免较矮窗口遮挡操作。

## 真实窗口回归

新增 `DialogOperationAuditTests`（7 项场景测试，包含 15 类弹窗的重复打开矩阵）。测试运行 AppKit 事件循环，呈现实际 SwiftUI sheet 与自定义外框，检查原生按钮的 hitTest；涉及纯 SwiftUI 的标签创建、日志展开入口时发送真实窗口鼠标事件。

15 类弹窗各重复打开两次，分别验证鼠标取消、输入框/编辑器聚焦后的 Esc 关闭、初始不抢焦点、取消不修改仓库：

| 类型 | 检查 |
| --- | --- |
| AI 范围、AI 设置 | 取消、Esc；范围切换、单选热区、Space、生成回调、记住选择 |
| 仓库工具、网络操作 | 取消、Esc、默认不执行操作 |
| 工作区搜索、工作区提交 | 取消、Esc、禁用状态由已有测试覆盖 |
| 标签管理 | 取消、Esc；通过顶部按钮进入创建页，验证三类标签互斥与注释必填，实际创建附注标签并用 Git 读取类型和注释 |
| 忽略文件、远程 URL | 取消、Esc；初始化、重新加载、编辑、保存，核对磁盘文件与 Git 配置 |
| 操作日志 | 取消、Esc；展开记录、打开完整输出、初始焦点、Cmd+A、实际复制、内层关闭后保留外层 |
| 克隆、初始化 | 取消、Esc；错误/重试/替换目录由已有窗口与业务测试覆盖 |
| 变基 | 取消、Esc、700 pt 高度时底部按钮热区 |
| 远程认证、首次推送 | 取消、Esc，不发送凭据或推送 |

复制检查保存并恢复原有剪贴板内容；AI 范围检查恢复原有偏好。所有修改、提交、重置、标签、克隆与网络业务测试使用可删除的临时仓库或本地 bare remote。

## 其余入口检查

已检查 MainWindow、LogWindow、RepositorySidebar、WorkspaceTree、WorkspaceProjects、CompareWindow、ComparisonExtrasMenu、MediaCompareView、RebaseWorkflowView、OperationLogView、BorderlessToolbar 的弹窗入口及取消、校验、忙碌状态与回调。

已有回归继续覆盖：拉取默认项与 Fetch 分支、强推默认取消、重置模式与实际 soft reset、长消息滚动、禁用按钮、表单按钮尺寸、克隆替换/重试、搜索大小写/正则/替换、编码转换、重命名、恢复/删除冲突文件、标签发布/删除、变基执行/中止/恢复、远程 URL/忽略文件旧快照保护。

搜索快捷键回归只查找当前测试新打开的弹窗，并在结束时明确关闭，避免遗留窗口混入后续检查。

运行命令：

```sh
./scripts/build.sh --test-dialog-audit
./scripts/build.sh
```

需要截图证据时使用 `AUVGIT_DIALOG_AUDIT_CAPTURE=1`，新增回归截图写入 `/tmp/auvgit-audit-*.png`，正常测试不写截图缓存。

## 回归结果

`./scripts/build.sh --test-dialog-audit`：176 项，0 失败，1 项跳过（测试进程无法激活窗口时的终端 Control-Tab；该项不是弹窗检查）。其中新增的 7 项弹窗场景全部通过。最终完整回归日志：`/tmp/auvgit-dialog-audit-final.log`。

`git diff --check` 通过。

## 安装版复核

`./scripts/build.sh` 已完成 Release 构建、签名、DMG 打包与 `/Applications/AuvGit.app` 替换安装，并清理构建缓存。安装版通过 `codesign --verify --strict`，其可执行文件与本轮构建产物逐字节一致。构建日志：`/tmp/auvgit-dialog-audit-build.log`。

在实际运行的安装版中完成以下检查，结束后仅保留主窗口：

- 系统“打开仓库…”选择器：从文件菜单打开，Esc 取消。
- 自定义“创建仓库”弹窗：从顶部按钮打开，Esc 取消；再次打开，真实鼠标点击“取消”关闭。未执行创建或克隆。

系统选择器通过 AXRaise 置前再发送按键；自定义弹窗使用 CGEvent 实际鼠标/键盘事件。检查脚本：`/tmp/auvgit-dialog-smoke.applescript`、`/tmp/auvgit-custom-dialog-smoke.swift`。

## 验证边界

测试不使用真实账号执行公网推送、修改钥匙串秘密或 GPG 签名，不启动用户配置的外部对比工具。系统“打开仓库”选择器已实际验证；其他 Open/Save 文件选择器与部分内嵌匿名弹窗完成入口/回调源码检查，未声称逐个按钮均做了实际系统交互。真实服务认证、签名和其余系统对话框仍需在对应环境做端到端验收。

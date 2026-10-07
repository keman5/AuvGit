# SmartGit 快捷键对齐

默认键取自本机 SmartGit 的「Keyboard shortcuts」设置；保留 RayGit 已有的用户自定义配置。只接已有操作，没有添加 SmartGit 独有功能。

同一个键按当前视图路由：主窗口的储藏与比较编辑器的保存都可用 ⌘S；历史、文件、比较分别使用 ⌘F；分支、储藏、文件重命名共用 F2。原生文本复制、输入及撤销行为保留，sheet 打开时暂停父窗口快捷键。

## 来源

- 设置界面的逐行观察记录：`/tmp/raygit-smartgit-shortcuts.txt`。
- 比较快捷键补充证据：本机 `/Applications/SmartGit.app/Contents/Resources/Java/smartgit.jar` 的注册调用，类 `amC`、`apG`、`ayh`、`bVO`。`Ii.b` 来自 macOS `SWT.MOD1`；`LJ.a(IIII)` 第三、第四参数为 macOS 默认键。
- 数字常量用随应用附带的 `org.eclipse.swt.cocoa.macosx.aarch64.jar` 校验：COMMAND=4194304、SHIFT=131072、CTRL=262144、F6=16777231、左右方向键=16777219/16777220。未猜测功能键。
- 全部实际配置来自 `KeyboardShortcuts.swift`；菜单提示与事件匹配共用同一个注册表。

## 注册表默认值

| 操作 | 默认键 | 视图 | 证据或说明 |
| --- | --- | --- | --- |
| Blame | ⌥⌘L | files | SmartGit 设置 |
| Show Log Window | ⇧⌘N | workspace | SmartGit 设置 |
| Show Changes | F4 | files, history | SmartGit 设置 |
| Open Repository | ⌘O | application | 保留 RayGit 已有默认键 |
| Refresh Repository | F5 | workspace, history | SmartGit 设置 |
| Stage | ⌘T | files | SmartGit 设置 |
| Unstage | ⇧⌘T | files | SmartGit 设置 |
| Commit | ⌘K | workspace | SmartGit 设置 |
| View Log | ⌘L | workspace, history | SmartGit 设置 |
| Hard Reset | ⌘R | history | SmartGit 设置 |
| Advanced Reset | ⇧⌘R | history | SmartGit 设置 |
| Copy Commit Hash | ⌘C | history | 保留 RayGit 已有默认键 |
| Create Branch | F7 | workspace, history | SmartGit 设置 |
| Create Tag | ⇧F7 | workspace, history | SmartGit 设置 |
| Commit Details | ↩ | history | 保留 RayGit 已有默认键 |
| Filter Commits | ⌘F | history | SmartGit 设置 |
| Refresh Repository (Alternate) | 未分配 | workspace, history | 保留可配置备用入口，默认不分配 |
| Clone Repository | ⇧⌘O | workspace | SmartGit 设置 |
| Filter Files | ⌘F | files | SmartGit 设置 |
| Select Committable Files | ⌥⌘A | files | SmartGit 设置 |
| Copy Path | ⌃⌘C | files | SmartGit 设置 |
| Copy Relative Path | ⇧⌘C | files | SmartGit 设置 |
| Select Child Commit | ⌥↑ | history | SmartGit 设置 |
| Select Parent Commit | ⌥↓ | history | SmartGit 设置 |
| Filter Unversioned Files | ⌘2 | files | 使用现有未跟踪文件筛选，非新增显示开关 |
| Show Ignored Files | ⌘3 | files | SmartGit 设置 |
| Pull | ⌘⇟ | workspace | SmartGit 设置 |
| Fetch | ⇧⌘⇟ | workspace | SmartGit 设置 |
| Push | ⌘⇞ | workspace | SmartGit 设置 |
| Edit File | ⌘E | files | SmartGit 设置 |
| Ignore | ⌘I | files | SmartGit 设置 |
| Move or Rename File | F2 | files | SmartGit 设置 |
| Use Message for Commit | ⇧⌘K | history | SmartGit 设置 |
| Discard | ⌘Z | files | SmartGit 设置 |
| Delete File | ⌫ | files | SmartGit 设置 |
| Stash All | ⌘S | workspace | SmartGit 设置 |
| Apply Stash | ⇧⌘S | workspace, stash | SmartGit 设置 |
| Rename Stash | F2 | stash | SmartGit 设置 |
| Check Out | ⌘G | history, branch | SmartGit 设置 |
| Rebase | ⌘D | history, branch | SmartGit 设置 |
| Rename Branch | F2 | branch | SmartGit 设置 |
| Find in Comparison | ⌘F | comparison | amC.a(Z, LI) |
| Find Next | ⌘G | comparison | amC.a(Z, LI) |
| Find Previous | ⇧⌘G | comparison | amC.a(Z, LI) |
| Previous Change | ⇧F6 | comparison | apG.d(String, LI) |
| Next Change | F6 | comparison | apG.d(String, LI) |
| Wrap Lines | 未分配 | comparison | amC.b/c(String, LI)，未分配 |
| Save Comparison | ⌘S | comparison | bVO + asN.a() |
| Reload Comparison | ⇧F5 | comparison | SmartGit 设置 |
| Next Conflict | ⌘K | comparison | ayh.a(String, LI) |
| Previous Conflict | ⇧⌘K | comparison | ayh.a(String, LI) |
| Take Left Block | ⌃⌘→ | comparison | apG.a(String, LI) |
| Take Right Block | ⌃⌘← | comparison | apG.a(String, LI) |
| Find and Replace | ⌘R | comparison | amC.a(Z, LI) |
| Compact Comparison | ⌘. | comparison | SmartGit 设置 |
| Line Numbers | 未分配 | comparison | amC.b/c(String, LI)，未分配 |
| Synchronize Scrolling | 未分配 | comparison | apG.b(String, LI)，未分配 |
| Stage Comparison | ⌘T | comparison | 复用 SmartGit Stage 默认键 |
| Activate Repositories | ⌥⌘1 | workspace | SmartGit 设置；已有区域焦点 |
| Activate Branches | ⌥⌘2 | workspace | SmartGit 设置；已有区域焦点 |
| Activate Files | ⌥⌘3 | workspace | SmartGit 设置；已有区域焦点 |
| Activate Changes | ⌥⌘4 | workspace | SmartGit 设置；已有区域焦点 |
| Activate History | ⌥⌘5 | workspace | SmartGit 设置；已有区域焦点 |
| Activate Commit | ⌥⌘6 | workspace | SmartGit 设置；已有区域焦点 |
| Activate Output | ⌥⌘7 | workspace | SmartGit 设置；已有区域焦点 |
| Find Object | ⌘P | workspace | SmartGit 设置；已有对象搜索 |

## 范围

没有可直接复用的已有操作，因此未添加：设置锚点、远程重命名、清空输出、递归文件显示开关、未更改文件显示开关、单独 Index Editor、Resolve Take Ours/Theirs、移除 Git 跟踪、撤销上次提交、同步 Pull+Push、选择另一个 Push 目标、直接编辑历史提交消息或 Squash。现有交互式 rebase 流程仍保留。

每项快捷键可独立启用或禁用，禁用后保留组合并释放占用。修饰键采用可多选按钮组；最右侧录制框捕获实际按键，单独按键保留按钮组选择，完整组合替换修饰键，Escape 取消录制。

支持功能键、方向键、Page Up/Down、数字、Return、Backspace，以及取消分配。冲突仅在重叠视图的已启用动作内检查，失败提示位于对应设置项，未通过校验的修改不会替换生效配置。允许 Cmd+C 等原生快捷键用于应用动作，文本输入区保留原生复制等编辑操作；恢复默认不会把无默认键的功能自动分配到其他键。

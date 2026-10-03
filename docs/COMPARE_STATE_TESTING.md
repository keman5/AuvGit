# 自动比较布局验收

运行 `python3 scripts/make-compare-demo.py` 生成新的 `/tmp/raygit-compare-*` 仓库。脚本没有远程地址、不修改现有仓库，并验证以下五个真实 Git 状态；Conflict.txt 保留实际 UU 冲突，不自动合并或标记解决。

在 RayGit 打开脚本输出的仓库，比较器布局选择“自动”。逐个打开文件：

| 文件 | Git XY | 自动布局，从左到右 | 初始结果 |
|---|---|---|---|
| UnstagedOnly.txt | ` M` | 索引／工作区（双栏） | 当前磁盘中的 Working tree change only |
| StagedOnly.txt | `M ` | HEAD／工作区（双栏） | Staged value，与索引相同 |
| Editor.swift | `MM` | HEAD／工作区／索引（三栏） | WORKTREE version、count = 3 |
| Untracked.txt | `??` | 缺失索引／工作区（双栏） | 当前未跟踪文件文本 |
| Conflict.txt | `UU` | Ours（当前 HEAD）／工作区结果／Theirs（stage 3）（三栏） | 磁盘中已有的真实冲突标记 |

所有布局只允许编辑工作区结果。自动选布局不调用自动合并，不用索引、HEAD 或其他冲突阶段替换当前工作区。左、右参考栏不保存也不写索引。共同祖先可用时仍可查看，但冲突默认左参考是 Ours。

1. 在 Editor.swift 中编辑结果，切换布局，再切回自动：已有草稿应保留。
2. 保存 Editor.swift：磁盘应更新；索引仍是 INDEX version。完整暂存需要另一次明确操作。
3. 在 StagedOnly.txt 的工作区新增并保存一行后重新加载：文件变为 MM，自动进入 HEAD／工作区／索引三栏。
4. Conflict.txt 仅检查布局、标记和当前内容；保留 UU 状态供后续手动解决。打开比较器不应改变阶段 1、2、3，也不应消除冲突。
5. 关闭有草稿的比较器或退出应用：应保护草稿，允许保存／丢弃／取消。取消关闭应保持窗口和草稿。

检查脚本输出仓库的状态：

```sh
git -C /tmp/raygit-compare-实际后缀 status --short
```

`ComparisonPresentationTests` 使用独立真实临时仓库验证仅暂存、仅未暂存、同时变更、未跟踪、删除、重命名、重命名后的工作区修改、内容完全相同时的可执行权限双侧变更，以及真实 UU 冲突。测试验证结果始终来自现有工作区；读取布局不写文件、不暂存、不解决冲突。`FileComparisonTests` 另验证工作区保存不更新索引。

布局判断采用实际 Git status，而不是只比较解码文字。因此重命名、文件模式和存在状态也会决定布局。没有显式 status 的调用方快照可按存在性、Git 模式、原始字节或对象 ID 作保守判断。

## 当前 GUI 验收证据

主代理已构建 Release 并重启应用，构建日志为 `/tmp/raygit-state-layout-build.log`；严格 `codesign` 验证通过。四语言验证结果为 4／21／844，通过。

在 `/tmp/raygit-compare-y9kt0xkf` 中逐一双击上述五个文件，自动布局及双栏基准均符合表格规则：仅未暂存和未跟踪使用索引基准，仅已暂存使用 HEAD 基准，同时变更及真实冲突使用对应三栏。

- Editor.swift 的实际截图显示 HEAD／工作区合并结果／索引。左右参考栏按 `x` 不可编辑；中间新增 `// Center edit verified` 后，切换双栏再切回自动，草稿保留。保存后，工作区包含该注释；`git show :Editor.swift` 仍是 INDEX version、count = 2，证明保存结果没有写索引。
- Conflict.txt 的实际截图显示左侧我方 HEAD、中间带原始冲突标记的当前结果、右侧 Theirs。只有中间可设置文本。验收没有修改或标记解决此文件；`git ls-files -u` 仍保留三个冲突阶段。

此临时仓库留给用户继续测试，Conflict.txt 保持 UU 状态。已有 GUI 编辑验收保存了 Editor.swift 的中心注释，后续可继续编辑；若需完全初始内容，可重新运行生成脚本创建另一份独立仓库。

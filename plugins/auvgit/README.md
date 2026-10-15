# AuvGit for Codex

在 Codex 里使用的本地 Git 插件。界面在对话侧边面板打开，不依赖 AuvGit.app 或 SmartGit，也不需要另外安装独立应用。

## 0.3.1 已实现

- 标题与仓库选择器合并；直接列出 Codex 全部本地项目，保留自定义名称，无需手动输入路径。支持刷新列表；同名项目显示路径以区分。
- SmartGit 式项目/分支树，右侧文件表格、差异与提交面板。
- 记住最后访问的仓库：当前 MCP 工作区明确时优先跟随，否则恢复上次仓库，再回退启动目录。记录跨面板关闭、插件重启及升级保留。
- 点击入口时重新读取 MCP 工作区 roots；在支持此上下文的宿主中随当前项目切换。无 roots 时优先恢复上次有效仓库并明确标注来源；没有有效目录时展示项目列表。
- 面板获得焦点时，Cmd+反引号打开交互式 PTY 终端，默认位于当前仓库；按项目保留隔离会话，支持 Ctrl+C、调整大小、结束会话。
- 本地仓库打开、切换，当前分支、前后游提交数量、文件状态。
- 本地/远端分支列表，创建本地分支、干净工作区下切换分支。
- 所有分支的拓扑提交历史、父子连线、分页、提交详情与差异。
- 工作区和暂存区差异、行号与增删颜色、新文件、二进制提示。
- 单文件或全部暂存、单文件取消暂存、首次提交、普通提交。
- 单击文件预览、双击或 Enter 打开编辑对比弹窗；HEAD / 索引 / 工作区对比，冲突 base / ours / theirs 参考。
- 差异块应用、上下差异导航、查找替换、撤销重做、折行、同步滚动、折叠相同行、可选第三参考栏。
- 工作区保存和索引保存分离；选择工作区基准 + 索引目标可部分暂存；冲突文件编辑后可显式标记解决。
- Fetch、Pull（--ff-only）、Push；按仓库保存自定义 shell 按钮，执行前显示完整命令，提供输出、退出码、超时和停止。
- 文件筛选、错误和加载状态、每 10 秒刷新、外部修改检查。
- 把选中差异作为上下文提供给 Codex，支持明暗主题与窄面板。

界面中的写操作由用户点击发起；聊天中的写工具遵循用户的授权。提交仅使用当前索引，不自动暂存其他文件，不推送远端。提交前显示说明和已暂存文件清单；Git hooks 正常运行。

## 安装与使用

当前发行包面向 **macOS Apple Silicon**，内含经过 SHA-256 校验的 Node 24 运行时和打包后的依赖。只需要已有 Codex 和系统 Git，不需要 npm install、Node 全局安装或额外 Git 客户端。Git 的身份、凭据、hooks、签名等沿用仓库和本机配置；首次使用 Git 的电脑仍需准备 Git。

开发者生成的发行目录带有本地插件市场。安装：

```sh
codex plugin marketplace add /absolute/path/to/auvgit-plugin
codex plugin add auvgit@auvgit-local
```

其中 `auvgit-plugin` 是含 `.agents/plugins/marketplace.json` 的发行目录。ZIP 只包含 `auvgit/` 插件包，可用于私下分发；若从 ZIP 安装，解压至某个市场目录的 `plugins/auvgit/`，并添加下面的市场文件：

```json
{
  "name": "auvgit-local",
  "plugins": [{
    "name": "auvgit",
    "source": {"source": "local", "path": "./plugins/auvgit"},
    "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
    "category": "Developer Tools"
  }]
}
```

0.2.1 加入以下入口；0.2.2 修正了 Codex 拒绝加载通用 MCP 配置的问题。不需要先给模型发送消息：

- **全局入口**：插件向 Codex 主导航注册“AuvGit”。点击后作为固定内容标签打开；入口具体位置、折叠方式由客户端决定。
- **聊天面板入口**：在客户端的插件内容入口中选择“AuvGit”，直接打开当前聊天的内容标签。
- **直达链接**：`codex://plugins/auvgit@auvgit-local/app/auvgit_open` 重新识别当前工作区，缺少上下文时打开仓库选择器。要直接打开某个仓库，添加 `path=`，值为 URL 编码后的 `/workspace?repo=<已 URL 编码的绝对路径>`。链接只读取仓库，不执行写操作或命令。

例如用 JavaScript 构造链接：

```js
const route = '/workspace?' + new URLSearchParams({ repo: '/absolute/path/to/repo' });
const link = 'codex://plugins/auvgit@auvgit-local/app/auvgit_open?path=' + encodeURIComponent(route);
```

更新后如果客户端仍缓存旧入口，重启 Codex 以重新加载插件声明。不带参数时重新读取宿主 roots；缺失或不明确时恢复上次仓库，最后才回退启动目录。若 Codex 复用了服务且没有传入新 roots，启动目录可能仍旧，此时在当前对话中说“打开当前项目的 AuvGit”即可使用明确路径。带路径的链接可直接进入。需要键盘启动时，可在 macOS 自带“快捷指令”中使用“打开 URL”动作打开此链接，再给该快捷指令分配键盘快捷键；插件本身不注册系统快捷键。插件使用本地 MCP stdio，不监听端口，不需要远端服务或 API Key。它不适用于纯网页端/云端访问你的本地磁盘。

项目树通过 Codex CLI 的只读 app-server `project/list` 接口（分页）读取本机项目，合并 MCP roots 和最近访问记录。每次打开入口或刷新列表时更新；接口不可用时显示缓存并提示。仅读取项目接口，不读取 Codex 私有状态文件或对话。需要当前 Codex CLI 提供此接口；不额外安装 CLI。远端/云端项目不属于本地目录列表。非 Git 或已删除目录显示为不可用。记录保存在 `~/.config/auvgit/workspace.json`（或 `AUVGIT_CONFIG_DIR`）；不写入仓库。终端快捷键只作用于插件面板，宿主/系统可能优先拦截；也可点击“终端”。终端 shell 沿用本机 SHELL，首次启动 cwd 设为仓库；用户可自行 cd，回到已有会话时保留该会话状态。终端关闭面板时尝试清理，异常断开后的会话在 30 分钟无请求后回收；每服务最多 8 个会话，每会话保留最近 256 Ki 字符。

## 当前范围

提供 SmartGit 常用对比流程，但尚非功能对等替代品：没有任意文件对比、图片/二进制编辑、自动三方合并、忽略空白比较或交互式 rebase / stash 专用界面。当前三栏是两个比较编辑栏加一个只读参考栏。切换编辑目标保留草稿，但重建该目标的撤销历史。远端分支仅供查看。历史合并提交使用 Git 原生 `show` 输出。

文本编辑仅支持不超过 2 MiB、统一 LF 或 CRLF 的 UTF-8 普通文件，保留 BOM 和工作区权限；非 UTF-8、混合换行、大文件、二进制、符号链接及子模块只读或拒绝编辑。保存工作区不自动暂存。索引编辑处理 Git blob 原文，不运行 clean/smudge 过滤器；保存并暂存走原生 git add。删除文件可通过保存草稿恢复为普通文件。

自定义命令以本机用户权限运行 `/bin/sh -c`，可能访问网络和修改数据；只执行用户配置且明确确认的命令。配置保存在 `~/.config/auvgit/`，不会自动读取仓库中的命令配置。单任务超时 120 秒、输出上限 200,000 字符，停止不能撤销已发生的修改。Git 凭据需事先配置，交互式登录提示会失败。

工具会在写操作前比较 HEAD、分支、索引和改动文件内容，并串行执行同一服务中的写操作。这是外部修改的预检查，不是跨进程事务锁；请避免其他客户端同时写同一仓库。单次 Git 输出限制为 16 MiB，面板差异最多显示 300,000 字符；大型二进制和大型仓库可能需要更长的状态读取时间。上下文按钮最多提供 40,000 字符，受 Codex 主机支持影响。

## 入口与公开分发

插件使用官方 global / thread entrypoint 和 MCP App deep links，不能替换原生顶部“变更”卡片，或往其下方注入按钮。当前公开规范也未提供由插件注册原生悬浮窗或全局快捷键的接口。入口声明和实际宿主显示须分别验收。规范参考：https://github.com/openai/mcp-extensions/blob/main/docs/spec.md#mcp-app-entrypoints。

目前尚无本插件的公开 Codex 安装地址。官方目录发布仍需真实发布者信息、政策地址、演示录像、审核，以及确认本地 stdio 包的目录资格。详见 `RELEASE_REVIEW.md`。本地安装身份始终为 `auvgit@auvgit-local`。

`auvgit-codex-marketplace-0.3.1-macos-arm64.zip` 包含完整本地市场，解压后对其中 `auvgit-plugin` 目录执行上面的两条安装命令即可。单独的 plugin ZIP 仍保留供包检查和后续发布准备。

## 源码开发

```sh
npm ci
npm run build
npm test
npm run preview
npm run package
```

安装了 Codex CLI 时，测试还会调用真实的 `plugin/read` 加载器，验证服务配置可被发现，并覆盖旧配置被拒绝的回归案例；没有 CLI 时该项会明确跳过。

`preview` 启动开发验证宿主，仅允许操作自动生成的临时仓库。它使用真正的 MCP stdio 客户端和 MCP App bridge，不属于生产插件，不会打入发行包。`package` 输出到仓库的 `.artifacts/auvgit-plugin/`，同时生成 ZIP。生产包包含 node-pty 必需的运行时代码、N-API 原生组件与 spawn-helper；不包含开发服务器、测试数据和本机仓库路径。打包时校验平台并保留 helper 执行权限。Codex 自带 Node 的签名限制可能拒绝第三方原生模块，因此优先使用插件附带的官方 Node 运行时。

安装包使用 Agent Plugins 1.0 manifest，并生成 `.codex-plugin/plugin.json`、`.mcp.json` 兼容文件。SDK 锁定为 MCP SDK 1.32.0 和 MCP Apps 1.7.5；面板声明 fullscreen 显示与聊天入口。客户端实际加载和显示需要单独验证，协议测试通过不能代替宿主验收。

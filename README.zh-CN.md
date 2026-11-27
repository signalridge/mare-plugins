# mare-plugins

[mare](https://github.com/signalridge/mare) 的可选插件与主题仓库（`1.0.0`，需要 Mare `>= 1.0.0`）。

[快速开始](#快速开始) · [插件一览](#插件一览) · [主题](#主题) · [文档](#文档) · [English](README.md) · **简体中文**

`mare` 本体已自带文件编辑、Shell 执行与内置插件。如果你需要额外的工作流插件、外部命令钩子、持久交互式终端、多智能体编排或 37 套内置主题，可以按需引入 `mare-plugins`。

## 快速开始

在 `~/.config/mare/init.lua` 中声明 `signalridge/mare-plugins`。

按需挑选单个或多个插件（通过 `opts` 或 `mare.plugin` 传入配置）：

```lua
mare.plugins.add {
  {
    "signalridge/mare-plugins",
    only = { "plan-mode", "todo" },
    opts = {
      ["plan-mode"] = { plan_effort = "high" },
    },
  },
}
```

仅加载内置主题、不启用任何插件（`only = {}`）：

```lua
mare.setup {
  flavor = "auto",
  flavor_dark = "catppuccin-mocha",
  flavor_light = "catppuccin-latte",
}

mare.plugins.add {
  { "signalridge/mare-plugins", only = {} },
}
```

或者一次性启用全部 20 个插件与 37 套主题：

```lua
mare.plugins.add {
  { "signalridge/mare-plugins" },
}
```

在终端运行 `mare plugin sync`，或在 Mare 中运行 `/reload` 生效。用 `/plugins` 查看插件状态，用 `/news` 查看发布说明，用 `/theme` 切换主题。

## 插件一览

全部 20 个插件清单均省略 `platforms`，可在 Linux、macOS 与 Windows 上加载。完整参数、Lua 服务契约、能力依赖与运行时边界见 [docs/plugins.md](docs/plugins.md)（英文）。

| 插件 | 入口 | 说明 |
| --- | --- | --- |
| [`ask_user_question`](plugins/ask_user_question/README.md) | `ask_user_question` | 结构化多选提问，支持推荐项、预览对比、自由输入与跳过。 |
| [`btw`](plugins/btw/README.md) | `btw` 服务、`btw.*` 动作 | 基于核心 `conversations` 的侧边对话状态条、状态栏段与记录查看器。 |
| [`codemode`](plugins/codemode/README.md) | `/codemode`、`codemode`、`codemode_wait` | 受限 Lua 脚本单元格，用于组合工具调用并过滤中间输出。 |
| [`goal`](plugins/goal/README.md) | `/goal`、`get_goal`、`create_goal`、`update_goal` | 持久化会话目标，支持空闲续跑、预算上限与完成审计。 |
| [`hooks`](plugins/hooks/README.md) | `/hooks` | 同步与受限异步 Claude Code / Codex 命令钩子，覆盖 9 个事件及 `notify`。 |
| [`mermaid`](plugins/mermaid/README.md) | `/mermaid`、`mermaid` | 自动渲染 `mermaid`/`mmd` 代码块并提供交互式图表查看器。 |
| [`peers`](plugins/peers/README.md) | `/peers`、`peer_list`、`peer_send`、`peer_status` | 发现本机运行中的其他 Mare 会话并进行受确认的消息通信。 |
| [`plan-mode`](plugins/plan-mode/README.md) | `/plan`、`exit_plan_mode` | 会话级规划模式，默认拦截本地写入、支持独立推理强度与计划审查。 |
| [`presets`](plugins/presets/README.md) | `/preset`、`presets` 服务 | 模型、系统提示与工具过滤的命名预设，并注册为会话级子智能体类型。 |
| [`schedule`](plugins/schedule/README.md) | `/schedule`、`/loop`、`schedule_*` | 持久化定时提示（`after`/`at`/`every`/`cron`/`rrule`）与会话循环。 |
| [`secrets`](plugins/secrets/README.md) | `/secrets`、`secrets` 服务 | 掩码录入会话密钥与配置文件凭证，仅在批准的工具字段中还原真值。 |
| [`session-search`](plugins/session-search/README.md) | `session_search`、`session_trace`、`session_event_*` | 在授权范围内只读检索与追踪历史会话、事件及子会话。 |
| [`session-title`](plugins/session-title/README.md) | `/title`、`session_title` 服务 | 自动生成会话标题，提供首条消息摘录兜底与可选后台 LLM 命名。 |
| [`team`](plugins/team/README.md) | `/team`、`team_*`、`team` 服务 | 共享多智能体任务板，支持 DAG 依赖、独占租约与持久会话记录。 |
| [`terminals`](plugins/terminals/README.md) | `terminal_open`、`terminal_send`、`terminal_read`、`terminal_list`、`terminal_signal`、`terminal_close` | 持久交互式 PTY（`bash` / `pwsh` 后端），适合 REPL 与多步交互命令。 |
| [`time-context`](plugins/time-context/README.md) | `agent:step_participant` | 在模型步骤获准执行时注入主机日期、时间与时区信息。 |
| [`todo`](plugins/todo/README.md) | `/todos`、`todo_write` | 会话任务清单，带变更 diff、可折叠进度面板与 `plan-mode` 互斥保护。 |
| [`tool-spill`](plugins/tool-spill/README.md) | `read_spill`、`tool/result` | 自动保存超长工具输出并返回可分页读取的恢复句柄。 |
| [`toolbelt`](plugins/toolbelt/README.md) | `grep`、`find`、`code_search`、`doc_search` | 封装已安装的只读搜索工具 `rg`、`fd`、`ast-grep`（`sg`）与 `rga`。 |
| [`workflow`](plugins/workflow/README.md) | `/workflow`、`workflow` | 沙箱 VM 内的确定性 Lua 多智能体编排，带实时进度面板与 `/resume` 历史。 |

## 主题

主题是仓库级资产，位于 [themes/](themes/)（共 25 套深色与 12 套浅色风格，其中 13 套包含上游 `.tmTheme` 语法定义）。启用任意插件即可使用全部 37 套主题，或用 `only = {}` 仅加载主题。完整风格列表、明暗自动配对、别名与对比度校验见 [docs/themes.md](docs/themes.md)（英文）。

## 文档

| 页面 | 内容 |
| --- | --- |
| [Mare](https://github.com/signalridge/mare) | 核心 CLI、插件加载器与运行时文档 |
| [文档总览](docs/README.md) | 仓库文档索引与加载方式说明（英文） |
| [插件参考](docs/plugins.md) | 命令、工具、Lua 服务、配置项、能力依赖与运行时边界（英文） |
| [主题指南](docs/themes.md) | 明暗配对、`/theme`、别名、对比度校验与全部 37 套主题（英文） |
| [开发指南](docs/development.md) | 清单规范、服务契约、单元测试与 E2E 测试（英文） |
| [发布说明](NEWS.md) | 版本更新记录，供 `/news` 展示（英文） |
| [贡献指南](CONTRIBUTING.md) | 开发环境、清单约定与 PR 校验清单（英文） |
| [安全策略](SECURITY.md) | 漏洞私密上报方式与覆盖的安全边界（英文） |

## 开发与测试

```sh
python3 tests/manifests.py
python3 tests/test_manifests.py
lua tests/service-contracts.lua
just specs
```

代码格式化（`stylua`）与完整 E2E 测试（`just test`）见 [CONTRIBUTING.md](CONTRIBUTING.md) 与 [docs/development.md](docs/development.md)。

## 许可证

采用 [MIT 许可协议](LICENSE)。随包分发的第三方 `.tmTheme` 语法主题来源与许可声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

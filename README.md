# zed-api

把 Zed 托管的模型转成本地 OpenAI / Anthropic 接口，让 **Codex、Claude Code、OpenCode** 直接连本机用。

三种协议（Responses / Chat Completions / Messages）都支持流式和工具调用，自带多账号调度、额度查看和中文 Web 管理页。

> 服务固定监听 `http://127.0.0.1:8001`，只在本机用，别暴露公网。

## 效果

Codex CLI / TUI：

![Codex CLI](docs/codex-cli.png)

Codex 桌面端（5.6 Sol，极高档位）：

![Codex Desktop](docs/codex-desktop.png)

## 能做什么

- **Codex**：原生 `/v1/responses`，reasoning、工具调用历史都完整透传。`/v1/models` 同时给出 OpenAI 和 Codex Desktop 两种格式，新版桌面端拿来就能用。
- **Claude Code**：`/v1/messages`，顶层 system、内容块、缓存标记、工具结果都按 Anthropic 语义处理。
- **OpenCode**：`/v1/chat/completions`，切模型、切思考档位最方便。
- **多账号**：健康账号优先，认证失败、限流、网络错误分别冷却，挂了自动换号，换完记住。
- **管理页**：每个账号的套餐、到期时间、额度、模型探测结果一目了然，可以单个或全部做健康检查。

## 模型与思考档位

| 模型 ID | 上游 | 说明 |
| --- | --- | --- |
| `gpt-5.6` | `gpt-5.6-sol` | 别名，方便配置 |
| `gpt-5.6-sol` / `-terra` / `-luna` | 同名 | GPT-5.6 三个变体 |
| `claude-sonnet-5` | 同名 | Claude Sonnet 5 |

GPT-5.6 思考档位：`none / low / medium / high / xhigh`，不传默认 `xhigh`。`max` 和 `minimal` 这条链路上游不支持，传了直接 400，不会偷偷降级。账号实际有哪些模型以 Zed 返回为准。

## 快速开始（Windows）

```powershell
.\start.ps1                        # 后台启动，127.0.0.1:8001
.\stop.ps1                         # 停止
.\zed2api.exe login my-account     # 首次先登录 Zed 账号
```

管理页：<http://127.0.0.1:8001>

健康检查：

```powershell
.\health-check.ps1                # 令牌+账单检查，不调模型
.\health-check.ps1 -Deep          # 当前账号发一次最低成本探测
.\health-check.ps1 -AllAccounts   # 所有账号各探测一次
.\health-check.ps1 -Streaming     # 顺带测三个协议的流式收尾
```

## 客户端配置

模板都在 `configs/`，往自己已有的配置里合并，别整个覆盖。配置前先确认服务活着：

```powershell
Invoke-RestMethod -Uri 'http://127.0.0.1:8001/v1/models'
```

### Codex

把 `configs/codex.config.toml.example` 合并进 `%USERPROFILE%\.codex\config.toml`：

```toml
model_provider = "zed_local"
model = "gpt-5.6-sol"
model_reasoning_effort = "xhigh"

[model_providers.zed_local]
name = "Zed Local"
base_url = "http://127.0.0.1:8001/v1"
wire_api = "responses"
requires_openai_auth = false
```

改完重启 Codex（旧进程不重读配置），然后验证：

```powershell
codex exec --skip-git-repo-check '请只回复：CODEX_OK'
```

本机开着 Clash 之类代理的话，`NO_PROXY` 里要有 `localhost,127.0.0.1`，不然发往本机的请求会被代理拦成 502。

### Claude Code

按想用的模型挑一个模板，合并进 `%USERPROFILE%\.claude\settings.json`：

- `configs/claude.settings.json.example` — Sonnet 5
- `configs/claude-gpt56-sol / -terra / -luna` — GPT-5.6 变体

地址填根路径 `http://127.0.0.1:8001`（客户端自己拼 `/v1/messages`）。重启后验证：

```powershell
claude -p '请只回复：CLAUDE_OK'
```

### OpenCode

把 `configs/opencode.json.example` 复制成项目根目录的 `opencode.json`，或合并里面的 `zed-local` Provider：

```powershell
opencode run --model zed-local/gpt-5.6-terra --variant low "你的任务"
```

`apiKey` 随便填个 `dummy`，本地不校验。

## API

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| POST | `/v1/responses` | OpenAI Responses |
| POST | `/v1/chat/completions` | OpenAI Chat Completions |
| POST | `/v1/messages` | Anthropic Messages |
| POST | `/v1/messages/count_tokens` | Claude Code 启动用的兼容桩 |
| GET | `/v1/models` | 模型列表（双格式） |
| GET | `/zed/accounts` | 账号与调度状态（脱敏） |
| GET | `/zed/accounts/status` | 全账号令牌/套餐/额度检查 |
| POST | `/zed/accounts/health` | 单账号或全账号模型探测 |
| POST | `/zed/accounts/switch` | 切换当前账号 |
| GET | `/zed/usage` | 当前账号用量 |
| GET | `/zed/billing` | 当前账号账单 |
| POST | `/zed/login` | 发起 GitHub OAuth 登录 |
| GET | `/zed/login/status` | 查询登录状态 |

## 构建

需要 Zig 0.15.x：

```powershell
cd webui && npm ci && npm run build && cd ..   # 前端产物内嵌进 EXE
zig build test                                  # 协议转换与流式回归测试
zig build -Doptimize=ReleaseSafe                # 产物：zig-out\bin\zed2api.exe
```

改了前端记得重新 `zig build`，不然 EXE 里还是旧页面。

## 已知限制

- 服务本身无鉴权，默认只监听 `127.0.0.1`。想通过中转/反代分享给别人用的话，务必自己在前面加一层鉴权，否则等于把账号额度裸奔出去。
- 请求格式完全按 Zed 官方客户端实现，但上游随时可能改协议或触发风控，不保证持续可用。
- `count_tokens` 是兼容桩，别拿来精确计费。
- 有些 Zed 套餐不公开数值额度，管理页只能显示"未公开"，精确金额去 Zed 官网看。
- 一次调度最多尝试 64 个账号。

## License

MIT（早期思路参考 [yukmakoto/zed2api](https://github.com/yukmakoto/zed2api)；本仓库为重写版。）

## 友链

LinuxDo

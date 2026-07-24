# zed-api

把 Zed 托管的模型转成本地 OpenAI / Anthropic 接口，给 **Codex、Claude Code、OpenCode** 直接用。

支持三种协议（Responses / Chat Completions / Messages）的流式输出和工具调用，带多账号健康调度、额度查看和中文 Web 管理页。早期结构参考了 [yukmakoto/zed2api](https://github.com/yukmakoto/zed2api)，在此基础上大量重写。

> 服务固定监听 `http://127.0.0.1:8001`，没有鉴权，只在本机使用，不要暴露到公网。

## 功能

- **Codex**：原生 `/v1/responses`，typed Items、reasoning 连续性、函数调用历史完整保留；`/v1/models` 同时返回 OpenAI `data` 和 Codex Desktop 需要的 `models` 目录格式，新版桌面端可以直接用。
- **Claude Code**：`/v1/messages`，兼容顶层 system、数组内容块、缓存标记和工具结果。
- **OpenCode**：`/v1/chat/completions`，模型和思考档位切换最方便。
- **多账号调度**：健康账号优先，401/403、429、网络错误分别有不同冷却策略，失败自动切换，切换结果持久化。
- **Web 管理页**：查看每个账号的套餐、到期时间、额度、模型探测结果；支持单账号 / 全账号健康检查。

## 模型与思考档位

| 模型 ID | 上游 | 说明 |
| --- | --- | --- |
| `gpt-5.6` | `gpt-5.6-sol` | 本地稳定别名 |
| `gpt-5.6-sol` / `-terra` / `-luna` | 同名 | GPT-5.6 三个变体 |
| `claude-sonnet-5` | 同名 | Claude Sonnet 5 |

GPT-5.6 思考档位支持 `none / low / medium / high / xhigh`，缺省 `xhigh`。`max` 和 `minimal` 在 Zed 这条链路上实测不可用，代理会直接返回 400，不做静默降级。账号实际能用哪些模型以 Zed 返回为准。

## 快速开始（Windows）

```powershell
# 启动（后台，127.0.0.1:8001）
.\start.ps1

# 停止
.\stop.ps1

# 首次使用先登录 Zed 账号
.\zed2api.exe login my-account
```

管理页：<http://127.0.0.1:8001>

`accounts.json` 里是登录凭据，已被 `.gitignore` 排除，别提交、别截图。

健康检查：

```powershell
.\health-check.ps1                # 默认：令牌+账单检查，不调用模型
.\health-check.ps1 -Deep          # 当前账号发一次最低成本模型探测
.\health-check.ps1 -AllAccounts   # 所有账号各探测一次
.\health-check.ps1 -Streaming     # 顺带验证三个协议的流式收尾
```

## 客户端配置

配置模板都在 `configs/` 目录，往已有配置里合并即可，不要整文件覆盖。配置前先确认服务已启动：

```powershell
Invoke-RestMethod -Uri 'http://127.0.0.1:8001/v1/models'
```

### Codex

合并 `configs/codex.config.toml.example` 到 `%USERPROFILE%\.codex\config.toml`：

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

改完重启 Codex（旧进程不会重新读配置），验证：

```powershell
codex exec --skip-git-repo-check '请只回复：CODEX_OK'
```

注意：如果本机开着代理（Clash 等），要保证 `NO_PROXY` 包含 `localhost,127.0.0.1`，否则发往本机的请求会被代理拦成 502。

### Claude Code

按想用的模型选一个模板，合并到 `%USERPROFILE%\.claude\settings.json`：

- `configs/claude.settings.json.example` — Sonnet 5
- `configs/claude-gpt56-sol.settings.json.example` / `-terra` / `-luna` — GPT-5.6 变体

地址填根路径 `http://127.0.0.1:8001`（客户端自己拼 `/v1/messages`）。重启 Claude Code 后验证：

```powershell
claude -p '请只回复：CLAUDE_OK'
```

### OpenCode

把 `configs/opencode.json.example` 复制为项目根目录的 `opencode.json`，或合并其中的 `zed-local` Provider：

```powershell
opencode run --model zed-local/gpt-5.6-terra --variant low "你的任务"
```

`apiKey` 填 `dummy` 即可，本地网关不校验。

## API

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| POST | `/v1/responses` | OpenAI Responses，流式/非流式 |
| POST | `/v1/chat/completions` | OpenAI Chat Completions，流式/非流式 |
| POST | `/v1/messages` | Anthropic Messages，流式/非流式 |
| POST | `/v1/messages/count_tokens` | Claude Code 启动兼容桩 |
| GET | `/v1/models` | 模型列表（OpenAI + Codex 双格式） |
| GET | `/zed/accounts` | 脱敏账号与调度状态 |
| GET | `/zed/accounts/status` | 全账号被动令牌/套餐/额度检查 |
| POST | `/zed/accounts/health` | 单账号或全账号主动模型探测 |
| POST | `/zed/accounts/switch` | 切换当前账号 |
| GET | `/zed/usage` | 当前账号套餐与用量 |
| GET | `/zed/billing` | 当前账号账单 |
| POST | `/zed/login` | 启动 GitHub OAuth 登录 |
| GET | `/zed/login/status` | 查询登录状态 |

请求示例（Responses 流式）：

```powershell
$body = @{
    model     = 'gpt-5.6-sol'
    input     = 'Reply with exactly: ok'
    reasoning = @{ effort = 'xhigh' }
    stream    = $true
    store     = $false
} | ConvertTo-Json -Depth 8 -Compress

Invoke-WebRequest -Uri 'http://127.0.0.1:8001/v1/responses' -Method Post -ContentType 'application/json' -Body $body
```

## 构建

需要 Zig 0.15.x：

```powershell
# 前端（产物内嵌进 EXE，改了前端必须重新 zig build）
cd webui && npm ci && npm run build && cd ..

# 后端
zig build test
zig build -Doptimize=ReleaseSafe
# 产物：zig-out\bin\zed2api.exe
```

## 目录结构

```text
src/                    Zig 后端与协议转换
webui/                  Web UI 源码
configs/                三个客户端的配置模板
start.ps1 / stop.ps1    启动 / 停止
health-check.ps1        健康检查脚本
accounts.example.json   账号配置示例（脱敏）
```

## 已知限制

- 仅绑定 `127.0.0.1`，无鉴权，不要做端口转发暴露公网。
- Zed 是上游服务，模型名、请求头、账号策略随时可能变；升级 Zed 客户端后需核对 `src/proxy.zig` 里的版本与请求头。
- `count_tokens` 是兼容桩，返回值不能用于精确计费。
- 部分 Zed 套餐不公开数值额度，Web UI 会显示"未公开"，精确金额去 Zed 官网看。
- 健康调度一次最多尝试 64 个账号。

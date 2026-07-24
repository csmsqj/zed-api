# Zed API 本地网关

面向 **Codex、Claude Code、OpenCode** 的本地 Zed 模型 API 适配器。项目重点适配 Codex 的 OpenAI Responses API 与 Claude Code 的 Anthropic Messages API，同时保留 OpenAI Chat Completions 兼容接口，并提供流式传输、工具调用、多账号健康调度、额度检测和中文 Web 管理页。

> 默认地址固定为 `http://127.0.0.1:8001`。服务没有公网鉴权，只应在本机回环地址使用。

## 一、项目定位、来源与维护范围

本项目将 [yukmakoto/zed2api](https://github.com/yukmakoto/zed2api) 作为早期工程参考，并复用了其目录结构与部分实现。当前版本不是对旧项目简单改名或换皮，而是由个人独立维护，并围绕真实客户端兼容和本地运维完成了大范围重写与扩展：

- **参考范围：** 早期目录组织、Zig 代理、Zed 登录和部分基础协议转换实现；
- **本项目重新设计：** 中文 Web 管理页的布局、视觉、交互与响应式适配，页面外观和信息架构不再沿用旧版；
- **本项目独立配置和维护：** `8001` 本地端口、Codex/OpenCode/Claude Code 配置模板、Responses 兼容层、三协议流式处理、请求规范化、多账号健康调度、额度检测、测试与部署脚本。

因此，从当前功能和维护关系看，上游主要承担早期架构与基础实现参考作用，新增能力、客户端配置和后续迭代均由本项目维护；从代码来源看，仓库仍保留部分上游实现，应如实保留来源说明。感谢原作者完成早期基础工作。

**来源说明必须保留：** 当前仓库仍属于基于上游代码形成的衍生版本，不能仅因修改量较大就描述为“从零完全原创”。截至 2026-07-24，上游仓库未提供明确的 `LICENSE` 文件；在公开源码、分发 EXE 或添加开源许可证前，应先取得原作者的明确授权，或完成不复用现有代码与资源的独立重写。

早期实现适合基础 OpenAI/Anthropic 兼容调用，但面对当前 Codex、OpenCode 和 Claude Code 请求时存在以下兼容缺口：

1. **请求标识不符合真实客户端特征。** 原版 `fakeUuid` 每次都用秒级时间重新初始化 PRNG；同一秒连续生成 `thread_id` 与 `prompt_id` 时会得到相同值，也没有设置 RFC 4122 v4 的 version/variant 位。本项目改用系统 CSPRNG，并生成互不相同的标准 v4 UUID。
2. **缺少原生 Responses 语义。** Codex 使用 typed Items、函数调用历史、reasoning 连续性等结构，简单套用 Chat Completions 会出现字段丢失或上游解析失败。本项目新增 `/v1/responses` 并在 provider 边界做规范化。
3. **Claude Code 请求结构兼容不足。** Claude Code 可能同时发送顶层 `system`、数组内容块、缓存标记、工具结果以及追加的 `role=system` 消息。本项目按 Anthropic 结构合并和保留这些字段。
4. **流式收尾与故障判定不完整。** 本项目补齐三种协议的 SSE 翻译、结构化 `stream_ended` 判断、客户端断开清理、真实 HTTP 错误识别和流开始前的账号故障转移。
5. **多账号只有基础顺序尝试。** 本项目增加按错误类型分类的冷却、连续失败计数、健康账号优先、活动账号持久化和显式单账号/全账号健康探测。
6. **缺少可观察性。** 新 Web UI 可查看每个账号的令牌、套餐、到期时间、上游公开的额度以及真实模型探测结果。

这些修正减少异常请求标识与格式错误，降低常见的 400/403/500、工具调用中断和客户端不兼容概率。项目不承诺账号状态；实际结果仍由账号套餐、Zed 政策和上游状态决定。

## 二、核心能力

### （1）三客户端与三协议

| 客户端         | 推荐接口                   | 模型选择                       | 思考策略                                 | 流式输出          |
| ----------- | ---------------------- | -------------------------- | ------------------------------------ | ------------- |
| Codex       | `/v1/responses`        | GPT-5.6 Sol / Terra / Luna | 默认 `xhigh`，保留客户端选择                   | SSE           |
| OpenCode    | `/v1/chat/completions` | GPT-5.6 Sol / Terra / Luna | 默认 `xhigh`，支持 variants               | SSE           |
| Claude Code | `/v1/messages`         | Sonnet 5 或 GPT-5.6 三变体     | 配置固定 `xhigh`；GPT-5.6 路由由代理强制 `xhigh` | Anthropic SSE |

支持的 GPT-5.6 思考档位为：

```text
none / low / medium / high / xhigh
```

- Codex、OpenCode 明确传入档位时原样保留；缺省值为 `xhigh`。
- Claude Code 通过 Anthropic 接口调用 GPT-5.6 时固定为 `xhigh`。
- Claude Code 的 Sonnet 5 模板同时设置 `CLAUDE_CODE_EFFORT_LEVEL=xhigh` 和 `effortLevel: "xhigh"`。
- OpenAI 官方文档中的 `max` 以及解析器可识别的 `minimal`，在当前 Zed 托管 GPT-5.6 链路上均未通过实测，因此代理返回明确的 400，不静默降级。

### （2）模型映射

| 客户端模型 ID          | 实际上游模型            | 说明              |
| ----------------- | ----------------- | --------------- |
| `gpt-5.6`         | `gpt-5.6-sol`     | 本地稳定别名          |
| `gpt-5.6-sol`     | `gpt-5.6-sol`     | GPT-5.6 Sol     |
| `gpt-5.6-terra`   | `gpt-5.6-terra`   | GPT-5.6 Terra   |
| `gpt-5.6-luna`    | `gpt-5.6-luna`    | GPT-5.6 Luna    |
| `claude-sonnet-5` | `claude-sonnet-5` | Claude Sonnet 5 |

账号是否拥有某个模型，以 Zed `/models` 返回和实际模型探测为准。

### （3）健康感知多账号调度

本项目不是“每个请求机械轮询”，而是健康感知调度：

- 当前健康账号优先，失败后自动尝试其他账号；
- `401/403` 认证问题、`429` 限流、网络/5xx 使用不同冷却策略；
- 连续失败账号降低优先级，恢复后重新参与调度；
- 成功故障转移后的账号会成为当前账号并写入 `active_account.txt`；
- Web UI 支持单账号检查和全部账号检查。

健康检查分为两层：

1. **被动检查（默认、零模型消耗）**：刷新 LLM token，并读取 Zed 账单/套餐接口。
2. **主动账号实测（手动触发）**：每个选中账号只发送一次请求，固定使用 `gpt-5.6-luna`、短提示词、`reasoning_effort=none` 和最多 16 个输出 token，不会轮流检测 Sol、Terra 或其他模型。探测直接绑定指定账号，不通过其他账号掩盖失败。

### （4）余额与额度展示

`GET /zed/accounts/status` 只返回脱敏状态，不返回 credential 或 JWT。Web UI 展示：

- 套餐名称与订阅到期时间；
- `used / limit / remaining`（上游提供数值时）；
- 令牌可用性、额度耗尽、账号限制、账单异常；
- 模型探测状态、耗时、最近检查时间和调度冷却。

部分 Zed 套餐会返回 `{ "limited": 0 }`，但模型仍可正常使用。项目将其解释为“未公开数值额度”，不会误报为余额耗尽；精确金额需前往 Zed 官方页面查看。

## 三、快速开始（Windows）

### （1）启动

在项目目录打开 PowerShell：

```powershell
# 固定默认端口：127.0.0.1:8001
.\start.ps1

# 停止由 start.ps1 启动的实例
.\stop.ps1
```

打开管理页：<http://127.0.0.1:8001>

如未配置账号：

```powershell
.\zed2api.exe login my-account
```

也可参考 `accounts.example.json`。`accounts.json` 含登录凭据，已由 `.gitignore` 排除，请勿提交、分享或写入截图。

### （2）检查服务

```powershell
# 默认：模型列表 + 全账号令牌/账单检查，不调用模型
.\health-check.ps1

# 仅对当前账号发送一次最低成本模型探测
.\health-check.ps1 -Deep

# 对全部账号各发送一次最低成本模型探测
.\health-check.ps1 -AllAccounts

# 可选：用三个小请求验证 Responses/Chat/Messages 的 SSE 收尾
.\health-check.ps1 -Streaming
```

`-Deep`、`-AllAccounts`、`-Streaming` 会产生模型请求；不带开关的默认检查不会产生模型输出费用。

## 四、客户端配置

### （1）三种配置的特点与选择

三套配置对应三种客户端协议，网关可以同时提供服务，但配置文件不能在客户端之间直接互换：

| 客户端配置 | 网关接口 | 主要特点 | 推荐场景 |
| --- | --- | --- | --- |
| Codex | `/v1/responses` | 使用原生 Responses typed Items，能完整保留 reasoning、工具调用及其历史关系 | 主要使用 Codex CLI、Codex 桌面端或 Codex IDE 功能 |
| OpenCode | `/v1/chat/completions` | 使用 OpenAI 兼容格式，模型和 `none/low/medium/high/xhigh` variants 切换最方便 | 需要在 OpenCode 中快速切换 Sol、Terra、Luna 与思考档位 |
| Claude Code | `/v1/messages` | 使用 Anthropic Messages 内容块、system 和工具结果语义 | 主要使用 Claude Code，或需要 Sonnet 5 / GPT-5.6 模板 |

三者的地址写法不同：Codex 和 OpenCode 的配置地址包含 `/v1`；Claude Code 配置根地址 `http://127.0.0.1:8001`，由客户端自动追加 `/v1/messages`。配置前先启动服务，并在 PowerShell 验证模型列表：

```powershell
# 能返回模型数组，说明本地网关已经启动且 8001 端口可访问。
Invoke-RestMethod -Uri 'http://127.0.0.1:8001/v1/models'
```

### （2）Codex：原生 Responses

将 `configs/codex.config.toml.example` 合并到：

```text
%USERPROFILE%\.codex\config.toml
```

核心配置：

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

配置步骤：

1. 打开 `%USERPROFILE%\.codex\config.toml`，已有配置时先保留原文件副本；
2. 将示例中的顶层 `model_provider`、`model`、`model_reasoning_effort` 和完整的 `[model_providers.zed_local]` 合并进去，不要把整个文件直接覆盖；
3. 重新启动 Codex 客户端，避免旧进程继续读取修改前的 Provider；
4. 在 PowerShell 执行以下命令验证。

```powershell
codex exec --skip-git-repo-check '请只回复：CODEX_OK'
```

Codex 使用原生 `/v1/responses`。`requires_openai_auth = false` 表示这个本地 Provider 不依赖 OpenAI 登录令牌；模型可换为 `gpt-5.6-terra` 或 `gpt-5.6-luna`，思考档位可选 `none/low/medium/high/xhigh`，默认 `xhigh`。

### （3）OpenCode：OpenAI 兼容与 variants

将 `configs/opencode.json.example` 复制为当前项目根目录的 `opencode.json`，或把其中的 `zed-local` Provider 合并到已有配置。该模板已经声明 Sol、Terra、Luna、裸别名和 Sonnet 5，并为 GPT-5.6 提供五种 variants。

```powershell
opencode run --model zed-local/gpt-5.6-terra --variant low "你的任务"
```

默认 provider 地址：

```json
{
  "npm": "@ai-sdk/openai-compatible",
  "options": {
    "baseURL": "http://127.0.0.1:8001/v1",
    "apiKey": "dummy"
  }
}
```

`apiKey = "dummy"` 只用于满足 OpenAI 兼容 SDK 的配置要求；本地网关当前不校验该值。验证时可用 `--model` 选择模型，用 `--variant` 选择思考档位，返回正常文本即表示配置生效。

### （4）Claude Code：Anthropic Messages

Sonnet 5 持久配置使用：

```text
configs/claude.settings.json.example
```

根据 GPT-5.6 变体，也可以选：

```text
configs/claude-gpt56-sol.settings.json.example
configs/claude-gpt56-terra.settings.json.example
configs/claude-gpt56-luna.settings.json.example
```

将对应内容合并到：

```text
%USERPROFILE%\.claude\settings.json
```

这些模板都指向 `http://127.0.0.1:8001`，设置 `NO_PROXY/no_proxy`，并按本项目要求固定 `xhigh`。

配置步骤：

1. Sonnet 5 选择 `claude.settings.json.example`；使用 GPT-5.6 时选择对应的 Sol、Terra 或 Luna 模板；
2. 将所选模板合并到 `%USERPROFILE%\.claude\settings.json`，已有其他 Claude Code 设置时不要整文件覆盖；
3. 关闭并重新启动 Claude Code，使环境变量和默认模型重新加载；
4. 执行以下命令验证。

```powershell
claude -p '请只回复：CLAUDE_OK'
```

Claude Code 的 `ANTHROPIC_BASE_URL` 不包含 `/v1`，这是因为客户端会自行拼接 Messages 路径。`NO_PROXY/no_proxy` 用于确保 Windows 上的本地请求不被系统代理转发；`ANTHROPIC_AUTH_TOKEN = "dummy"` 是本地兼容配置占位值。

## 五、API 一览

| 方法     | 路径                          | 作用                             |
| ------ | --------------------------- | ------------------------------ |
| `POST` | `/v1/responses`             | OpenAI Responses，流式/非流式        |
| `POST` | `/v1/chat/completions`      | OpenAI Chat Completions，流式/非流式 |
| `POST` | `/v1/messages`              | Anthropic Messages，流式/非流式      |
| `POST` | `/v1/messages/count_tokens` | Claude Code 启动兼容桩              |
| `GET`  | `/v1/models`                | 当前模型列表                         |
| `GET`  | `/zed/accounts`             | 脱敏账号与调度状态                      |
| `GET`  | `/zed/accounts/status`      | 全账号被动令牌/套餐/额度检查                |
| `POST` | `/zed/accounts/health`      | 单账号或全账号主动模型探测                  |
| `POST` | `/zed/accounts/switch`      | 切换当前账号                         |
| `GET`  | `/zed/usage`                | 读取当前账号的套餐与用量信息                 |
| `GET`  | `/zed/billing`              | 读取当前账号的账单响应                     |
| `POST` | `/zed/login`                | 启动 GitHub OAuth 登录             |
| `GET`  | `/zed/login/status`         | 查询 GitHub OAuth 登录状态           |

单账号健康检查：

```powershell
Invoke-RestMethod `
  -Uri 'http://127.0.0.1:8001/zed/accounts/health' `
  -Method Post `
  -ContentType 'application/json' `
  -Body '{"account":"my-account"}'
```

全部账号健康检查：

```powershell
Invoke-RestMethod `
  -Uri 'http://127.0.0.1:8001/zed/accounts/health' `
  -Method Post `
  -ContentType 'application/json' `
  -Body '{}'
```

## 六、官方格式请求示例

### （1）OpenAI Responses 流式请求

```powershell
$body = @{
    model             = 'gpt-5.6-sol'
    input             = 'Reply with exactly: ok'
    reasoning         = @{ effort = 'xhigh' }
    stream            = $true
    store             = $false
} | ConvertTo-Json -Depth 8 -Compress

Invoke-WebRequest `
    -Uri 'http://127.0.0.1:8001/v1/responses' `
    -Method Post `
    -ContentType 'application/json' `
    -Body $body
```

### （2）Anthropic Messages 流式请求

```powershell
$body = @{
    model         = 'claude-sonnet-5'
    max_tokens    = 1024
    stream        = $true
    output_config = @{ effort = 'xhigh' }
    messages      = @(
        @{ role = 'user'; content = 'Reply with exactly: ok' }
    )
} | ConvertTo-Json -Depth 8 -Compress

Invoke-WebRequest `
    -Uri 'http://127.0.0.1:8001/v1/messages' `
    -Method Post `
    -Headers @{ 'anthropic-version' = '2023-06-01'; 'x-api-key' = 'dummy' } `
    -ContentType 'application/json' `
    -Body $body
```

## 七、构建

### （1）重新构建 Web UI

```powershell
Set-Location .\webui
npm ci
npm run build
Set-Location ..
```

前端由 Vite 构建为单文件 `webui/dist/index.html`。

### （2）构建后端

需要 Zig `0.15.x`：

```powershell
# 先执行协议转换与流式回归测试
zig build test

# 测试通过后再构建正式二进制
zig build -Doptimize=ReleaseSafe
```

产物位于：

```text
zig-out\bin\zed2api.exe
```

后端会把 `webui/dist/index.html` 内嵌进 EXE，因此前端变化后必须再次执行 Zig 构建。

## 八、目录结构

```text
src/                    Zig 后端与协议转换
webui/                  Web UI 源码和单文件构建产物
configs/                Codex、OpenCode、Claude Code 配置模板
zed2api.exe             正式 ReleaseSafe 二进制
start.ps1               默认在 8001 后台启动
stop.ps1                按 PID 安全停止
health-check.ps1        被动检查与可选主动/流式检查
accounts.example.json   脱敏账号配置示例
```

## 九、安全与已知限制

- 服务仅绑定 `127.0.0.1`，没有 API Key 校验；请勿通过端口转发、Nginx 或防火墙规则直接公开到公网。
- Zed 是上游服务，模型名称、请求头、版本和账号策略可能变化。升级 Zed 客户端后，应重新核对 `src/proxy.zig` 中的版本与请求头，并完成端到端验证。
- `count_tokens` 当前是 Claude Code 兼容桩，返回值不用于精确计费。
- Zed 未公开数值额度的套餐，Web UI 只能显示“未公开”，不能推算真实金额。
- 健康调度一次最多尝试 64 个账号；更大的账号池需要扩展固定 try-order 缓冲区并补充并发测试。
- 本项目降低格式错误和异常请求特征，不代表绕过上游政策，也不保证账号状态。
- 上游当前未声明开源许可证；公开分发前必须先解决原始代码授权问题。`.gitignore` 只能避免新文件被 Git 跟踪，无法移除已经进入 Git 历史的凭据。

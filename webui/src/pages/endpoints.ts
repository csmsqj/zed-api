interface EndpointDefinition {
  method: 'GET' | 'POST'
  path: string
  description: string
  group: '模型协议' | '账号管理' | '兼容接口'
}

const ENDPOINTS: EndpointDefinition[] = [
  { method: 'POST', path: '/v1/responses', description: '面向 Codex 的 OpenAI Responses API，支持流式和非流式响应', group: '模型协议' },
  { method: 'POST', path: '/v1/chat/completions', description: 'OpenAI Chat Completions 兼容接口', group: '模型协议' },
  { method: 'POST', path: '/v1/messages', description: '面向 Claude Code 的 Anthropic Messages 原生接口', group: '模型协议' },
  { method: 'POST', path: '/v1/messages/count_tokens', description: 'Claude Code 启动阶段的 Token 计数兼容接口', group: '兼容接口' },
  { method: 'GET', path: '/v1/models', description: '返回当前网关可用的模型列表', group: '兼容接口' },
  { method: 'POST', path: '/api/event_logging/batch', description: 'Claude Code 事件上报兼容占位接口', group: '兼容接口' },
  { method: 'GET', path: '/zed/accounts', description: '读取脱敏后的账号列表与当前调度账号', group: '账号管理' },
  { method: 'GET', path: '/zed/accounts/status', description: '被动检查全部账号的令牌、套餐和额度', group: '账号管理' },
  { method: 'POST', path: '/zed/accounts/health', description: '对单个或全部账号执行低成本模型实测', group: '账号管理' },
  { method: 'POST', path: '/zed/accounts/switch', description: '切换当前优先调度账号', group: '账号管理' },
  { method: 'GET', path: '/zed/usage', description: '读取当前账号的套餐与用量信息', group: '账号管理' },
  { method: 'GET', path: '/zed/billing', description: '读取当前账号的 Zed 账单响应', group: '账号管理' },
  { method: 'POST', path: '/zed/login', description: '启动 GitHub OAuth 登录流程', group: '账号管理' },
  { method: 'GET', path: '/zed/login/status', description: '查询 GitHub OAuth 登录流程状态', group: '账号管理' },
]

const PROTOCOLS = [
  { name: 'Responses', client: 'Codex 首选', path: '/v1/responses', tone: 'cyan' },
  { name: 'Chat Completions', client: '通用 OpenAI 客户端', path: '/v1/chat/completions', tone: 'blue' },
  { name: 'Messages', client: 'Claude Code 首选', path: '/v1/messages', tone: 'violet' },
]

export function renderEndpoints() {
  const page = document.getElementById('page-endpoints')!
  const groups: EndpointDefinition['group'][] = ['模型协议', '账号管理', '兼容接口']

  page.innerHTML = `
    <div class="page-heading">
      <div>
        <span class="eyebrow">协议与路由</span>
        <h1>接口清单</h1>
        <p>网关同时提供 Responses、Chat Completions 和 Anthropic Messages 三套请求方式。</p>
      </div>
    </div>

    <div class="protocol-grid">
      ${PROTOCOLS.map(protocol => `
        <article class="protocol-card ${protocol.tone}">
          <span>${protocol.client}</span>
          <strong>${protocol.name}</strong>
          <code>${protocol.path}</code>
        </article>
      `).join('')}
    </div>

    ${groups.map(group => `
      <section class="endpoint-section">
        <div class="section-heading"><div><span>${group}</span><p>${group === '模型协议' ? '模型请求入口' : group === '账号管理' ? '账号、额度与调度接口' : '客户端启动与兼容接口'}</p></div></div>
        <div class="endpoint-table">
          ${ENDPOINTS.filter(endpoint => endpoint.group === group).map(endpoint => `
            <div class="endpoint-row">
              <span class="method-badge ${endpoint.method.toLowerCase()}">${endpoint.method}</span>
              <code>${endpoint.path}</code>
              <p>${endpoint.description}</p>
            </div>
          `).join('')}
        </div>
      </section>
    `).join('')}
  `
}

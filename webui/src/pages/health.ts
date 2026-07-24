import { icons } from '../icons'

interface CheckResult {
  name: string
  description: string
  status: 'ok' | 'fail' | 'pending'
  detail: string
  latency?: number
}

interface CheckDefinition {
  name: string
  description: string
  run: () => Promise<Omit<CheckResult, 'name' | 'description'>>
}

const CHECKS: CheckDefinition[] = [
  {
    name: 'API 服务',
    description: '确认本地网关能够返回模型列表',
    run: async () => {
      const started = performance.now()
      const response = await fetch('/v1/models', { cache: 'no-store' })
      const latency = Math.round(performance.now() - started)
      if (!response.ok) return { status: 'fail', detail: `HTTP ${response.status}`, latency }
      const data = await response.json() as { data?: unknown[] }
      return { status: 'ok', detail: `已加载 ${data.data?.length ?? 0} 个模型`, latency }
    },
  },
  {
    name: '账号配置',
    description: '确认至少存在一个可调度账号',
    run: async () => {
      const started = performance.now()
      const response = await fetch('/zed/accounts', { cache: 'no-store' })
      const latency = Math.round(performance.now() - started)
      if (!response.ok) return { status: 'fail', detail: `HTTP ${response.status}`, latency }
      const data = await response.json() as { accounts?: { name: string; current: boolean }[] }
      const accountList = data.accounts ?? []
      if (accountList.length === 0) return { status: 'fail', detail: '尚未配置账号', latency }
      const current = accountList.find(account => account.current)
      return { status: 'ok', detail: `${accountList.length} 个账号，当前：${current?.name ?? '未选择'}`, latency }
    },
  },
  {
    name: '令牌与额度',
    description: '被动检查全部账号，不产生模型请求',
    run: async () => {
      const started = performance.now()
      const response = await fetch('/zed/accounts/status', { cache: 'no-store' })
      const latency = Math.round(performance.now() - started)
      if (!response.ok) return { status: 'fail', detail: `HTTP ${response.status}`, latency }
      const data = await response.json() as { accounts?: { token_ok: boolean }[] }
      const accountList = data.accounts ?? []
      const usable = accountList.filter(account => account.token_ok).length
      return {
        status: usable === accountList.length && accountList.length > 0 ? 'ok' : 'fail',
        detail: `${usable}/${accountList.length} 个令牌可用`,
        latency,
      }
    },
  },
  {
    name: 'Codex Responses 路由',
    description: '检查 /v1/responses 路由与跨域响应',
    run: async () => checkRoute('/v1/responses'),
  },
  {
    name: 'Chat Completions 路由',
    description: '检查 /v1/chat/completions 兼容路由',
    run: async () => checkRoute('/v1/chat/completions'),
  },
  {
    name: 'Claude Messages 路由',
    description: '检查 /v1/messages 原生协议路由',
    run: async () => checkRoute('/v1/messages'),
  },
]

async function checkRoute(path: string): Promise<Omit<CheckResult, 'name' | 'description'>> {
  const started = performance.now()
  try {
    const response = await fetch(path, { method: 'OPTIONS' })
    const latency = Math.round(performance.now() - started)
    return { status: response.ok ? 'ok' : 'fail', detail: `HTTP ${response.status}`, latency }
  } catch (error) {
    return { status: 'fail', detail: error instanceof Error ? error.message : '路由不可达' }
  }
}

function escapeHtml(value: string): string {
  const element = document.createElement('div')
  element.textContent = value
  return element.innerHTML
}

export function renderHealth() {
  const page = document.getElementById('page-health')!
  page.innerHTML = `
    <div class="page-heading">
      <div>
        <span class="eyebrow">只读诊断</span>
        <h1>服务检查</h1>
        <p>检查服务、账号、令牌和三种协议路由；本页面不会主动发送模型推理请求。</p>
      </div>
      <div class="heading-actions">
        <button class="button secondary" id="rerun-button" type="button">${icons.refresh} 重新检查</button>
      </div>
    </div>

    <div class="notice-banner neutral">
      <span>${icons.alertCircle}</span>
      <p>路由检查只验证接口是否可达。需要验证真实模型输出时，请前往“账号中心”执行模型实测。</p>
    </div>

    <div class="health-summary" id="health-summary"></div>
    <div class="health-list" id="health-list"></div>
  `

  document.getElementById('rerun-button')!.addEventListener('click', () => void runChecks())
  void runChecks()
}

async function runChecks() {
  const list = document.getElementById('health-list')!
  const summary = document.getElementById('health-summary')!
  const rerunButton = document.getElementById('rerun-button') as HTMLButtonElement
  rerunButton.disabled = true
  rerunButton.innerHTML = '<span class="spinner"></span>正在检查'

  list.innerHTML = CHECKS.map(check => `
    <article class="health-row pending">
      <span class="health-icon"><span class="spinner"></span></span>
      <div class="health-copy">
        <strong>${check.name}</strong>
        <p>${check.description}</p>
      </div>
      <span class="health-result">检查中</span>
    </article>
  `).join('')
  summary.className = 'health-summary checking'
  summary.innerHTML = `<span class="spinner"></span><div><strong>正在执行 ${CHECKS.length} 项检查</strong><p>请稍候，检查完成后会显示每项耗时。</p></div>`

  const results: CheckResult[] = []
  for (let index = 0; index < CHECKS.length; index += 1) {
    const check = CHECKS[index]
    let result: CheckResult
    try {
      result = { name: check.name, description: check.description, ...await check.run() }
    } catch (error) {
      result = {
        name: check.name,
        description: check.description,
        status: 'fail',
        detail: error instanceof Error ? error.message : '检查异常',
      }
    }
    results.push(result)

    const row = list.querySelectorAll<HTMLElement>('.health-row')[index]
    if (row) {
      row.className = `health-row ${result.status}`
      row.innerHTML = `
        <span class="health-icon">${result.status === 'ok' ? icons.checkCircle : icons.xCircle}</span>
        <div class="health-copy"><strong>${result.name}</strong><p>${result.description}</p></div>
        <div class="health-result"><strong>${escapeHtml(result.detail)}</strong>${result.latency != null ? `<span>${result.latency} 毫秒</span>` : ''}</div>
      `
    }
  }

  const passed = results.filter(result => result.status === 'ok').length
  const allPassed = passed === results.length
  summary.className = `health-summary ${allPassed ? 'ok' : 'warn'}`
  summary.innerHTML = `
    <span class="health-summary-icon">${allPassed ? icons.checkCircle : icons.alertCircle}</span>
    <div>
      <strong>${allPassed ? '全部基础检查通过' : `${passed}/${results.length} 项检查通过`}</strong>
      <p>完成时间：${new Date().toLocaleString('zh-CN', { hour12: false })}</p>
    </div>
  `
  rerunButton.disabled = false
  rerunButton.innerHTML = `${icons.refresh} 重新检查`
}

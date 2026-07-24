import {
  checkAccountHealth,
  fetchAccounts,
  fetchAccountStatuses,
  fetchLoginStatus,
  startLogin,
  switchAccount,
  type Account,
  type AccountHealthResult,
  type AccountQuotaStatus,
} from '../api'
import { icons } from '../icons'
import { showToast } from '../toast'

let accounts: Account[] = []
let statuses = new Map<string, AccountQuotaStatus>()
let refreshingAccountData = false
let checkingAllAccounts = false
const checkingAccounts = new Set<string>()

function escapeHtml(value: string): string {
  // 账号元数据来自本地服务响应；统一按文本渲染，避免异常字段被浏览器当成 HTML。
  const element = document.createElement('div')
  element.textContent = value
  return element.innerHTML
}

function formatPlan(plan?: string): string {
  if (!plan || plan === 'unknown') return '套餐未公开'
  return plan.replace(/^zed_/, 'Zed ').replaceAll('_', ' ')
}

function formatDate(value?: string | null): string {
  if (!value) return '未公开'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return '未公开'
  return date.toLocaleDateString('zh-CN', { year: 'numeric', month: 'long', day: 'numeric' })
}

function formatCheckedAt(value?: number): string {
  if (!value) return '尚未检测'
  return new Date(value * 1000).toLocaleString('zh-CN', { hour12: false })
}

function quotaPresentation(status: AccountQuotaStatus | undefined) {
  if (!status) {
    return {
      className: refreshingAccountData ? 'checking' : 'unchecked',
      label: refreshingAccountData ? '正在读取' : '尚未检查',
      detail: refreshingAccountData ? '正在读取令牌和账单信息' : '刷新账号数据后显示令牌与额度状态',
    }
  }

  switch (status.quota_state) {
    case 'available':
      return {
        className: 'available',
        label: '额度可用',
        detail: `已用 ${status.used ?? 0} / ${status.limit ?? '未知'}，剩余 ${status.remaining ?? '未知'}`,
      }
    case 'exhausted':
      return {
        className: 'unavailable',
        label: '额度已用尽',
        detail: `已用 ${status.used ?? status.limit ?? '未知'} / ${status.limit ?? '未知'}`,
      }
    case 'unmetered':
      return {
        className: 'available',
        label: '令牌可用',
        detail: '令牌有效；当前套餐没有通过接口公开数值额度',
      }
    case 'restricted':
      return {
        className: 'unavailable',
        label: '账号受限',
        detail: 'Zed 当前未向该账号开放模型访问',
      }
    case 'unknown':
      return {
        className: 'warning',
        label: '额度未知',
        detail: '令牌有效，但账单信息暂时没有返回',
      }
    default:
      return {
        className: 'unavailable',
        label: '令牌不可用',
        detail: 'LLM 令牌刷新失败，请重新登录该账号',
      }
  }
}

function healthPresentation(status: AccountQuotaStatus | undefined, accountName: string) {
  const checking = checkingAllAccounts || checkingAccounts.has(accountName)
  if (checking) {
    return {
      className: 'checking',
      label: '正在实测',
      detail: '仅使用 gpt-5.6-luna、none 推理档位和最多 16 个输出 Token',
    }
  }

  switch (status?.model_state ?? 'unchecked') {
    case 'healthy':
      return {
        className: 'available',
        label: '模型正常',
        detail: `推理耗时 ${status?.model_latency_ms ?? 0} 毫秒 · ${formatCheckedAt(status?.model_checked_at)}`,
      }
    case 'auth_error':
      return {
        className: 'unavailable',
        label: '认证失败',
        detail: '真实模型请求未通过账号认证',
      }
    case 'rate_limited':
      return {
        className: 'warning',
        label: '触发限流',
        detail: '模型路由返回频率或额度限制，账号已进入冷却',
      }
    case 'upstream_error':
      return {
        className: 'unavailable',
        label: '上游异常',
        detail: '低成本推理探测没有完整结束',
      }
    default:
      return {
        className: 'unchecked',
        label: '尚未实测',
        detail: '点击实测 Luna 后只发送一次最小推理请求',
      }
  }
}

function quotaValue(status: AccountQuotaStatus | undefined): { value: string; detail: string } {
  if (!status) {
    return {
      value: refreshingAccountData ? '读取中' : '尚未检查',
      detail: '被动检查不会调用模型',
    }
  }
  if (!status.token_ok) return { value: '不可用', detail: '令牌刷新失败' }
  if (status.limit != null && status.limit > 0) {
    return {
      value: `剩余 ${status.remaining ?? 0}`,
      detail: `已使用 ${status.used ?? 0} / ${status.limit} 次模型请求`,
    }
  }
  return {
    value: 'Zed 未公开',
    detail: status.usage_based_billing ? '已启用按量计费' : '精确用量请前往 Zed 账单页面查看',
  }
}

function mergeHealthResult(result: AccountHealthResult) {
  const existing = statuses.get(result.name)
  if (existing) statuses.set(result.name, { ...existing, ...result })

  const account = accounts.find(item => item.name === result.name)
  if (account) {
    account.healthy = result.scheduler_healthy
    account.cooldown_s = result.cooldown_s
    account.last_status = result.last_status
  }
}

function renderOverview(checkedAt?: number) {
  const overview = document.getElementById('account-overview')
  if (!overview) return

  const values = [...statuses.values()]
  const usable = values.filter(status => status.usable).length
  const healthy = values.filter(status => status.model_state === 'healthy').length
  const cooling = accounts.filter(account => (statuses.get(account.name)?.cooldown_s ?? account.cooldown_s ?? 0) > 0).length
  const current = accounts.find(account => account.current)?.name ?? '未选择'
  const checked = checkedAt
    ? new Date(checkedAt * 1000).toLocaleTimeString('zh-CN', { hour12: false })
    : '等待刷新'

  overview.innerHTML = `
    <article class="metric-card featured">
      <span class="metric-label">当前调度账号</span>
      <strong>${escapeHtml(current)}</strong>
      <small>新请求会优先使用此账号</small>
    </article>
    <article class="metric-card">
      <span class="metric-label">令牌可用</span>
      <strong class="metric-good">${statuses.size ? `${usable} / ${accounts.length}` : '--'}</strong>
      <small>被动令牌检查结果</small>
    </article>
    <article class="metric-card">
      <span class="metric-label">Luna 实测正常</span>
      <strong class="metric-good">${statuses.size ? `${healthy} / ${accounts.length}` : '--'}</strong>
      <small>真实最小推理请求结果</small>
    </article>
    <article class="metric-card">
      <span class="metric-label">冷却中</span>
      <strong class="${cooling ? 'metric-warn' : ''}">${cooling}</strong>
      <small>最近刷新：${escapeHtml(checked)}</small>
    </article>
  `
}

function renderAccountCards() {
  const list = document.getElementById('account-list')
  if (!list) return

  if (accounts.length === 0) {
    list.innerHTML = `
      <div class="empty-state">
        <div class="empty-state-icon">${icons.users}</div>
        <strong>还没有可用账号</strong>
        <p>通过下方 GitHub OAuth 登录按钮添加第一个 Zed 账号。</p>
      </div>
    `
    return
  }

  list.innerHTML = accounts.map((account, index) => {
    const status = statuses.get(account.name)
    const quota = quotaPresentation(status)
    const health = healthPresentation(status, account.name)
    const balance = quotaValue(status)
    const cooldown = status?.cooldown_s ?? account.cooldown_s ?? 0
    const checking = checkingAllAccounts || checkingAccounts.has(account.name)

    return `
      <article class="account-card ${account.current ? 'active' : ''}">
        <header class="account-card-header">
          <div class="account-identity">
            <span class="account-avatar">${escapeHtml(account.name.slice(0, 1).toUpperCase())}</span>
            <div>
              <div class="account-name-line">
                <strong>${escapeHtml(account.name)}</strong>
                ${account.current ? '<span class="state-pill current">当前账号</span>' : ''}
              </div>
              <span class="account-id">用户编号 ${escapeHtml(account.user_id)}</span>
            </div>
          </div>
          <div class="account-state-group">
            <span class="state-pill ${quota.className}">${escapeHtml(quota.label)}</span>
            <span class="state-pill ${health.className}">${escapeHtml(health.label)}</span>
          </div>
        </header>

        <div class="account-detail-grid">
          <div class="detail-cell">
            <span>套餐</span>
            <strong>${escapeHtml(formatPlan(status?.plan))}</strong>
            <small>${status?.billing_ok ? '已读取账单信息' : escapeHtml(quota.detail)}</small>
          </div>
          <div class="detail-cell">
            <span>到期或续订</span>
            <strong>${escapeHtml(formatDate(status?.subscription_ends_at))}</strong>
            <small>${status?.overdue ? 'Zed 返回账单逾期提示' : '来自 Zed 账号接口'}</small>
          </div>
          <div class="detail-cell">
            <span>额度</span>
            <strong>${escapeHtml(balance.value)}</strong>
            <small>${escapeHtml(balance.detail)}</small>
          </div>
          <div class="detail-cell">
            <span>模型链路</span>
            <strong class="tone-${health.className}">${escapeHtml(health.label)}</strong>
            <small>${escapeHtml(health.detail)}${cooldown > 0 ? ` · 冷却 ${cooldown} 秒` : ''}</small>
          </div>
        </div>

        <footer class="account-card-footer">
          <a href="https://zed.dev/account/billing" target="_blank" rel="noreferrer">
            查看 Zed 账单 ${icons.externalLink}
          </a>
          <div>
            <button class="button secondary health-button" data-index="${index}" type="button" ${checking ? 'disabled' : ''}>
              ${checking ? '<span class="spinner"></span>检测中' : `${icons.activity} 实测 Luna`}
            </button>
            ${account.current
              ? `<span class="active-account-hint">${icons.check} 已参与优先调度</span>`
              : `<button class="button primary switch-button" data-index="${index}" type="button">切换到此账号</button>`}
          </div>
        </footer>
      </article>
    `
  }).join('')

  list.querySelectorAll<HTMLButtonElement>('.switch-button').forEach(button => {
    button.addEventListener('click', async () => {
      const account = accounts[Number(button.dataset.index)]
      if (!account) return
      button.disabled = true
      try {
        await switchAccount(account.name)
        showToast(`已切换到账号：${account.name}`)
        await loadAccounts()
      } catch (error) {
        showToast(`账号切换失败：${error instanceof Error ? error.message : '未知错误'}`)
        button.disabled = false
      }
    })
  })

  list.querySelectorAll<HTMLButtonElement>('.health-button').forEach(button => {
    button.addEventListener('click', () => {
      const account = accounts[Number(button.dataset.index)]
      if (account) void runHealthCheck(account.name)
    })
  })
}

function updateActionButtons() {
  const refreshButton = document.getElementById('refresh-accounts-button') as HTMLButtonElement | null
  if (refreshButton) {
    refreshButton.disabled = refreshingAccountData || checkingAllAccounts
    refreshButton.innerHTML = refreshingAccountData
      ? '<span class="spinner"></span>正在刷新'
      : `${icons.refresh} 刷新账号数据`
  }

  const healthButton = document.getElementById('check-all-button') as HTMLButtonElement | null
  if (healthButton) {
    healthButton.disabled = checkingAllAccounts || refreshingAccountData || accounts.length === 0
    healthButton.innerHTML = checkingAllAccounts
      ? '<span class="spinner"></span>正在实测全部账号'
      : `${icons.activity} 全部账号实测`
  }
}

async function refreshAccountData(silent = false) {
  if (refreshingAccountData || accounts.length === 0) return
  refreshingAccountData = true
  updateActionButtons()
  renderAccountCards()

  try {
    const response = await fetchAccountStatuses()
    statuses = new Map(response.accounts.map(status => [status.name, status]))
    renderOverview(response.checked_at)
    renderAccountCards()
    if (!silent) showToast('账号令牌、套餐与额度信息已刷新；本操作没有调用模型')
  } catch (error) {
    if (!silent) showToast(`账号数据刷新失败：${error instanceof Error ? error.message : '未知错误'}`)
  } finally {
    refreshingAccountData = false
    updateActionButtons()
    renderAccountCards()
  }
}

async function runHealthCheck(accountName?: string) {
  if (checkingAllAccounts || (accountName && checkingAccounts.has(accountName))) return
  if (accountName) checkingAccounts.add(accountName)
  else checkingAllAccounts = true
  updateActionButtons()
  renderAccountCards()

  try {
    const response = await checkAccountHealth(accountName)
    response.accounts.forEach(mergeHealthResult)
    renderOverview()
    const passed = response.accounts.filter(result => result.model_ok).length
    showToast(`账号实测完成：${passed}/${response.accounts.length} 通过 · 仅 ${response.probe.model} · ${response.probe.reasoning_effort}`)
  } catch (error) {
    showToast(`账号实测失败：${error instanceof Error ? error.message : '未知错误'}`)
  } finally {
    if (accountName) checkingAccounts.delete(accountName)
    else checkingAllAccounts = false
    updateActionButtons()
    renderAccountCards()
  }
}

async function loadAccounts() {
  const list = document.getElementById('account-list')
  if (!list) return

  try {
    const data = await fetchAccounts()
    accounts = data.accounts ?? []
    const count = document.getElementById('acc-count')
    if (count) count.textContent = String(accounts.length)
    renderOverview()
    renderAccountCards()
    updateActionButtons()
    if (accounts.length > 0) void refreshAccountData(true)
  } catch (error) {
    list.innerHTML = `<div class="error-state">账号加载失败：${error instanceof Error ? escapeHtml(error.message) : '未知错误'}</div>`
  }
}

export function renderAccounts() {
  const page = document.getElementById('page-accounts')!
  page.innerHTML = `
    <div class="page-heading">
      <div>
        <span class="eyebrow">账号与故障转移</span>
        <h1>账号中心</h1>
        <p>集中查看令牌、套餐、额度、冷却状态和真实模型链路，并控制当前优先调度账号。</p>
      </div>
      <div class="heading-actions">
        <button class="button secondary" id="refresh-accounts-button" type="button">${icons.refresh} 刷新账号数据</button>
        <button class="button primary" id="check-all-button" type="button">${icons.activity} 全部账号实测</button>
      </div>
    </div>

    <div class="notice-banner">
      <span>${icons.shield}</span>
      <p><strong>检测成本说明</strong>：令牌、套餐和额度检查不会调用模型；账号实测只会对每个选中账号调用一次 gpt-5.6-luna，使用 none 推理档位、短提示词和最多 16 个输出 Token，不会轮流检测其他模型。</p>
    </div>

    <div class="metric-grid" id="account-overview"></div>

    <div class="section-heading">
      <div><span>账号列表</span><p>健康账号优先，异常账号会按错误类型自动进入冷却。</p></div>
    </div>
    <div class="account-list" id="account-list">
      <div class="loading-panel"><span class="spinner"></span>正在加载账号</div>
    </div>

    <button class="add-account-card" id="add-account-button" type="button">
      <span class="add-account-icon">${icons.plus}</span>
      <span><strong>添加 Zed 账号</strong><small>通过 GitHub OAuth 完成登录，不在页面中输入或保存密码</small></span>
      <span class="add-account-arrow">${icons.arrowRight}</span>
    </button>
    <div class="login-banner" id="login-banner" hidden></div>
  `

  document.getElementById('add-account-button')!.addEventListener('click', () => void startOAuthLogin())
  document.getElementById('refresh-accounts-button')!.addEventListener('click', () => void refreshAccountData())
  document.getElementById('check-all-button')!.addEventListener('click', () => void runHealthCheck())
  void loadAccounts()
}

async function startOAuthLogin() {
  const banner = document.getElementById('login-banner')!
  const button = document.getElementById('add-account-button') as HTMLButtonElement
  button.disabled = true
  banner.hidden = false
  banner.innerHTML = '<span class="spinner"></span><span>正在生成密钥并启动 GitHub OAuth…</span>'

  try {
    const data = await startLogin()
    if (data.error) {
      banner.innerHTML = `<span class="error-text">${icons.xCircle} ${escapeHtml(data.error)}</span>`
      button.disabled = false
      return
    }

    banner.innerHTML = `
      <span class="spinner"></span>
      <span>等待 GitHub 授权回调，请在浏览器窗口完成登录。</span>
      ${data.login_url ? `<a href="${escapeHtml(data.login_url)}" target="_blank" rel="noreferrer">打开授权页面 ${icons.externalLink}</a>` : ''}
    `

    const startedAt = Date.now()
    const poll = window.setInterval(async () => {
      if (Date.now() - startedAt > 5 * 60 * 1000) {
        window.clearInterval(poll)
        banner.innerHTML = `<span class="error-text">${icons.alertCircle} 登录等待已超时，请重新发起授权。</span>`
        button.disabled = false
        return
      }

      try {
        const status = await fetchLoginStatus()
        if (status.status === 'success') {
          window.clearInterval(poll)
          banner.innerHTML = `${icons.checkCircle}<span>账号登录成功，正在刷新账号列表。</span>`
          button.disabled = false
          statuses.clear()
          showToast('Zed 账号添加成功')
          await loadAccounts()
          window.setTimeout(() => { banner.hidden = true }, 3000)
        } else if (status.status === 'failed') {
          window.clearInterval(poll)
          banner.innerHTML = `<span class="error-text">${icons.xCircle} 登录失败，请重新尝试。</span>`
          button.disabled = false
        }
      } catch {
        // OAuth 工作线程更新状态时可能短暂不可读，保留轮询即可。
      }
    }, 1500)
  } catch (error) {
    banner.innerHTML = `<span class="error-text">${icons.xCircle} 登录启动失败：${error instanceof Error ? escapeHtml(error.message) : '未知错误'}</span>`
    button.disabled = false
  }
}

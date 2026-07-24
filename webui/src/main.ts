import './style.css'
import { icons } from './icons'
import { renderAccounts } from './pages/accounts'
import { renderEndpoints } from './pages/endpoints'
import { renderHealth } from './pages/health'
import { renderIntegration } from './pages/integration'

type PageId = 'accounts' | 'health' | 'endpoints' | 'integration'

const PAGE_TITLES: Record<PageId, string> = {
  accounts: '账号中心',
  health: '服务检查',
  endpoints: '接口清单',
  integration: '客户端接入',
}

const app = document.getElementById('app')!
const port = location.port || '8001'

app.innerHTML = `
  <div class="app-shell">
    <aside class="side-panel">
      <div class="brand-block">
        <div class="brand-mark">${icons.zap}</div>
        <div>
          <strong>Zed API 网关</strong>
          <span>本地模型接入控制台</span>
        </div>
      </div>

      <div class="service-overview" id="service-overview">
        <div class="service-overview-head">
          <span class="live-dot checking" id="service-dot"></span>
          <span id="service-label">正在检查服务</span>
        </div>
        <div class="service-overview-meta">
          <span>127.0.0.1:${port}</span>
          <span id="model-count">-- 个模型</span>
        </div>
      </div>

      <nav class="primary-nav" aria-label="主导航">
        <section class="nav-section">
          <p>运行管理</p>
          <button class="nav-item active" data-page="accounts" type="button">
            <span class="nav-icon">${icons.users}</span>
            <span>账号中心</span>
            <span class="nav-badge" id="acc-count">0</span>
          </button>
          <button class="nav-item" data-page="health" type="button">
            <span class="nav-icon">${icons.activity}</span>
            <span>服务检查</span>
          </button>
        </section>

        <section class="nav-section">
          <p>开发接入</p>
          <button class="nav-item" data-page="endpoints" type="button">
            <span class="nav-icon">${icons.globe}</span>
            <span>接口清单</span>
          </button>
          <button class="nav-item" data-page="integration" type="button">
            <span class="nav-icon">${icons.code}</span>
            <span>客户端接入</span>
          </button>
        </section>
      </nav>

      <footer class="side-footer">
        <div>${icons.shield}</div>
        <p><strong>仅监听本机地址</strong><span>账号凭据不会发送到前端页面</span></p>
      </footer>
    </aside>

    <section class="workspace">
      <header class="topbar">
        <div>
          <span class="topbar-kicker">控制台 / <span id="current-page-name">账号中心</span></span>
          <strong id="topbar-title">账号中心</strong>
        </div>
        <div class="topbar-status">
          <span class="topbar-clock" id="local-clock"></span>
          <span class="runtime-chip">${icons.server} 服务端口 ${port}</span>
        </div>
      </header>

      <main class="page-stage">
        <section class="page active" id="page-accounts"></section>
        <section class="page" id="page-health"></section>
        <section class="page" id="page-endpoints"></section>
        <section class="page" id="page-integration"></section>
      </main>
    </section>
  </div>
  <div class="toast" id="toast" role="status" aria-live="polite"></div>
`

function isPageId(value: string | undefined): value is PageId {
  return value != null && value in PAGE_TITLES
}

function activatePage(pageId: PageId, updateHash = true) {
  document.querySelectorAll<HTMLButtonElement>('.nav-item[data-page]').forEach(button => {
    const active = button.dataset.page === pageId
    button.classList.toggle('active', active)
    if (active) button.setAttribute('aria-current', 'page')
    else button.removeAttribute('aria-current')
  })

  document.querySelectorAll<HTMLElement>('.page').forEach(page => {
    page.classList.toggle('active', page.id === `page-${pageId}`)
  })

  const title = PAGE_TITLES[pageId]
  document.getElementById('current-page-name')!.textContent = title
  document.getElementById('topbar-title')!.textContent = title
  document.title = `${title} · Zed API 网关`
  if (updateHash) history.replaceState(null, '', `#${pageId}`)
}

document.querySelectorAll<HTMLButtonElement>('.nav-item[data-page]').forEach(button => {
  button.addEventListener('click', () => {
    const pageId = button.dataset.page
    if (isPageId(pageId)) activatePage(pageId)
  })
})

window.addEventListener('hashchange', () => {
  const pageId = location.hash.slice(1)
  if (isPageId(pageId)) activatePage(pageId, false)
})

function updateClock() {
  document.getElementById('local-clock')!.textContent = new Intl.DateTimeFormat('zh-CN', {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  }).format(new Date())
}

async function refreshServiceState() {
  const dot = document.getElementById('service-dot')!
  const label = document.getElementById('service-label')!
  const count = document.getElementById('model-count')!
  dot.className = 'live-dot checking'
  label.textContent = '正在检查服务'

  try {
    const response = await fetch('/v1/models', { cache: 'no-store' })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const data = await response.json() as { data?: unknown[] }
    dot.className = 'live-dot online'
    label.textContent = '本地服务运行中'
    count.textContent = `${data.data?.length ?? 0} 个模型`
  } catch {
    dot.className = 'live-dot offline'
    label.textContent = '本地服务未响应'
    count.textContent = '连接失败'
  }
}

renderAccounts()
renderHealth()
renderEndpoints()
renderIntegration()

const initialPage = location.hash.slice(1)
activatePage(isPageId(initialPage) ? initialPage : 'accounts', false)
updateClock()
window.setInterval(updateClock, 1000)
void refreshServiceState()
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') void refreshServiceState()
})

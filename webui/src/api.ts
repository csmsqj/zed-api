export interface Account {
  name: string
  user_id: string
  current: boolean
  healthy?: boolean
  cooldown_s?: number
  consecutive_failures?: number
  last_status?: number
}

export interface AccountsResponse {
  accounts: Account[]
  current: string
}

export interface AccountQuotaStatus {
  name: string
  user_id: string
  current: boolean
  scheduler_healthy: boolean
  cooldown_s: number
  last_status: number
  check_ok: boolean
  token_ok: boolean
  billing_ok: boolean
  usable: boolean
  quota_state: 'available' | 'exhausted' | 'unmetered' | 'restricted' | 'unknown' | 'unavailable'
  plan?: string
  used?: number | null
  limit?: number | null
  remaining?: number | null
  subscription_ends_at?: string | null
  usage_based_billing?: boolean
  overdue?: boolean
  account_too_young?: boolean
  model_ok?: boolean
  model_state?: AccountModelState
  model_checked_at?: number
  model_latency_ms?: number
  error?: string
}

export interface AccountStatusesResponse {
  checked_at: number
  accounts: AccountQuotaStatus[]
}

export type AccountModelState = 'unchecked' | 'healthy' | 'auth_error' | 'rate_limited' | 'upstream_error'

export interface AccountHealthResult {
  name: string
  model_ok: boolean
  model_state: AccountModelState
  model_checked_at: number
  model_latency_ms: number
  scheduler_healthy: boolean
  cooldown_s: number
  last_status: number
}

export interface AccountHealthResponse {
  checked_at: number
  probe: {
    model: string
    reasoning_effort: string
    max_output_tokens: number
  }
  accounts: AccountHealthResult[]
}

export interface UsageInfo {
  plan?: string
  monthly_spend_in_cents?: number
  monthly_spending_limit_in_cents?: number
  subscriptionPeriod?: string[]
  githubUserLogin?: string
  // from /client/users/me
  user?: { github_login?: string; name?: string; avatar_url?: string }
  planInfo?: {
    plan?: string
    subscription_period?: { started_at?: string; ended_at?: string }
    usage?: { model_requests?: { used?: number; limit?: { limited?: number } } }
  }
  [key: string]: unknown
}

export async function fetchAccounts(): Promise<AccountsResponse> {
  const r = await fetch('/zed/accounts')
  if (!r.ok) throw new Error(`${r.status}`)
  return r.json()
}

export async function fetchAccountStatuses(): Promise<AccountStatusesResponse> {
  const r = await fetch('/zed/accounts/status')
  if (!r.ok) throw new Error(`${r.status}`)
  return r.json()
}

/**
 * Run an explicit inference probe. Omitting `name` checks all accounts;
 * callers should only invoke this from a user action because it consumes one
 * deliberately tiny model request per selected account.
 */
export async function checkAccountHealth(name?: string): Promise<AccountHealthResponse> {
  const r = await fetch('/zed/accounts/health', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(name ? { account: name } : {}),
  })
  if (!r.ok) {
    const detail = await r.text()
    throw new Error(`${r.status}${detail ? `: ${detail}` : ''}`)
  }
  return r.json()
}

export async function switchAccount(name: string): Promise<void> {
  const r = await fetch('/zed/accounts/switch', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ account: name }),
  })
  if (!r.ok) throw new Error(`${r.status}`)
}

export async function fetchUsage(): Promise<UsageInfo> {
  const r = await fetch('/zed/usage')
  if (!r.ok) throw new Error(`${r.status}`)
  return r.json()
}

export async function fetchBilling(): Promise<Record<string, unknown>> {
  const r = await fetch('/zed/billing')
  if (!r.ok) throw new Error(`${r.status}`)
  return r.json()
}

export async function startLogin(name?: string): Promise<{ login_url?: string; error?: string }> {
  const r = await fetch('/zed/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(name ? { name } : {}),
  })
  return r.json()
}

export async function fetchLoginStatus(): Promise<{ status: string }> {
  const r = await fetch('/zed/login/status')
  return r.json()
}

export interface ChatMessage {
  role: 'user' | 'assistant' | 'system'
  content: string
}

export async function sendOpenAI(
  model: string,
  messages: ChatMessage[],
  maxTokens = 4096,
): Promise<string> {
  const r = await fetch('/v1/chat/completions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, messages, max_tokens: maxTokens }),
  })
  const d = await r.json()
  return d.choices?.[0]?.message?.content ?? JSON.stringify(d, null, 2)
}

export async function sendAnthropic(
  model: string,
  messages: ChatMessage[],
  maxTokens = 4096,
): Promise<string> {
  const r = await fetch('/v1/messages', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, messages, max_tokens: maxTokens }),
  })
  const d = await r.json()
  return d.content?.[0]?.text ?? JSON.stringify(d, null, 2)
}

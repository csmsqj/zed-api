// 控制台使用的轻量内联图标，避免额外加载字体或外部静态资源。
const icon = (body: string, size = 18) => `
  <svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none"
    stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
    aria-hidden="true">${body}</svg>`

export const icons = {
  zap: icon('<path d="M13.4 2.8 5 13h6l-.4 8.2L19 11h-6l.4-8.2Z"/>'),
  users: icon('<circle cx="9" cy="8" r="3.2"/><path d="M3.5 20v-1.1A5.5 5.5 0 0 1 9 13.4a5.5 5.5 0 0 1 5.5 5.5V20"/><path d="M15.5 5.6a3 3 0 0 1 0 5.8M16.4 14.2a4.8 4.8 0 0 1 4.1 4.7V20"/>'),
  activity: icon('<path d="M3 12h3.2l2-5.2 4.1 11 2.4-6.2H21"/>'),
  globe: icon('<circle cx="12" cy="12" r="8.8"/><path d="M3.4 12h17.2M12 3.2c2.2 2.4 3.3 5.3 3.3 8.8S14.2 18.4 12 20.8C9.8 18.4 8.7 15.5 8.7 12S9.8 5.6 12 3.2Z"/>'),
  code: icon('<path d="m8.5 7-5 5 5 5M15.5 7l5 5-5 5M13.6 4.5 10.4 19.5"/>'),
  plus: icon('<path d="M12 5v14M5 12h14"/>'),
  check: icon('<path d="m5 12.5 4.2 4.2L19.5 6.5"/>'),
  checkCircle: icon('<circle cx="12" cy="12" r="9"/><path d="m7.8 12.2 2.8 2.8 5.8-6"/>'),
  xCircle: icon('<circle cx="12" cy="12" r="9"/><path d="m9 9 6 6m0-6-6 6"/>'),
  alertCircle: icon('<circle cx="12" cy="12" r="9"/><path d="M12 7.5v5.2M12 16.5h.01"/>'),
  copy: icon('<rect x="8" y="8" width="11" height="11" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/>', 15),
  server: icon('<rect x="3" y="4" width="18" height="6" rx="2"/><rect x="3" y="14" width="18" height="6" rx="2"/><path d="M7 7h.01M7 17h.01M11 7h7M11 17h7"/>'),
  shield: icon('<path d="M12 3 5 6v5.2c0 4.5 2.6 7.8 7 9.8 4.4-2 7-5.3 7-9.8V6l-7-3Z"/><path d="m9 12 2 2 4-4"/>'),
  logIn: icon('<path d="M14 4h4a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-4M10 8l4 4-4 4M14 12H3"/>'),
  send: icon('<path d="m21 3-7.5 18-3.2-7.3L3 10.5 21 3Z"/><path d="m10.3 13.7 4.4-4.4"/>'),
  arrowRight: icon('<path d="M5 12h14m-5-5 5 5-5 5"/>'),
  refresh: icon('<path d="M19.5 8A8 8 0 1 0 20 15M19.5 8V3.8M19.5 8h-4.2"/>'),
  heart: icon('<path d="M20 5.8a5 5 0 0 0-7.1 0L12 6.7l-.9-.9A5 5 0 0 0 4 12.9l8 8 8-8a5 5 0 0 0 0-7.1Z"/>'),
  clock: icon('<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3.5 2"/>'),
  externalLink: icon('<path d="M14 4h6v6M20 4l-9 9"/><path d="M18 13v5a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h5"/>', 13),
} as const

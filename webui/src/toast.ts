let hideTimer: ReturnType<typeof setTimeout> | undefined

export function showToast(message: string) {
  const toast = document.getElementById('toast')
  if (!toast) return

  toast.textContent = message
  toast.classList.add('visible')
  if (hideTimer) window.clearTimeout(hideTimer)
  hideTimer = window.setTimeout(() => toast.classList.remove('visible'), 3200)
}

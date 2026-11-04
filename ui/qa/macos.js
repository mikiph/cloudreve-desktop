// Development-only UI fixture. No real credentials, native IPC or HTTP requests.
if (!import.meta.env.DEV || !['localhost', '127.0.0.1'].includes(location.hostname)) {
  throw new Error('The macOS QA fixture only runs on a local development server')
}
let clockHour12 = null
let next = 0
const callbacks = new Map()
const listeners = new Map()
const requests = new Map()
const calls = []
window.__TAURI_OS_PLUGIN_INTERNALS__ = { platform: 'macos', os_type: 'macos' }
window.__TAURI_EVENT_PLUGIN_INTERNALS__ = {
  unregisterListener: (_event, id) => listeners.delete(id),
}
window.__TAURI_INTERNALS__ = {
  metadata: { currentWindow: { label: 'add_drive' }, currentWebview: { label: 'add_drive' } },
  convertFileSrc: (path) => path,
  transformCallback: (handler) => { callbacks.set(++next, handler); return next },
  invoke: async (command, args = {}) => {
    calls.push(command)
    if (command === 'plugin:event|listen') {
      const id = ++next
      listeners.set(id, { event: args.event, handler: callbacks.get(args.handler) })
      return id
    }
    if (command === 'get_clock_preferences') return { hour12: clockHour12, system_hour12: false }
    if (command === 'set_clock_hour12') {
      clockHour12 = args.hour12
      for (const listener of listeners.values()) {
        if (listener.event === 'clock-preferences-changed') listener.handler({ payload: null })
      }
      return
    }
    if (command === 'get_general_settings') return { language: null, log_level: 'info', log_max_files: 5, log_dir: '/test/logs' }
    if (command === 'plugin:window|theme') return 'light'
    if (command === 'plugin:app|version') return '0.2.1'
    if (command === 'plugin:opener|open_url') {
      const state = new URL(args.url).searchParams.get('state')
      const payload = 'cloudreve://callback/desktop?code=mock&state=' + encodeURIComponent(state)
        + '&name=Cloudreve&path=cloudreve%3A%2F%2Fmy&user_id=qa'
      for (const listener of listeners.values()) {
        if (listener.event === 'deeplink') listener.handler({ payload })
      }
      return
    }
    if (command === 'plugin:http|fetch') {
      const id = ++next
      requests.set(id, { url: args.clientConfig.url, read: false })
      return id
    }
    if (command === 'plugin:http|fetch_send') {
      return { status: 200, statusText: 'OK', url: requests.get(args.rid).url, headers: [], rid: args.rid }
    }
    if (command === 'plugin:http|fetch_read_body') {
      const request = requests.get(args.rid)
      if (request.read) return [1]
      request.read = true
      const data = request.url.includes('token')
        ? { access_token: 'mock-access', refresh_token: 'mock-refresh', expires_in: 3600, refresh_token_expires_in: 7200 }
        : request.url.includes('ping') ? { code: 0, data: '4.12.0' } : { icons: [] }
      return [...new TextEncoder().encode(JSON.stringify(data)), 0]
    }
    if (command === 'add_drive') return 'qa-drive'
    if (command === 'complete_finder_setup') return '/Users/qa/Library/CloudStorage/Cloudreve'
    if (command === 'verify_finder_setup') {
      if (!document.querySelector('#approve').checked) throw 'Approve Cloudreve in Finder to continue.'
      return
    }
    if (command === 'list_file_provider_issues') return new URLSearchParams(location.search).has('deleteIssue') ? [{
      id: 'pending:qa-delete', drive_id: 'qa-drive', drive_name: 'QA Drive',
      item_identifier: 'cloudreve-item:/qa-app', filename: 'Cloudreve.app', is_folder: true,
      operation: 'delete', source: 'pending', kind: null, application: null,
      message: 'An unfinished upload is holding this item.', error_domain: 'NSFileProviderErrorDomain',
      error_code: -2005, conflict_id: null, updated_at: Date.now(),
    }] : []
    if (command === 'resolve_file_provider_issue') return null
    if (command === 'get_status_summary') {
      const phase = document.querySelector('#health').value
      const scenario = document.querySelector('#progress-case').value
      const drives = [{ id: 'qa-drive', name: 'Cloudreve', instance_url: 'https://cloudreve.example', sync_path: '/test' }]
      const syncHealth = [{ drive_id: 'qa-drive', connected: phase !== 'offline', recovery: {
          phase: phase === 'offline' ? 'checking' : phase, items_checked: 482, folders_checked: 18,
          updated_at: Date.now(), last_completed_at: new Date().setHours(18, 5, 0, 0), error: phase === 'retrying' ? 'Connection timed out' : null,
          folder_progress: phase === 'applying' ? {
            completed: scenario === 'large' ? 1209 : 37,
            total: scenario === 'large' ? 3000 : scenario === 'discovered' ? 146 : 129,
            remaining: scenario === 'large' ? 1791 : scenario === 'discovered' ? 109 : 92,
            pages_checked: 85, items_checked: scenario === 'large' ? 240000 : 12020, retrying: 0,
          } : null,
          target_sequence: phase === 'applying' || phase === 'completed' ? 42 : null,
      } }]
      if (scenario === 'mixed') {
        drives.push({ id: 'qa-second', name: 'Second Drive', instance_url: 'https://cloudreve.example', sync_path: '/second' })
        drives.push({ id: 'qa-done', name: 'Completed Drive', instance_url: 'https://cloudreve.example', sync_path: '/done' })
        syncHealth.push({ drive_id: 'qa-second', connected: true, recovery: {
          ...syncHealth[0].recovery, phase, items_checked: 18,
          folder_progress: { completed: 3, total: 10, remaining: 7, pages_checked: 4, items_checked: 45, retrying: 0 },
        } })
        syncHealth.push({ drive_id: 'qa-done', connected: true, recovery: {
          ...syncHealth[0].recovery, phase: 'completed', items_checked: 99999,
          folder_progress: { completed: 3000, total: 3000, remaining: 0, pages_checked: 9000, items_checked: 99999, retrying: 0 },
        } })
      }
      const failedHistory = new URLSearchParams(location.search).has('repeatedFailures')
        ? Array.from({ length: 27 }, (_, index) => ({
          id: `fp-transfer-attempt-${index}`, drive_id: 'qa-drive', task_type: 'upload',
          local_path: '/QA/Cloudreve.app/Contents/PlugIns/CloudreveFileProvider.appex',
          status: 'Failed', progress: 0, total_bytes: 96, processed_bytes: 0,
          error: index === 0 ? 'This macOS package cannot be uploaded directly. Compress it into a ZIP file and upload the ZIP instead.' : 'The Internet connection appears to be offline.',
          created_at: Math.floor(Date.now() / 1000) - index * 7200,
          updated_at: Math.floor(Date.now() / 1000) - index * 7200,
        })) : []
      return { drives, active_tasks: [], finished_tasks: failedHistory, pending_conflicts: [],
        sync_health: syncHealth.filter((health) => !args.driveId || health.drive_id === args.driveId),
      }
    }
    if (command === 'plugin:window|destroy') { location.hash = '#/popup'; return }
    return null
  },
}
// Expose only fixture call counts for inspection through this page's DOM.
setInterval(() => {
  document.body.dataset.accountSaves = calls.filter((call) => call === 'add_drive').length
  document.body.dataset.tokenExchanges = [...requests.values()].filter((request) => request.url.includes('token')).length
}, 250)
if (!location.hash) location.hash = '#/add-drive'
await import('../src/main.tsx')

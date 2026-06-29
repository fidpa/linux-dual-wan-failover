// Minimal client glue for the linux-dual-wan-failover dashboard.
// HTMX handles all reactive UI; this file only renders JSON responses
// (config, history) and manages the diagnostics SSE stream.

(function () {
  // === helpers ============================================================

  // CSRF cookie is HttpOnly — read the token from the <meta> tag rendered
  // by base.html.j2 instead of from document.cookie.
  function getCsrfCookie() {
    const meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.getAttribute('content') || '' : '';
  }

  function escapeHtml(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  // SQLite stores ISO datetimes as "YYYY-MM-DD HH:MM:SS[.uuuuuu]".
  // JavaScript Date wants "YYYY-MM-DDTHH:MM:SS.SSS" (3-digit ms).
  function parseSqliteTs(ts) {
    if (!ts) return null;
    if (ts instanceof Date) return ts;
    if (typeof ts === 'number') return new Date(ts * 1000);
    const m = String(ts).match(/^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(\.\d{1,6})?(Z|[+-]\d{2}:?\d{2})?$/);
    if (!m) return null;
    const ms = m[3] ? m[3].slice(0, 4) : ''; // .xxx (truncate microseconds)
    const tz = m[4] || '';
    const d = new Date(`${m[1]}T${m[2]}${ms}${tz}`);
    return isNaN(d.getTime()) ? null : d;
  }

  function fmtTs(ts) {
    if (ts == null || ts === '') return '';
    if (typeof ts === 'number' || /^\d+$/.test(ts)) {
      const d = new Date(Number(ts) * 1000);
      return isNaN(d.getTime()) ? String(ts) : d.toLocaleString();
    }
    const d = parseSqliteTs(ts);
    return d ? d.toLocaleString() : String(ts);
  }

  // Strip ANSI color escape codes from subprocess output.
  function stripAnsi(s) {
    // eslint-disable-next-line no-control-regex
    return String(s).replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '');
  }

  const EVENT_TYPE_CLASS = {
    failover: 'badge-failover',
    failback: 'badge-failback',
    test:     'badge-test',
  };
  function eventBadge(type) {
    const t = String(type || 'other');
    const cls = EVENT_TYPE_CLASS[t] || 'badge-other';
    return `<span class="badge ${cls}">${escapeHtml(t)}</span>`;
  }

  // === /api/config — render JSON into the table body =====================

  window.renderConfigForm = function (event) {
    if (event.detail.failed || !event.detail.xhr) return;
    const body = document.getElementById('config-body');
    let payload;
    try { payload = JSON.parse(event.detail.xhr.responseText); } catch (e) { return; }
    if (!payload || !payload.fields) return;

    const rows = [];
    for (const [key, spec] of Object.entries(payload.fields)) {
      const helpText = escapeHtml(spec.help || '');
      const k = escapeHtml(key);
      const cur = spec.current === null
        ? '<em class="muted">unset</em>'
        : escapeHtml(spec.current);
      rows.push(`
        <tr>
          <td><code>${k}</code><div class="muted">${helpText}</div></td>
          <td>${cur}</td>
          <td><input type="number" data-key="${k}" min="${Number(spec.min)}" max="${Number(spec.max)}" aria-label="New value for ${k}" /></td>
          <td><span class="muted">[${Number(spec.min)}, ${Number(spec.max)}]</span></td>
        </tr>
      `);
    }
    rows.push(`
      <tr><td colspan="4">
        <button id="config-apply" class="btn-warn" aria-label="Apply pending configuration changes">Apply non-empty changes</button>
        <span id="config-result" class="muted"></span>
      </td></tr>
    `);
    body.innerHTML = rows.join('');

    document.getElementById('config-apply').addEventListener('click', async () => {
      const inputs = body.querySelectorAll('input[data-key]');
      const changes = {};
      let hasInvalid = false;
      inputs.forEach((el) => {
        if (el.value === '') return;
        // Inline validation: visualise out-of-range values
        if (!el.checkValidity()) {
          el.classList.add('invalid');
          hasInvalid = true;
          return;
        }
        el.classList.remove('invalid');
        changes[el.dataset.key] = Number(el.value);
      });
      const result = document.getElementById('config-result');
      if (hasInvalid) { result.textContent = 'Some values are out of range. Fix highlighted fields.'; return; }
      if (!Object.keys(changes).length) { result.textContent = 'No changes entered.'; return; }
      if (!confirm('Apply ' + Object.keys(changes).length + ' config change(s) and restart failover-monitor?')) return;
      const resp = await fetch('/api/config', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': getCsrfCookie() },
        body: JSON.stringify(changes),
      });
      const text = await resp.text();
      result.textContent = `[${resp.status}] ${text}`;
    });
  };

  // === /api/history — render JSON into the table body ====================

  window.renderHistory = function (event) {
    if (event.detail.failed || !event.detail.xhr) return;
    const body = document.getElementById('history-body');
    let payload;
    try { payload = JSON.parse(event.detail.xhr.responseText); } catch (e) { return; }
    if (!payload || !payload.events) return;
    if (!payload.events.length) {
      body.innerHTML = '<tr><td colspan="5" class="muted">No events.</td></tr>';
      return;
    }
    const rows = payload.events.slice(0, 100).map((ev) => {
      const reason = ev.reason || '';
      // Failover Event-ID (Correlation-ID): reconstruct this failover across all
      // services. The title is a copy-ready grep command (logs live in files).
      const eid = ev.event_id || '';
      const traceCell = eid
        ? `<td class="trace"><code title="grep FAILOVER_EVENT_ID=${escapeHtml(eid)} /var/log/linux-dual-wan-failover/*.log">${escapeHtml(eid)}</code></td>`
        : '<td class="trace muted">–</td>';
      return `
        <tr>
          <td><time datetime="${escapeHtml(ev.timestamp || '')}">${escapeHtml(fmtTs(ev.timestamp))}</time></td>
          <td>${eventBadge(ev.event_type)}</td>
          <td>${escapeHtml(ev.from_interface || '–')} → ${escapeHtml(ev.to_interface || '–')}</td>
          <td class="reason" title="${escapeHtml(reason)}"><code>${escapeHtml(reason)}</code></td>
          ${traceCell}
        </tr>
      `;
    });
    body.innerHTML = rows.join('');
  };

  // === Action-result colouring ===========================================
  // After any POST that targets #action-result, colour the pane by status.

  document.addEventListener('htmx:afterRequest', (event) => {
    const target = event.detail && event.detail.target;
    if (!target || target.id !== 'action-result') return;
    const status = event.detail.xhr ? event.detail.xhr.status : 0;
    target.classList.remove('ok', 'error');
    if (status === 0) return;
    target.classList.add(status >= 400 ? 'error' : 'ok');
  });

  // === Diagnostics — POST + read SSE-style chunks via fetch+ReadableStream

  document.addEventListener('DOMContentLoaded', () => {
    const runBtn = document.getElementById('diag-run');
    if (!runBtn) return;
    const out = document.getElementById('diag-output');
    runBtn.addEventListener('click', async () => {
      const tool = document.getElementById('diag-tool').value;
      const target = document.getElementById('diag-target').value.trim();
      const iface = document.getElementById('diag-iface').value;
      const count = document.getElementById('diag-count').value;
      if (!target) { out.textContent = 'Target required.'; return; }

      out.textContent = `> ${tool} ${target} (${iface || 'default'} x${count})\n`;
      runBtn.disabled = true;

      try {
        const resp = await fetch(`/api/diag/${encodeURIComponent(tool)}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': getCsrfCookie() },
          body: JSON.stringify({ target, iface, count: Number(count) }),
        });
        if (!resp.ok || !resp.body) {
          out.textContent += `[error] HTTP ${resp.status}\n`;
          return;
        }
        const reader = resp.body.getReader();
        const decoder = new TextDecoder();
        let buf = '';
        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          buf += decoder.decode(value, { stream: true });
          let idx;
          while ((idx = buf.indexOf('\n\n')) !== -1) {
            const block = buf.slice(0, idx);
            buf = buf.slice(idx + 2);
            const lines = block.split('\n');
            for (const ln of lines) {
              if (ln.startsWith('data: '))            out.textContent += stripAnsi(ln.slice(6)) + '\n';
              else if (ln.startsWith('event: end'))       out.textContent += '[end]\n';
              else if (ln.startsWith('event: error'))     out.textContent += '[ERROR]\n';
              else if (ln.startsWith('event: truncated')) out.textContent += '[truncated]\n';
            }
            out.scrollTop = out.scrollHeight;
          }
        }
      } catch (e) {
        out.textContent += `[exception] ${e}\n`;
      } finally {
        runBtn.disabled = false;
      }
    });
  });
})();

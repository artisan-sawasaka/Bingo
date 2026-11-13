/* Bingo Drum 3D — phone / iPad remote.
 * Protocol: docs/protocol.md (WebSocket JSON on ws://<host>/ws).
 * Operations: pull the lever (draw), switch the TV to the number-history
 * screen and back, open the max-number screen and reset (new game).
 * The lever only produces "pull completed"; sending is done by requestSpin(),
 * so an alternative 1-tap button can reuse it later.
 */
'use strict';

/* ------------------------------------------------------------------ pure lever math */
const LeverMath = {
  ARM_RAW: 0.85,      // finger travel (fraction of track) needed to arm
  DISARM_RAW: 0.75,   // hysteresis: move back above this to disarm
  LAG: 0.18,          // spring resistance before the detent
  // Maps raw finger travel (0 = top, 1 = full track) to knob position (0..~1.04).
  position(raw, armed) {
    if (raw <= 0) return Math.max(-0.05, raw * 0.15);
    if (armed) {
      const over = Math.max(0, raw - 1);
      return 1 + Math.min(0.04, over * 0.12); // rubber band past the end
    }
    const r = Math.min(raw, 1.2);
    return Math.min(0.92, r * (1 - LeverMath.LAG * r));
  },
  nextArmed(raw, armed) {
    if (armed) return raw >= LeverMath.DISARM_RAW;
    return raw >= LeverMath.ARM_RAW;
  },
  // Critically-damped spring step toward target. Returns [pos, vel].
  spring(pos, vel, target, dt, stiffness = 260) {
    const damping = 2 * Math.sqrt(stiffness);
    const acc = stiffness * (target - pos) - damping * vel;
    vel += acc * dt;
    pos += vel * dt;
    return [pos, vel];
  },
};

/* ------------------------------------------------------------------ protocol helpers */
const Protocol = {
  newId() {
    const b = new Uint8Array(12);
    (self.crypto || window.crypto).getRandomValues(b);
    return Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
  },
  tokenFromHash(hash) {
    const m = /(?:^#|&)k=([A-Za-z0-9_-]{16,64})(?:&|$)/.exec(hash || '');
    return m ? m[1] : '';
  },
  isToken(t) { return typeof t === 'string' && /^[A-Za-z0-9_-]{16,64}$/.test(t); },
  // Address that carries the connection code. "Add to Home Screen" bookmarks
  // the CURRENT address, and the home-screen app starts with its own empty
  // storage (iOS), so the code has to stay in the address at all times.
  urlWithToken(pathname, search, token) {
    return `${pathname || '/'}${search || ''}${Protocol.isToken(token) ? `#k=${token}` : ''}`;
  },
  // Same rules as GameState.validate_max_number_text on the PC (PC validates again).
  validateMax(text, min = 1, max = 999) {
    const t = String(text == null ? '' : text).trim();
    if (!t) return { ok: false, value: 0, error: '最大番号を入力してください' };
    if (!/^[0-9]{1,6}$/.test(t)) return { ok: false, value: 0, error: `${min}〜${max} の整数を入力してください` };
    const v = parseInt(t, 10);
    if (v < min || v > max) return { ok: false, value: v, error: `${min}〜${max} の範囲で入力してください` };
    return { ok: true, value: v, error: '' };
  },
  // On-screen keypad: digit / 'C' (clear) / 'B' (backspace). `fresh` = the next
  // digit replaces the shown value (right after opening, a preset or −/＋).
  keypad(value, key, fresh, maxLen = 3) {
    const cur = String(value == null ? '' : value);
    if (key === 'C') return '';
    if (key === 'B') return cur.slice(0, -1);
    if (!/^[0-9]$/.test(key)) return cur;
    let next = (fresh ? '' : cur) + key;
    next = next.replace(/^0+(?=[0-9])/, '');
    return next.length > maxLen ? cur : next;
  },
  // Opened from a home-screen icon (no browser bars). Deliberately ignores
  // `display-mode: fullscreen`, which is also true during Fullscreen API use.
  isStandaloneLaunch(nav, matches) {
    if (nav && nav.standalone === true) return true;
    return !!(matches && matches('(display-mode: standalone)'));
  },
  digitsOnly(text, maxLen = 3) {
    return String(text || '').replace(/[０-９]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xFEE0)).replace(/[^0-9]/g, '').slice(0, maxLen);
  },
};

if (typeof module === 'object' && module.exports) {
  module.exports = { LeverMath, Protocol };
} else {
  main();
}

function main() {
  const $ = (id) => document.getElementById(id);
  const app = $('app');
  const lever = $('lever');
  const knob = $('knob');
  const fill = $('fill');
  const connPill = $('connPill');
  const counts = $('counts');
  const lastNumberEl = $('lastNumber');
  const recentEl = $('recent');
  const hintEl = $('leverHint');
  const messageEl = $('message');
  const overlay = $('overlay');
  const overlayTitle = $('overlayTitle');
  const overlayBody = $('overlayBody');
  const overlayBtn = $('overlayBtn');
  const overlayBtn2 = $('overlayBtn2');
  const soundBtn = $('soundBtn');
  const fsBtn = $('fsBtn');
  const fsLabel = $('fsLabel');
  const historyBtn = $('historyBtn');
  const historyLabel = $('historyLabel');
  const setupBtn = $('setupBtn');
  const sheetEl = $('sheet');
  const sheetTitle = $('sheetTitle');
  const sheetInfo = $('sheetInfo');
  const sheetRange = $('sheetRange');
  const sheetError = $('sheetError');
  const maxInput = $('maxInput');
  const stepEdit = $('stepEdit');
  const stepConfirm = $('stepConfirm');
  const confirmText = $('confirmText');
  const sheetCancel = $('sheetCancel');
  const sheetStart = $('sheetStart');
  const confirmNo = $('confirmNo');
  const confirmYes = $('confirmYes');
  const thresholdMark = document.querySelector('.mark-threshold');

  const TOKEN_KEY = 'bingoRemote.token';
  const CLIENT_KEY = 'bingoRemote.clientId';
  const SOUND_KEY = 'bingoRemote.sound';
  const PING_MS = 4000;
  const STALE_MS = 11000;
  const PENDING_TIMEOUT_MS = 4000;

  const memory = {};
  const store = {
    get(k) { try { return localStorage.getItem(k) || sessionStorage.getItem(k) || ''; } catch (_) { return memory[k] || ''; } },
    set(k, v) { memory[k] = v; try { localStorage.setItem(k, v); } catch (_) { try { sessionStorage.setItem(k, v); } catch (_) { /* memory only */ } } },
  };

  /* ---------- token: from #k=… (QR / home-screen icon), else from storage ---------- */
  // The code is deliberately KEPT in the address (it used to be removed):
  // "Add to Home Screen" saves the current address, and the home-screen app
  // has its own empty storage, so an icon made from a code-less address could
  // never connect ("QRコードから開いてください"). A fragment is never sent over HTTP.
  let token = Protocol.tokenFromHash(location.hash);
  if (token) store.set(TOKEN_KEY, token); else token = store.get(TOKEN_KEY);
  if (!Protocol.isToken(token)) token = '';
  function keepTokenInUrl() {
    if (!token || Protocol.tokenFromHash(location.hash) === token) return;
    try { history.replaceState(null, '', Protocol.urlWithToken(location.pathname, location.search, token)); } catch (_) { /* ignore */ }
  }
  keepTokenInUrl();
  let clientId = store.get(CLIENT_KEY);
  if (!/^[A-Za-z0-9_-]{4,64}$/.test(clientId)) { clientId = Protocol.newId(); store.set(CLIENT_KEY, clientId); }
  let soundOn = store.get(SOUND_KEY) !== 'off';

  /* ---------- state ---------- */
  let ws = null;
  let conn = token ? 'connecting' : 'no_token';  // connecting | open | closed | auth_failed | no_token
  let server = null;          // last state snapshot
  let lastRx = 0;
  let pingTimer = 0;
  let reconnectTimer = 0;
  let backoff = 500;
  let pending = null;         // spin { id, at }
  let awaitingReveal = false; // our spin accepted, waiting for animation_finished
  let screenPending = false;  // show_screen sent, waiting for the result
  let messageTimer = 0;
  // max-number sheet
  // fresh: the next keypad digit replaces the shown value instead of appending
  const sheet = { open: false, step: 'edit', waitScreenUntil: 0, newGame: null, draftTimer: 0, fresh: true, confirmValue: 0 };

  /* ================================================================ WebSocket */
  function connect() {
    clearTimeout(reconnectTimer);
    if (!token) { setConn('no_token'); return; }
    if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;
    setConn('connecting');
    let sock;
    try {
      sock = new WebSocket(`ws://${location.host}/ws`);
    } catch (e) {
      scheduleReconnect();
      return;
    }
    ws = sock;
    sock.onopen = () => {
      lastRx = Date.now();
      sock.send(JSON.stringify({ type: 'hello', v: 1, token, client_id: clientId }));
    };
    sock.onmessage = (ev) => {
      if (sock !== ws) return;
      lastRx = Date.now();
      let msg;
      try { msg = JSON.parse(ev.data); } catch (_) { return; }
      if (msg && typeof msg.type === 'string') handleMessage(msg);
    };
    sock.onclose = (ev) => {
      if (sock !== ws) return;
      ws = null;
      stopPing();
      if (ev && ev.code === 4001 && conn !== 'auth_failed') setConn('auth_failed');
      if (conn === 'auth_failed') return;
      setConn('closed');
      scheduleReconnect();
    };
    sock.onerror = () => { /* onclose follows */ };
  }

  function scheduleReconnect() {
    clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(connect, backoff);
    backoff = Math.min(backoff * 2, 5000);
  }

  function forceReconnect() {
    if (ws) { const old = ws; ws = null; try { old.close(); } catch (_) { /* ignore */ } }
    stopPing();
    backoff = 500;
    if (conn !== 'auth_failed' && conn !== 'no_token') connect();
  }

  function send(obj) {
    if (ws && ws.readyState === WebSocket.OPEN) { ws.send(JSON.stringify(obj)); return true; }
    return false;
  }

  function startPing() {
    stopPing();
    pingTimer = setInterval(() => {
      if (Date.now() - lastRx > STALE_MS) { forceReconnect(); return; }
      send({ type: 'ping', t: Date.now() });
    }, PING_MS);
  }
  function stopPing() { clearInterval(pingTimer); pingTimer = 0; }

  function handleMessage(msg) {
    switch (msg.type) {
      case 'welcome':
        backoff = 500;
        setConn('open');
        startPing();
        applyState(msg.state);
        // Re-send unanswered requests (same id ⇒ the PC never applies them twice).
        if (pending && Date.now() - pending.at < PENDING_TIMEOUT_MS) {
          send({ type: 'spin_request', request_id: pending.id });
        } else if (pending) {
          pending = null;
          flash('送信できませんでした。もう一度引いてください');
        }
        if (sheet.newGame && Date.now() - sheet.newGame.at < 6000) {
          send({ type: 'new_game', request_id: sheet.newGame.id, max_number: sheet.newGame.value });
        }
        break;
      case 'state_snapshot':
        applyState(msg.state);
        break;
      case 'spin_accepted':
        if (pending && msg.request_id === pending.id) {
          pending = null;
          awaitingReveal = true;
          if (!msg.duplicate) clickSound(220, 0.06);
        }
        // A duplicate of a draw that already finished (re-sent after a reconnect)
        // gets no animation_finished: the attached state clears the wait.
        if (msg.state) applyState(msg.state); else render();
        break;
      case 'spin_rejected':
        if (pending && (msg.request_id === pending.id || !msg.request_id)) {
          pending = null;
          flash(msg.message || '抽選できませんでした');
        }
        if (msg.state) applyState(msg.state); else render();
        break;
      case 'spin_started':
        render();
        break;
      case 'animation_finished':
        awaitingReveal = false;
        applyState(msg.state);
        break;
      case 'command_result':
        screenPending = false;
        if (!msg.ok) {
          flash(msg.message || '操作できませんでした');
          if (msg.screen === 'setup' && sheet.open) closeSheet(false);
        }
        render();
        break;
      case 'new_game_result':
        if (sheet.newGame && msg.request_id === sheet.newGame.id) {
          const v = sheet.newGame.value;
          sheet.newGame = null;
          if (msg.ok) {
            closeSheet(false);
            flash(`最大 ${v} で新しいゲームを開始しました`);
          } else {
            setSheetStep('edit');
            sheetError.textContent = msg.message || '開始できませんでした';
          }
          renderSheet();
        }
        break;
      case 'auth_failed':
        setConn('auth_failed', msg.message);
        break;
      default:
        break;
    }
  }

  function applyState(s) {
    if (s && typeof s === 'object') server = s;
    if (server && server.phase !== 'spinning') awaitingReveal = false;
    syncSheet();
    render();
  }

  function setConn(c, detail) {
    conn = c;
    if (c !== 'open') { if (!pending) awaitingReveal = false; screenPending = false; }
    if (c === 'auth_failed' || c === 'no_token') {
      // A home-screen icon cannot pick up a new code by itself: scanning the QR
      // opens the browser, not this app, so the icon has to be made again.
      const how = launchedStandalone
        ? 'このホーム画面のアイコンは' + (c === 'auth_failed' ? '古い接続コードのままです' : '接続コードが入っていません') + '。\nアイコンを削除し、PC（テレビ）の接続画面（Qキー）のQRコードをカメラで読み取ってブラウザで開いてから、もう一度「ホーム画面に追加」してください。'
        : 'PC（テレビ）の接続画面（Qキー）に表示されているQRコードを、カメラで読み取ってください。';
      showOverlay(c === 'auth_failed' ? '接続できません' : 'QRコードから開いてください',
        (detail ? detail + '\n' : '') + how, null);
    } else if (overlayKind === 'conn') {
      hideOverlay();
    }
    render();
  }

  /* ================================================================ Spin request */
  // Separated from the lever so a 1-tap button can call it in the future.
  function requestSpin() {
    if (!canSpin()) return false;
    pending = { id: Protocol.newId(), at: Date.now() };
    if (!send({ type: 'spin_request', request_id: pending.id })) {
      forceReconnect(); // kept pending briefly; re-sent on reconnect
    }
    setTimeout(() => {
      if (pending && Date.now() - pending.at >= PENDING_TIMEOUT_MS) {
        pending = null;
        flash('PCから応答がありません');
        render();
      }
    }, PENDING_TIMEOUT_MS + 50);
    render();
    return true;
  }

  function canSpin() {
    return conn === 'open' && server && server.can_spin && server.phase === 'ready' && !pending && !awaitingReveal && !sheet.open;
  }

  /* ================================================================ TV screen switching */
  function canSwitchScreens() {
    return conn === 'open' && server && server.phase !== 'spinning' && !pending && !awaitingReveal && !screenPending;
  }

  historyBtn.addEventListener('click', () => {
    unlockAudio();
    if (!canSwitchScreens() || !server || server.phase === 'setup') return;
    const target = server.screen === 'history' ? 'main' : 'history';
    if (send({ type: 'show_screen', screen: target })) { screenPending = true; clickSound(520, 0.04); }
    render();
  });

  setupBtn.addEventListener('click', () => {
    unlockAudio();
    if (!canSwitchScreens()) return;
    openSheet(false);
  });

  /* ================================================================ Max number / reset sheet */
  function hasGame() { return server && server.phase !== 'setup' && server.max_number > 0; }

  function openSheet(fromServer) {
    if (sheet.open) return;
    sheet.open = true;
    sheet.newGame = null;
    sheet.fresh = true;
    setSheetStep('edit');
    maxInput.value = String((server && server.default_max) || 75);
    sheetError.textContent = '';
    sheetEl.hidden = false;
    if (!fromServer) {
      sheet.waitScreenUntil = Date.now() + 2500;
      send({ type: 'show_screen', screen: 'setup' });
    }
    renderSheet();
    render();
  }

  function closeSheet(tellPc) {
    if (!sheet.open) return;
    sheet.open = false;
    sheet.newGame = null;
    sheetEl.hidden = true;
    try { maxInput.blur(); } catch (_) { /* ignore */ }
    if (tellPc && hasGame()) send({ type: 'show_screen', screen: 'main' });
    render();
  }

  // Keep the sheet consistent with the TV: it opens by itself while no game
  // exists, and closes when the PC leaves the max-number screen.
  function syncSheet() {
    if (!server || conn !== 'open') return;
    if (server.phase === 'setup' && !sheet.open) { openSheet(true); return; }
    if (!sheet.open || sheet.newGame) { renderSheet(); return; }
    if (server.screen === 'setup') { sheet.waitScreenUntil = 0; renderSheet(); return; }
    if (Date.now() < sheet.waitScreenUntil) return; // our show_screen is in flight
    closeSheet(false);
  }

  function setSheetStep(step) {
    sheet.step = step;
    if (step !== 'confirm') sheet.confirmValue = 0;
    stepEdit.hidden = step !== 'edit';
    stepConfirm.hidden = step !== 'confirm';
  }

  function sheetLimits() {
    return { min: (server && server.min_max) || 1, max: (server && server.max_max) || 999 };
  }

  function renderSheet() {
    if (!sheet.open) return;
    const g = hasGame();
    const { min, max } = sheetLimits();
    sheetTitle.textContent = g ? '最大番号の設定・リセット' : '最大番号を決めてゲーム開始';
    sheetInfo.textContent = g
      ? `現在のゲーム：最大 ${server.max_number}・${server.drawn_count}球抽選済み（開始するとリセット）`
      : '紙のビンゴカードは通常 1〜75 です';
    sheetRange.textContent = `${min}〜${max}`;
    sheetCancel.hidden = !g;
    sheetStart.textContent = g ? 'この番号でリセット…' : 'ゲーム開始';
    const busy = !!sheet.newGame || conn !== 'open';
    sheetStart.disabled = busy;
    confirmYes.disabled = busy;
    confirmYes.textContent = sheet.newGame ? '送信中…' : 'リセットして開始';
  }

  function sendDraft() {
    clearTimeout(sheet.draftTimer);
    sheet.draftTimer = setTimeout(() => send({ type: 'setup_draft', max_number: maxInput.value }), 120);
  }

  // The value can only change in the edit step (the confirmation shows a frozen value).
  const editable = () => sheet.open && sheet.step === 'edit' && !sheet.newGame;
  for (const b of document.querySelectorAll('.step-btn')) {
    b.addEventListener('click', () => {
      if (!editable()) return;
      const { min, max } = sheetLimits();
      const cur = parseInt(maxInput.value, 10) || 0;
      maxInput.value = String(Math.min(max, Math.max(min, cur + Number(b.dataset.step))));
      sheet.fresh = true;
      sheetError.textContent = '';
      sendDraft();
    });
  }
  for (const b of document.querySelectorAll('.preset')) {
    b.addEventListener('click', () => {
      if (!editable()) return;
      maxInput.value = b.dataset.v; sheet.fresh = true; sheetError.textContent = ''; sendDraft();
    });
  }
  // On-screen keypad (no system keyboard: it would cover the sheet in landscape
  // and can drop iPad Safari out of fullscreen).
  for (const b of document.querySelectorAll('.key')) {
    b.addEventListener('click', () => {
      if (!editable()) return;
      maxInput.value = Protocol.keypad(maxInput.value, b.dataset.k, sheet.fresh);
      sheet.fresh = false;
      sheetError.textContent = '';
      sendDraft();
    });
  }
  sheetCancel.addEventListener('click', () => closeSheet(true));
  sheetStart.addEventListener('click', () => {
    if (!editable()) return;
    const { min, max } = sheetLimits();
    const v = Protocol.validateMax(maxInput.value, min, max);
    if (!v.ok) { sheetError.textContent = v.error; return; }
    if (!hasGame()) { submitNewGame(v.value); return; }
    setSheetStep('confirm');
    sheet.confirmValue = v.value; // exactly what the confirmation text shows
    confirmText.textContent = `最大 ${v.value} で新しいゲームを始めます。\n現在のゲーム（${server.drawn_count}球抽選済み）はリセットされます。`;
    try { maxInput.blur(); } catch (_) { /* ignore */ }
    renderSheet();
  });
  confirmNo.addEventListener('click', () => { setSheetStep('edit'); renderSheet(); });
  confirmYes.addEventListener('click', () => {
    if (sheet.step === 'confirm' && sheet.confirmValue > 0) submitNewGame(sheet.confirmValue);
  });

  function submitNewGame(value) {
    if (sheet.newGame) return;
    sheet.newGame = { id: Protocol.newId(), at: Date.now(), value };
    if (!send({ type: 'new_game', request_id: sheet.newGame.id, max_number: value })) forceReconnect();
    setTimeout(() => {
      if (sheet.newGame && Date.now() - sheet.newGame.at >= 6000) {
        sheet.newGame = null;
        setSheetStep('edit');
        sheetError.textContent = 'PCから応答がありません。もう一度お試しください';
        renderSheet();
      }
    }, 6100);
    renderSheet();
  }

  /* ================================================================ Lever */
  let pos = 0, vel = 0;          // knob position 0..1 (fraction of travel)
  let dragging = null;           // { id, startY, armed }
  let mode = 'idle';             // idle | drag | return | fired
  let firedUntil = 0;
  let releasedAt = 0;
  let lastFrame = 0;
  let travel = 1;

  function measure() {
    const h = lever.clientHeight;
    const k = knob.offsetHeight || 96;
    travel = Math.max(80, h - k);
    const markY = k / 2 + travel * LeverMath.position(LeverMath.ARM_RAW, false);
    thresholdMark.style.top = `${markY}px`;
    paintLever();
  }

  function paintLever() {
    const y = pos * travel;
    knob.style.transform = `translate3d(0, ${y.toFixed(1)}px, 0)`;
    fill.style.height = `${Math.max(0, y).toFixed(1)}px`;
    lever.setAttribute('aria-valuenow', String(Math.round(Math.max(0, Math.min(1, pos)) * 100)));
  }

  function setLeverAttr(v) { if (app.dataset.lever !== v) app.dataset.lever = v; }

  function onPointerDown(e) {
    if (dragging) return;
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    e.preventDefault();
    unlockAudio();
    settleIfStuck();
    if (!canSpin() || mode === 'fired') {
      lever.classList.remove('shake'); void lever.offsetWidth; lever.classList.add('shake');
      vibrate(30);
      if (conn !== 'open') flash('PCと接続されていません');
      else if (server && server.screen === 'setup') flash('最大数の設定中は抽選できません');
      return;
    }
    dragging = { id: e.pointerId, startY: e.clientY - pos * travel, armed: false };
    mode = 'drag';
    try { lever.setPointerCapture(e.pointerId); } catch (_) { /* ignore */ }
    kick();
  }

  function onPointerMove(e) {
    if (!dragging || e.pointerId !== dragging.id) return;
    e.preventDefault();
    const raw = (e.clientY - dragging.startY) / travel;
    const armed = LeverMath.nextArmed(raw, dragging.armed);
    if (armed !== dragging.armed) {
      dragging.armed = armed;
      if (armed) { vibrate(15); clickSound(660, 0.04); }
    }
    pos = LeverMath.position(raw, armed);
    vel = 0;
    setLeverAttr(armed ? 'armed' : 'drag');
    hintEl.textContent = armed ? '離すと抽選！' : 'もっと下へ';
    paintLever();
  }

  function endDrag(e, cancelled) {
    if (!dragging || (e && e.pointerId !== dragging.id)) return;
    const fire = dragging.armed && !cancelled && canSpin();
    try { lever.releasePointerCapture(dragging.id); } catch (_) { /* ignore */ }
    dragging = null;
    releasedAt = performance.now();
    if (fire) {
      mode = 'fired';
      firedUntil = performance.now() + 160;
      pos = 1; vel = 0;
      vibrate([10, 40, 20]);
      clickSound(330, 0.08);
      requestSpin();
    } else {
      mode = 'return';
    }
    setLeverAttr(fire ? 'fired' : 'idle');
    render();
    kick();
  }

  function frame(t) {
    const dt = Math.min(0.05, lastFrame ? (t - lastFrame) / 1000 : 0.016);
    lastFrame = t;
    let active = false;
    if (mode === 'return' || (mode === 'fired' && t >= firedUntil)) {
      const stiff = mode === 'fired' ? 90 : 260; // fired lever returns slowly
      [pos, vel] = LeverMath.spring(pos, vel, 0, dt, stiff);
      if (Math.abs(pos) < 0.002 && Math.abs(vel) < 0.01) {
        pos = 0; vel = 0;
        mode = 'idle';
        setLeverAttr('idle');
        render();
      } else active = true;
      paintLever();
    } else if (mode === 'fired' || mode === 'drag') {
      active = mode === 'fired';
    }
    if (active) requestAnimationFrame(frame); else lastFrame = 0;
  }
  function kick() { lastFrame = 0; requestAnimationFrame(frame); }

  // rAF pauses while the page is hidden/not painted; never let the lever stay
  // stuck in the "fired" pose because of that.
  function settleIfStuck() {
    if ((mode === 'fired' || mode === 'return') && !dragging && performance.now() - releasedAt > 1500) {
      pos = 0; vel = 0; mode = 'idle';
      setLeverAttr('idle');
      paintLever();
    }
  }

  lever.addEventListener('pointerdown', onPointerDown);
  lever.addEventListener('pointermove', onPointerMove);
  lever.addEventListener('pointerup', (e) => endDrag(e, false));
  lever.addEventListener('pointercancel', (e) => endDrag(e, true));
  lever.addEventListener('lostpointercapture', (e) => endDrag(e, true));
  // iPad Safari fullscreen: a downward swipe is the system "exit fullscreen"
  // gesture, and WebKit decides whether native gestures may run at touchstart.
  // Cancelling touchstart (everywhere except real controls) keeps the lever
  // pull from closing fullscreen. Pointer events still fire for the lever.
  document.addEventListener('touchstart', (e) => {
    const t = e.target;
    if (t && t.closest && t.closest('button, input, a, .sheet-card, .overlay-card')) return;
    e.preventDefault();
  }, { passive: false });
  // Belt and braces against page scroll / zoom gestures on iOS.
  document.addEventListener('touchmove', (e) => {
    // The reset sheet may scroll on very short screens; everything else is fixed.
    if (e.target && e.target.closest && e.target.closest('.sheet-card')) return;
    e.preventDefault();
  }, { passive: false });
  document.addEventListener('gesturestart', (e) => e.preventDefault());
  document.addEventListener('dblclick', (e) => e.preventDefault());
  document.addEventListener('contextmenu', (e) => e.preventDefault());

  /* ================================================================ Rendering */
  function render() {
    settleIfStuck();
    app.dataset.conn = conn;
    app.dataset.phase = server ? server.phase : 'setup';
    app.dataset.screen = server ? (server.screen || 'main') : 'main';
    const ok = canSpin();
    app.classList.toggle('disabled', !ok && mode !== 'drag');

    let pill = '';
    let hint = '';
    if (conn === 'connecting') { pill = '接続中…'; hint = 'PCに接続しています'; }
    else if (conn === 'closed') { pill = '切断 — 再接続中'; hint = 'Wi-Fiを確認してください'; }
    else if (conn === 'auth_failed') { pill = '認証エラー'; hint = 'QRコードを読み取り直してください'; }
    else if (conn === 'no_token') { pill = '未接続'; hint = 'QRコードから開いてください'; }
    else if (!server) { pill = '接続済み'; }
    else if (pending) { pill = '送信中…'; hint = '送信中…'; }
    else if (server.phase === 'spinning' || awaitingReveal) { pill = '抽選中'; hint = '抽選中… テレビを見てください'; }
    else if (server.phase === 'setup') { pill = '準備中'; hint = '最大番号を決めてください'; }
    else if (server.screen === 'setup' || sheet.open) { pill = '最大数の設定中'; hint = '設定中は抽選できません'; }
    else if (server.phase === 'finished') { pill = '終了'; hint = '全ての番号が出ました'; }
    else if (server.paused) { pill = '一時停止'; hint = 'PC側で設定画面を表示中'; }
    else if (ok) { pill = '抽選できます'; hint = 'レバーを下まで引いて離す'; }
    else { pill = '待機中'; hint = 'お待ちください'; }
    connPill.textContent = pill;
    if (!dragging) hintEl.textContent = hint;

    if (server && server.max_number > 0) {
      counts.textContent = `${server.drawn_count}球目 / 残り ${server.remaining}`;
      lastNumberEl.textContent = server.last_number == null ? '—' : String(server.last_number);
      const rest = (server.recent || []).slice(1, 5);
      recentEl.replaceChildren(...rest.map((n) => { const s = document.createElement('span'); s.textContent = String(n); return s; }));
    } else {
      counts.textContent = '— / —';
      lastNumberEl.textContent = '—';
      recentEl.replaceChildren();
    }

    const sw = canSwitchScreens();
    const onHistory = !!(server && server.screen === 'history');
    historyBtn.disabled = !sw || !server || server.phase === 'setup';
    historyBtn.classList.toggle('active', onHistory);
    historyLabel.textContent = onHistory ? 'メイン画面に戻す' : '番号一覧を表示';
    setupBtn.disabled = !sw;
    setupBtn.classList.toggle('active', !!(server && server.screen === 'setup'));
    renderSheet();
  }

  function flash(text) {
    messageEl.textContent = text;
    clearTimeout(messageTimer);
    messageTimer = setTimeout(() => { messageEl.textContent = ''; }, 3500);
  }

  // btn / btn2: { label, onClick } or null. kind 'conn' overlays are cleared by reconnects.
  // Button handlers run inside the tap, so they may (re)enter fullscreen.
  let overlayKind = '';
  let overlayAction = null;
  let overlayAction2 = null;
  function showOverlay(title, body, btn, kind = 'conn', btn2 = null) {
    overlayKind = kind;
    overlayTitle.textContent = title;
    if (body instanceof Node) overlayBody.replaceChildren(body); else overlayBody.textContent = body;
    overlayAction = btn ? btn.onClick : null;
    overlayBtn.textContent = btn ? btn.label : '';
    overlayBtn.hidden = !btn;
    overlayAction2 = btn2 ? btn2.onClick : null;
    overlayBtn2.textContent = btn2 ? btn2.label : '';
    overlayBtn2.hidden = !btn2;
    overlay.hidden = false;
  }
  function hideOverlay() { overlay.hidden = true; overlayKind = ''; overlayAction = null; overlayAction2 = null; }
  overlayBtn.addEventListener('click', () => { const a = overlayAction; hideOverlay(); if (a) a(); });
  overlayBtn2.addEventListener('click', () => { const a = overlayAction2; hideOverlay(); if (a) a(); });

  /* ================================================================ Fullscreen (hide Safari's tabs / address bar) */
  // Home-screen launch is decided ONCE at startup and only from standalone
  // signals: `display-mode: fullscreen` also matches while the Fullscreen API
  // is active, which must not hide the button that exits it.
  const launchedStandalone = Protocol.isStandaloneLaunch(navigator, window.matchMedia ? (q) => matchMedia(q).matches : null);
  const fsSupported = () => !!(document.fullscreenEnabled || document.webkitFullscreenEnabled);
  const fsActive = () => !!(document.fullscreenElement || document.webkitFullscreenElement);

  function enterFullscreen() {
    const el = document.documentElement;
    try {
      const r = el.requestFullscreen ? el.requestFullscreen({ navigationUI: 'hide' }) : el.webkitRequestFullscreen();
      if (r && typeof r.catch === 'function') r.catch(() => showHomeScreenHelp());
    } catch (_) { showHomeScreenHelp(); }
  }
  function exitFullscreen() {
    try { (document.exitFullscreen || document.webkitExitFullscreen).call(document); } catch (_) { /* ignore */ }
  }

  // iPhone Safari has no page fullscreen: the "Add to Home Screen" icon opens
  // without Safari's bars. The home-screen app has its own storage, so the
  // connection code must be in the address the icon is made from.
  function showHomeScreenHelp(intro) {
    keepTokenInUrl();
    const box = document.createElement('div');
    const p = document.createElement('p');
    p.textContent = intro || 'このブラウザは全画面表示に対応していません。ホーム画面に追加したアイコンから開くと、タブやアドレスバーなしで表示できます。';
    const ol = document.createElement('ol');
    for (const t of ['共有ボタン（□↑）をタップ（iPad は画面右上、iPhone は画面下）', '「ホーム画面に追加」を選んで「追加」', 'Safari を閉じ、ホーム画面の「ビンゴ」アイコンから開く']) {
      const li = document.createElement('li'); li.textContent = t; ol.appendChild(li);
    }
    const note = document.createElement('p');
    note.textContent = '※ PCのIPアドレスが変わった時やQRを再発行した時は、QRから開き直して追加し直してください。';
    box.append(p, ol, note);
    showOverlay('タブやアドレスバーなしで使うには', box, { label: '閉じる', onClick: () => {} }, 'help');
  }

  // Fullscreen closed by the lever pull itself (iPad swipe-down) → offer a
  // one-tap way back, and the home-screen app that has no such gesture.
  let fsExitRequested = false;
  let fsWasActive = false;
  function onFullscreenChange() {
    const on = fsActive();
    const leverRelated = !!dragging || performance.now() - releasedAt < 2000;
    if (fsWasActive && !on && !fsExitRequested && leverRelated) {
      showOverlay('全画面が解除されました',
        'レバーを下に引く動きで、iPad の「下スワイプで全画面を閉じる」操作が働いたようです。\nもう一度全画面にするか、解除されない「ホーム画面に追加」で使ってください。',
        { label: '全画面に戻す', onClick: () => enterFullscreen() }, 'help',
        { label: 'ホーム画面に追加する方法', onClick: () => showHomeScreenHelp('ホーム画面に追加したアイコンから開くと、タブやアドレスバーが出ず、下スワイプで解除されることもありません。') });
    }
    fsWasActive = on;
    fsExitRequested = false;
    paintFullscreen();
    setTimeout(measure, 150);
  }

  function paintFullscreen() {
    fsBtn.hidden = launchedStandalone;  // set explicitly on every repaint
    if (launchedStandalone) return;
    const on = fsActive();
    fsBtn.setAttribute('aria-pressed', on ? 'true' : 'false');
    fsBtn.setAttribute('aria-label', on ? '全画面を終了' : '全画面表示');
    fsLabel.textContent = on ? '戻す' : '全画面';
  }
  fsBtn.addEventListener('click', () => {
    unlockAudio();
    if (!fsSupported()) { showHomeScreenHelp(); return; }
    if (fsActive()) { fsExitRequested = true; exitFullscreen(); } else enterFullscreen();
  });
  for (const ev of ['fullscreenchange', 'webkitfullscreenchange']) {
    document.addEventListener(ev, onFullscreenChange);
  }

  /* ================================================================ Feedback (sound / haptics) */
  let audioCtx = null;
  function unlockAudio() {
    if (!soundOn) return;
    try {
      if (!audioCtx) { const AC = window.AudioContext || window.webkitAudioContext; if (AC) audioCtx = new AC(); }
      if (audioCtx && audioCtx.state === 'suspended') audioCtx.resume();
    } catch (_) { audioCtx = null; }
  }
  // Only ever called from inside a user gesture handler.
  function clickSound(freq, dur) {
    if (!soundOn || !audioCtx) return;
    try {
      const t = audioCtx.currentTime;
      const o = audioCtx.createOscillator();
      const g = audioCtx.createGain();
      o.type = 'square';
      o.frequency.setValueAtTime(freq, t);
      g.gain.setValueAtTime(0.12, t);
      g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
      o.connect(g).connect(audioCtx.destination);
      o.start(t); o.stop(t + dur + 0.02);
    } catch (_) { /* ignore */ }
  }
  function vibrate(p) { try { if (navigator.vibrate) navigator.vibrate(p); } catch (_) { /* iOS: unsupported */ } }

  function paintSound() { soundBtn.setAttribute('aria-pressed', soundOn ? 'true' : 'false'); }
  soundBtn.addEventListener('click', () => {
    soundOn = !soundOn;
    store.set(SOUND_KEY, soundOn ? 'on' : 'off');
    unlockAudio();
    paintSound();
  });

  /* ================================================================ Lifecycle */
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') {
      if (dragging) endDrag(null, true);
      return;
    }
    // Back from lock screen / app switch: connection may be dead without onclose.
    keepTokenInUrl();
    if (!ws || ws.readyState !== WebSocket.OPEN || Date.now() - lastRx > PING_MS * 1.5) forceReconnect();
    else send({ type: 'get_state' });
  });
  window.addEventListener('pageshow', (e) => { keepTokenInUrl(); if (e.persisted) forceReconnect(); });
  // Re-scanning a QR while this page is open may only change the #fragment.
  window.addEventListener('hashchange', () => {
    const t = Protocol.tokenFromHash(location.hash);
    if (!t) { keepTokenInUrl(); return; }  // fragment lost: put the code back
    if (t === token && conn !== 'auth_failed' && conn !== 'no_token') return;
    token = t;
    store.set(TOKEN_KEY, token);
    conn = 'connecting';
    hideOverlay();
    forceReconnect();
  });
  window.addEventListener('online', () => forceReconnect());
  window.addEventListener('resize', measure);
  window.addEventListener('orientationchange', () => setTimeout(measure, 250));

  paintSound();
  paintFullscreen();
  measure();
  render();
  connect();
}

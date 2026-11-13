// node --test tests/web/  — pure logic of the phone lever (web-remote/app.js)
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { LeverMath, Protocol } = require(path.join(__dirname, '..', '..', 'web-remote', 'app.js'));

test('knob lags behind the finger before the detent', () => {
  for (const raw of [0.1, 0.4, 0.7]) {
    const p = LeverMath.position(raw, false);
    assert.ok(p > 0 && p < raw, `raw ${raw} -> ${p}`);
  }
});

test('position is monotonic and capped before arming', () => {
  let prev = -1;
  for (let r = 0; r <= 1.2; r += 0.01) {
    const p = LeverMath.position(r, false);
    assert.ok(p >= prev - 1e-9);
    assert.ok(p <= 0.92);
    prev = p;
  }
});

test('arming needs ARM_RAW and has hysteresis', () => {
  assert.equal(LeverMath.nextArmed(0.84, false), false);
  assert.equal(LeverMath.nextArmed(0.85, false), true);
  assert.equal(LeverMath.nextArmed(0.8, true), true);   // stays armed
  assert.equal(LeverMath.nextArmed(0.74, true), false); // disarms
});

test('armed lever snaps to the bottom with a small rubber band', () => {
  assert.equal(LeverMath.position(0.9, true), 1);
  assert.ok(LeverMath.position(2.0, true) <= 1.04);
});

test('pulling up only moves a little', () => {
  assert.ok(LeverMath.position(-1, false) >= -0.05);
});

test('spring returns to rest', () => {
  let pos = 1, vel = 0;
  for (let i = 0; i < 120; i++) [pos, vel] = LeverMath.spring(pos, vel, 0, 1 / 60);
  assert.ok(Math.abs(pos) < 0.01, `pos ${pos}`);
});

test('token is read only from a well-formed fragment', () => {
  assert.equal(Protocol.tokenFromHash('#k=AbCdEfGhIjKlMnOpQrSt'), 'AbCdEfGhIjKlMnOpQrSt');
  assert.equal(Protocol.tokenFromHash('#x=1&k=AbCdEfGhIjKlMnOpQrSt'), 'AbCdEfGhIjKlMnOpQrSt');
  assert.equal(Protocol.tokenFromHash('#k=short'), '');
  assert.equal(Protocol.tokenFromHash('#k=bad<script>xxxxxxxxxxx'), '');
  assert.equal(Protocol.tokenFromHash(''), '');
});

test('the address always carries the connection code (home-screen icons keep it)', () => {
  const t = 'AbCdEfGhIjKlMnOpQrStUvWx';
  const url = Protocol.urlWithToken('/', '', t);
  assert.equal(url, `/#k=${t}`);
  // What "Add to Home Screen" bookmarks must be readable again at launch.
  assert.equal(Protocol.tokenFromHash(url.slice(url.indexOf('#'))), t);
  assert.equal(Protocol.urlWithToken('/index.html', '?x=1', t), `/index.html?x=1#k=${t}`);
  assert.equal(Protocol.urlWithToken('', '', t), `/#k=${t}`);
  // Nothing invalid is ever written into the address.
  assert.equal(Protocol.urlWithToken('/', '', ''), '/');
  assert.equal(Protocol.urlWithToken('/', '', 'bad<script>xxxxxxxxxxxx'), '/');
  assert.equal(Protocol.isToken(t), true);
  assert.equal(Protocol.isToken('short'), false);
  assert.equal(Protocol.isToken(null), false);
});

test('max number validation mirrors the PC rules', () => {
  assert.deepEqual(Protocol.validateMax('75'), { ok: true, value: 75, error: '' });
  assert.equal(Protocol.validateMax('1').ok, true);
  assert.equal(Protocol.validateMax('999').ok, true);
  for (const bad of ['', ' ', '0', '-1', '1000', '7.5', 'abc', '1e2', '99999999']) {
    assert.equal(Protocol.validateMax(bad).ok, false, `reject ${JSON.stringify(bad)}`);
  }
  assert.equal(Protocol.validateMax('50', 1, 40).ok, false);
});

test('digitsOnly strips non-digits, converts full-width, caps length', () => {
  assert.equal(Protocol.digitsOnly('７５'), '75');
  assert.equal(Protocol.digitsOnly('7a5-'), '75');
  assert.equal(Protocol.digitsOnly('12345'), '123');
  assert.equal(Protocol.digitsOnly(null), '');
});

test('keypad: replace when fresh, append, cap, clear, backspace, leading zero', () => {
  assert.equal(Protocol.keypad('75', '9', true), '9');
  assert.equal(Protocol.keypad('9', '0', false), '90');
  assert.equal(Protocol.keypad('100', '5', false), '100');   // 3 digits max
  assert.equal(Protocol.keypad('90', 'B', false), '9');
  assert.equal(Protocol.keypad('75', 'B', true), '7');
  assert.equal(Protocol.keypad('90', 'C', false), '');
  assert.equal(Protocol.keypad('0', '5', false), '5');
  assert.equal(Protocol.keypad('', '0', false), '0');
  assert.equal(Protocol.keypad('12', 'x', false), '12');
});

test('home-screen launch ignores display-mode: fullscreen (Fullscreen API)', () => {
  const only = (q0) => (q) => q === q0;
  assert.equal(Protocol.isStandaloneLaunch({ standalone: true }, null), true);
  assert.equal(Protocol.isStandaloneLaunch({}, only('(display-mode: standalone)')), true);
  assert.equal(Protocol.isStandaloneLaunch({}, only('(display-mode: fullscreen)')), false);
  assert.equal(Protocol.isStandaloneLaunch({ standalone: false }, () => false), false);
  assert.equal(Protocol.isStandaloneLaunch(undefined, null), false);
});

test('request ids satisfy the server format', () => {
  globalThis.self = globalThis;
  const id = Protocol.newId();
  assert.match(id, /^[0-9a-f]{24}$/);
});

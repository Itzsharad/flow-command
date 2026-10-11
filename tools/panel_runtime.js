  var root = document.getElementById('fc-lp');
  var $ = function (s) { return root.querySelector(s); };
  var $$ = function (s) { return Array.prototype.slice.call(root.querySelectorAll(s)); };
  var post = function (m) { try { window.webkit.messageHandlers.fc.postMessage(m); } catch (e) {} };
  var panel = $('#fc-panel'), track = $('#fc-track');
  var scene = document.createElement('div'); scene.className = 'scene'; panel.insertBefore(scene, panel.firstChild);
  var current = '';
  var MODE = '__MODE__';
  var LOCKED = __LOCKED__;

  function actor() { return BUDDIES[current] && BUDDIES[current].g === 'world' ? scene.querySelector('.resident') : track.querySelector('.buddy'); }
  function sparkle(n) {
    var el = actor(); if (!el) return;
    var host = BUDDIES[current].g === 'world' ? scene : track;
    var er = el.getBoundingClientRect(), hr = host.getBoundingClientRect();
    var x = er.left - hr.left + er.width / 2 - 6, y = er.top - hr.top;
    var set = BUDDIES[current].sparks || ['✦'];
    for (var i = 0; i < (n || 5); i++) {
      var sp = document.createElement('span');
      sp.className = 'spark'; sp.textContent = set[i % set.length];
      sp.style.left = (x + rnd(-12, 12)) + 'px';
      if (host === scene) sp.style.top = y + 'px';
      sp.style.setProperty('--dx', rnd(-22, 22) + 'px');
      sp.style.animationDelay = (i * 0.08) + 's';
      host.appendChild(sp);
      setTimeout(function (node) { return function () { node.remove(); }; }(sp), 1900);
    }
  }
  function hop() { var el = actor(); if (!el) return; el.classList.remove('hop'); void el.offsetWidth; el.classList.add('hop'); setTimeout(function () { el.classList.remove('hop'); }, 600); }
  function cheer() { if (!BUDDIES[current] || BUDDIES[current].g !== 'world') return; scene.classList.add('cheer'); setTimeout(function () { scene.classList.remove('cheer'); }, 1800); }
  function speak(text) {
    var el = actor(); if (!el || !text) return;
    var old = track.querySelector('.say-bubble'); if (old) old.remove();
    var bub = document.createElement('div'); bub.className = 'say-bubble'; bub.textContent = text; track.appendChild(bub);
    var er = el.getBoundingClientRect(), tr = track.getBoundingClientRect();
    var left = er.left - tr.left + er.width / 2 - bub.offsetWidth / 2;
    bub.style.left = Math.max(-6, Math.min(left, track.clientWidth - bub.offsetWidth + 6)) + 'px';
    setTimeout(function () { bub.remove(); }, 2500);
  }
  function poke() { var l = BUDDIES[current].lines; hop(); sparkle(4); cheer(); speak(l[Math.floor(Math.random() * l.length)]); }
  function setBuddy(key, greet) {
    if (!BUDDIES[key]) key = 'classic';
    if (key === current) return;
    current = key;
    var B = BUDDIES[key];
    panel.setAttribute('data-buddy', key);
    panel.classList.toggle('world', B.g === 'world');
    $$('.bchip').forEach(function (c) { c.classList.toggle('on', c.getAttribute('data-b') === key); });
    track.innerHTML = ''; scene.innerHTML = ''; scene.className = 'scene';
    if (B.g === 'world') { scene.innerHTML = B.build(); scene.querySelector('.resident').addEventListener('click', poke); }
    else if (key !== 'classic') {
      track.innerHTML = '<div class="buddy" title="Click me!"><div class="flip"><div class="bob">' + B.svg + '</div></div></div>';
      track.querySelector('.buddy').addEventListener('click', poke);
    }
    if (greet && key !== 'classic') setTimeout(function () { hop(); sparkle(5); cheer(); speak(B.lines[0]); }, 80);
    reportSize();
  }
  function setMood(m) {
    if (panel.classList.contains('is-' + m)) return;
    panel.classList.remove('is-listen', 'is-work', 'is-done');
    panel.classList.add('is-' + m);
    if (m === 'done') { hop(); sparkle(6); cheer(); }
  }

  /* waveform */
  var wave = $('#wave');
  for (var i = 0; i < 26; i++) wave.appendChild(document.createElement('b'));
  var bars = $$('#wave b'), level = 0, talking = false;
  setInterval(function () {
    bars.forEach(function (b, i) {
      var h = talking ? 4 + Math.min(1, level * 1.6) * 22 * (0.45 + 0.55 * Math.abs(Math.sin(Date.now() / 150 + i * 0.7))) : 4;
      b.style.height = h.toFixed(1) + 'px';
    });
  }, 90);

  function esc(t) { var d = document.createElement('div'); d.textContent = t == null ? '' : String(t); return d.innerHTML; }
  function show(el, on) { el.style.display = on ? '' : 'none'; }

  var lastSize = '';
  function reportSize() {
    requestAnimationFrame(function () {
      var st = $('.stage'); if (!st) return;
      var s = Math.ceil(st.offsetWidth) + 'x' + Math.ceil(st.offsetHeight);
      if (s !== lastSize) { lastSize = s; post({ action: 'size', w: st.offsetWidth, h: st.offsetHeight }); }
    });
  }

  function render(s) {
    setBuddy(s.buddy || 'classic', false);
    var p = s.phase;
    var dot = $('#dot');
    dot.className = 'p-dot' + ({ understanding: ' work', working: ' work', confirm: ' work', handoff: ' work', done: ' ok', failed: ' fail' }[p] || '');
    $('#title').textContent = s.title || '';
    var t = $('#timer');
    show(t, p === 'working'); if (p === 'working') { var e = Math.floor(s.elapsed || 0); t.textContent = Math.floor(e / 60) + ':' + ('0' + (e % 60)).slice(-2); }
    var listening = p === 'listening' || p === 'holding';
    talking = listening; level = s.level || 0;
    show(wave, listening || p === 'understanding');
    var said = $('#said');
    if (listening || p === 'understanding') {
      said.className = 'said' + (s.live ? '' : ' hint nocaret') + (p === 'understanding' ? ' nocaret' : '');
      said.innerHTML = s.live ? '“' + esc(s.live) + '”' : 'Try: “Open Chrome and go to claude.ai”';
      show(said, true);
    } else if (p === 'working') { said.className = 'said nocaret'; said.innerHTML = '“' + esc(s.instruction) + '”'; show(said, true); }
    else show(said, false);
    var q = $('#qbox'); show(q, p === 'confirm' || p === 'handoff'); q.textContent = s.question || '';
    var steps = $('#steps');
    var showSteps = (p === 'working' || p === 'done' || p === 'failed') && s.steps && s.steps.length;
    show(steps, !!showSteps);
    if (showSteps) {
      steps.innerHTML = s.steps.map(function (x) { return '<li class="show ' + (x.state === 'done' ? 'done' : x.state === 'failed' ? 'failed' : 'current') + '"><s></s><span>' + esc(x.text) + '</span></li>'; }).join('');
    }
    var st = $('#status'); show(st, p === 'working' && !!s.status); st.textContent = s.status || '';
    var r = $('#result'); show(r, p === 'done' || p === 'failed'); r.textContent = s.result || '';
    var btns = $('#btns'), h = '';
    if (p === 'working') h = '<button class="pbtn stop" data-a="stop">Stop</button>';
    else if (p === 'confirm') h = '<button class="pbtn primary" data-a="yes">Yes, do it</button><button class="pbtn ghost" data-a="no">No</button>';
    else if (p === 'handoff') h = '<button class="pbtn primary" data-a="yes">Continue</button><button class="pbtn ghost" data-a="no">Stop</button>';
    else if ((p === 'done' || p === 'failed') && s.fix) h = '<button class="pbtn primary" data-a="fix">' + esc(s.fix) + '</button>';
    if (btns.getAttribute('data-h') !== h) { btns.innerHTML = h; btns.setAttribute('data-h', h); }
    show(btns, !!h);
    var key = esc(s.holdKey || 'your key');
    $('#foot').innerHTML = p === 'holding' ? '<span>Let go of <kbd>' + key + '</kbd> when you’re done</span>'
      : listening ? '<span>Hold <kbd>' + key + '</kbd> to talk</span><span>Esc to stop</span>'
      : p === 'working' ? '<span>Press <kbd>' + key + '</kbd> or Esc to stop</span><span>or say “stop”</span>'
      : (p === 'confirm' || p === 'handoff') ? '<span>Or just say “yes” or “no”</span>'
      : '<span>Flow Command</span>';
    setMood(listening || p === 'understanding' ? 'listen' : (p === 'done' ? 'done' : 'work'));
    reportSize();
  }

  root.addEventListener('click', function (e) {
    var b = e.target.closest && e.target.closest('[data-a]');
    if (b) post({ action: b.getAttribute('data-a') });
  });

  /* ---------- Settings preview: picker + demo loop ---------- */
  function buildPicker() {
    var chips = $('#chips');
    Object.keys(BUDDIES).forEach(function (key) {
      var B = BUDDIES[key];
      var b = document.createElement('button');
      b.type = 'button'; b.className = 'bchip'; b.setAttribute('data-b', key); b.setAttribute('data-g', B.g);
      b.innerHTML = (B.g === 'world' ? '<span class="mini wtile" style="background:' + B.tile + '">' : '<span class="mini">') + B.svg + '</span><span></span>';
      b.lastChild.textContent = B.name;
      var locked = LOCKED.indexOf(key) >= 0;
      if (locked) { b.classList.add('locked'); var lk = document.createElement('span'); lk.className = 'lock'; lk.textContent = 'PRO'; b.appendChild(lk); }
      b.addEventListener('click', function () { setBuddy(key, true); post({ action: locked ? 'locked' : 'buddy', key: key }); });
      chips.appendChild(b);
    });
    $$('.ptabs button').forEach(function (t) { t.addEventListener('click', function () { group(t.getAttribute('data-g')); }); });
    function group(g) {
      $$('.ptabs button').forEach(function (t) { t.classList.toggle('on', t.getAttribute('data-g') === g); });
      $$('.bchip').forEach(function (c) { c.hidden = c.getAttribute('data-g') !== g; });
    }
    group(BUDDIES[current] ? BUDDIES[current].g : 'walk');
    $$('.bchip').forEach(function (c) { c.classList.toggle('on', c.getAttribute('data-b') === current); });
  }
  function demo() {
    var said = 'Open GoHighLevel and switch to my client’s account';
    var steps = ['Going to app.gohighlevel.com', 'Opening the account switcher', 'Clicking “Client account”'];
    var t = 0, base = { buddy: current, holdKey: 'right ⌘' };
    function S(o) { var x = {}; for (var k in base) x[k] = base[k]; for (var k2 in o) x[k2] = o[k2]; x.buddy = current; return x; }
    function tick() {
      t = (t + 1) % 22;
      if (t < 8) render(S({ phase: 'listening', title: 'Listening — what should I do?', live: said.slice(0, Math.ceil(said.length * t / 7)), level: 0.5 + Math.random() * 0.4 }));
      else if (t < 16) { var n = Math.min(3, t - 7); render(S({ phase: 'working', title: 'Working', instruction: said, elapsed: (t - 8), steps: steps.slice(0, n).map(function (x, i) { return { text: x, state: i < n - 1 ? 'done' : 'current' }; }) })); }
      else render(S({ phase: 'done', title: 'Done — 3 steps in 3.4s', steps: steps.map(function (x) { return { text: x, state: 'done' }; }), result: 'Switched to your client’s account.' }));
    }
    tick(); setInterval(tick, 450);
  }

  window.fc = { render: render, setBuddy: setBuddy, poke: poke };
  setBuddy('__BUDDY__', false);
  if (MODE === 'preview') { root.classList.add('preview'); buildPicker(); demo(); }

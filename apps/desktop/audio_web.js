// audio_web.js — quine's own WebAudio output device (replaces sokol_audio).
//
// Linked into the wasm via emscripten `--js-library`. The wasm-side mixer
// (`modules/audio`) renders interleaved PCM each frame; this JS owns the output
// device, so we negotiate the *real* channel count the browser allows
// (`destination.maxChannelCount`, capped at 8 / 7.1) instead of sokol's stereo.
//
// Two output paths, picked at init, behind one wasm API (init / needed / push):
//
//   1. AudioWorklet + SharedArrayBuffer ring  (preferred — low latency)
//      A separate SAB ring (NOT the wasm heap, so no -pthread build) is shared
//      with an AudioWorkletProcessor. The main thread writes the mixer's PCM into
//      the ring; the worklet drains it on the audio thread. SPSC, lock-free via
//      Atomics on two frame counters. Needs cross-origin isolation (COOP/COEP) so
//      `SharedArrayBuffer` exists, and a context whose rate == the mixer's (we
//      request it) so the ring maps 1:1 with no resampling.
//
//   2. Main-thread AudioBuffer scheduling  (fallback)
//      No SAB / worklet / matching rate → schedule AudioBuffers ahead on the main
//      thread. Higher latency + main-thread jank, but works anywhere (incl. iPad
//      Safari with no COI headers); the AudioBuffer carries the mixer's rate so
//      the context resamples (no pitch error).
//
// The worklet processor runs at the mixer's sample rate (we only take that path
// when `ctx.sampleRate === mixerRate`), so it reads one ring frame per output
// frame — no resampler in the hot path.
mergeInto(LibraryManager.library, {
  // Create the context, negotiate channels, and (async) try to upgrade to the
  // worklet+SAB path. Returns channels (<= 8), or 0 if WebAudio is unavailable.
  quine_web_audio_init: function (mixerRate) {
    try {
      var Ctor = (typeof AudioContext !== 'undefined') ? AudioContext
        : (typeof webkitAudioContext !== 'undefined' ? webkitAudioContext : null);
      if (!Ctor) return 0;

      // Request the mixer's rate so the worklet ring is 1:1 (Safari 14.1+ honors
      // this). If the browser overrides it we just stay on the resampling
      // AudioBuffer fallback.
      var ctx;
      try { ctx = new Ctor({ sampleRate: mixerRate }); } catch (e) { ctx = new Ctor(); }

      var maxch = ctx.destination.maxChannelCount | 0;
      var ch = Math.max(1, Math.min(8, maxch || 2));
      try {
        ctx.destination.channelCount = ch;
        ctx.destination.channelCountMode = 'explicit';
        ctx.destination.channelInterpretation = 'discrete';
      } catch (e) {
        ch = Math.min(ch, 2); // some devices reject >2 — fall back to stereo
      }

      var A = { ctx: ctx, ch: ch, rate: mixerRate, mode: 'buffer', next: 0, look: 0.18 };
      var g = (typeof window !== 'undefined') ? window : globalThis;

      // Publish a host-readable snapshot of the audio state with QUOTED keys, so
      // emscripten's closure pass can't rename them (it renamed `Module._quineAudio`
      // and the page could never read it). The host reads `window.quineAudio`:
      // { mode, channels, sampleRate, block, state }. Re-published on every change.
      var publish = function () {
        g['quineAudio'] = {
          'mode': A.mode,
          'channels': A.ch,
          'sampleRate': A.rate,
          'contextRate': A.ctx ? A.ctx.sampleRate : 0,
          'block': A.mode === 'worklet' ? 128 : 0,
          'state': A.ctx ? A.ctx.state : '',
        };
      };
      publish();

      var resume = function () {
        if (ctx.state !== 'running') ctx.resume().then(publish, publish);
        publish();
      };
      ['pointerdown', 'keydown', 'touchstart'].forEach(function (ev) {
        g.addEventListener(ev, resume, { passive: true });
      });

      // Try the worklet+SAB upgrade (async). Conditions: the page is genuinely
      // cross-origin isolated (the canonical gate — more reliable than just
      // `typeof SharedArrayBuffer`, e.g. inside a non-isolated iframe), AudioWorklet
      // support, and a matching rate. Otherwise we stay on the buffer fallback, so
      // the engine still plays audio when embedded in an ordinary (non-COI) page.
      // (bracket access so emscripten's closure pass can't fold/strip the gate)
      if (globalThis['crossOriginIsolated'] === true && typeof SharedArrayBuffer !== 'undefined' &&
          ctx.audioWorklet && Math.abs(ctx.sampleRate - mixerRate) < 1) {
        try {
          // Ring + target are multiples of the worklet's 128-frame quantum. At
          // 48 kHz: cap 8192 ≈ 170 ms of slack; target 2048 ≈ 43 ms latency, with
          // ~127 ms of headroom to absorb main-thread (rAF) write jitter.
          var cap = 8192; // 64 quanta
          A.cap = cap;
          A.target = 2048; // 16 quanta
          A.control = new Int32Array(new SharedArrayBuffer(8)); // [read, write] frame counters
          A.data = new Float32Array(new SharedArrayBuffer(cap * ch * 4)); // interleaved ring

          var src =
            'class QuineSink extends AudioWorkletProcessor {' +
            '  constructor(o){super();var p=o.processorOptions;' +
            '    this.ix=new Int32Array(p.control);this.d=new Float32Array(p.data);' +
            '    this.ch=p.channels;this.cap=p.frames;}' +
            '  process(inputs,outputs){var out=outputs[0];var oc=out.length;var n=out[0].length;' +
            '    var r=Atomics.load(this.ix,0);var w=Atomics.load(this.ix,1);var avail=w-r;' +
            '    for(var i=0;i<n;i++){' +
            '      if(avail>0){var s=(r%this.cap)*this.ch;' +
            '        for(var c=0;c<oc;c++){out[c][i]=(c<this.ch)?this.d[s+c]:0;}r++;avail--;}' +
            '      else{for(var c=0;c<oc;c++){out[c][i]=0;}}}' +
            '    Atomics.store(this.ix,0,r);return true;}}' +
            'registerProcessor("quine-sink",QuineSink);';
          var url = URL.createObjectURL(new Blob([src], { type: 'application/javascript' }));
          ctx.audioWorklet.addModule(url).then(function () {
            var node = new AudioWorkletNode(ctx, 'quine-sink', {
              numberOfInputs: 0, numberOfOutputs: 1, outputChannelCount: [ch],
              processorOptions: { control: A.control.buffer, data: A.data.buffer, channels: ch, frames: cap },
            });
            node.connect(ctx.destination);
            A.node = node;
            A.mode = 'worklet';
            publish();
          }).catch(function () { /* stay on the buffer fallback */ });
        } catch (e) { /* stay on the buffer fallback */ }
      }
      return ch;
    } catch (e) {
      return 0;
    }
  },

  // Frames the device wants now (so the wasm renders that many). Worklet: keep
  // ~target frames in the ring. Buffer: keep `look` seconds scheduled ahead.
  quine_web_audio_needed: function () {
    var A = Module._quineAudio;
    if (!A || A.ctx.state !== 'running') return 0;
    if (A.mode === 'worklet') {
      var r = Atomics.load(A.control, 0);
      var w = Atomics.load(A.control, 1);
      var avail = w - r;
      var want = A.target - avail; // keep ~target frames (16 × 128) buffered
      var free = A.cap - avail;
      if (want < 0) want = 0;
      if (want > free) want = free;
      return want;
    }
    var now = A.ctx.currentTime;
    if (A.next < now) A.next = now; // underran — resync to the clock
    var want2 = (A.look - (A.next - now)) * A.rate;
    if (want2 < 0) want2 = 0;
    if (want2 > A.rate) want2 = A.rate; // cap a single render at ~1 s
    return want2 | 0;
  },

  // Submit `frames` of interleaved float PCM at wasm address `ptr`.
  quine_web_audio_push: function (ptr, frames, channels) {
    var A = Module._quineAudio;
    if (!A || frames <= 0) return;
    var base = ptr >> 2; // f32 index into HEAPF32

    if (A.mode === 'worklet') {
      var r = Atomics.load(A.control, 0);
      var w = Atomics.load(A.control, 1);
      var free = A.cap - (w - r);
      var nw = Math.min(frames, free);
      var d = A.data, cap = A.cap, ch = A.ch;
      for (var i = 0; i < nw; i++) {
        var s = (w % cap) * ch;
        var k = base + i * channels;
        for (var c = 0; c < ch; c++) { d[s + c] = (c < channels) ? HEAPF32[k + c] : 0; }
        w++;
      }
      Atomics.store(A.control, 1, w);
      return;
    }

    // Buffer fallback: de-interleave into an AudioBuffer at the mixer's rate and
    // schedule it ahead (the context resamples on playback).
    var abuf = A.ctx.createBuffer(channels, frames, A.rate);
    for (var c2 = 0; c2 < channels; c2++) {
      var cd = abuf.getChannelData(c2);
      var kk = base + c2;
      for (var j = 0; j < frames; j++) { cd[j] = HEAPF32[kk]; kk += channels; }
    }
    var srcNode = A.ctx.createBufferSource();
    srcNode.buffer = abuf;
    srcNode.connect(A.ctx.destination);
    var t = A.next, now2 = A.ctx.currentTime;
    if (t < now2) t = now2;
    srcNode.start(t);
    A.next = t + frames / A.rate;
  },
});

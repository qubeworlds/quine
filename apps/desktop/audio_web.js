// audio_web.js — quine's own WebAudio output device (replaces sokol_audio).
//
// Linked into the wasm via emscripten `--js-library`. The wasm-side mixer
// (`modules/audio`) renders interleaved PCM each frame; here we de-interleave it
// into an `AudioBuffer` and schedule it ahead on a single `AudioContext`. We own
// the whole path, so we negotiate the *real* output channel count the browser
// allows — `destination.maxChannelCount`, capped at 8 (7.1) — instead of being
// stuck at sokol's stereo. The buffer carries the mixer's sample rate, so the
// context resamples on playback (no pitch error if the device runs at 48 kHz).
//
// Main-thread render + AudioBuffer scheduling (no AudioWorklet, no
// SharedArrayBuffer) keeps it dependency-free and works on iPad Safari with no
// cross-origin-isolation headers. The trade-off is main-thread jank can underrun;
// an AudioWorklet + SAB ring is the later upgrade for lower-latency output.
mergeInto(LibraryManager.library, {
  // Create the context and negotiate the channel count. Returns channels (<= 8),
  // or 0 if WebAudio is unavailable. The context starts suspended (autoplay
  // policy); a one-time user-gesture listener resumes it.
  quine_web_audio_init: function (mixerRate) {
    try {
      var Ctor = (typeof AudioContext !== 'undefined') ? AudioContext : (typeof webkitAudioContext !== 'undefined' ? webkitAudioContext : null);
      if (!Ctor) return 0;
      var ctx = new Ctor();
      var maxch = ctx.destination.maxChannelCount | 0;
      var ch = Math.max(1, Math.min(8, maxch || 2));
      try {
        ctx.destination.channelCount = ch;
        ctx.destination.channelCountMode = 'explicit';
        ctx.destination.channelInterpretation = 'discrete';
      } catch (e) {
        ch = Math.min(ch, 2); // some devices reject >2 — fall back to stereo
      }
      var resume = function () { if (ctx.state !== 'running') { ctx.resume(); } };
      ['pointerdown', 'keydown', 'touchstart'].forEach(function (ev) {
        (typeof window !== 'undefined' ? window : globalThis).addEventListener(ev, resume, { passive: true });
      });
      Module._quineAudio = { ctx: ctx, ch: ch, rate: mixerRate, next: 0, look: 0.18 };
      return ch;
    } catch (e) {
      return 0;
    }
  },

  // Frames the scheduler wants now to keep `look` seconds buffered ahead of the
  // context clock. 0 while suspended (pre-gesture) so we don't render uselessly.
  quine_web_audio_needed: function () {
    var A = Module._quineAudio;
    if (!A || A.ctx.state !== 'running') return 0;
    var now = A.ctx.currentTime;
    if (A.next < now) A.next = now; // underran — resync to the clock
    var want = (A.look - (A.next - now)) * A.rate;
    if (want < 0) want = 0;
    if (want > A.rate) want = A.rate; // cap a single render at ~1s
    return want | 0;
  },

  // Schedule `frames` of interleaved float PCM at wasm address `ptr`.
  quine_web_audio_push: function (ptr, frames, channels) {
    var A = Module._quineAudio;
    if (!A || frames <= 0) return;
    var abuf = A.ctx.createBuffer(channels, frames, A.rate);
    var base = ptr >> 2; // f32 index into HEAPF32
    for (var c = 0; c < channels; c++) {
      var cd = abuf.getChannelData(c);
      var k = base + c;
      for (var i = 0; i < frames; i++) { cd[i] = HEAPF32[k]; k += channels; }
    }
    var src = A.ctx.createBufferSource();
    src.buffer = abuf;
    src.connect(A.ctx.destination);
    var t = A.next;
    var now = A.ctx.currentTime;
    if (t < now) t = now;
    src.start(t);
    A.next = t + frames / A.rate;
  },
});

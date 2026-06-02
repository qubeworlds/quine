// keepie-uppie skill — the interpreted form of keepie-uppie.ts, running in
// QuickJS against the quine_* host natives. The actor sees the ball, runs under
// its predicted landing, and heads it back up on each touch. (This is the plain
// JS the editor's keepie-uppie.ts compiles to; the @world/shared/runtime facade
// would normally wrap these natives, but the logic is identical.)
(function () {
  var RUN_SPEED = 3.2,
    REACH = 2.0,
    JUGGLE_LAUNCH = 4.2,
    JUGGLE_H_DAMP = 0.4,
    PREDICT_HORIZON = 1.5,
    SQUASH_PER_IMPACT = 0.04,
    SQUASH_MAX = 0.3;

  function clamp(v, lo, hi) {
    return v < lo ? lo : v > hi ? hi : v;
  }

  // Before the step: predict where the ball falls to head height and run the
  // actor so its head ends up under that spot.
  __quine_onPreStep(function (dt) {
    var bpx = __quine_bodyPos("ball", 0),
      bpy = __quine_bodyPos("ball", 1),
      bpz = __quine_bodyPos("ball", 2);
    var bvx = __quine_bodyVel("ball", 0),
      bvy = __quine_bodyVel("ball", 1),
      bvz = __quine_bodyVel("ball", 2);
    var hpx = __quine_bodyPos("head", 0),
      hpy = __quine_bodyPos("head", 1),
      hpz = __quine_bodyPos("head", 2);

    var g = -__quine_gravityY();
    var catchY = hpy + __quine_radius("head") + __quine_radius("ball");
    var dy = bpy - catchY;
    var disc = bvy * bvy + 2 * g * dy;
    var tLand = disc > 0 ? Math.min((bvy + Math.sqrt(disc)) / g, PREDICT_HORIZON) : 0;
    var landX = bpx + bvx * tLand;
    var landZ = bpz + bvz * tLand;

    var px = __quine_transformPos("dancer", 0),
      py = __quine_transformPos("dancer", 1),
      pz = __quine_transformPos("dancer", 2);
    var tgtX = clamp(landX - (hpx - px), -REACH, REACH);
    var tgtZ = clamp(landZ - (hpz - pz), -REACH, REACH);
    var stepMax = RUN_SPEED * dt;
    __quine_setTransformPos(
      "dancer",
      px + clamp(tgtX - px, -stepMax, stepMax),
      py,
      pz + clamp(tgtZ - pz, -stepMax, stepMax),
    );
  });

  // After the step: head a touched ball back up + damp its drift, and squash the
  // actor + ball from the real impact. A ground touch squashes the ball.
  __quine_onPostStep(function (dt) {
    var ih = __quine_contact("ball", "head");
    var ig = __quine_contact("ball", "ground");
    if (ih > 0) {
      __quine_setBodyVel(
        "ball",
        __quine_bodyVel("ball", 0) * JUGGLE_H_DAMP,
        JUGGLE_LAUNCH,
        __quine_bodyVel("ball", 2) * JUGGLE_H_DAMP,
      );
      __quine_bumpSquash("dancer", Math.min(ih * SQUASH_PER_IMPACT, SQUASH_MAX));
    }
    var impact = Math.max(ih, ig);
    if (impact > 0) __quine_bumpSquash("ball", Math.min(impact * SQUASH_PER_IMPACT, SQUASH_MAX));
  });
})();

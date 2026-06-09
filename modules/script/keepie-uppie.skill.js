// keepie-uppie skill -- the interpreted form of the editor's keepie-uppie.ts,
// running in QuickJS against the prelude facade. The actor sees the ball, runs
// under its predicted landing, and heads it back up on each touch. Apart from
// the IIFE wrapper (no ES module loader), this is the same code as
// keepie-uppie.ts using the same world.get(...)/entity.body API.
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

  var dancer = world.get("dancer"),
    ball = world.get("ball"),
    head = world.get("head"),
    ground = world.get("ground");

  // Before the step: predict where the ball falls to head height and run the
  // actor so its head ends up under that spot.
  onPreStep(function (dt) {
    var bp = ball.body.position,
      bv = ball.body.velocity,
      hp = head.body.position;
    var g = -world.gravity.y;
    var catchY = hp.y + head.body.radius + ball.body.radius;
    var dy = bp.y - catchY;
    var disc = bv.y * bv.y + 2 * g * dy;
    var tLand = disc > 0 ? Math.min((bv.y + Math.sqrt(disc)) / g, PREDICT_HORIZON) : 0;
    var landX = bp.x + bv.x * tLand;
    var landZ = bp.z + bv.z * tLand;

    var pos = dancer.transform.position;
    var tgtX = clamp(landX - (hp.x - pos.x), -REACH, REACH);
    var tgtZ = clamp(landZ - (hp.z - pos.z), -REACH, REACH);
    var stepMax = RUN_SPEED * dt;
    dancer.transform.position = {
      x: pos.x + clamp(tgtX - pos.x, -stepMax, stepMax),
      y: pos.y,
      z: pos.z + clamp(tgtZ - pos.z, -stepMax, stepMax),
    };
  });

  // After the step: head a touched ball back up + damp its drift, and squash the
  // actor + ball from the real impact. A ground touch squashes the ball.
  onPostStep(function () {
    var ih = world.contactImpulse(ball, head);
    var ig = world.contactImpulse(ball, ground);
    if (ih > 0) {
      var v = ball.body.velocity;
      ball.body.velocity = { x: v.x * JUGGLE_H_DAMP, y: JUGGLE_LAUNCH, z: v.z * JUGGLE_H_DAMP };
      dancer.squash.value = Math.min(dancer.squash.value + ih * SQUASH_PER_IMPACT, SQUASH_MAX);
    }
    var impact = Math.max(ih, ig);
    if (impact > 0) ball.squash.value = Math.min(ball.squash.value + impact * SQUASH_PER_IMPACT, SQUASH_MAX);
  });
})();

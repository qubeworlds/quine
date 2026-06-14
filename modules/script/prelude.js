// Skill runtime prelude -- the Roblox-flavored facade over the quine_* natives.
//
// Loaded into the JS context before a skill, so a skill can be written against
// the same surface as the editor's @world/shared/runtime (world.get(name),
// entity.body.velocity, onPreStep/onPostStep) instead of the raw natives.
// Component accessors read the live engine on get and write back on set.
var world = (function () {
  function vec(name, comp) {
    return { x: comp(name, 0), y: comp(name, 1), z: comp(name, 2) };
  }
  function entity(name) {
    return {
      name: name,
      get transform() {
        return {
          get position() {
            return vec(name, __quine_transformPos);
          },
          set position(v) {
            __quine_setTransformPos(name, v.x, v.y, v.z);
          },
        };
      },
      get body() {
        return {
          get position() {
            return vec(name, __quine_bodyPos);
          },
          get velocity() {
            return vec(name, __quine_bodyVel);
          },
          set velocity(v) {
            __quine_setBodyVel(name, v.x, v.y, v.z);
          },
          get radius() {
            return __quine_radius(name);
          },
        };
      },
      get squash() {
        return {
          get value() {
            return __quine_squashValue(name);
          },
          set value(v) {
            __quine_bumpSquash(name, v);
          },
        };
      },
      get material() {
        return {
          // Emissive glow (a Vec3 {x,y,z}); render reads it as a uniform.
          set emissive(v) {
            __quine_setEmissive(name, v.x, v.y, v.z);
          },
        };
      },
    };
  }
  return {
    get gravity() {
      return { x: 0, y: __quine_gravityY(), z: 0 };
    },
    get: function (name) {
      return entity(name);
    },
    contactImpulse: function (a, b) {
      return __quine_contact(a.name, b.name);
    },
  };
})();

function onPreStep(fn) {
  __quine_onPreStep(fn);
}
function onPostStep(fn) {
  __quine_onPostStep(fn);
}

// Input: an app-exposed device axis (e.g. a held-key value), read each tick.
// `id` is an integer axis index; the app writes it, the skill reads it.
function input(id) {
  return __quine_axis(id | 0);
}

// Audio: queue synth intents the app drains to the device after the tick (the
// engine stays silent in headless/CI — sound is app/render-side). `bus` is a
// sustained voice (e.g. a coil hum); `sfx` is a one-shot (kind 0 = boom). Sound
// design — mapping a game value to freq/gain — lives here in the skill.
var audio = {
  bus: function (bus, freq, gain, noise) {
    __quine_audioBus(bus | 0, freq, gain, noise || 0);
  },
  sfx: function (kind, freq, gain) {
    __quine_sfx(kind | 0, freq, gain);
  },
};

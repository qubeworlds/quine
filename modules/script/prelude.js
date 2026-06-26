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
          // Euler XYZ radians. A skill turns an entity (e.g. an Asteroids ship)
          // by writing this; the renderer reads the same Transform.rotation.
          get rotation() {
            return vec(name, __quine_transformRot);
          },
          set rotation(v) {
            __quine_setTransformRot(name, v.x, v.y, v.z);
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
          // Orientation quaternion {x,y,z,w} from the physics body. Read it to
          // apply thrust in the body frame (so a tilted quad's lift tilts too).
          get rotation() {
            return {
              x: __quine_bodyRot(name, 0),
              y: __quine_bodyRot(name, 1),
              z: __quine_bodyRot(name, 2),
              w: __quine_bodyRot(name, 3),
            };
          },
          get radius() {
            return __quine_radius(name);
          },
          // Accumulate a world-space force {x,y,z} at a world point {x,y,z} for the
          // next step (off-centre → torque). A quad's 4 rotor thrusts go in here.
          addForce: function (f, p) {
            __quine_addForce(name, f.x, f.y, f.z, p.x, p.y, p.z);
          },
          // Accumulate a pure torque {x,y,z} — a quad's yaw drag-reaction couple.
          addTorque: function (t) {
            __quine_addTorque(name, t.x, t.y, t.z);
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
    // Spawn a new entity by cloning a template entity's mesh + material (e.g. a
    // bullet or rock fragment). Returns an entity handle (same API as get) you
    // position via `.transform`, or null if the template is unknown / the pool is
    // full. Despawn it with world.despawn(handle) when it expires or is hit.
    spawn: function (template) {
      var n = __quine_spawn(template);
      return n ? entity(n) : null;
    },
    despawn: function (e) {
      __quine_despawn(typeof e === "string" ? e : e.name);
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

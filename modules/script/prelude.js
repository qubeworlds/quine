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

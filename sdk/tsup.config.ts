import { defineConfig } from 'tsup';

// The build version is baked in from QUINE_VERSION (the publisher passes the git
// SHA). It drives the SDK's default engine base — a versioned SDK loads the
// matching versioned engine, so the two ship in lockstep. Unset = 'dev' (latest).
export default defineConfig({
  entry: ['src/index.ts'],
  format: ['esm'],
  dts: true,
  clean: true,
  define: {
    __QUINE_VERSION__: JSON.stringify(process.env.QUINE_VERSION ?? 'dev'),
  },
});

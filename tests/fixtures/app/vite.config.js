import { defineConfig } from 'vite';
import laravel from 'laravel-vite-plugin';

// laravel-vite-plugin rather than a bare vite config, for one reason: it writes
// the manifest to public/build/manifest.json keyed by the SOURCE path
// ('resources/js/app.js'). Vite's own default puts it at
// public/build/.vite/manifest.json, and routes/web.php reads the former - the
// path and the key are both part of what GET / asserts.
//
// refresh is off: there is no dev server in the smoke suite, only `vite build`.
export default defineConfig({
    plugins: [
        laravel({
            input: ['resources/js/app.js'],
            refresh: false,
        }),
    ],
});

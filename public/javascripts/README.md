# Vendored JavaScript bundles

This directory holds third-party browser builds that the plugin lazy-loads
at runtime via Discourse's `loadScript` helper. Files are served by
Discourse at `/plugins/discourse-npn-critique-reply/javascripts/<file>`.

## Required: `konva-9.3.20.min.js`

The Konva-backed visual notes renderer depends on this file. It is **not
committed to the repository** — operators must vendor it before enabling
visual notes with the Konva renderer.

### Why not committed?

- Pinned version (`9.3.20`) keeps behavior reproducible without a build
  step or npm install.
- Keeping the binary out of git keeps the repo lightweight and avoids
  conflating plugin source with vendored dependencies.

### Install

From the plugin root:

```bash
curl -L https://unpkg.com/konva@9.3.20/konva.min.js \
  -o public/javascripts/konva-9.3.20.min.js
```

Verify expected size (~145 KB):

```bash
wc -c public/javascripts/konva-9.3.20.min.js
# expect approximately 145000-160000
```

Restart Discourse so the static asset is picked up.

### Verify it's serving

Once the file is in place, browse to:

```
http://<your-discourse-host>/plugins/discourse-npn-critique-reply/javascripts/konva-9.3.20.min.js
```

You should get the JS file back with `Content-Type: application/javascript`.
A 404 means the file is not in `public/javascripts/` or Discourse didn't
pick it up — restart usually fixes that.

### What loads it

The plugin loads this script via:

```js
loadScript("/plugins/discourse-npn-critique-reply/javascripts/konva-9.3.20.min.js")
```

…from `assets/javascripts/discourse/lib/npn-critique-reply-konva-stage.js`,
the first time a critic opens the visual notes feature. The script attaches
`window.Konva`, which the stage module then consumes.

### What if I don't install it?

The Critique Helper modal falls back to the original HTML pin overlay.
All visual notes functionality continues working — only the renderer
differs. The fallback path is logged via `console.warn` under
`npn_critique_reply_debug_enabled`.

### Upgrading Konva

Bump the URL in `lib/npn-critique-reply-konva-stage.js` (the `KONVA_URL`
constant), re-run the curl with the new version in the filename, and
keep the old file around for one release cycle so deploys mid-rollout
don't 404 on either side.

Do **not** upgrade to Konva 10.x without testing — there are API
changes in `Layer.draw()` semantics, transformer behavior, and a few
other places. Pin to a known-good version.

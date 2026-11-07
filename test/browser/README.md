# Browser specs for the failure report viewer

These specs open real failure pages in Chromium over `file://` and check the
tabs, the citations of an explanation and the index page. They are not part of
`mix test` and do not ship in the Hex package.

To run them from the repository root:

```bash
mix run test/browser/generate_pages.exs /tmp/pd_pages
cd test/browser
npm ci
npx playwright install --with-deps chromium
PD_PAGES_DIR=/tmp/pd_pages npx playwright test
```

Set `PD_BROWSER` to the path of a Chrome or Chromium binary to use it in place
of the one Playwright installs.

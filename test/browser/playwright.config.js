// @ts-check
const { defineConfig } = require("@playwright/test");

// PD_PAGES_DIR names the directory that generate_pages.exs wrote.
// PD_BROWSER, when set, names a Chromium or Chrome binary to use in place of
// the one `npx playwright install` fetched.
module.exports = defineConfig({
  testDir: "./specs",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: 0,
  reporter: [["list"], ["html", { open: "never" }]],
  use: {
    browserName: "chromium",
    launchOptions: process.env.PD_BROWSER ? { executablePath: process.env.PD_BROWSER } : {},
  },
});

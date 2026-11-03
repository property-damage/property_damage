const { test, expect } = require("@playwright/test");
const { files, url, watchErrors } = require("./pages");

const index = () => url("index.html");
const label = (page) => page.locator("#lbl");
const frameFile = (page) => page.locator("#f").getAttribute("src");

test("the index lists every page and shows the first without a console error", async ({
  page,
}) => {
  const errors = watchErrors(page);
  await page.goto(index());

  const listed = await page.evaluate(() =>
    JSON.parse(document.getElementById("pd-reports").textContent).map((r) => r.file),
  );
  expect(listed).toEqual(files);
  expect(files.length).toBeGreaterThanOrEqual(2);

  await expect(label(page)).toContainText(`1/${files.length}`);
  expect(await frameFile(page)).toBe(files[0]);
  await expect(page.frameLocator("#f").locator("#view")).toBeAttached();
  expect(errors).toEqual([]);
});

test("the buttons move between reports and wrap around", async ({ page }) => {
  await page.goto(index());
  const n = files.length;

  await page.locator("#next").click();
  await expect(label(page)).toContainText(`2/${n}`);
  expect(await frameFile(page)).toBe(files[1]);

  await page.locator("#prev").click();
  await expect(label(page)).toContainText(`1/${n}`);
  expect(await frameFile(page)).toBe(files[0]);

  await page.locator("#prev").click();
  await expect(label(page)).toContainText(`${n}/${n}`);
  expect(await frameFile(page)).toBe(files[n - 1]);
});

test("the arrow keys move between reports while the index page has focus", async ({ page }) => {
  await page.goto(index());
  const n = files.length;
  await page.evaluate(() => {
    if (document.activeElement) document.activeElement.blur();
    window.focus();
  });

  await page.keyboard.press("ArrowRight");
  await expect(label(page)).toContainText(`2/${n}`);
  expect(await frameFile(page)).toBe(files[1]);

  await page.keyboard.press("ArrowLeft");
  await expect(label(page)).toContainText(`1/${n}`);
});

test("the hash names the report to open", async ({ page }) => {
  const last = files[files.length - 1];
  await page.goto(`${index()}#r=${encodeURIComponent(last)}`);

  await expect(label(page)).toContainText(`${files.length}/${files.length}`);
  expect(await frameFile(page)).toBe(last);
});

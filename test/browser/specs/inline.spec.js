const fs = require("fs");
const { pathToFileURL } = require("url");
const { test, expect } = require("@playwright/test");
const { explained, paired, expanded, dir, url, watchErrors } = require("./pages");
const path = require("path");

// The header of a comparison band is the first line of its .rband.
const header = (page, label) =>
  page.locator(".rband").filter({ hasText: new RegExp(`^\\[${label}\\] `) }).locator(".rh");

test.describe("the band header of a root a target ran under an expansion entry", () => {
  test("a root split into leaves names each leaf and its step", async ({ page }) => {
    const errors = watchErrors(page);
    await page.goto(url(expanded));

    const text = await header(page, "4").innerText();
    for (const target of ["carol", "dave"]) {
      expect(text).toContain(`${target} split it into DepositFirst (step 4.0) and DepositRest (step 4.1)`);
    }
    expect(text).not.toContain("ran it as");
    expect(errors).toEqual([]);
  });

  test("a root kept as itself under a listed entry reads as one step", async ({ page }) => {
    await page.goto(url(expanded));

    const text = await header(page, "1").innerText();
    for (const target of ["carol", "dave"]) expect(text).toContain(`${target} kept it as one step`);
    expect(text).not.toContain("ran it as");
  });

  test("a root whose entry has no commands reads as dropped", async ({ page }) => {
    await page.goto(url(expanded));

    const text = await header(page, "5").innerText();
    for (const target of ["carol", "dave"]) expect(text).toContain(`${target} dropped it`);
  });

  test("the dropped header reads the listing, not the What this checks section", async ({ page }, testInfo) => {
    // The same page with the "What this checks" section cut out of the embedded report text.
    const html = fs.readFileSync(path.join(dir, expanded), "utf8");
    const pattern = /(<script type="application\/json" id="pd-report">)(.*?)(<\/script>)/s;
    const text = JSON.parse(html.match(pattern)[2]);
    const cut = text.replace(/## What this checks\n[\s\S]*?(?=\n## )/, "");
    expect(cut).not.toContain("What this checks");
    const file = testInfo.outputPath("without-checks.html");
    fs.writeFileSync(file, html.replace(pattern, (_m, a, _b, c) => a + JSON.stringify(cut).replace(/</g, "\\u003c") + c));

    const errors = watchErrors(page);
    await page.goto(pathToFileURL(file).href);

    await expect(page.locator('[data-section="what-this-checks"]')).toHaveCount(0);
    const text5 = await header(page, "5").innerText();
    for (const target of ["carol", "dave"]) expect(text5).toContain(`${target} dropped it`);
    expect(errors).toEqual([]);
  });

  test("a page whose roots ran as themselves names no path in any header", async ({ page }) => {
    await page.goto(url(paired));

    const text = await page.locator(".rband .rh").allInnerTexts();
    expect(text.length).toBeGreaterThan(0);
    for (const line of text) expect(line).not.toMatch(/ran it as|split it|kept it|dropped it/);
  });
});

test.describe("the citation markers of an explanation", () => {
  // Narrow, so that a paragraph wraps and "the last line" is a real place.
  test.use({ viewport: { width: 360, height: 800 } });

  test("each marker ends its paragraph, on the paragraph's last line", async ({ page }) => {
    await page.goto(url(explained));

    const where = await page.evaluate(() =>
      [...document.querySelectorAll("#pd-explanation-view .xcites")].map((cites) => {
        const para = cites.parentElement;
        const text = document.createRange();
        text.selectNodeContents(para.firstChild);
        const lines = [...text.getClientRects()];
        const last = lines[lines.length - 1];
        const p = para.getBoundingClientRect();
        return {
          tag: para.tagName,
          lines: lines.length,
          marks: [...cites.children].map((m) => {
            const r = m.getBoundingClientRect();
            const mid = (r.top + r.bottom) / 2;
            return {
              inside: r.left >= p.left && r.right <= p.right + 1 && r.top >= p.top && r.bottom <= p.bottom + 1,
              onLastLine: mid >= last.top && mid <= last.bottom,
            };
          }),
        };
      }),
    );

    expect(where.length).toBeGreaterThanOrEqual(3);
    for (const claim of where) {
      expect(claim.tag).toBe("P");
      expect(claim.marks.length).toBeGreaterThan(0);
      for (const mark of claim.marks) expect(mark).toEqual({ inside: true, onLastLine: true });
    }
    expect(where.some((claim) => claim.lines > 1)).toBe(true);
  });

  test("a hypothesis has no Evidence label, and keeps its next steps", async ({ page }) => {
    await page.goto(url(explained));

    await expect(page.locator("#pd-explanation-view")).not.toContainText("Evidence");
    await expect(page.locator(".xhyp .xlbl")).toHaveText(["Next steps"]);
    await expect(page.locator(".xhyp > p .xcite")).toHaveText(["1", "2", "3"]);
  });

  test("a source marker unfolds its lines below the paragraph and folds them again", async ({ page }) => {
    await page.goto(url(explained));

    const cite = page.locator(".xcite.xsrc");
    const para = page.locator(".xhyp > p");
    await cite.click();
    await expect(cite).toHaveAttribute("aria-expanded", "true");
    const block = page.locator(".xcode");
    await expect(block.locator(".xl")).toHaveCount(3);
    const [p, b] = [await para.boundingBox(), await block.boundingBox()];
    expect(b.y).toBeGreaterThanOrEqual(p.y + p.height - 1);
    await expect(para.locator(".xcode")).toHaveCount(0);

    await cite.click();
    await expect(cite).toHaveAttribute("aria-expanded", "false");
    await expect(block).toHaveCount(0);
  });

  test("an unfolded source block still folds after a citation jump, and marks no element of the run", async ({ page }) => {
    await page.goto(url(explained));

    const cite = page.locator(".xcite.xsrc");
    await cite.click();
    await expect(page.locator(".xcode")).toHaveCount(1);

    await page.locator(".xcite[data-ref]:not(.xsrc)").first().click();
    await expect(page.locator("[data-cite]")).toHaveCount(1);
    await page.locator('#pd-tabs [data-view="explanation"]').click();

    await cite.click();
    await expect(cite).toHaveAttribute("aria-expanded", "false");
    await expect(page.locator(".xcode")).toHaveCount(0);
  });
});

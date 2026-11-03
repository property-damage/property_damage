const { test, expect } = require("@playwright/test");
const { explained, plain, paired, url, watchErrors } = require("./pages");

const selected = (page, view) =>
  expect(page.locator(`#pd-tabs [data-view="${view}"]`)).toHaveAttribute("aria-selected", "true");

test.describe("a page with an explanation", () => {
  test("opens on the Explanation tab and loads without a console error", async ({ page }) => {
    const errors = watchErrors(page);
    await page.goto(url(explained));

    await selected(page, "explanation");
    await expect(page.locator("#pd-explanation-view")).toBeVisible();
    await expect(page.locator("#view")).toBeHidden();
    await expect(page.locator("#pd-explanation-view h3")).toContainText("Hypothesis 1 (likely)");
    expect(errors).toEqual([]);
  });

  test("the tabs switch between the explanation and the run, and back", async ({ page }) => {
    await page.goto(url(explained));

    await page.locator('#pd-tabs [data-view="run"]').click();
    await selected(page, "run");
    await expect(page.locator("#view")).toBeVisible();
    await expect(page.locator("#pd-explanation-view")).toBeHidden();

    await page.locator('#pd-tabs [data-view="explanation"]').click();
    await selected(page, "explanation");
    await expect(page.locator("#pd-explanation-view")).toBeVisible();
    await expect(page.locator("#view")).toBeHidden();
  });

  test("every citation that resolves is a button, none reads as missing", async ({ page }) => {
    await page.goto(url(explained));

    await expect(page.locator(".xcite[data-ref]")).toHaveCount(5);
    await expect(page.locator(".xcite.xnone")).toHaveCount(0);
  });

  test("each non-source citation jumps to its target in the Run view", async ({ page }) => {
    await page.goto(url(explained));

    const ids = await page
      .locator(".xcite[data-ref]:not(.xsrc)")
      .evaluateAll((els) => els.map((e) => e.getAttribute("data-ref")));
    expect(ids.length).toBeGreaterThanOrEqual(3);

    for (const id of ids) {
      await page.locator('#pd-tabs [data-view="explanation"]').click();
      await page.locator(`.xcite[data-ref="${id}"]`).first().click();

      await selected(page, "run");
      const target = page.locator("[data-cite]");
      await expect(target).toHaveCount(1);
      await expect(target).toHaveAttribute("data-cite", id);
      await expect(target).toBeVisible();
      await expect(target).toHaveClass(/xhl/);
    }
  });

  for (const theme of ["light", "dark"]) {
    test(`in the ${theme} theme, the mark on a cited element uses a color nothing else in the page uses`, async ({ page }) => {
      await page.goto(url(explained));
      await page.evaluate((t) => document.documentElement.setAttribute("data-theme", t), theme);
      await page.locator(".xcite[data-ref]:not(.xsrc)").first().click();
      await selected(page, "run");

      const { mark, others } = await page.evaluate(() => {
        const marked = document.querySelector("[data-cite]");
        const mark = getComputedStyle(marked).outlineColor;
        const props = ["color", "backgroundColor", "borderTopColor", "borderRightColor", "borderBottomColor", "borderLeftColor", "outlineColor"];
        const others = new Set();
        for (const el of document.querySelectorAll("body *")) {
          const cs = getComputedStyle(el);
          for (const p of props) {
            if (el === marked && p === "outlineColor") continue;
            if (p === "outlineColor" && cs.outlineStyle === "none") continue;
            if (p.startsWith("border") && cs[p.replace("Color", "Style")] === "none") continue;
            others.add(cs[p]);
          }
        }
        // Every color token of the theme counts too, so a color this page happens not to render is still taken.
        const probe = document.body.appendChild(document.createElement("span"));
        for (const sheet of document.styleSheets)
          for (const rule of sheet.cssRules)
            for (const name of rule.style || [])
              if (name.startsWith("--") && name !== "--cite") {
                probe.style.color = `var(${name})`;
                const c = getComputedStyle(probe).color;
                if (probe.style.color) others.add(c);
              }
        probe.remove();
        return { mark, others: [...others] };
      });

      expect(others).not.toContain(mark);
    });
  }

  test("a source citation unfolds its lines and folds them again", async ({ page }) => {
    await page.goto(url(explained));

    const cite = page.locator(".xcite.xsrc");
    await expect(cite).toHaveAttribute("aria-expanded", "false");
    await cite.click();
    await expect(cite).toHaveAttribute("aria-expanded", "true");
    await expect(page.locator(".xcode .xl")).toHaveCount(3);

    await cite.click();
    await expect(cite).toHaveAttribute("aria-expanded", "false");
    await expect(page.locator(".xcode")).toHaveCount(0);
  });
});

test.describe("citations", () => {
  test("a citation shows a number, and its id is in the tooltip", async ({ page }) => {
    await page.goto(url(explained));

    const resolved = page.locator(".xcite[data-ref]");
    const ids = await resolved.evaluateAll((els) => els.map((e) => e.getAttribute("data-ref")));
    expect(ids.length).toBeGreaterThanOrEqual(3);
    for (let i = 0; i < ids.length; i++) {
      const cite = resolved.nth(i);
      await expect(cite).toHaveText(/^[0-9]+$/);
      expect(await cite.getAttribute("title")).toContain(ids[i]);
      expect(await cite.getAttribute("aria-label")).toContain(ids[i]);
    }
    // numbers restart within each claim: the hypothesis cites three ids
    await expect(page.locator(".xcites").nth(1).locator(".xcite")).toHaveText(["1", "2", "3"]);
  });
});

test.describe("history", () => {
  const tab = (page, view) => page.locator(`#pd-tabs [data-view="${view}"]`);
  const entries = (page) => page.evaluate(() => history.length);

  test("a tab click adds an entry: Back shows the other tab", async ({ page }) => {
    await page.goto(url(explained));
    const length = await entries(page);

    await tab(page, "run").click();
    await selected(page, "run");
    expect(await entries(page)).toBe(length + 1);

    await page.goBack();
    await selected(page, "explanation");
    await expect(page.locator("#pd-explanation-view")).toBeVisible();

    await page.goForward();
    await selected(page, "run");
  });

  test("clicking the tab already shown adds no entry", async ({ page }) => {
    await page.goto(url(explained));
    const length = await entries(page);

    await tab(page, "explanation").click();
    await tab(page, "run").click();
    await tab(page, "run").click();
    expect(await entries(page)).toBe(length + 1);

    await page.goBack();
    await selected(page, "explanation");
    expect(await entries(page)).toBe(length + 1);
  });

  test("Back and Forward walk a citation jump and a tab click, each with its scroll", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 900, height: 300 });
    await page.goto(url(explained));
    await page.evaluate(() => {
      document.body.style.paddingBottom = "3000px";
    });
    const length = await entries(page);

    const cite = page.locator(".xcite[data-ref]:not(.xsrc)").last();
    await cite.scrollIntoViewIfNeeded();
    await page.evaluate(() => window.scrollTo(0, window.scrollY + 120));
    const before = await page.evaluate(() => window.scrollY);
    expect(before).toBeGreaterThan(50);
    const id = await cite.getAttribute("data-ref");

    await cite.click();
    await selected(page, "run");
    await tab(page, "explanation").click();
    await selected(page, "explanation");
    expect(await entries(page)).toBe(length + 2);

    await page.goBack();
    await selected(page, "run");
    await expect(page.locator("[data-cite]")).toHaveAttribute("data-cite", id);

    await page.goBack();
    await selected(page, "explanation");
    await expect.poll(() => page.evaluate(() => window.scrollY)).toBe(before);

    await page.goForward();
    await selected(page, "run");
    await expect(page.locator("[data-cite]")).toHaveAttribute("data-cite", id);

    await page.goForward();
    await selected(page, "explanation");
  });

  test("Run-view actions add no entries", async ({ page }) => {
    await page.goto(url(explained));
    await tab(page, "run").click();
    const length = await entries(page);

    await page.locator("#view .st").first().click();
    await page.keyboard.press("ArrowDown");

    expect(await entries(page)).toBe(length);
  });
});

test.describe("a page of two targets", () => {
  test("the Run view opens with the linking checkbox checked, and it can be unchecked", async ({
    page,
  }) => {
    await page.goto(url(paired));

    const box = page.locator("#linked");
    await expect(box).toBeChecked();
    await box.uncheck();
    await expect(box).not.toBeChecked();
  });
});

test.describe("a page without an explanation", () => {
  test("opens on the Run view, with no tabs and no console error", async ({ page }) => {
    const errors = watchErrors(page);
    await page.goto(url(plain));

    await expect(page.locator("#view .facts").first()).toBeVisible();
    await expect(page.locator("#pd-tabs")).toHaveCount(0);
    expect(errors).toEqual([]);
  });
});

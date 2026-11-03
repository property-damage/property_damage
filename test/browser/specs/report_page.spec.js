const { test, expect } = require("@playwright/test");
const { explained, plain, url, watchErrors } = require("./pages");

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

test.describe("a page without an explanation", () => {
  test("opens on the Run view, with no tabs and no console error", async ({ page }) => {
    const errors = watchErrors(page);
    await page.goto(url(plain));

    await expect(page.locator("#view .facts").first()).toBeVisible();
    await expect(page.locator("#pd-tabs")).toHaveCount(0);
    expect(errors).toEqual([]);
  });
});

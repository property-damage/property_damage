// Shared helpers: where the generated pages are, and what they hold.
const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");

const dir = process.env.PD_PAGES_DIR;
if (!dir || !fs.existsSync(path.join(dir, "index.html"))) {
  throw new Error("set PD_PAGES_DIR to a directory written by generate_pages.exs");
}

const files = fs
  .readdirSync(dir)
  .filter((f) => f.endsWith(".html") && f !== "index.html")
  .sort();

// The generator explains the check failure only; the other page has no
// explanation, whatever its kind is named.
const explained = files.find((f) => f.includes("check_failed"));
const plain = files.find((f) => f.includes("bob"));

// The page of a run with two targets, which has the Run view's linking checkbox.
const paired = files.find((f) => f.includes("PairModel"));

// The page of a run whose targets ran roots as a kept entry, as leaves and not at all.
const expanded = files.find((f) => f.includes("ExpandModel"));

const url = (file) => pathToFileURL(path.join(dir, file)).href;

// Collects what a page logs as an error, so a spec can assert there is none.
function watchErrors(page) {
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e.message)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push(m.text());
  });
  return errors;
}

module.exports = { dir, files, explained, plain, paired, expanded, url, watchErrors };

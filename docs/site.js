// Schnellbild's website: what moves while scrolling (see site.css). No libraries.
// The "js" class hides what rises in, so it is set only where the observer
// that shows it again exists; elsewhere the page simply stands still.
if ("IntersectionObserver" in window) {
  document.documentElement.classList.add("js");

  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Sections rise in once they come into view.
  const reveal = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add("in");
      reveal.unobserve(entry.target);
    }
  }, { rootMargin: "0px 0px -8% 0px" });
  document.querySelectorAll("[data-reveal]").forEach((element) => reveal.observe(element));

  // Numbers count up when they arrive ("20" → 0 … 20), the rest of the text stays.
  const counter = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      counter.unobserve(entry.target);
      const match = entry.target.textContent.match(/^(\d+)(.*)$/);
      const target = match ? Number(match[1]) : 0;
      if (still || target < 2) continue;
      const start = performance.now();
      const step = (now) => {
        const t = Math.min(1, (now - start) / 1200);
        entry.target.textContent = Math.round(target * (1 - Math.pow(1 - t, 3))) + match[2];
        if (t < 1) requestAnimationFrame(step);
      };
      requestAnimationFrame(step);
    }
  });
  document.querySelectorAll(".stat b").forEach((element) => counter.observe(element));

  // Close the language menu when clicking or tabbing elsewhere, or with Escape.
  function closeMenus(keep) {
    document.querySelectorAll("details.lang[open]").forEach((menu) => {
      if (!keep || !menu.contains(keep)) menu.removeAttribute("open");
    });
  }
  document.addEventListener("click", (event) => closeMenus(event.target));
  document.addEventListener("focusin", (event) => closeMenus(event.target));
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    const open = document.querySelector("details.lang[open]");
    if (!open) return;
    open.removeAttribute("open");
    open.querySelector("summary").focus();
  });

  // The bar gets its glass once the page moves; the hero screenshot straightens
  // up (--p 0 → 1) and screenshots drift with their place on screen (--d -1 … 1).
  const hero = document.querySelector(".hero");
  const drifting = [...document.querySelectorAll("[data-parallax]")];
  let queued = false;
  function update() {
    queued = false;
    const y = scrollY;
    const height = innerHeight;
    document.body.classList.toggle("scrolled", y > 8);
    if (still) return;
    if (hero) hero.style.setProperty("--p", Math.min(1, y / (height * 0.45)).toFixed(3));
    for (const element of drifting) {
      const box = element.getBoundingClientRect();
      if (box.bottom < -100 || box.top > height + 100) continue;
      const offset = (box.top + box.height / 2 - height / 2) / height;
      element.style.setProperty("--d", Math.max(-1, Math.min(1, offset)).toFixed(3));
    }
  }
  addEventListener("scroll", () => {
    if (!queued) { queued = true; requestAnimationFrame(update); }
  }, { passive: true });
  addEventListener("resize", update);
  update();
}

// Light or dark: the system's choice until the visitor picks with the switch in
// the bar (kept in localStorage; picking what the system shows forgets it again).
// The head sets data-theme before the page is drawn; here the screenshots' and
// the browser bar's media queries follow a choice too.
(() => {
  const root = document.documentElement;
  const systemDark = matchMedia("(prefers-color-scheme: dark)");
  const button = document.querySelector("button.theme");
  const shown = () => root.dataset.theme || (systemDark.matches ? "dark" : "light");
  function apply() {
    const picked = root.dataset.theme;
    // data-media keeps a source's own query while a choice has set it to "all" / "not all"
    document.querySelectorAll('source[media*="prefers-color-scheme"], source[data-media], meta[name="theme-color"]').forEach((element) => {
      if (!element.dataset.media) element.dataset.media = element.getAttribute("media");
      const forDark = element.dataset.media.includes("dark");
      element.setAttribute("media", picked ? ((picked === "dark") === forDark ? "all" : "not all") : element.dataset.media);
    });
    if (button) {
      const label = button.dataset[shown() === "dark" ? "light" : "dark"];
      button.setAttribute("aria-label", label);
      button.title = label;
    }
  }
  if (button) {
    root.classList.add("theme-switch");
    button.addEventListener("click", () => {
      const next = shown() === "dark" ? "light" : "dark";
      const system = systemDark.matches ? "dark" : "light";
      try {
        if (next === system) localStorage.removeItem("theme"); else localStorage.setItem("theme", next);
      } catch (error) { /* storage blocked: the choice lasts for this page */ }
      if (next === system) delete root.dataset.theme; else root.dataset.theme = next;
      apply();
    });
  }
  systemDark.addEventListener("change", apply);
  apply();
})();

// Screenshots open large in a dialog: ← → step through all of them, a click or Esc closes.
(() => {
  const shots = [...document.querySelectorAll(".shot img, .media img")];
  if (!shots.length || !("HTMLDialogElement" in window)) return;
  const labels = document.body.dataset;
  const dialog = document.createElement("dialog");
  dialog.className = "lightbox";
  const large = document.createElement("img");
  const close = document.createElement("button");
  close.type = "button";
  close.className = "close";
  close.textContent = "×";
  close.setAttribute("aria-label", labels.close || "Close");
  dialog.append(large, close);
  document.body.append(dialog);
  let index = 0;
  // The page shows each screenshot as wide as its place needs; the dialog loads the
  // widest (the last of a srcset) of the source the browser would take: the format it
  // took for a screenshot already there (AVIF, WebP or the PNG), the theme shown. So
  // ← → also reach screenshots that haven't loaded yet.
  function format() {
    const loaded = shots.map((shot) => shot.currentSrc).find(Boolean) || "";
    const match = loaded.match(/\.(avif|webp)$/);
    return match ? `image/${match[1]}` : "";
  }
  function widest(shot) {
    const type = format();
    const picture = shot.parentElement;
    const sources = picture && picture.tagName === "PICTURE" ? [...picture.querySelectorAll("source")] : [];
    const source = sources.find((source) =>
      (source.type || "") === type && (!source.media || matchMedia(source.media).matches));
    return source ? source.srcset.split(",").pop().trim().split(/\s+/)[0] : shot.currentSrc || shot.src;
  }
  function show(at) {
    index = (at + shots.length) % shots.length;
    const shot = shots[index];
    large.src = widest(shot);
    large.alt = shot.alt;
  }
  shots.forEach((shot, at) => {
    shot.classList.add("zoomable");
    shot.tabIndex = 0;
    shot.setAttribute("role", "button");
    shot.setAttribute("aria-label", `${labels.enlarge || "Enlarge"}: ${shot.alt}`);
    const open = () => { show(at); dialog.showModal(); };
    shot.addEventListener("click", open);
    shot.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") { event.preventDefault(); open(); }
    });
  });
  dialog.addEventListener("click", () => dialog.close());
  dialog.addEventListener("keydown", (event) => {
    if (event.key === "ArrowRight") { event.preventDefault(); show(index + 1); }
    if (event.key === "ArrowLeft") { event.preventDefault(); show(index - 1); }
  });
})();

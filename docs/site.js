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

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

  // The demo video plays muted while it is on screen and stops when it leaves;
  // with "reduce motion" it keeps its controls and waits for a click.
  if (!still) {
    const playing = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) entry.target.play().catch(() => { entry.target.controls = true; });
        else entry.target.pause();
      }
    }, { threshold: 0.4 });
    document.querySelectorAll("video.demo").forEach((video) => {
      video.controls = false;
      video.muted = true;
      playing.observe(video);
    });
  }

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
    // data-media keeps a source's own query while a choice has changed it
    document.querySelectorAll('source[media*="prefers-color-scheme"], source[data-media], meta[name="theme-color"]').forEach((element) => {
      if (!element.dataset.media) element.dataset.media = element.getAttribute("media");
      const own = element.dataset.media;
      const forDark = own.includes("dark");
      // the theme's part of the query becomes "all" or the whole query "not all"; the
      // rest of it (the globe's phone picture: "and (max-width: 640px)") stays
      const rest = own.replace(/\(prefers-color-scheme: (dark|light)\)/, "all");
      element.setAttribute("media", picked ? ((picked === "dark") === forDark ? rest : "not all") : own);
    });
    if (button) {
      const label = button.dataset[shown() === "dark" ? "light" : "dark"];
      button.setAttribute("aria-label", label);
      button.title = label;
    }
    document.dispatchEvent(new Event("themeshown"));
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

// The video's still carries the video playing, the badge and the bar moving along
// (build_site.py motion): the theme's video (data-light / data-dark: "url|type,…"),
// shown once it plays, while it is on screen. With "reduce motion" (site.css hides
// it) or without script the still stands alone.
const motion = (() => {
  const root = document.documentElement;
  const systemDark = matchMedia("(prefers-color-scheme: dark)");
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const theme = () => root.dataset.theme || (systemDark.matches ? "dark" : "light");
  // The sources of the theme shown, in `video` (another video's when given)
  function use(video, from = video) {
    const list = from.dataset[theme()];
    if (!list || video.dataset.shown === list) return;
    video.dataset.shown = list;
    video.classList.remove("on");
    video.replaceChildren(...list.split(",").map((entry) => {
      const [src, type] = entry.split("|");
      const source = document.createElement("source");
      source.src = src;
      source.type = type;
      return source;
    }));
    video.load();
  }
  function play(video) {
    if (!still) video.play().catch(() => {});
  }
  const videos = [...document.querySelectorAll("video.motion")];
  if (!still && videos.length && "IntersectionObserver" in window) {
    const seen = new Set();
    const watch = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) { seen.add(entry.target); use(entry.target); play(entry.target); }
        else { seen.delete(entry.target); entry.target.pause(); }
      }
    }, { threshold: 0.25 });
    videos.forEach((video) => {
      video.addEventListener("playing", () => video.classList.add("on"));
      watch.observe(video);
    });
    document.addEventListener("themeshown", () => seen.forEach((video) => { use(video); play(video); }));
  }
  return { use, play, still };
})();

// Screenshots open large in a dialog: ← → step through all of them, a click or Esc closes.
// The video's still opens with the video playing over it, as on the page.
(() => {
  const shots = [...document.querySelectorAll(".shot img, .views img, .media img")];
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
  const frame = document.createElement("span");
  frame.className = "playing";
  const moving = document.createElement("video");
  moving.className = "motion";
  moving.muted = true;
  moving.loop = true;
  moving.playsInline = true;
  moving.setAttribute("aria-hidden", "true");
  moving.addEventListener("playing", () => moving.classList.add("on"));
  frame.append(large, moving);
  dialog.append(frame, close);
  document.body.append(dialog);
  let index = 0;
  let source = null;   // the page's video over the still shown
  // The page shows each screenshot as wide as its place needs; the dialog loads the
  // widest (the last of a srcset) of the source the browser would take for the theme
  // shown. So ← → also reach screenshots that haven't loaded yet.
  function widest(shot) {
    const picture = shot.parentElement;
    const sources = picture && picture.tagName === "PICTURE" ? [...picture.querySelectorAll("source")] : [];
    const source = sources.find((source) => !source.media || matchMedia(source.media).matches);
    return source ? source.srcset.split(",").pop().trim().split(/\s+/)[0] : shot.currentSrc || shot.src;
  }
  function show(at) {
    index = (at + shots.length) % shots.length;
    const shot = shots[index];
    large.src = widest(shot);
    large.alt = shot.alt;
    source = shot.closest(".playing")?.querySelector("video.motion") || null;
    moving.hidden = !source || motion.still;
    if (moving.hidden) {
      moving.pause();
      return;
    }
    moving.style.cssText = source.style.cssText;
    motion.use(moving, source);
    motion.play(moving);
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
  dialog.addEventListener("close", () => moving.pause());
  dialog.addEventListener("keydown", (event) => {
    if (event.key === "ArrowRight") { event.preventDefault(); show(index + 1); }
    if (event.key === "ArrowLeft") { event.preventDefault(); show(index - 1); }
  });
  document.addEventListener("themeshown", () => {
    if (dialog.open && source && !moving.hidden) { motion.use(moving, source); motion.play(moving); }
  });
})();

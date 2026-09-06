"use strict";
(() => {
  for (const node of document.querySelectorAll("[data-tex]")) {
    const tex = node.dataset.tex;
    try {
      katex.render(tex, node, {
        displayMode: node.dataset.display === "true",
        output: "htmlAndMathml", throwOnError: true, trust: false,
        strict: "ignore", maxExpand: 1000, maxSize: 20,
        macros: {} // A formula cannot redefine commands in another formula.
      });
    } catch (_) {
      // Never drop content or disguise a partial conversion as valid math.
      node.classList.add("math-fallback");
      node.textContent = tex;
      node.title = "此公式暂不支持完整排版；保留原始 LaTeX";
      node.setAttribute("aria-label", node.title + ": " + tex);
    }
  }
  function reportScroll() {
    // Scroll events are already frame-coalesced. Do not depend on animation
    // frames, which WebKit suspends in occluded or offscreen app windows.
    const root = document.scrollingElement;
    window.webkit.messageHandlers.readerScroll.postMessage({
      top: root.scrollTop, total: root.scrollHeight, height: root.clientHeight
    });
  }
  window.addEventListener("scroll", reportScroll, { passive: true });
  window.addEventListener("resize", reportScroll);
  new ResizeObserver(reportScroll).observe(document.querySelector("main"));
  document.fonts.ready.then(() => { document.body.dataset.ready = "true"; reportScroll(); });
  reportScroll();
})();

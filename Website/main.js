const BRAND = { name: "OpenDuckFrame", logo: "assets/icon.png" };

const COPY = {
  zh: {
    meta: "在 Mac 上实时补帧和超分。24 帧变成 48 帧，低分辨率画面放大到屏幕分辨率，全部在本地完成。",
    ariaNav: "页面章节",
    ariaFoot: "页脚",
    ariaLang: "切换语言",
    navHow: "怎么工作",
    navUses: "使用场景",
    navFaq: "常见问题",
    h1a: "让 Mac 上的画面",
    h1b: "更流畅、更清晰",
    sub: "实时补帧，把 24 帧变成 48 帧；实时超分，把低分辨率画面放大到屏幕分辨率。网页视频、下载的视频、游戏和串流画面都能用，全部在本地完成。",
    download: "下载 Mac 版（即将推出）",
    seeHow: "看看原理",
    demoTitle: "预览",
    srcLabel: "原始 24 fps",
    outLabel: "补帧后 48 fps",
    demoNote: "示意动画，非实机录屏",
    howTitle: "它是怎么工作的",
    howBefore: "选一个窗口，",
    howAfter: "在它上面叠一层输出画面。采集、识别帧率、补帧、显示，全部在你的 Mac 上完成。",
    how1t: "识别真实帧率",
    how1d: "只数画面真正变化的帧，24 帧的视频按 24 帧算，不会被 120 Hz 刷新率骗到。",
    how2t: "补帧和超分",
    how2d: "2 倍、3 倍补帧，24 → 48、30 → 60；低分辨率画面实时放大，细节更清楚。",
    how3t: "算力不够自动降档",
    how3d: "跟不上时退到更低倍率，避免画面忽快忽慢。",
    how4t: "到屏幕上限就直通",
    how4d: "内容乘倍率超过屏幕刷新率时直接显示原画，不让显卡白忙。",
    how5t: "跟着窗口走",
    how5d: "输出贴在原窗口的位置，窗口挪到哪里跟到哪里。",
    how6t: "全部本地处理",
    how6d: "采集和模型都在本机运行，画面不上传。",
    how7t: "帧率一眼看清",
    how7d: "角落的小面板实时显示内容帧率、输出帧率和当前倍率。",
    usesTitle: "适合用在哪",
    usesLede: "四个最常用的场景，也可以选任何窗口试试。",
    use1t: "网页视频",
    use1d: "浏览器里的视频网站，普通窗口或网页全屏都行，24 帧补到 48 帧。",
    use2t: "下载的视频",
    use2d: "播放器里的电影和剧集，镜头平移不再一顿一顿，低清片源也能放大得更清楚。",
    use3t: "游戏超分",
    use3d: "用较低分辨率跑游戏，换更高帧率，再实时放大到屏幕分辨率，清晰和流畅兼顾。",
    use4t: "Windows 游戏串流到 Mac",
    use4d: "用串流软件把 Windows 电脑上的游戏投到 Mac，在 Mac 上超分，串流画面更清晰。",
    use5t: "任意窗口",
    use5d: "别的窗口也能选，效果自己看。",
    faqTitle: "常见问题",
    faqLede: "还有别的问题？",
    faqContact: "到 GitHub 提交问题",
    faq1before: "",
    faq1after: "是什么？",
    faq1a: "一款 Mac 上的实时补帧和超分应用。它识别窗口里画面的真实帧率，用本地 AI 模型补出中间帧，也能把低分辨率画面实时放大，让视频、游戏和串流画面更流畅、更清晰。",
    faq2q: "需要什么样的 Mac？",
    faq2a: "Apple 芯片的 Mac，macOS 14 或更高版本。Apple 帧率转换等部分引擎需要 macOS 26。",
    faq3q: "会增加延迟吗？",
    faq3a: "会。补帧要等到下一帧画面才能算中间帧。2 倍补帧时，从采集到显示实测约 70–80 毫秒，看视频没问题，不适合竞技游戏。",
    faq4q: "支持全屏吗？",
    faq4a: "目前支持普通窗口和网页全屏。macOS 原生全屏还在开发中。",
    faq5q: "画面会上传吗？",
    faq5a: "不会。采集、识别和补帧都在你的 Mac 上完成。",
    faq6q: "多少钱？",
    faq6a: "免费。源代码以 MIT 许可公开在 GitHub 上。",
    getTitle: "想第一时间用上？",
    getAfter: "正在打磨中，Mac 版即将推出。",
    privacy: "隐私",
    contact: "联系我们",
  },
  en: {
    meta: "Real-time frame interpolation and upscaling on Mac. 24 fps becomes 48, and a low-resolution picture is enlarged to the display resolution. All of it stays on this Mac.",
    ariaNav: "Sections",
    ariaFoot: "Footer",
    ariaLang: "Switch language",
    navHow: "How it works",
    navUses: "Use cases",
    navFaq: "Questions",
    h1a: "Make the picture on Mac",
    h1b: "smoother and clearer",
    sub: "Real-time interpolation turns 24 fps into 48. Real-time upscaling enlarges a low-resolution picture to the display resolution. Web video, downloaded video, games, and streamed pictures all work, and everything is done locally on this Mac.",
    download: "Download for Mac (coming soon)",
    seeHow: "See how it works",
    demoTitle: "Preview",
    srcLabel: "Source 24 fps",
    outLabel: "Interpolated 48 fps",
    demoNote: "Illustrative animation, not a real screen recording.",
    howTitle: "How it works",
    howBefore: "Pick a window, and ",
    howAfter: " lays an output picture over it. Capture, frame-rate detection, interpolation, and display all happen on your Mac.",
    how1t: "Read the real frame rate",
    how1d: "It counts only frames where the picture actually changes. A 24 fps video stays 24 fps, and a 120 Hz refresh rate does not fool it.",
    how2t: "Interpolation and upscaling",
    how2d: "2× and 3× interpolation, 24 → 48 and 30 → 60. A low-resolution picture is enlarged in real time, with clearer detail.",
    how3t: "Steps down when the Mac falls behind",
    how3d: "If it cannot keep up, it drops to a lower multiple so the picture does not speed up and slow down.",
    how4t: "Passes through at the screen limit",
    how4d: "When the content times the multiple would pass the display refresh rate, it shows the original picture and does not keep the GPU busy for nothing.",
    how5t: "Follows the window",
    how5d: "The output sits on the original window and moves wherever that window moves.",
    how6t: "Processed entirely on device",
    how6d: "Capture and the model both run on this Mac. The picture is not uploaded.",
    how7t: "Frame rate in the corner",
    how7d: "A small panel shows the content frame rate, the output frame rate, and the current multiple, live.",
    usesTitle: "Where it fits",
    usesLede: "Four everyday cases, or pick any window and try it.",
    use1t: "Web video",
    use1d: "Video sites in the browser, in a normal window or in web fullscreen, with 24 fps filled in to 48.",
    use2t: "Downloaded video",
    use2d: "Films and series in a player. Camera pans no longer step along, and a low-resolution source can be enlarged more clearly.",
    use3t: "Game upscaling",
    use3d: "Run a game at a lower resolution for a higher frame rate, then enlarge it to the display resolution in real time, so it stays both clear and smooth.",
    use4t: "Windows games streamed to a Mac",
    use4d: "Use streaming software to send a game from a Windows PC to a Mac, then upscale it on the Mac so the streamed picture is clearer.",
    use5t: "Any window",
    use5d: "Other windows can be selected too. Judge the result yourself.",
    faqTitle: "Common questions",
    faqLede: "Other questions?",
    faqContact: "Open an issue on GitHub",
    faq1before: "What is ",
    faq1after: "?",
    faq1a: "A real-time frame interpolation and upscaling app for Mac. It reads the real frame rate of the picture in a window, uses an on-device AI model to draw the frames in between, and can enlarge a low-resolution picture in real time, so video, games, and streamed pictures look smoother and clearer.",
    faq2q: "What kind of Mac does it need?",
    faq2a: "A Mac with Apple silicon running macOS 14 or later. Some engines, such as Apple frame-rate conversion, need macOS 26.",
    faq3q: "Does it add latency?",
    faq3a: "Yes. Interpolation has to wait for the next frame before it can draw the one in between. At 2×, the measured time from capture to display is about 70–80 milliseconds. Fine for watching video, and a poor fit for competitive games.",
    faq4q: "Does fullscreen work?",
    faq4a: "Normal windows and web fullscreen work today. Native macOS fullscreen is still in development.",
    faq5q: "Is the picture uploaded?",
    faq5a: "No. Capture, detection, and interpolation all happen on your Mac.",
    faq6q: "How much does it cost?",
    faq6a: "Free. The source code is published on GitHub under the MIT License.",
    getTitle: "Want it as soon as it is ready?",
    getAfter: " is still being polished. The Mac version is coming soon.",
    privacy: "Privacy",
    contact: "Contact",
  },
};

function brandName() {
  if (typeof BRAND.name === "string" && BRAND.name.trim() !== "") return BRAND.name;
  return "OpenDuckFrame";
}

function resolvedTheme() {
  const explicit = document.documentElement.getAttribute("data-theme");
  if (explicit === "dark" || explicit === "light") return explicit;
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function applyBrand() {
  const name = brandName();
  document.querySelectorAll("[data-brand-name]").forEach((el) => {
    el.textContent = name;
  });
  const logo = typeof BRAND.logo === "string" ? BRAND.logo.trim() : "";
  document.querySelectorAll(".logo-slot").forEach((slot) => {
    slot.replaceChildren();
    slot.classList.toggle("has-logo", logo !== "");
    if (!logo) return;
    const img = document.createElement("img");
    img.src = logo;
    img.alt = "";
    slot.append(img);
  });
}

function applyThemeLabel() {
  const btn = document.querySelector('[data-action="theme"]');
  if (!btn) return;
  const toDark = resolvedTheme() !== "dark";
  const en = document.documentElement.lang === "en";
  btn.setAttribute(
    "aria-label",
    en ? (toDark ? "Switch to dark" : "Switch to light") : (toDark ? "切换到深色" : "切换到浅色"),
  );
}

function applyLang(next) {
  const dict = COPY[next] || COPY.zh;
  document.documentElement.lang = next === "en" ? "en" : "zh-CN";
  document.querySelectorAll("[data-i18n]").forEach((el) => {
    const key = el.getAttribute("data-i18n");
    if (dict[key] != null) el.textContent = dict[key];
  });
  document.querySelectorAll("[data-i18n-aria]").forEach((el) => {
    const key = el.getAttribute("data-i18n-aria");
    if (dict[key] != null) el.setAttribute("aria-label", dict[key]);
  });
  applyBrand();
  const name = brandName();
  document.title = next === "en"
    ? `${name} · Real-time interpolation and upscaling for Mac`
    : `${name} · Mac 实时补帧与超分`;
  const meta = document.querySelector('meta[name="description"]');
  if (meta && dict.meta) meta.setAttribute("content", dict.meta);
  const langBtn = document.querySelector('[data-action="lang"]');
  if (langBtn) {
    langBtn.textContent = next === "en" ? "EN / ZH" : "中 / EN";
    if (dict.ariaLang) langBtn.setAttribute("aria-label", dict.ariaLang);
  }
  applyThemeLabel();
}

function bindControls() {
  const langBtn = document.querySelector('[data-action="lang"]');
  if (langBtn) {
    langBtn.addEventListener("click", () => {
      applyLang(document.documentElement.lang === "en" ? "zh" : "en");
    });
  }
  const themeBtn = document.querySelector('[data-action="theme"]');
  if (themeBtn) {
    themeBtn.addEventListener("click", () => {
      const next = resolvedTheme() === "dark" ? "light" : "dark";
      document.documentElement.setAttribute("data-theme", next);
      applyThemeLabel();
    });
  }
  document.querySelectorAll('[data-cta="download"]').forEach((btn) => {
    btn.addEventListener("click", (event) => {
      event.preventDefault();
    });
  });
  const faq = document.querySelector("#faq");
  if (!faq) return;
  faq.addEventListener("click", (event) => {
    const button = event.target.closest("[data-faq] button");
    if (!button || !faq.contains(button)) return;
    const expanded = button.getAttribute("aria-expanded") === "true";
    button.setAttribute("aria-expanded", expanded ? "false" : "true");
    const panel = document.getElementById(button.getAttribute("aria-controls"));
    if (panel) panel.setAttribute("aria-hidden", expanded ? "true" : "false");
    const item = button.closest("[data-faq]");
    if (item) item.classList.toggle("open", !expanded);
  });
}

function startDemo() {
  const source = document.querySelector('[data-demo="source"]');
  const output = document.querySelector('[data-demo="output"]');
  if (!source || !output) return;
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
  const SOURCE_FPS = 24;
  const CYCLE_MS = 2000;
  const SOURCE_FRAMES = SOURCE_FPS * (CYCLE_MS / 1000);
  const TRAIL = 6;

  function makeGhosts(ball) {
    const ghosts = [];
    for (let i = 0; i < TRAIL; i += 1) {
      const ghost = document.createElement("span");
      ghost.className = "ghost";
      ghost.setAttribute("aria-hidden", "true");
      ball.parentElement.insertBefore(ghost, ball);
      ghosts.push(ghost);
    }
    return ghosts;
  }

  const sourceGhosts = makeGhosts(source);
  const outputGhosts = makeGhosts(output);

  function move(el, phase, opacity) {
    const stage = el.parentElement;
    const width = stage.clientWidth;
    const inset = 18;
    const travel = Math.max(0, width - el.offsetWidth - inset * 2);
    el.style.transform = `translateX(${(inset + travel * phase).toFixed(2)}px)`;
    if (opacity != null) el.style.opacity = String(opacity);
  }

  function paintTrail(ghosts, hist) {
    ghosts.forEach((ghost, index) => {
      const phase = hist[index];
      if (phase == null) {
        ghost.style.opacity = "0";
        return;
      }
      move(ghost, phase, 0.34 * Math.pow(0.62, index));
    });
  }

  function park() {
    move(source, 0.42);
    move(output, 0.42);
    sourceGhosts.concat(outputGhosts).forEach((ghost) => {
      ghost.style.opacity = "0";
    });
  }

  let running = false;
  function loop() {
    if (running) return;
    if (reduce.matches) {
      park();
      return;
    }
    running = true;
    const origin = performance.now();
    let lastFrame = -1;
    const sourceHist = [];
    const outputHist = [];

    function push(hist, phase) {
      if (hist.length && phase + 0.25 < hist[0]) hist.length = 0;
      hist.unshift(phase);
      if (hist.length > TRAIL) hist.length = TRAIL;
    }

    function frame(now) {
      if (reduce.matches) {
        running = false;
        park();
        return;
      }
      const elapsed = now - origin;
      const outPhase = (elapsed % CYCLE_MS) / CYCLE_MS;
      const sourceFrame = Math.floor(elapsed / (1000 / SOURCE_FPS));
      const srcPhase = (sourceFrame % SOURCE_FRAMES) / SOURCE_FRAMES;
      move(output, outPhase);
      move(source, srcPhase);
      push(outputHist, outPhase);
      if (sourceFrame !== lastFrame) {
        push(sourceHist, srcPhase);
        lastFrame = sourceFrame;
      }
      paintTrail(outputGhosts, outputHist);
      paintTrail(sourceGhosts, sourceHist);
      requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }

  reduce.addEventListener("change", () => {
    running = false;
    loop();
  });
  loop();
}

applyLang("zh");
bindControls();
startDemo();

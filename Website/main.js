const BRAND = { name: "OpenDuckFrame", logo: "assets/openduckframe-icon.png" };

const COPY = {
  "zh": {
    "meta": "OpenDuckFrame（开源小鸭），Mac 实时补帧与超分应用。支持窗口、显示器和本地视频，Apple 与 RIFE 插帧，画面在本机处理，MIT 开源。",
    "browserBadge": "浏览器窗口",
    "ariaNav": "页面章节",
    "ariaFoot": "页脚",
    "ariaLang": "切换语言",
    "navHow": "怎么工作",
    "navUses": "使用场景",
    "navFaq": "常见问题",
    "h1a": "让 Mac 上的画面",
    "h1b": "更流畅、更清晰",
    "sub": "给正在看的画面补帧，给低分辨率内容超分。浏览器、游戏、串流窗口和本地视频，在一个工作台里设置，全部在你的 Mac 上处理。",
    "download": "获取开源 Mac 版",
    "seeHow": "使用指南",
    "demoTitle": "预览",
    "srcLabel": "原始 24 fps",
    "outLabel": "补帧后 48 fps",
    "demoNote": "示意动画，非实机录屏",
    "howTitle": "它是怎么工作的",
    "howBefore": "选好画面来源，",
    "howAfter": "把采集、补帧、超分与显示连在一起。根据内容和设备选择技术，也可以只开启其中一项。",
    "how1t": "选择画面来源",
    "how1d": "选窗口、显示器或视频文件。网页视频和串流可通过对应的应用窗口接入。",
    "how2t": "选择补帧与超分技术",
    "how2d": "Apple 插帧与 RIFE 可选；Lanczos、MetalFX 等负责放大画面。可用技术随系统、硬件和输入变化。",
    "how3t": "找到合适的处理档位",
    "how3d": "设置目标帧率或 X2 / X3 / X4。跟不上时，可以降低分辨率、倍率，或切换更轻的引擎。",
    "how4t": "按显示器能力输出",
    "how4d": "实际呈现受屏幕刷新率和处理预算限制。请求的倍率与最终看到的帧率分别显示。",
    "how5t": "让输出跟随你的观看方式",
    "how5d": "跟随来源窗口，或在指定显示器全屏输出。把常用设置保存成配置，下次直接切换。",
    "how6t": "全部本地处理",
    "how6d": "采集和模型都在本机运行，画面不上传。",
    "how7t": "看实际输出，再判断效果",
    "how7d": "查看帧率显示，在原始、增强和对比视图之间切换，用自己的内容判断画质和流畅度。",
    "usesTitle": "适合用在哪",
    "usesLede": "视频、游戏和串流，各有适合的处理方式。",
    "use1t": "网页视频",
    "use1d": "选择浏览器里的视频窗口，在本机补帧和放大画面。受保护的视频可能无法采集。",
    "use2t": "本地视频",
    "use2d": "直接打开 MKV、MP4、MOV 等文件，配合字幕播放，再按片源选择补帧和超分。",
    "use3t": "游戏超分",
    "use3d": "将游戏窗口作为来源，用 MetalFX 或 Lanczos 放大画面；补帧是否合适，需要结合游戏节奏与延迟判断。",
    "use4t": "Windows 游戏串流到 Mac",
    "use4d": "先用你熟悉的串流软件将 PC 画面传到 Mac，再选择串流窗口进行增强。",
    "use5t": "从你正在看的窗口开始",
    "use5d": "选择来源、设置技术、对比画面。常用设置可以保存下来。",
    "faqTitle": "常见问题",
    "faqLede": "还有别的问题？",
    "faqContact": "到 GitHub 交流",
    "faq1before": "",
    "faq1after": "是什么？",
    "faq1a": "OpenDuckFrame（开源小鸭）是一款原生 Mac 实时补帧与超分应用。它可以处理窗口、显示器或本地视频，也带有支持字幕、Quick Look 和多种格式的视频播放器。",
    "faq2q": "需要什么样的 Mac？",
    "faq2a": "需要 Apple 芯片 Mac，基础播放要求 macOS 14 或更高版本。Apple 插帧、Apple 超分与字幕生成翻译需要 macOS 26 或更高版本及支持的硬件。部分实验技术还需要额外模型或更新的系统。",
    "faq3q": "会增加延迟吗？",
    "faq3a": "会增加处理延迟，具体取决于引擎、来源分辨率和质量设置。不同算法对前后帧的需求也不同。看视频与玩游戏对延迟的容忍度不同，建议先用原始和增强视图对比自己的内容。",
    "faq4q": "支持全屏吗？",
    "faq4a": "可以选择输出显示器并使用全屏输出。来源窗口的原生全屏、网页全屏和遮挡行为会因应用与 macOS 而异；遇到问题时可先退回普通窗口或重新选择来源。",
    "faq5q": "画面会上传吗？",
    "faq5a": "不会。采集画面、视频和字幕内容都在你的 Mac 上处理。无需账号，没有播放统计。系统字幕服务首次使用时，macOS 可能下载所需的语言模型。",
    "faq6q": "是免费开源的吗？",
    "faq6a": "是。OpenDuckFrame 自有代码采用 MIT 许可证，可以免费获取、修改和构建。第三方库和模型分别遵循各自的许可证，完整说明在 GitHub 仓库中。",
    "getTitle": "让你正在看的内容，更合心意",
    "getAfter": " 现已开源。按你的内容，选择合适的补帧与超分。",
    "privacy": "隐私",
    "contact": "反馈问题",
    "requirements": "Apple 芯片 · macOS 14+ · MIT 开源",
    "sourceNote": "当前可从源码构建，打包版本请关注",
    "releases": "版本发布",
    "productTitle": "按内容选择技术，在一个工作台里完成",
    "productCaption": "OpenDuckFrame v0.1.0 实机技术库界面。部分实验技术需要额外模型或运行库。",
    "source": "源码"
  },
  "en": {
    "meta": "OpenDuckFrame is an open-source Mac app for real-time frame generation and upscaling. Enhance windows, displays and local videos on your Mac. MIT licensed.",
    "browserBadge": "Browser window",
    "ariaNav": "Sections",
    "ariaFoot": "Footer",
    "ariaLang": "Switch language",
    "navHow": "How it works",
    "navUses": "Use cases",
    "navFaq": "Questions",
    "h1a": "Make the picture on Mac",
    "h1b": "smoother and clearer",
    "sub": "Generate in-between frames and upscale lower-resolution pictures. Browser video, games, streamed windows and local files, configured in one workbench and processed on your Mac.",
    "download": "Get the open-source Mac app",
    "seeHow": "Getting started",
    "demoTitle": "Preview",
    "srcLabel": "Source 24 fps",
    "outLabel": "Interpolated 48 fps",
    "demoNote": "Illustrative animation, not a real screen recording.",
    "howTitle": "How it works",
    "howBefore": "Choose your source. ",
    "howAfter": " connects capture, frame generation, upscaling and output. Pick a backend for your content and Mac, or enable just one enhancement.",
    "how1t": "Choose your picture",
    "how1d": "Select a window, display or video file. Web video and streams come in through their application windows.",
    "how2t": "Pick your enhancement",
    "how2d": "Choose Apple interpolation or RIFE, and scaling with Lanczos, MetalFX and more. Availability depends on the system, hardware and input.",
    "how3t": "Find a suitable processing mode",
    "how3d": "Set a target frame rate or X2 / X3 / X4. If output falls behind, reduce resolution or the multiplier, or choose a lighter engine.",
    "how4t": "Work with your display",
    "how4d": "Actual presentation depends on refresh rate and the processing budget. The requested mode and observed output rate are distinct.",
    "how5t": "Choose where to watch",
    "how5d": "Follow the source window or use fullscreen output on a selected display. Save profiles to switch between your usual settings.",
    "how6t": "Processed entirely on device",
    "how6d": "Capture and the model both run on this Mac. The picture is not uploaded.",
    "how7t": "Judge the output you see",
    "how7d": "Watch the FPS display and compare original, enhanced and side-by-side views using your own content.",
    "usesTitle": "Where it fits",
    "usesLede": "Different content calls for different settings.",
    "use1t": "Web video",
    "use1d": "Select your browser video window for local frame generation and scaling. Protected video may not be capturable.",
    "use2t": "Local video",
    "use2d": "Open MKV, MP4, MOV and other files directly, play with subtitles, and choose enhancement settings for the source.",
    "use3t": "Game upscaling",
    "use3d": "Select a game window and scale it with MetalFX or Lanczos. Judge frame generation against the game’s pacing and added latency.",
    "use4t": "Windows games streamed to a Mac",
    "use4d": "Use your streaming software to send the PC picture to your Mac, then select that window for enhancement.",
    "use5t": "Start with the window you are watching",
    "use5d": "Choose a source, pick a backend and compare the picture. Save settings you want to use again.",
    "faqTitle": "Common questions",
    "faqLede": "Other questions?",
    "faqContact": "Ask on GitHub",
    "faq1before": "What is ",
    "faq1after": "?",
    "faq1a": "OpenDuckFrame is a native Mac app for real-time frame generation and upscaling of windows, displays and local video. It also includes a video player with subtitles, Quick Look and broad format support.",
    "faq2q": "What kind of Mac does it need?",
    "faq2a": "An Apple silicon Mac running macOS 14 or later for basic playback. Apple interpolation, Apple super resolution and on-device subtitle generation / translation require macOS 26+ and supported hardware. Some experimental backends need extra models or a newer system.",
    "faq3q": "Does it add latency?",
    "faq3a": "Yes. Processing latency depends on the engine, source resolution and quality, and algorithms have different frame requirements. Video viewing and games tolerate different delays, so compare original and enhanced views with your own content.",
    "faq4q": "Does fullscreen work?",
    "faq4a": "You can choose an output display and use fullscreen output. Native fullscreen, web fullscreen and occlusion behavior vary by source app and macOS. Try a normal window or reselect the source if needed.",
    "faq5q": "Is the picture uploaded?",
    "faq5a": "No. Captured pictures, media and subtitles are processed on your Mac. There is no account or playback analytics. macOS may download system language models before first use of subtitle services.",
    "faq6q": "Is it free and open source?",
    "faq6a": "Yes. OpenDuckFrame’s own code is MIT licensed and free to obtain, modify and build. Third-party libraries and models retain their own licenses, documented in the GitHub repository.",
    "getTitle": "Make what you watch feel right",
    "getAfter": " is open source. Choose frame generation and scaling that suit your content.",
    "privacy": "Privacy",
    "contact": "Feedback",
    "requirements": "Apple silicon · macOS 14+ · MIT licensed",
    "sourceNote": "Build from source today. Follow packaged downloads in",
    "releases": "Releases",
    "productTitle": "Pick the right technology, in one workbench",
    "productCaption": "The technology library in OpenDuckFrame v0.1.0, captured on a Mac. Some experimental backends require additional models or runtimes.",
    "source": "Source"
  }
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
    slot.setAttribute("aria-hidden", "true");
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
  const OUTPUT_FPS = 48;
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
    let lastOutputFrame = -1;
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
      const outputFrame = Math.floor(elapsed / (1000 / OUTPUT_FPS));
      const outPhase = (outputFrame % (OUTPUT_FPS * CYCLE_MS / 1000)) / (OUTPUT_FPS * CYCLE_MS / 1000);
      const sourceFrame = Math.floor(elapsed / (1000 / SOURCE_FPS));
      const srcPhase = (sourceFrame % SOURCE_FRAMES) / SOURCE_FRAMES;
      move(output, outPhase);
      move(source, srcPhase);
      if (outputFrame !== lastOutputFrame) {
        push(outputHist, outPhase);
        lastOutputFrame = outputFrame;
      }
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

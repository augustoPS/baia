/* ds-runtime.js — resolves the Vitreous component library as window.VG.

   Prefers the compiled bundle (_ds_bundle.js) once the design-system compiler has
   produced it; until then it transpiles the component sources in place, so every
   card and UI kit renders standalone. Also provides VG_LOAD / VG_RUN for the kits'
   own JSX files.

   Load AFTER react, react-dom and @babel/standalone. */
(function () {
  var PATHS = [
    "components/controls/Button.jsx",
    "components/controls/SegmentedControl.jsx",
    "components/controls/Switch.jsx",
    "components/controls/Checkbox.jsx",
    "components/controls/RadioGroup.jsx",
    "components/controls/Slider.jsx",
    "components/controls/Stepper.jsx",
    "components/controls/PopUpButton.jsx",
    "components/controls/TextField.jsx",
    "components/controls/SearchField.jsx",
    "components/controls/TokenField.jsx",
    "components/controls/ProgressBar.jsx",
    "components/display/Badge.jsx",
    "components/display/StatusDot.jsx",
    "components/display/KeyCap.jsx",
    "components/display/Spinner.jsx",
    "components/display/Divider.jsx",
    "components/display/Tooltip.jsx",
    "components/display/Table.jsx",
    "components/display/ListRow.jsx",
    "components/surfaces/Material.jsx",
    "components/surfaces/Box.jsx",
    "components/surfaces/GroupedSection.jsx",
    "components/surfaces/SplitView.jsx",
    "components/surfaces/Inspector.jsx",
    "components/surfaces/Popover.jsx",
    "components/surfaces/Menu.jsx",
    "components/surfaces/Sheet.jsx",
    "components/surfaces/Alert.jsx",
    "components/chrome/WindowFrame.jsx",
    "components/chrome/Toolbar.jsx",
    "components/chrome/Sidebar.jsx",
    "components/chrome/Tabs.jsx",
    "components/chrome/MenuBar.jsx",
    "components/chrome/Dock.jsx",
    "components/chrome/ControlCenter.jsx",
    "components/chrome/CommandPalette.jsx"
  ];

  var NEED = ["Button", "Material", "WindowFrame", "Sidebar", "Toolbar", "ListRow", "TextField"];

  function get(url) {
    try {
      var xhr = new XMLHttpRequest();
      xhr.open("GET", url, false);
      xhr.send();
      return xhr.status === 200 ? xhr.responseText : null;
    } catch (e) { return null; }
  }

  function fromBundle() {
    for (var i = 0, keys = Object.getOwnPropertyNames(window); i < keys.length; i++) {
      try {
        var v = window[keys[i]];
        if (v && typeof v === "object" && NEED.every(function (n) { return typeof v[n] === "function"; })) return v;
      } catch (e) {}
    }
    return null;
  }

  var tag = document.currentScript && document.currentScript.src ? document.currentScript.src : "";
  var roots = [tag.replace(/ds-runtime\.js.*$/, ""), "", "../", "../../", "../../../"];
  var root = roots[0];
  for (var ri = 0; ri < roots.length; ri++) {
    if (get(roots[ri] + "components/controls/Button.jsx")) { root = roots[ri]; break; }
  }

  function compile(src) {
    return window.Babel.transform(
      src.replace(/^\s*import[^\n]*\n/gm, "").replace(/export\s+(function|const|let|var|class)/g, "$1"),
      { presets: [["react", { runtime: "classic" }]] }
    ).code;
  }

  var bundleSrc = get(root + "_ds_bundle.js");
  if (bundleSrc) {
    try { (0, eval)(bundleSrc); } catch (e) { console.warn("[ds-runtime] bundle eval failed", e); }
  }

  var ns = fromBundle();
  if (!ns) {
    ns = {};
    PATHS.forEach(function (p) {
      var src = get(root + p);
      if (!src) { console.warn("[ds-runtime] missing " + p); return; }
      var names = (src.match(/export\s+function\s+\w+/g) || []).map(function (m) { return m.split(/\s+/).pop(); });
      if (!names.length) return;
      try {
        var code = compile(src);
        var mod = new Function("React", code + "\nreturn {" + names.join(", ") + "};")(window.React);
        names.forEach(function (n) { ns[n] = mod[n]; });
      } catch (e) {
        console.error("[ds-runtime] " + p, e);
      }
    });
  }
  window.VG = ns;

  /* Page-level JSX: transpiled with the classic runtime and run in global scope. */
  window.VG_LOAD = function (paths) {
    paths.forEach(function (p) {
      var src = get(p);
      if (!src) { console.warn("[ds-runtime] missing " + p); return; }
      try { (0, eval)(compile(src)); } catch (e) { console.error("[ds-runtime] " + p, e); }
    });
  };

  window.VG_RUN = function (id) {
    var el = document.getElementById(id);
    if (!el) { console.warn("[ds-runtime] no script #" + id); return; }
    try { (0, eval)(compile(el.textContent)); } catch (e) { console.error("[ds-runtime] #" + id, e); }
  };
})();

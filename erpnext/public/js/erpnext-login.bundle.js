// FDS ERP sign-in page - the orbiting module diagram.
//
// Loaded ONLY on /login (see erpnext/utilities/website_context.py).
//
// This never edits frappe's markup: it appends one <aside> and adds one class
// to the wrapper that already holds login.html's five <section>s. If anything
// here fails or is disabled, the page renders exactly as frappe ships it.
//
// The diagram is desktop-only. On narrow screens nothing is built at all, so
// phones never parse the SVG - which is also why this listens for viewport
// changes rather than only checking once.

(function () {
	"use strict";

	var SVG_NS = "http://www.w3.org/2000/svg";
	var LOGO_SRC = "/assets/erpnext/images/fds-erp-logo.png";
	var DESKTOP_QUERY = "(min-width: 1024px)";

	// viewBox is square; everything is positioned relative to its centre.
	var VIEW = 520;
	var CENTRE = VIEW / 2;

	// Inner rings turn faster, loosely echoing orbital periods.
	var RINGS = [
		{ radius: 96, duration: "48s" },
		{ radius: 152, duration: "76s" },
		{ radius: 208, duration: "108s" },
	];

	// Customer-facing modules only, taken from erpnext/modules.txt. Internal
	// ones (Setup, Utilities, Portal, Regional, EDI, ...) are deliberately left
	// out - this is a shop window, not a site map.
	var MODULES = [
		{ ring: 0, label: "Accounts", blurb: "Ledgers, invoicing and financial reporting." },
		{ ring: 0, label: "Selling", blurb: "Quotations, sales orders and customer records." },
		{ ring: 1, label: "Stock", blurb: "Inventory across warehouses, batches and serials." },
		{ ring: 1, label: "Buying", blurb: "Suppliers, purchase orders and receipts." },
		{ ring: 1, label: "CRM", blurb: "Leads, opportunities and the sales pipeline." },
		{ ring: 2, label: "Manufacturing", blurb: "Bills of materials, work orders and capacity." },
		{ ring: 2, label: "Projects", blurb: "Tasks, timesheets and project costing." },
		{ ring: 2, label: "Assets", blurb: "Acquisition, depreciation and maintenance." },
	];

	var DEFAULT_TITLE = "One system, every department";
	var DEFAULT_BLURB = "Hover a module to see what it covers.";

	function el(tag, attrs, parent) {
		var node = document.createElementNS(SVG_NS, tag);
		for (var name in attrs) {
			if (Object.prototype.hasOwnProperty.call(attrs, name)) {
				node.setAttribute(name, attrs[name]);
			}
		}
		if (parent) {
			parent.appendChild(node);
		}
		return node;
	}

	function html(tag, className, parent) {
		var node = document.createElement(tag);
		if (className) {
			node.className = className;
		}
		if (parent) {
			parent.appendChild(node);
		}
		return node;
	}

	// The brand mark, echoed as vector: linked nodes in the logo's mint.
	function buildCore(parent) {
		el("circle", { class: "erp-orbit__core-glow", r: 58 }, parent);

		var spokes = [
			[0, -30],
			[28, 12],
			[-28, 12],
		];
		spokes.forEach(function (point) {
			el("line", { class: "erp-orbit__core-link", x1: 0, y1: 0, x2: point[0], y2: point[1] }, parent);
		});

		el("rect", { class: "erp-orbit__core-node", x: -11, y: -11, width: 22, height: 22, rx: 6 }, parent);
		spokes.forEach(function (point) {
			el(
				"rect",
				{
					class: "erp-orbit__core-node",
					x: point[0] - 8,
					y: point[1] - 8,
					width: 16,
					height: 16,
					rx: 5,
				},
				parent
			);
		});
	}

	function buildDiagram(onFocus, onBlur) {
		var svg = el("svg", {
			class: "erp-orbit__svg",
			viewBox: "0 0 " + VIEW + " " + VIEW,
			// Decorative as a whole; each node carries its own accessible name.
			role: "presentation",
			focusable: "false",
		});

		RINGS.forEach(function (ring) {
			el("circle", { class: "erp-orbit__ring", cx: CENTRE, cy: CENTRE, r: ring.radius }, svg);
		});

		// Local 0,0 is now the centre, which is what the CSS rotations assume.
		var origin = el("g", { transform: "translate(" + CENTRE + "," + CENTRE + ")" }, svg);
		buildCore(origin);

		// One rotating <g> per ring, so all the modules on a ring share a period.
		var rings = RINGS.map(function (ring) {
			return el("g", { class: "erp-orbit__spin", style: "--erp-dur: " + ring.duration }, origin);
		});

		var counts = [0, 0, 0];
		MODULES.forEach(function (module) {
			counts[module.ring] += 1;
		});

		var placed = [0, 0, 0];
		MODULES.forEach(function (module) {
			var ring = RINGS[module.ring];
			// Spread evenly around the ring, offset so rings don't line up.
			var angle = (360 / counts[module.ring]) * placed[module.ring] + module.ring * 24;
			placed[module.ring] += 1;

			// Nested groups keep the two transform channels apart: the SVG
			// transform attribute carries the static angle and radius, while CSS
			// animates .erp-orbit__spin / __counter. Setting both on one element
			// would let the CSS transform win and blow away the placement.
			var spoke = el("g", { transform: "rotate(" + angle + ")" }, rings[module.ring]);
			var arm = el("g", { transform: "translate(" + ring.radius + ",0)" }, spoke);
			var upright = el("g", { transform: "rotate(" + -angle + ")" }, arm);

			var node = el(
				"g",
				{
					class: "erp-orbit__node",
					tabindex: "0",
					role: "img",
					"aria-label": module.label + ". " + module.blurb,
				},
				upright
			);

			// Counter-rotates at the ring's own speed so text stays upright.
			var counter = el(
				"g",
				{ class: "erp-orbit__counter", style: "--erp-dur: " + ring.duration },
				node
			);
			var group = el("g", { class: "erp-orbit__node-group" }, counter);

			el("circle", { class: "erp-orbit__dot", r: 17 }, group);
			var label = el("text", { class: "erp-orbit__label", x: 0, y: 36 }, group);
			label.textContent = module.label;

			// Pointer and keyboard get identical treatment.
			node.addEventListener("mouseenter", function () {
				onFocus(node, module);
			});
			node.addEventListener("focus", function () {
				onFocus(node, module);
			});
			node.addEventListener("mouseleave", onBlur);
			node.addEventListener("blur", onBlur);
		});

		return svg;
	}

	function buildPanel() {
		var aside = html("aside", "erp-orbit");
		// Purely supporting imagery; the form beside it is the real content.
		aside.setAttribute("aria-hidden", "false");

		var logo = html("img", "erp-orbit__logo", aside);
		logo.src = LOGO_SRC;
		logo.alt = "FDS ERP";
		logo.width = 176;
		logo.height = 176;
		logo.decoding = "async";

		var caption = html("div", "erp-orbit__caption");
		var title = html("p", "erp-orbit__caption-title", caption);
		var text = html("p", "erp-orbit__caption-text", caption);
		title.textContent = DEFAULT_TITLE;
		text.textContent = DEFAULT_BLURB;

		var active = null;

		function focusModule(node, module) {
			if (active) {
				active.classList.remove("is-active");
			}
			active = node;
			node.classList.add("is-active");
			aside.classList.add("is-paused");
			title.textContent = module.label;
			text.textContent = module.blurb;
		}

		function blurModule() {
			if (active) {
				active.classList.remove("is-active");
				active = null;
			}
			aside.classList.remove("is-paused");
			title.textContent = DEFAULT_TITLE;
			text.textContent = DEFAULT_BLURB;
		}

		aside.appendChild(buildDiagram(focusModule, blurModule));
		aside.appendChild(caption);
		return aside;
	}

	function mount() {
		// Anchored on .for-login rather than a styling class: frappe's own
		// login.js drives the hash routing off these section classes, so they
		// are far more stable than presentational ones.
		var section = document.querySelector("section.for-login");
		var wrapper = section && section.parentElement;
		if (!wrapper || wrapper.querySelector(".erp-orbit")) {
			return;
		}

		wrapper.classList.add("erp-login-grid");
		// Appended last on purpose - CSS order:-1 moves it left visually while
		// the sign-in form keeps first place in the tab order.
		wrapper.appendChild(buildPanel());
	}

	function unmount() {
		var panel = document.querySelector(".erp-orbit");
		if (panel && panel.parentElement) {
			panel.parentElement.removeChild(panel);
		}
	}

	function sync(matches) {
		if (matches) {
			mount();
		} else {
			unmount();
		}
	}

	function init() {
		if (!document.body || document.body.dataset.path !== "login") {
			return;
		}

		var query = window.matchMedia(DESKTOP_QUERY);
		sync(query.matches);

		var onChange = function (event) {
			sync(event.matches);
		};
		if (typeof query.addEventListener === "function") {
			query.addEventListener("change", onChange);
		} else if (typeof query.addListener === "function") {
			// Safari < 14.
			query.addListener(onChange);
		}
	}

	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", init);
	} else {
		init();
	}
})();

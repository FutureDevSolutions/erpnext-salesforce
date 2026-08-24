# Copyright (c) 2026, Frappe Technologies Pvt. Ltd. and contributors
# For license information, please see license.txt

"""Per-page website context tweaks.

Wired up through the ``update_website_context`` hook, which frappe calls once
per rendered website page (see ``frappe/website/page_renderers/base_template_page.py``).
"""

LOGIN_ROUTE = "login"

#: Assets that dress up the sign-in page. Deliberately NOT added to the global
#: ``web_include_css`` / ``web_include_js`` hooks: those load on every portal
#: page, and nothing outside /login has any use for an orbit diagram.
LOGIN_CSS = "erpnext-login.bundle.css"
LOGIN_JS = "erpnext-login.bundle.js"


def add_login_assets(context):
	"""Attach the sign-in page's stylesheet and script, and only there.

	frappe seeds ``context.web_include_css`` / ``_js`` from the app hooks before
	this runs (``website_settings.py``), so we append rather than assign - other
	apps may have contributed already.
	"""
	if context.get("path") != LOGIN_ROUTE:
		return

	for key, asset in (("web_include_css", LOGIN_CSS), ("web_include_js", LOGIN_JS)):
		existing = context.get(key) or []
		# A website page can be rendered more than once in a single request
		# (error pages re-render), so guard against adding the asset twice.
		if asset not in existing:
			context[key] = [*existing, asset]

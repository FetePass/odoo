{
    "name": "FeteLABS Branding",
    "summary": "Puts the FeteLABS name and icon everywhere the web client shows its own",
    "description": """
The browser title, the favicon, the installable app, the login page, the
"Powered by" line on public pages, dialogs and the user menu say FeteLABS.
Apps that only exist in Odoo Enterprise are not offered.
""",
    "version": "19.0.1.0.0",
    "category": "Hidden",
    "author": "Fete Labs",
    "website": "https://fetelabs.ai",
    "license": "LGPL-3",
    "depends": ["web", "base_setup"],
    "auto_install": True,
    "data": [
        "data/ir_config_parameter.xml",
        "views/webclient_templates.xml",
    ],
    "assets": {
        "web._assets_primary_variables": [
            ("before", "web/static/src/scss/primary_variables.scss",
             "fetelabs_branding/static/src/scss/primary_variables.scss"),
        ],
        "web.assets_backend": [
            "fetelabs_branding/static/src/js/*.js",
            "fetelabs_branding/static/src/scss/branding.scss",
        ],
    },
}

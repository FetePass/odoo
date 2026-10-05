{
    "name": "FeteLABS Branding: Point of Sale",
    "summary": "FeteLABS on receipts and on the customer display",
    "version": "19.0.1.0.0",
    "category": "Hidden",
    "author": "Fete Labs",
    "website": "https://fetelabs.ai",
    "license": "LGPL-3",
    "depends": ["fetelabs_branding", "point_of_sale"],
    "auto_install": True,
    "assets": {
        "point_of_sale._assets_pos": ["fetelabs_branding_pos/static/src/*.xml"],
        "point_of_sale.customer_display_assets": ["fetelabs_branding_pos/static/src/*.xml"],
    },
}

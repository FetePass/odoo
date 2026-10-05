from odoo import models

FETELABS_URL = "https://fetelabs.ai"


class IrHttp(models.AbstractModel):
    _inherit = "ir.http"

    def session_info(self):
        info = super().session_info()
        # The user menu's Help item opens this address.
        info["support_url"] = FETELABS_URL
        return info

from odoo import api, models


class IrModuleModule(models.Model):
    _inherit = "ir.module.module"

    # Odoo lists its paid Enterprise apps in Apps as "Upgrade" cards
    # (base/data/ir_module_module.xml, to_buy = True). FeteLABS cannot
    # install them, so the Apps screen leaves them out. Only the screen's
    # reads are narrowed; code looking a module up by name is unaffected.
    @api.model
    def web_search_read(self, domain, specification, offset=0, limit=None, order=None, count_limit=None):
        return super().web_search_read(
            [*domain, ("to_buy", "=", False)], specification,
            offset=offset, limit=limit, order=order, count_limit=count_limit,
        )

    # The category counts beside the Apps list come from here.
    @api.model
    def search_panel_select_range(self, field_name, **kwargs):
        kwargs["search_domain"] = [*kwargs.get("search_domain", []), ("to_buy", "=", False)]
        result = super().search_panel_select_range(field_name, **kwargs)
        if field_name == "category_id" and kwargs.get("enable_counters"):
            # A category whose only apps are Enterprise ones (Helpdesk, Sign)
            # would be listed with nothing in it.
            result["values"] = [v for v in result["values"] if v.get("__count")]
        return result

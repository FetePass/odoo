import { Dialog } from "@web/core/dialog/dialog";
import { titleService } from "@web/core/browser/title_service";
import { registry } from "@web/core/registry";
import { patch } from "@web/core/utils/patch";

const NAME = "FeteLABS";

// A dialog with no title of its own is titled with the product's name.
Dialog.defaultProps = { ...Dialog.defaultProps, title: NAME };

// The tab title falls back to the product's name when nothing else is open.
patch(titleService, {
    start() {
        const service = super.start(...arguments);
        const named = () => {
            if (/(^|\) )Odoo$/.test(document.title)) {
                document.title = document.title.replace(/Odoo$/, NAME);
            }
        };
        const { setParts, setCounters } = service;
        service.setParts = (parts) => {
            setParts(parts);
            named();
        };
        service.setCounters = (counters) => {
            setCounters(counters);
            named();
        };
        named();
        return service;
    },
});

// There is no Odoo.com account behind a FeteLABS login.
registry.category("user_menuitems").remove("odoo_account");

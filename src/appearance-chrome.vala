/* Shared Appearance chrome controls (Preferences + Welcome tour). */
public class Mail.AppearanceChrome : Object {
    public const int WELCOME_TOUR_VERSION = 2;

    public delegate void RestartNeededFunc ();

    /**
     * ComboRow: Follow system vs IconOven.
     * Only list_factory is custom (popover preview). The closed-state factory
     * must stay default — a custom factory there breaks ComboRow selection.
     * GSettings value "adwaita" means system theme icons (not bundled Adwaita).
     */
    public static Adw.ComboRow create_icons_combo_row (bool compact = false) {
        var icons_row = new Adw.ComboRow () {
            title = _("UI icons"),
            subtitle = compact
                ? null
                : _("Follow system uses your desktop’s icon theme. IconOven is Letter’s set — modern and elegant."),
            subtitle_lines = compact ? 1 : 2,
            model = new Gtk.StringList ({
                _("Follow system"),
                _("IconOven"),
            }),
        };
        icons_row.list_factory = icons_preview_factory ();
        return icons_row;
    }

    private static void refill_preview (Gtk.Box box, bool iconoven) {
        Gtk.Widget? child = box.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            box.remove (child);
            child = next;
        }
        string[] preview;
        if (iconoven) {
            preview = {
                "letter-mail-unread",
                "letter-folder",
                "letter-system-search",
            };
        } else {
            preview = {
                "mail-unread-symbolic",
                "folder-symbolic",
                "system-search-symbolic",
            };
        }
        foreach (unowned string name in preview) {
            box.append (new Gtk.Image.from_icon_name (name) {
                pixel_size = 16,
                valign = Gtk.Align.CENTER,
            });
        }
    }

    private static Gtk.SignalListItemFactory icons_preview_factory () {
        var factory = new Gtk.SignalListItemFactory ();
        factory.setup.connect ((obj) => {
            var list_item = (Gtk.ListItem) obj;
            list_item.child = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10) {
                valign = Gtk.Align.CENTER,
            };
        });
        factory.bind.connect ((obj) => {
            var list_item = (Gtk.ListItem) obj;
            var box = (Gtk.Box) list_item.child;
            Gtk.Widget? child = box.get_first_child ();
            while (child != null) {
                var next = child.get_next_sibling ();
                box.remove (child);
                child = next;
            }
            bool iconoven = list_item.position == 1;
            string title = iconoven ? _("IconOven") : _("Follow system");
            refill_preview (box, iconoven);
            box.append (new Gtk.Label (title) {
                xalign = 0f,
                hexpand = true,
                valign = Gtk.Align.CENTER,
            });
        });
        return factory;
    }

    /**
     * Wire chrome-icons to @settings.
     * When already frozen (main UI up), @on_restart_needed is called after a change.
     */
    public static void bind_icons_combo_row (
        Adw.ComboRow icons_row,
        Settings settings,
        owned RestartNeededFunc? on_restart_needed
    ) {
        var syncing = false;
        icons_row.selected = settings.get_string ("chrome-icons") == "iconoven" ? 1 : 0;
        icons_row.notify["selected"].connect (() => {
            if (syncing)
                return;
            if (icons_row.selected == Gtk.INVALID_LIST_POSITION)
                return;
            var next = icons_row.selected == 1 ? "iconoven" : "adwaita";
            if (settings.get_string ("chrome-icons") == next)
                return;
            settings.set_string ("chrome-icons", next);
            if (Utils.chrome_icons_are_frozen () && on_restart_needed != null)
                on_restart_needed ();
        });
        settings.changed["chrome-icons"].connect (() => {
            var want = settings.get_string ("chrome-icons") == "iconoven" ? 1 : 0;
            if (icons_row.selected == want)
                return;
            syncing = true;
            icons_row.selected = want;
            syncing = false;
        });
    }
}

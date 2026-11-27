/* Shared three-page tour used by SetupWindow and WelcomeDialog. */
public class Mail.WelcomeTour : Object {
    public Adw.Carousel carousel { get; private set; }
    public Gtk.Widget footer { get; private set; }
    public signal void finished ();

    private Gtk.Button back_button;
    private Gtk.Button next_button;
    private Gtk.Button accounts_button;
    private uint page_index;
    private bool skip_goa;
    private Settings settings;
    private Adw.ComboRow? rail_color_row;
    private Gtk.Button? rail_color_button;

    public WelcomeTour () {
        this.skip_goa = Environment.get_variable ("LETTER_SKIP_GOA") == "1";
        this.settings = new Settings (Config.APP_ID);

        this.carousel = new Adw.Carousel () {
            hexpand = true,
            vexpand = true,
            allow_scroll_wheel = false,
            interactive = true,
        };
        this.carousel.append (status_page (
            "mail-unread-symbolic",
            _("Welcome to Letter"),
            _("Letter is designed for a modern email experience and it can be used on any desktop environment.\n\nOn GNOME, you can use Online Accounts so mail stays alongside Calendar and Contacts. Letter Identity is Letter’s own engine: solid and stable sync, smoother local search, and Google, Microsoft 365, or IMAP signed in from Letter.")
        ));
        this.carousel.append (build_appearance_page ());

        string needs_body;
        if (this.skip_goa) {
            needs_body = _("Add a mail account in Letter: Google, Microsoft 365, or IMAP. Letter Identity includes what you need to sign in.");
        } else {
            needs_body = _("Add a mail account in Letter: Google, Microsoft 365, or IMAP. Letter Identity includes what you need to sign in.\n\nOn GNOME you can instead use Settings → Online Accounts.");
        }
        var needs = status_page (
            "preferences-system-symbolic",
            _("Add your mail"),
            needs_body
        );
        this.accounts_button = new Gtk.Button.with_label (_("Add Account")) {
            halign = Gtk.Align.CENTER,
            focusable = false,
        };
        this.accounts_button.add_css_class ("pill");
        this.accounts_button.add_css_class ("suggested-action");
        this.accounts_button.clicked.connect (open_add_account);
        needs.child = this.accounts_button;
        this.carousel.append (needs);
        this.carousel.page_changed.connect ((index) => {
            this.page_index = index;
            update_chrome ();
        });

        this.back_button = new Gtk.Button.with_label (_("Back")) {
            valign = Gtk.Align.CENTER,
        };
        this.back_button.add_css_class ("pill");
        this.back_button.clicked.connect (go_back);

        this.next_button = new Gtk.Button.with_label (_("Next")) {
            valign = Gtk.Align.CENTER,
        };
        this.next_button.add_css_class ("pill");
        this.next_button.add_css_class ("suggested-action");
        this.next_button.clicked.connect (go_next);

        var dots = new Adw.CarouselIndicatorDots () {
            carousel = this.carousel,
            hexpand = true,
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER,
        };

        var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            hexpand = true,
        };
        bar.add_css_class ("welcome-footer");
        bar.append (this.back_button);
        bar.append (dots);
        bar.append (this.next_button);
        this.footer = bar;

        update_chrome ();
    }

    public void reset_to_first_page () {
        if (this.carousel.n_pages > 0)
            this.carousel.scroll_to (this.carousel.get_nth_page (0), false);
        this.page_index = 0;
        update_chrome ();
    }

    /* Compact custom page — avoid Adw.StatusPage’s 128px icon + scroll. */
    private Gtk.Widget build_appearance_page () {
        var page = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) {
            hexpand = true,
            vexpand = true,
            valign = Gtk.Align.CENTER,
            halign = Gtk.Align.FILL,
            margin_start = 20,
            margin_end = 20,
            margin_top = 8,
            margin_bottom = 8,
        };
        page.add_css_class ("welcome-appearance");

        page.append (new Gtk.Image.from_icon_name (Utils.icon ("computer-symbolic")) {
            pixel_size = 48,
            halign = Gtk.Align.CENTER,
        });
        page.append (new Gtk.Label (_("One experience, one interface")) {
            wrap = true,
            justify = Gtk.Justification.CENTER,
            halign = Gtk.Align.CENTER,
            css_classes = { "title-2" },
        });
        page.append (new Gtk.Label (
            _("Letter uses GTK 4 for a clean, elegant interface and a modern, balanced look. Thanks to the Flatpak build it can be installed on every desktop environment (GNOME, KDE, COSMIC, Cinnamon…). GNOME users from version 44 onward will find a coherent, familiar interface.")
        ) {
            wrap = true,
            justify = Gtk.Justification.CENTER,
            halign = Gtk.Align.CENTER,
            max_width_chars = 48,
            css_classes = { "body" },
        });

        var group = new Adw.PreferencesGroup () {
            halign = Gtk.Align.CENTER,
            width_request = 400,
        };

        if (Utils.is_gnome_session ()) {
            var icons_row = AppearanceChrome.create_icons_combo_row (true);
            AppearanceChrome.bind_icons_combo_row (icons_row, this.settings, () => {
                var gtk_app = GLib.Application.get_default () as Gtk.Application;
                if (gtk_app == null)
                    return;
                foreach (var w in gtk_app.get_windows ()) {
                    var mail = w as Window;
                    if (mail == null)
                        continue;
                    mail.show_toast (
                        _("Restart Letter to apply the new icon set")
                    );
                    break;
                }
            });
            group.add (icons_row);
        }

        migrate_account_rail_settings (this.settings);

        var rail_enabled = new Adw.SwitchRow () {
            title = _("Enable account rail"),
            active = this.settings.get_boolean ("account-rail-enabled"),
        };
        rail_enabled.notify["active"].connect (() => {
            this.settings.set_boolean ("account-rail-enabled", rail_enabled.active);
            update_rail_color_visibility (rail_enabled.active);
        });
        group.add (rail_enabled);

        this.rail_color_row = new Adw.ComboRow () {
            title = _("Account rail colour"),
            model = new Gtk.StringList ({
                _("Default"),
                _("Follow system"),
                _("Custom"),
            }),
        };
        var rail_mode = this.settings.get_string ("account-rail");
        this.rail_color_row.selected = rail_mode == "theme" ? 1 : rail_mode == "custom" ? 2 : 0;
        this.rail_color_row.notify["selected"].connect (() => {
            if (this.rail_color_row.selected == Gtk.INVALID_LIST_POSITION)
                return;
            switch (this.rail_color_row.selected) {
                case 1:
                    this.settings.set_string ("account-rail", "theme");
                    break;
                case 2:
                    this.settings.set_string ("account-rail", "custom");
                    break;
                default:
                    this.settings.set_string ("account-rail", "default");
                    break;
            }
            update_rail_color_button ();
        });
        group.add (this.rail_color_row);

        this.rail_color_button = new Gtk.Button () {
            valign = Gtk.Align.CENTER,
            tooltip_text = _("Choose a custom colour"),
            icon_name = Utils.icon ("color-select-symbolic"),
        };
        this.rail_color_button.add_css_class ("circular");
        this.rail_color_button.clicked.connect (pick_rail_color);
        this.rail_color_row.add_suffix (this.rail_color_button);

        update_rail_color_visibility (rail_enabled.active);
        update_rail_color_button ();

        page.append (group);
        return page;
    }

    private void update_rail_color_visibility (bool enabled) {
        if (this.rail_color_row != null)
            this.rail_color_row.visible = enabled;
    }

    private void update_rail_color_button () {
        if (this.rail_color_button == null || this.rail_color_row == null)
            return;
        this.rail_color_button.visible =
            this.rail_color_row.visible && this.rail_color_row.selected == 2;
    }

    private void pick_rail_color () {
        Gtk.Window? parent = null;
        var root = this.carousel.get_root ();
        if (root is Gtk.Window)
            parent = (Gtk.Window) root;
        var dialog = new Gtk.ColorChooserDialog (_("Choose Colour"), parent) {
            modal = true,
            use_alpha = false,
            resizable = false,
        };
        var initial = Gdk.RGBA ();
        if (!initial.parse (this.settings.get_string ("account-rail-color")))
            initial.parse ("#3584e4");
        dialog.set_rgba (initial);
        dialog.response.connect ((response) => {
            if (response == Gtk.ResponseType.OK)
                this.settings.set_string ("account-rail-color", rgba_to_hex (dialog.get_rgba ()));
            dialog.destroy ();
        });
        dialog.present ();
    }

    private static string rgba_to_hex (Gdk.RGBA rgba) {
        return "#%02x%02x%02x".printf (
            (int) (rgba.red * 255.0 + 0.5),
            (int) (rgba.green * 255.0 + 0.5),
            (int) (rgba.blue * 255.0 + 0.5)
        );
    }

    private static void migrate_account_rail_settings (Settings settings) {
        if (settings.get_string ("account-rail") != "hide")
            return;
        settings.set_boolean ("account-rail-enabled", false);
        settings.set_string ("account-rail", "default");
    }

    private static Adw.StatusPage status_page (string icon, string title, string description) {
        var page = new Adw.StatusPage () {
            icon_name = Utils.icon (icon),
            title = title,
            description = description,
            hexpand = true,
            vexpand = true,
        };
        page.add_css_class ("welcome-status");
        return page;
    }

    private void update_chrome () {
        var last = this.page_index + 1 >= this.carousel.n_pages;
        this.back_button.sensitive = this.page_index > 0;
        this.next_button.label = last ? _("Get Started") : _("Next");
        this.accounts_button.focusable = last;
    }

    private void open_add_account () {
        var app = GLib.Application.get_default ();
        if (app != null)
            app.activate_action ("add-mail-account", null);
        else
            Utils.open_online_accounts ();
    }

    private void go_back () {
        if (this.page_index == 0)
            return;
        this.carousel.scroll_to (this.carousel.get_nth_page (this.page_index - 1), true);
    }

    private void go_next () {
        if (this.page_index + 1 >= this.carousel.n_pages) {
            /* Get Started — do not reopen Add Account; let the app show mail
             * (or a clear “no accounts” message). */
            finished ();
            return;
        }
        this.carousel.scroll_to (this.carousel.get_nth_page (this.page_index + 1), true);
    }
}

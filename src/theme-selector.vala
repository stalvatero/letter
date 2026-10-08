public class Mail.ThemeSelector : Gtk.Box {
    private Settings settings;
    private Gtk.CheckButton system_button;
    private Gtk.CheckButton light_button;
    private Gtk.CheckButton dark_button;
    private bool syncing;

    public ThemeSelector (Settings settings) {
        Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 18);
        this.settings = settings;
        add_css_class ("theme-selector");
        hexpand = true;
        halign = Gtk.Align.CENTER;
        valign = Gtk.Align.CENTER;

        this.system_button = add_choice (null, "default", "theme-system", _("Follow the system appearance"));
        this.light_button = add_choice (this.system_button, "light", "theme-light", _("Light appearance"));
        this.dark_button = add_choice (this.system_button, "dark", "theme-dark", _("Dark appearance"));
        sync_from_settings ();
        this.settings.changed["color-scheme"].connect (sync_from_settings);
    }

    private Gtk.CheckButton add_choice (
        Gtk.CheckButton? group,
        string value,
        string css,
        string tooltip
    ) {
        var button = new Gtk.CheckButton () {
            tooltip_text = tooltip,
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER,
        };
        button.add_css_class (css);
        if (group != null)
            button.set_group (group);
        button.toggled.connect (() => {
            if (this.syncing || !button.active)
                return;
            this.settings.set_string ("color-scheme", value);
        });
        append (button);
        return button;
    }

    private void sync_from_settings () {
        var value = this.settings.get_string ("color-scheme");
        this.syncing = true;
        this.system_button.active = value == "default";
        this.light_button.active = value == "light";
        this.dark_button.active = value == "dark";
        this.syncing = false;
    }
}

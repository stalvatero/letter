public class Mail.ThemeSelector : Gtk.Box {
    public ThemeSelector (Settings settings) {
        Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 18);
        add_css_class ("theme-selector");
        hexpand = true;
        halign = Gtk.Align.CENTER;
        valign = Gtk.Align.CENTER;

        Gtk.CheckButton? group = null;
        group = add_choice (settings, group, "default", "theme-system", _("Follow the system appearance"));
        add_choice (settings, group, "light", "theme-light", _("Light appearance"));
        add_choice (settings, group, "dark", "theme-dark", _("Dark appearance"));
    }

    private Gtk.CheckButton add_choice (
        Settings settings,
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
        button.active = settings.get_string ("color-scheme") == value;
        button.toggled.connect (() => {
            if (button.active)
                settings.set_string ("color-scheme", value);
        });
        append (button);
        return button;
    }
}

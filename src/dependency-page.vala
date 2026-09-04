public class Mail.SystemPackage : Object {
    public string title { get; set; default = ""; }
    public string purpose { get; set; default = ""; }
    public bool installed { get; set; }
    public string deb { get; set; default = ""; }
    public string rpm { get; set; default = ""; }
    public string pacman { get; set; default = ""; }
    public string help { get; set; default = ""; }

    public string install_tooltip () {
        if (this.help.length > 0)
            return this.help;
        return "%s\nsudo apt install %s\n\n%s\nsudo dnf install %s\n\n%s\nsudo pacman -S %s".printf (
            _("Debian / Ubuntu"),
            this.deb,
            _("Fedora"),
            this.rpm,
            _("Arch Linux"),
            this.pacman
        );
    }
}

public class Mail.DependencyListPage : Adw.NavigationPage {
    public DependencyListPage () {
        Object (title: _("Dependencies"));

        var header = new Adw.HeaderBar ();
        var intro = new Gtk.Label (
            _("Letter is made for the GNOME desktop from version 50 onward and makes full use of the GTK 4 and libadwaita libraries. A normal GNOME installation already includes everything needed to make it work. Check the essential packages below, and the optional ones only if you need them.")
        ) {
            wrap = true,
            xalign = 0,
            max_width_chars = 56,
        };
        intro.add_css_class ("body");

        var essential = new Adw.PreferencesGroup () {
            title = _("Essential"),
        };
        var required = required_packages ();
        for (uint i = 0; i < required.length; i++)
            essential.add (dependency_row (required[i]));

        var recommended = new Adw.PreferencesGroup () {
            title = _("Recommended"),
        };
        var optional = recommended_packages ();
        for (uint i = 0; i < optional.length; i++)
            recommended.add (dependency_row (optional[i]));

        var page = new Gtk.Box (Gtk.Orientation.VERTICAL, 16);
        page.append (intro);
        page.append (essential);
        page.append (recommended);

        var clamp = new Adw.Clamp () {
            child = page,
            maximum_size = 680,
            tightening_threshold = 480,
            margin_start = 16,
            margin_end = 16,
            margin_top = 16,
            margin_bottom = 16,
        };
        var toolbar = new Adw.ToolbarView () {
            content = clamp,
        };
        toolbar.add_top_bar (header);
        child = toolbar;
    }

    public static uint missing_count () {
        uint missing = 0;
        var required = required_packages ();
        for (uint i = 0; i < required.length; i++) {
            if (!required[i].installed)
                missing++;
        }
        var optional = recommended_packages ();
        for (uint i = 0; i < optional.length; i++) {
            if (!optional[i].installed)
                missing++;
        }
        return missing;
    }

    private static GenericArray<SystemPackage> required_packages () {
        var listed = new GenericArray<SystemPackage> ();
        listed.add (package (
            _("GNOME Online Accounts"),
            _("Account sign-in for Google, Microsoft 365, Exchange, and IMAP"),
            Utils.has_gnome_online_accounts (),
            "gnome-online-accounts",
            "gnome-online-accounts",
            "gnome-online-accounts"
        ));
        listed.add (package (
            _("Evolution Data Server"),
            _("Mail, calendar, and contacts backend used by Letter"),
            Utils.has_evolution_data_server (),
            "evolution-data-server",
            "evolution-data-server",
            "evolution-data-server"
        ));
        return listed;
    }

    private static GenericArray<SystemPackage> recommended_packages () {
        var listed = new GenericArray<SystemPackage> ();
        listed.add (package (
            _("Microsoft Graph backends"),
            _("evolution-ews for Microsoft 365 mail, calendar, and contacts"),
            Utils.has_microsoft365_calendar_backend () && Utils.has_microsoft365_mail_backend (),
            "evolution-ews",
            "evolution-ews",
            "evolution-ews"
        ));

        var spell = package (
            _("Hunspell"),
            _("Spell checking in the compose editor. Install Hunspell plus a dictionary for your language."),
            Utils.hunspell_dictionaries_present (),
            "hunspell",
            "hunspell",
            "hunspell"
        );
        spell.help = hunspell_help ();
        listed.add (spell);

        listed.add (package (
            _("Sushi"),
            _("Quick attachment preview. Without it, Letter opens the file in the default application."),
            Utils.program_installed ("sushi"),
            "gnome-sushi",
            "sushi",
            "sushi"
        ));
        return listed;
    }

    private static string hunspell_help () {
        return "%s\n\n%s\n%s\n\n%s\nsudo apt install hunspell\nsudo apt search '^hunspell-'\n\n%s\nsudo dnf install hunspell\nsudo dnf search hunspell-\n\n%s\nsudo pacman -S hunspell\npacman -Ss hunspell-\n\n%s".printf (
            _("Install Hunspell and the dictionary for your language. Enchant is pulled in automatically."),
            _("Search your package manager for hunspell- followed by the language code."),
            _("Examples: hunspell-it, hunspell-en-us, hunspell-fr, hunspell-de-de."),
            _("Debian / Ubuntu"),
            _("Fedora"),
            _("Arch Linux"),
            _("The compose editor uses the same language as the desktop.")
        );
    }

    private static SystemPackage package (
        string title,
        string purpose,
        bool installed,
        string deb,
        string rpm,
        string pacman
    ) {
        return new SystemPackage () {
            title = title,
            purpose = purpose,
            installed = installed,
            deb = deb,
            rpm = rpm,
            pacman = pacman,
        };
    }

    private static Adw.ActionRow dependency_row (SystemPackage package) {
        var row = new Adw.ActionRow () {
            title = package.title,
            subtitle = package.purpose,
            activatable = false,
        };
        var commands = new Gtk.Label (package.install_tooltip ()) {
            xalign = 0,
            selectable = true,
            wrap = true,
            max_width_chars = 42,
        };
        commands.add_css_class ("caption");
        commands.add_css_class ("monospace");
        var popover = new Gtk.Popover () {
            autohide = true,
            child = commands,
        };
        var info = new Gtk.MenuButton () {
            valign = Gtk.Align.CENTER,
            icon_name = "help-about-symbolic",
            tooltip_text = package.install_tooltip (),
            has_frame = false,
            always_show_arrow = false,
            popover = popover,
        };
        info.add_css_class ("flat");
        info.add_css_class ("circular");

        var status = new Gtk.Label (package.installed ? _("Installed") : _("Missing")) {
            valign = Gtk.Align.CENTER,
        };
        status.add_css_class ("caption");
        status.add_css_class (package.installed ? "success" : "error");
        row.add_suffix (info);
        row.add_suffix (status);
        return row;
    }
}

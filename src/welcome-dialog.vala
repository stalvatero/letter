public class Mail.WelcomeDialog : Adw.Dialog {
    private Adw.Carousel carousel;
    private Gtk.Button back_button;
    private Gtk.Button next_button;
    private Gtk.Button accounts_button;
    private uint page_index;

    public WelcomeDialog () {
        Object (
            content_width: 520,
            content_height: 580,
            follows_content_size: false
        );

        if (Config.PROFILE == "development")
            add_css_class ("devel");

        this.carousel = new Adw.Carousel () {
            hexpand = true,
            vexpand = true,
            allow_scroll_wheel = true,
            interactive = true,
        };
        this.carousel.append (status_page (
            "mail-unread-symbolic",
            _("Welcome to Letter"),
            _("Letter is the email application designed for the GNOME desktop and integrates with Calendar and Contacts. It uses the same accounts you already have: Google, Microsoft 365, Exchange, IMAP.")
        ));
        this.carousel.append (status_page (
            "computer-symbolic",
            _("One experience, one interface"),
            _("Sign-in stays in Online Accounts in GNOME Settings. Evolution Data Server handles the mail flow. Letter uses the GTK 4 and libadwaita libraries, so GNOME 50 or later is required for it to work correctly.")
        ));
        var needs = status_page (
            "preferences-system-symbolic",
            _("What Letter needs"),
            _("Add at least one mail account in Settings → Online Accounts. IMAP is added there too. Microsoft 365 also needs the evolution-ews package. Without Online Accounts, Letter has nothing to show — by design.")
        );
        var accounts = new Gtk.Button.with_label (_("Online Accounts")) {
            halign = Gtk.Align.CENTER,
            focusable = false,
        };
        accounts.add_css_class ("pill");
        accounts.clicked.connect (() => Utils.open_online_accounts ());
        needs.child = accounts;
        this.carousel.append (needs);
        this.accounts_button = accounts;
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

        var footer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            hexpand = true,
        };
        footer.add_css_class ("welcome-footer");
        footer.append (this.back_button);
        footer.append (dots);
        footer.append (this.next_button);

        var header = new Adw.HeaderBar ();
        /* Bottom bar stays visible — a vexpand carousel used to push the
         * footer off-screen so the dialog looked like a single page. */
        var view = new Adw.ToolbarView () {
            content = this.carousel,
        };
        view.add_top_bar (header);
        view.add_bottom_bar (footer);
        this.child = view;
        this.title = _("Welcome");

        map.connect (() => {
            Idle.add (() => {
                if (this.carousel.n_pages > 0)
                    this.carousel.scroll_to (this.carousel.get_nth_page (0), false);
                this.page_index = 0;
                update_chrome ();
                return Source.REMOVE;
            });
        });

        update_chrome ();
    }

    private static Adw.StatusPage status_page (string icon, string title, string description) {
        return new Adw.StatusPage () {
            icon_name = icon,
            title = title,
            description = description,
            hexpand = true,
            vexpand = true,
        };
    }

    private uint current_index () {
        return this.page_index;
    }

    private void update_chrome () {
        var index = current_index ();
        var last = index + 1 >= this.carousel.n_pages;
        this.back_button.sensitive = index > 0;
        this.next_button.label = last ? _("Get Started") : _("Next");
        this.accounts_button.focusable = last;
    }

    private void go_back () {
        var index = current_index ();
        if (index == 0)
            return;
        this.carousel.scroll_to (this.carousel.get_nth_page (index - 1), true);
    }

    private void go_next () {
        var index = current_index ();
        if (index + 1 >= this.carousel.n_pages) {
            close ();
            return;
        }
        this.carousel.scroll_to (this.carousel.get_nth_page (index + 1), true);
    }
}

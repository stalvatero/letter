/* Shared three-page tour used by SetupWindow and WelcomeDialog. */
public class Mail.WelcomeTour : Object {
    public Adw.Carousel carousel { get; private set; }
    public Gtk.Widget footer { get; private set; }
    public signal void finished ();

    private Gtk.Button back_button;
    private Gtk.Button next_button;
    private Gtk.Button accounts_button;
    private uint page_index;

    public WelcomeTour () {
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
        this.accounts_button = new Gtk.Button.with_label (_("Online Accounts")) {
            halign = Gtk.Align.CENTER,
            focusable = false,
        };
        this.accounts_button.add_css_class ("pill");
        this.accounts_button.add_css_class ("suggested-action");
        this.accounts_button.clicked.connect (() => Utils.open_online_accounts ());
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

    private static Adw.StatusPage status_page (string icon, string title, string description) {
        return new Adw.StatusPage () {
            icon_name = icon,
            title = title,
            description = description,
            hexpand = true,
            vexpand = true,
        };
    }

    private void update_chrome () {
        var last = this.page_index + 1 >= this.carousel.n_pages;
        this.back_button.sensitive = this.page_index > 0;
        this.next_button.label = last ? _("Get Started") : _("Next");
        this.accounts_button.focusable = last;
    }

    private void go_back () {
        if (this.page_index == 0)
            return;
        this.carousel.scroll_to (this.carousel.get_nth_page (this.page_index - 1), true);
    }

    private void go_next () {
        if (this.page_index + 1 >= this.carousel.n_pages) {
            finished ();
            return;
        }
        this.carousel.scroll_to (this.carousel.get_nth_page (this.page_index + 1), true);
    }
}

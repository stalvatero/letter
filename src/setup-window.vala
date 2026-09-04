/* Shown instead of the main shell when GNOME Online Accounts has no mail. */
public class Mail.SetupWindow : Adw.ApplicationWindow {
    public SetupWindow (Gtk.Application app) {
        Object (
            application: app,
            title: Utils.app_display_name (),
            default_width: 560,
            default_height: 520,
            resizable: false
        );

        if (Config.PROFILE == "development")
            add_css_class ("devel");

        var accounts = new Gtk.Button.with_label (_("Online Accounts")) {
            halign = Gtk.Align.CENTER,
        };
        accounts.add_css_class ("pill");
        accounts.add_css_class ("suggested-action");
        accounts.clicked.connect (() => Utils.open_online_accounts ());

        var status = new Adw.StatusPage () {
            icon_name = "mail-unread-symbolic",
            title = _("Add a mail account"),
            description = _("Letter uses the same accounts as Calendar and Contacts. Add Google, Microsoft 365, or IMAP in Settings → Online Accounts, then return here."),
            hexpand = true,
            vexpand = true,
            child = accounts,
        };

        var hint = new Gtk.Label (
            _("Letter stays closed until at least one mail account is available.")
        ) {
            wrap = true,
            justify = Gtk.Justification.CENTER,
            max_width_chars = 42,
            margin_bottom = 24,
        };
        hint.add_css_class ("dim-label");

        var body = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            hexpand = true,
            vexpand = true,
        };
        body.append (status);
        body.append (hint);

        var view = new Adw.ToolbarView () {
            content = body,
        };
        view.add_top_bar (new Adw.HeaderBar ());
        this.content = view;
    }
}

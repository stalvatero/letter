/**
 * In-app Letter Identity wizard — add mail without GNOME Online Accounts.
 *
 * Google / Microsoft → native OAuth (not yet); IMAP password only for
 * providers that expose real IMAP LOGIN (Fastmail, mailbox.org, ISP, …).
 */
public class Mail.IdentityImapDialog : Adw.Dialog {
    public signal void account_added (string account_id);

    private Adw.NavigationView nav;
    private Adw.NavigationPage imap_page;
    private Adw.Banner error_banner;
    private Adw.EntryRow email_row;
    private Adw.PasswordEntryRow password_row;
    private Adw.EntryRow name_row;
    private Adw.EntryRow user_row;
    private Adw.EntryRow imap_host_row;
    private Adw.SpinRow imap_port_row;
    private Adw.EntryRow smtp_host_row;
    private Adw.SpinRow smtp_port_row;
    private Gtk.Button add_button;
    private bool busy;
    private bool presets_locked;
    private bool name_touched;
    private bool user_touched;

    public IdentityImapDialog () {
        Object (title: _("Add Mail Account"), content_width: 460, content_height: 520);
        build_ui ();
    }

    private void build_ui () {
        this.nav = new Adw.NavigationView ();
        this.imap_page = build_imap_page ();
        this.nav.add (build_chooser_page ());
        this.child = this.nav;
    }

    private void open_imap_page () {
        clear_error ();
        if (this.nav.find_page ("imap") == null)
            this.nav.push (this.imap_page);
        else
            this.nav.push_by_tag ("imap");
    }

    private Adw.NavigationPage build_chooser_page () {
        var header = new Adw.HeaderBar ();

        var list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.NONE,
            margin_top = 12,
            margin_bottom = 12,
            margin_start = 12,
            margin_end = 12,
        };
        list.add_css_class ("boxed-list");

        var google = new Adw.ActionRow () {
            title = _("Google"),
            subtitle = _("Gmail — Sign in with Google"),
            activatable = true,
        };
        google.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
        google.activated.connect (() => start_oauth.begin ("google"));

        var microsoft = new Adw.ActionRow () {
            title = _("Microsoft"),
            subtitle = _("Outlook / Microsoft 365 — Sign in with Microsoft"),
            activatable = true,
        };
        microsoft.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
        microsoft.activated.connect (() => start_oauth.begin ("microsoft"));

        var imap = new Adw.ActionRow () {
            title = _("IMAP"),
            subtitle = _("Fastmail, mailbox.org, ISP, or other IMAP host"),
            activatable = true,
        };
        imap.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
        imap.activated.connect (open_imap_page);

        list.append (google);
        list.append (microsoft);
        list.append (imap);

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        box.append (list);

        var hint = new Gtk.Label (
            _("Google and Microsoft open your browser to sign in. IMAP is for hosts with a normal password (or app password).")
        ) {
            wrap = true,
            justify = Gtk.Justification.CENTER,
            margin_start = 24,
            margin_end = 24,
            margin_top = 12,
            margin_bottom = 12,
        };
        hint.add_css_class ("dim-label");
        hint.add_css_class ("caption");
        box.append (hint);

        if (Environment.get_variable ("LETTER_SKIP_GOA") != "1"
            && Utils.has_gnome_online_accounts ()) {
            var goa_list = new Gtk.ListBox () {
                selection_mode = Gtk.SelectionMode.NONE,
                margin_top = 0,
                margin_bottom = 18,
                margin_start = 12,
                margin_end = 12,
            };
            goa_list.add_css_class ("boxed-list");
            var goa = new Adw.ActionRow () {
                title = _("Or open GNOME Online Accounts"),
                subtitle = _("Add mail in Settings — Calendar and Contacts stay shared on GNOME"),
                activatable = true,
            };
            goa.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
            goa.activated.connect (() => {
                Utils.open_online_accounts ();
                close ();
            });
            goa_list.append (goa);
            box.append (goa_list);
        }

        var toolbar = new Adw.ToolbarView () {
            content = box,
        };
        toolbar.add_top_bar (header);

        return new Adw.NavigationPage (toolbar, _("Add Mail Account")) {
            tag = "chooser",
        };
    }

    private Adw.NavigationPage build_imap_page () {
        var header = new Adw.HeaderBar ();
        this.add_button = new Gtk.Button.with_label (_("Add")) {
            sensitive = false,
        };
        this.add_button.add_css_class ("suggested-action");
        this.add_button.clicked.connect (() => save.begin ());
        header.pack_end (this.add_button);

        this.error_banner = new Adw.Banner ("") {
            revealed = false,
        };

        var page = new Adw.PreferencesPage ();

        var basics = new Adw.PreferencesGroup () {
            title = _("IMAP account"),
            description = _("Gmail and Outlook are not added here. Many hosts (including Fastmail) want an app-specific password for IMAP — not the same password as the web login."),
        };
        this.email_row = new Adw.EntryRow () {
            title = _("Email"),
            input_purpose = Gtk.InputPurpose.EMAIL,
        };
        this.email_row.changed.connect (on_email_changed);
        this.password_row = new Adw.PasswordEntryRow () {
            title = _("Password"),
        };
        this.password_row.changed.connect (() => {
            clear_error ();
            update_add_sensitive ();
        });
        this.name_row = new Adw.EntryRow () {
            title = _("Your name"),
        };
        this.name_row.changed.connect (() => {
            if (!this.presets_locked)
                this.name_touched = true;
        });
        basics.add (this.email_row);
        basics.add (this.password_row);
        basics.add (this.name_row);
        page.add (basics);

        var servers = new Adw.PreferencesGroup () {
            title = _("Servers"),
            description = _("Filled for known IMAP hosts. Expand to edit."),
        };
        var expander = new Adw.ExpanderRow () {
            title = _("IMAP and SMTP settings"),
            subtitle = _("Host, port, and username"),
            expanded = true,
        };
        this.user_row = new Adw.EntryRow () {
            title = _("Username"),
        };
        this.user_row.changed.connect (() => {
            if (!this.presets_locked)
                this.user_touched = true;
        });
        this.imap_host_row = new Adw.EntryRow () {
            title = _("IMAP host"),
        };
        this.imap_host_row.changed.connect (update_add_sensitive);
        this.imap_port_row = new Adw.SpinRow.with_range (1, 65535, 1) {
            title = _("IMAP port"),
            value = 993,
        };
        this.smtp_host_row = new Adw.EntryRow () {
            title = _("SMTP host"),
        };
        this.smtp_port_row = new Adw.SpinRow.with_range (1, 65535, 1) {
            title = _("SMTP port"),
            value = 465,
        };
        expander.add_row (this.user_row);
        expander.add_row (this.imap_host_row);
        expander.add_row (this.imap_port_row);
        expander.add_row (this.smtp_host_row);
        expander.add_row (this.smtp_port_row);
        servers.add (expander);
        page.add (servers);

        var toolbar = new Adw.ToolbarView () {
            content = page,
        };
        toolbar.add_top_bar (header);
        toolbar.add_top_bar (this.error_banner);

        return new Adw.NavigationPage (toolbar, _("IMAP Account")) {
            tag = "imap",
        };
    }

    private async void start_oauth (string provider) {
        if (this.busy)
            return;

        if (provider == "google"
            && (IdentityOAuth.google_client_id () == null
                || IdentityOAuth.google_client_secret () == null)) {
            var alert = new Adw.AlertDialog (
                _("Google OAuth credentials missing"),
                _("Create a Google Cloud Desktop OAuth client, then set LETTER_GOOGLE_CLIENT_ID and LETTER_GOOGLE_CLIENT_SECRET (both shown on the client page). Add yourself as an OAuth test user. IMAP remains available for Fastmail and similar hosts.")
            );
            alert.add_response ("ok", _("OK"));
            alert.add_response ("imap", _("Use IMAP instead"));
            alert.set_response_appearance ("imap", Adw.ResponseAppearance.SUGGESTED);
            alert.response.connect ((response) => {
                if (response == "imap")
                    open_imap_page ();
            });
            alert.present (this);
            return;
        }
        if (provider == "microsoft" && IdentityOAuth.microsoft_client_id () == null) {
            var alert = new Adw.AlertDialog (
                _("Microsoft client id missing"),
                _("Register a Letter Azure public client named “Letter E-mail Client” (personal + work accounts), add redirect http://127.0.0.1:8743/letter-oauth, then set LETTER_MS_CLIENT_ID. See PLATFORM-MS-AZURE-APP.md. Hotmail needs no IT; work M365 uses the same Client ID later. LETTER_MS_MAIL=graph enables the Graph engine (opt-in).")
            );
            alert.add_response ("ok", _("OK"));
            alert.add_response ("imap", _("Use IMAP instead"));
            alert.set_response_appearance ("imap", Adw.ResponseAppearance.SUGGESTED);
            alert.response.connect ((response) => {
                if (response == "imap")
                    open_imap_page ();
            });
            alert.present (this);
            return;
        }

        this.busy = true;
        var wait = new Adw.AlertDialog (
            provider == "google" ? _("Sign in with Google") : _("Sign in with Microsoft"),
            _("Complete sign-in in your browser. Letter is waiting for the redirect…")
        );
        wait.add_response ("cancel", _("Cancel"));
        wait.default_response = "cancel";
        var cancellable = new Cancellable ();
        wait.response.connect (() => cancellable.cancel ());
        wait.present (this);

        try {
            var oauth = new IdentityOAuth ();
            IdentityOAuthProfile profile;
            if (provider == "google")
                profile = yield oauth.sign_in_google (cancellable);
            else
                profile = yield oauth.sign_in_microsoft (cancellable);

            wait.force_close ();

            var catalog = IdentityCatalog.load ();
            IdentityAccount acc;
            if (provider == "google") {
                acc = catalog.add_oauth_google (
                    profile.email,
                    profile.display_name ?? profile.email
                );
            } else {
                acc = catalog.add_oauth_microsoft (
                    profile.email,
                    profile.display_name ?? profile.email
                );
                if (IdentityOAuth.microsoft_mail_uses_graph ())
                    acc.graph_scope_stamp = IdentityOAuth.MICROSOFT_GRAPH_SCOPE;
            }
            catalog.save ();
            IdentitySecrets.store_oauth_tokens (
                acc.id,
                _("Letter OAuth: %s").printf (profile.email),
                profile.tokens
            );
            if (provider == "microsoft" && IdentityOAuth.microsoft_mail_uses_graph ()) {
                IdentitySecrets.store_oauth_tokens (
                    IdentityOAuth.graph_secret_id (acc.id),
                    _("Letter OAuth Graph: %s").printf (profile.email),
                    profile.tokens
                );
            }
            account_added (acc.id);
            close ();
        } catch (Error e) {
            wait.force_close ();
            this.busy = false;
            if (e is IOError.CANCELLED || e is IdentityOAuthError.CANCELLED)
                return;
            var err = new Adw.AlertDialog (_("Could not sign in"), e.message);
            err.add_response ("ok", _("OK"));
            err.present (this);
            warning ("Identity OAuth %s failed: %s", provider, e.message);
        }
    }

    private void clear_error () {
        if (this.error_banner == null)
            return;
        this.error_banner.revealed = false;
        this.error_banner.title = "";
    }

    private void show_error (string message) {
        this.error_banner.title = message;
        this.error_banner.revealed = true;
    }

    private void on_email_changed () {
        clear_error ();
        var email = this.email_row.text.strip ();
        if (is_oauth_consumer_domain (email_domain (email))) {
            show_error (_("Gmail and Outlook are added with Sign in with Google / Microsoft — not IMAP password. Go back and choose Google or Microsoft, or use an IMAP provider."));
            this.add_button.sensitive = false;
            return;
        }
        if (!this.presets_locked)
            apply_provider_presets (email);
        update_add_sensitive ();
    }

    private void update_add_sensitive () {
        var email = this.email_row.text.strip ();
        var pass = this.password_row.text;
        var host = this.imap_host_row.text.strip ();
        this.add_button.sensitive = !this.busy
            && email.index_of_char ('@') > 0
            && pass.length > 0
            && host.length > 0
            && !is_oauth_consumer_domain (email_domain (email));
    }

    private static string email_domain (string email) {
        var at = email.last_index_of_char ('@');
        if (at <= 0 || at + 1 >= email.length)
            return "";
        return email.substring (at + 1).down ();
    }

    /** Consumer Google / Microsoft — native OAuth only in product UX. */
    private static bool is_oauth_consumer_domain (string domain) {
        if (domain.length == 0)
            return false;
        if (domain == "gmail.com" || domain == "googlemail.com")
            return true;
        if (domain == "outlook.com" || domain == "hotmail.com"
            || domain == "live.com" || domain == "msn.com")
            return true;
        return false;
    }

    private void apply_provider_presets (string email) {
        var domain = email_domain (email);
        if (domain.length == 0 || !domain_ready (domain))
            return;
        if (is_oauth_consumer_domain (domain))
            return;

        string imap_host;
        uint imap_port = 993;
        string smtp_host;
        uint smtp_port = 465;

        if (domain == "fastmail.com" || domain.has_suffix (".fastmail.com")) {
            imap_host = "imap.fastmail.com";
            smtp_host = "smtp.fastmail.com";
            smtp_port = 465;
        } else if (domain == "mailbox.org" || domain.has_suffix (".mailbox.org")) {
            imap_host = "imap.mailbox.org";
            smtp_host = "smtp.mailbox.org";
            smtp_port = 465;
        } else if (domain == "migadu.com" || domain.has_suffix (".migadu.com")) {
            imap_host = "imap.migadu.com";
            smtp_host = "smtp.migadu.com";
            smtp_port = 465;
        } else if (domain.has_suffix ("yahoo.com") || domain == "ymail.com") {
            imap_host = "imap.mail.yahoo.com";
            smtp_host = "smtp.mail.yahoo.com";
        } else if (domain == "icloud.com" || domain == "me.com" || domain == "mac.com") {
            imap_host = "imap.mail.me.com";
            smtp_host = "smtp.mail.me.com";
            smtp_port = 587;
        } else if (domain.index_of_char ('.') < 0) {
            return;
        } else {
            imap_host = "imap." + domain;
            smtp_host = "smtp." + domain;
        }

        this.presets_locked = true;
        if (!this.user_touched)
            this.user_row.text = email;
        this.imap_host_row.text = imap_host;
        this.imap_port_row.value = imap_port;
        this.smtp_host_row.text = smtp_host;
        this.smtp_port_row.value = smtp_port;
        if (!this.name_touched)
            this.name_row.text = email;
        this.presets_locked = false;
    }

    private static bool domain_ready (string domain) {
        if (domain == "fastmail.com" || domain.has_suffix (".fastmail.com")
            || domain == "mailbox.org" || domain.has_suffix (".mailbox.org")
            || domain == "migadu.com" || domain.has_suffix (".migadu.com")
            || domain == "ymail.com"
            || domain == "icloud.com" || domain == "me.com" || domain == "mac.com")
            return true;
        if (domain.has_suffix ("yahoo.com"))
            return true;
        return domain.index_of_char ('.') > 0;
    }

    private async void save () {
        if (this.busy)
            return;

        var email = this.email_row.text.strip ();
        var password = this.password_row.text;
        var name = this.name_row.text.strip ();
        if (name.length == 0)
            name = email;
        var user = this.user_row.text.strip ();
        if (user.length == 0)
            user = email;
        var imap_host = this.imap_host_row.text.strip ();
        var imap_port = (uint) this.imap_port_row.value;
        var smtp_host = this.smtp_host_row.text.strip ();
        if (smtp_host.length == 0)
            smtp_host = null;
        var smtp_port = (uint) this.smtp_port_row.value;

        if (is_oauth_consumer_domain (email_domain (email))) {
            show_error (_("Gmail and Outlook are not added with IMAP password. Choose Google or Microsoft on the previous screen when available."));
            return;
        }

        if (email.index_of_char ('@') <= 0 || password.length == 0 || imap_host.length == 0) {
            show_error (_("Enter email, password, and IMAP host."));
            return;
        }
        var smtp_resolved = IdentityMailVerify.resolve_smtp_host (smtp_host, imap_host);
        if (smtp_resolved.length == 0) {
            show_error (_("Enter an SMTP host."));
            return;
        }

        clear_error ();
        this.busy = true;
        update_add_sensitive ();
        this.add_button.label = _("Checking…");

        Error? verify_error = null;
        var login_user = user;
        var pass_copy = password;
        var i_host = imap_host;
        var i_port = (uint16) imap_port;
        var s_host = smtp_resolved;
        var s_port = (uint16) smtp_port;
        SourceFunc resume = save.callback;
        new Thread<void*> ("letter-identity-verify", () => {
            try {
                IdentityMailVerify.verify_password (
                    login_user, pass_copy, i_host, i_port, s_host, s_port
                );
            } catch (Error e) {
                verify_error = e;
            }
            Idle.add (() => {
                resume ();
                return Source.REMOVE;
            });
            return null;
        });
        yield;

        if (verify_error != null) {
            this.busy = false;
            this.add_button.label = _("Add");
            update_add_sensitive ();
            show_error (IdentityMailVerify.explain (verify_error));
            warning ("Identity verify failed for %s imap=%s:%u smtp=%s:%u: %s",
                login_user, i_host, i_port, s_host, s_port, verify_error.message);
            Secret.password_wipe (pass_copy);
            return;
        }

        try {
            var catalog = IdentityCatalog.load ();
            var acc = catalog.add_imap (
                email,
                name,
                user,
                imap_host,
                imap_port,
                true,
                smtp_resolved,
                smtp_port,
                true
            );
            catalog.save ();
            IdentitySecrets.store_password (
                acc.id,
                _("Letter mail: %s").printf (email),
                password
            );
            Secret.password_wipe (password);
            Secret.password_wipe (pass_copy);
            account_added (acc.id);
            close ();
        } catch (Error e) {
            this.busy = false;
            this.add_button.label = _("Add");
            update_add_sensitive ();
            show_error (e.message);
            Secret.password_wipe (pass_copy);
        }
    }
}

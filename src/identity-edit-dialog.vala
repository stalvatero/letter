/**
 * Edit a Letter Identity account.
 *
 * OAuth (Google / Microsoft): local label + sender name only — connection
 * details are fixed by the provider.
 * Native IMAP: label, sender, username/password, and servers (verified on save
 * when connection fields change).
 */
public class Mail.IdentityEditDialog : Adw.Dialog {
    public signal void account_updated (string account_id);

    private string account_id;
    private IdentityAccount account;
    private Adw.Banner error_banner;
    private Adw.EntryRow label_row;
    private Adw.EntryRow sender_row;
    private Adw.EntryRow email_row;
    private Adw.EntryRow? user_row;
    private Adw.PasswordEntryRow? password_row;
    private Adw.EntryRow? imap_host_row;
    private Adw.SpinRow? imap_port_row;
    private Adw.EntryRow? smtp_host_row;
    private Adw.SpinRow? smtp_port_row;
    private Gtk.Button save_button;
    private bool busy;
    private bool oauth;

    /* Snapshot at open — skip IMAP verify when only label/sender changed. */
    private string initial_user = "";
    private string initial_imap_host = "";
    private uint initial_imap_port;
    private string initial_smtp_host = "";
    private uint initial_smtp_port;

    public IdentityEditDialog (string account_id) throws Error {
        Object (
            title: _("Edit Account"),
            content_width: 460,
            content_height: 560
        );
        this.account_id = account_id;
        var catalog = IdentityCatalog.load ();
        IdentityAccount? found = null;
        for (uint i = 0; i < catalog.accounts.length; i++) {
            if (catalog.accounts[i].id == account_id) {
                found = catalog.accounts[i];
                break;
            }
        }
        if (found == null) {
            throw new IOError.NOT_FOUND (
                _("No Letter Identity account “%s”.").printf (account_id)
            );
        }
        this.account = found;
        this.oauth = found.uses_oauth2 ();
        build_ui ();
    }

    private void build_ui () {
        var header = new Adw.HeaderBar ();
        this.save_button = new Gtk.Button.with_label (_("Save")) {
            sensitive = true,
        };
        this.save_button.add_css_class ("suggested-action");
        this.save_button.clicked.connect (() => save.begin ());
        header.pack_end (this.save_button);

        this.error_banner = new Adw.Banner ("") {
            revealed = false,
        };

        var page = new Adw.PreferencesPage ();

        var basics = new Adw.PreferencesGroup () {
            title = _("Account"),
            description = _("The account label is only for you — in the account list. The name on sent mail is what recipients see."),
        };
        this.label_row = new Adw.EntryRow () {
            title = _("Account label"),
            text = this.account.display_name ?? "",
        };
        this.label_row.changed.connect (() => {
            clear_error ();
            update_save_sensitive ();
        });
        this.sender_row = new Adw.EntryRow () {
            title = _("Name on sent mail"),
            text = this.account.effective_sender_name (),
        };
        this.sender_row.changed.connect (clear_error);
        this.email_row = new Adw.EntryRow () {
            title = _("Email"),
            text = this.account.email ?? "",
            sensitive = false,
        };
        basics.add (this.label_row);
        basics.add (this.sender_row);
        basics.add (this.email_row);
        page.add (basics);

        if (this.oauth) {
            var kind = (this.account.kind ?? "").down ();
            string conn_title;
            string conn_subtitle;
            if (kind == "google") {
                conn_title = _("Google");
                conn_subtitle = _("Signed in with Google (OAuth2). Mail uses IMAP with XOAUTH2 — host and ports are fixed by Google.");
            } else if (kind == "microsoft" || kind == "ms365") {
                conn_title = _("Microsoft");
                conn_subtitle = _("Signed in with Microsoft (OAuth2). Mail uses IMAP with XOAUTH2 — host and ports are fixed by Microsoft.");
            } else {
                conn_title = _("OAuth2");
                conn_subtitle = _("Signed in with OAuth2. Server settings are managed by the provider.");
            }
            var connection = new Adw.PreferencesGroup () {
                title = _("Connection"),
                description = _("These settings cannot be changed. Remove the account and sign in again if you need a different provider."),
            };
            var row = new Adw.ActionRow () {
                title = conn_title,
                subtitle = conn_subtitle,
            };
            connection.add (row);
            page.add (connection);
        } else {
            this.initial_user = this.account.username ?? this.account.email ?? "";
            this.initial_imap_host = this.account.imap_host ?? "";
            this.initial_imap_port = this.account.imap_port > 0 ? this.account.imap_port : 993;
            this.initial_smtp_host = this.account.smtp_host ?? "";
            this.initial_smtp_port = this.account.smtp_port > 0 ? this.account.smtp_port : 465;

            var creds = new Adw.PreferencesGroup () {
                title = _("Sign-in"),
                description = _("Leave the password blank to keep the current one."),
            };
            this.user_row = new Adw.EntryRow () {
                title = _("Username"),
                text = this.initial_user,
            };
            this.user_row.changed.connect (clear_error);
            this.password_row = new Adw.PasswordEntryRow () {
                title = _("Password"),
            };
            this.password_row.changed.connect (clear_error);
            creds.add (this.user_row);
            creds.add (this.password_row);
            page.add (creds);

            var servers = new Adw.PreferencesGroup () {
                title = _("Servers"),
                description = _("Letter checks IMAP and SMTP before saving when these change. Port 587 uses STARTTLS; 465 uses TLS."),
            };
            this.imap_host_row = new Adw.EntryRow () {
                title = _("IMAP host"),
                text = this.initial_imap_host,
            };
            this.imap_host_row.changed.connect (() => {
                clear_error ();
                update_save_sensitive ();
            });
            this.imap_port_row = new Adw.SpinRow.with_range (1, 65535, 1) {
                title = _("IMAP port"),
                value = this.initial_imap_port,
            };
            this.smtp_host_row = new Adw.EntryRow () {
                title = _("SMTP host"),
                text = this.initial_smtp_host,
            };
            this.smtp_port_row = new Adw.SpinRow.with_range (1, 65535, 1) {
                title = _("SMTP port"),
                value = this.initial_smtp_port,
            };
            servers.add (this.imap_host_row);
            servers.add (this.imap_port_row);
            servers.add (this.smtp_host_row);
            servers.add (this.smtp_port_row);
            page.add (servers);
        }

        var toolbar = new Adw.ToolbarView () {
            content = page,
        };
        toolbar.add_top_bar (header);
        toolbar.add_top_bar (this.error_banner);
        this.child = toolbar;
        update_save_sensitive ();
    }

    private void clear_error () {
        this.error_banner.revealed = false;
        this.error_banner.title = "";
    }

    private void show_error (string message) {
        this.error_banner.title = message;
        this.error_banner.revealed = true;
    }

    private void update_save_sensitive () {
        var label = this.label_row.text.strip ();
        if (this.oauth) {
            this.save_button.sensitive = !this.busy && label.length > 0;
            return;
        }
        var host = this.imap_host_row != null ? this.imap_host_row.text.strip () : "";
        this.save_button.sensitive = !this.busy
            && label.length > 0
            && host.length > 0;
    }

    private bool connection_fields_changed () {
        if (this.oauth || this.imap_host_row == null)
            return false;
        var user = this.user_row != null ? this.user_row.text.strip () : "";
        var imap_host = this.imap_host_row.text.strip ();
        var imap_port = (uint) this.imap_port_row.value;
        var smtp_host = this.smtp_host_row.text.strip ();
        var smtp_port = (uint) this.smtp_port_row.value;
        var new_password = this.password_row != null && this.password_row.text.length > 0;
        return new_password
            || user != this.initial_user
            || imap_host != this.initial_imap_host
            || imap_port != this.initial_imap_port
            || smtp_host != this.initial_smtp_host
            || smtp_port != this.initial_smtp_port;
    }

    private async void save () {
        if (this.busy)
            return;

        var label = this.label_row.text.strip ();
        if (label.length == 0)
            label = this.account.email;
        var sender = this.sender_row.text.strip ();
        if (sender.length == 0)
            sender = label;

        if (this.oauth) {
            clear_error ();
            try {
                var catalog = IdentityCatalog.load ();
                IdentityAccount? row = null;
                for (uint i = 0; i < catalog.accounts.length; i++) {
                    if (catalog.accounts[i].id == this.account_id) {
                        row = catalog.accounts[i];
                        break;
                    }
                }
                if (row == null)
                    throw new IOError.NOT_FOUND (_("Account disappeared."));
                row.display_name = label;
                row.sender_name = sender;
                catalog.save ();
                account_updated (row.id);
                close ();
            } catch (Error e) {
                show_error (e.message);
            }
            return;
        }

        var user = this.user_row.text.strip ();
        if (user.length == 0)
            user = this.account.email;
        var imap_host = this.imap_host_row.text.strip ();
        var imap_port = (uint) this.imap_port_row.value;
        var smtp_host = this.smtp_host_row.text.strip ();
        string? smtp_host_or_null = smtp_host.length > 0 ? smtp_host : null;
        var smtp_port = (uint) this.smtp_port_row.value;
        string? new_password = null;
        if (this.password_row != null && this.password_row.text.length > 0)
            new_password = this.password_row.text;

        if (imap_host.length == 0) {
            show_error (_("Enter an IMAP host."));
            return;
        }
        var smtp_resolved = IdentityMailVerify.resolve_smtp_host (smtp_host_or_null, imap_host);
        if (smtp_resolved.length == 0) {
            show_error (_("Enter an SMTP host."));
            return;
        }

        clear_error ();
        var need_verify = connection_fields_changed ();
        if (need_verify) {
            this.busy = true;
            update_save_sensitive ();
            this.save_button.label = _("Checking…");

            Error? verify_error = null;
            var login_user = user;
            var acc_id = this.account_id;
            string? pass_copy = new_password;
            var i_host = imap_host;
            var i_port = (uint16) imap_port;
            var s_host = smtp_resolved;
            var s_port = (uint16) smtp_port;
            SourceFunc resume = save.callback;
            new Thread<void*> ("letter-identity-edit-verify", () => {
                string? password = null;
                try {
                    password = pass_copy;
                    if (password == null || password.length == 0)
                        password = IdentitySecrets.lookup_password (acc_id);
                    if (password == null || password.length == 0) {
                        throw new IOError.FAILED (
                            _("No password stored. Enter a new password to verify the connection.")
                        );
                    }
                    IdentityMailVerify.verify_password (
                        login_user, password, i_host, i_port, s_host, s_port
                    );
                } catch (Error e) {
                    verify_error = e;
                } finally {
                    if (pass_copy == null && password != null)
                        Secret.password_wipe (password);
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
                this.save_button.label = _("Save");
                update_save_sensitive ();
                show_error (IdentityMailVerify.explain (verify_error));
                warning ("Identity edit verify failed for %s imap=%s:%u smtp=%s:%u: %s",
                    login_user, i_host, i_port, s_host, s_port, verify_error.message);
                return;
            }
        }

        try {
            var catalog = IdentityCatalog.load ();
            IdentityAccount? row = null;
            for (uint i = 0; i < catalog.accounts.length; i++) {
                if (catalog.accounts[i].id == this.account_id) {
                    row = catalog.accounts[i];
                    break;
                }
            }
            if (row == null)
                throw new IOError.NOT_FOUND (_("Account disappeared."));

            row.display_name = label;
            row.sender_name = sender;
            row.username = user;
            row.imap_host = imap_host;
            row.imap_port = imap_port;
            row.imap_tls = true;
            row.smtp_host = smtp_resolved;
            row.smtp_port = smtp_port;
            row.smtp_tls = true;
            catalog.save ();

            if (new_password != null && new_password.length > 0) {
                IdentitySecrets.store_password (
                    row.id,
                    _("Letter mail: %s").printf (row.email),
                    new_password
                );
                Secret.password_wipe (new_password);
            }

            account_updated (row.id);
            close ();
        } catch (Error e) {
            this.busy = false;
            this.save_button.label = _("Save");
            update_save_sensitive ();
            show_error (e.message);
        }
    }
}

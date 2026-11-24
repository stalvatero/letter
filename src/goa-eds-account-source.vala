/**
 * Legacy AccountSource: GNOME Online Accounts + Evolution Data Server.
 * Golden-path Identity will be a sibling source; this stays optional.
 */
public class Mail.GoaEdsAccountSource : Object, AccountSource {
    public string id {
        get {
            return "goa-eds";
        }
    }

    public string? error_message {
        get {
            return this._error_message;
        }
    }

    public uint calendar_count {
        get {
            return this._calendar_count;
        }
    }

    public uint contact_count {
        get {
            return this._contact_count;
        }
    }

    public E.SourceRegistry? registry {
        get {
            return this._registry;
        }
    }

    public Goa.Client? goa { get; private set; }

    private string? _error_message;
    private uint _calendar_count;
    private uint _contact_count;
    private E.SourceRegistry? _registry;
    private bool watching = false;
    private bool loading = false;
    private bool loaded = false;

    public async void load () {
        while (this.loading) {
            Idle.add (load.callback);
            yield;
        }
        if (this.loaded)
            return;

        this.loading = true;
        this._error_message = null;

        try {
            try {
                this._registry = yield new E.SourceRegistry (null);
            } catch (Error e) {
                warning ("Could not connect to Evolution Data Server: %s", e.message);
                this._error_message = e.message;
            }

            try {
                this.goa = yield new Goa.Client (null);
            } catch (Error e) {
                warning ("Could not connect to GNOME Online Accounts: %s", e.message);
                if (this._error_message == null)
                    this._error_message = e.message;
            }

            refresh_counts ();
            this.loaded = true;
            /* AccountStore.load rebuilds and notifies; watchers fire changed. */

            if (!this.watching) {
                this.watching = true;

                if (this.registry != null) {
                    this.registry.source_added.connect (() => on_backend_changed ());
                    this.registry.source_removed.connect (() => on_backend_changed ());
                    this.registry.source_changed.connect (() => on_backend_changed ());
                    this.registry.source_enabled.connect (() => on_backend_changed ());
                    this.registry.source_disabled.connect (() => on_backend_changed ());
                }

                if (this.goa != null) {
                    this.goa.account_added.connect (() => on_backend_changed ());
                    this.goa.account_removed.connect (() => on_backend_changed ());
                    this.goa.account_changed.connect (() => on_backend_changed ());
                }
            }
        } finally {
            this.loading = false;
        }
    }

    public GenericArray<Account> primary_accounts () {
        var list = new GenericArray<Account> ();
        if (this.goa == null)
            return list;

        foreach (var object in this.goa.get_accounts ()) {
            var account = account_from_goa (object);
            if (account != null)
                list.add (account);
        }
        return list;
    }

    public GenericArray<Account> enrichment_accounts () {
        var list = new GenericArray<Account> ();
        if (this.registry == null)
            return list;

        foreach (var source in this.registry.list_sources (E.SOURCE_EXTENSION_MAIL_ACCOUNT)) {
            if (source.get_uid () == "vfolder")
                continue;
            var account = account_from_source (source);
            if (account != null)
                list.add (account);
        }
        return list;
    }

    private void on_backend_changed () {
        refresh_counts ();
        changed ();
    }

    private void refresh_counts () {
        this._calendar_count = 0;
        this._contact_count = 0;

        if (this._registry == null)
            return;

        foreach (var source in this._registry.list_enabled (E.SOURCE_EXTENSION_CALENDAR)) {
            if (!is_builtin (source))
                this._calendar_count++;
        }

        foreach (var source in this._registry.list_enabled (E.SOURCE_EXTENSION_ADDRESS_BOOK)) {
            if (!is_builtin (source))
                this._contact_count++;
        }
    }

    private Account? account_from_source (E.Source source) {
        var mail_account = (E.SourceMailAccount) source.get_extension (E.SOURCE_EXTENSION_MAIL_ACCOUNT);
        var backend_name = mail_account.dup_backend_name ();
        if (mail_account.get_builtin () || backend_name == "maildir"
            || backend_name == "mbox" || backend_name == "local")
            return null;

        var account = new Account () {
            uid = source.get_uid (),
            source_uid = source.get_uid (),
            display_name = source.dup_display_name (),
            enabled = source.get_enabled (),
            has_mail = source.get_enabled (),
            backend_name = backend_name,
        };

        var identity_uid = mail_account.dup_identity_uid ();
        if (identity_uid != null && this.registry != null) {
            var identity_source = this.registry.ref_source (identity_uid);
            if (identity_source != null && identity_source.has_extension (E.SOURCE_EXTENSION_MAIL_IDENTITY)) {
                var identity = (E.SourceMailIdentity) identity_source.get_extension (E.SOURCE_EXTENSION_MAIL_IDENTITY);
                account.email = identity.dup_address ();
                var name = identity.dup_name ();
                if (name != null && name.length > 0)
                    account.display_name = name;
            }
        }

        string? goa_type = null;
        apply_goa_extension (source, account);
        var parent_uid = source.get_parent ();
        if (parent_uid != null && this.registry != null) {
            var parent = this.registry.ref_source (parent_uid);
            if (parent != null) {
                apply_goa_extension (parent, account);
                if (parent.has_extension (E.SOURCE_EXTENSION_COLLECTION)) {
                    var collection = (E.SourceCollection) parent.get_extension (E.SOURCE_EXTENSION_COLLECTION);
                    account.has_calendar = collection.get_calendar_enabled ();
                    account.has_contacts = collection.get_contacts_enabled ();
                    goa_type = parent.dup_display_name ();
                    var identity = collection.dup_identity ();
                    if (identity != null && account.goa_id == null)
                        account.goa_id = identity;
                }
            }
        }

        account.kind = AccountKind.from_provider (goa_type, account.backend_name);
        return account;
    }

    private Account? account_from_goa (Goa.Object object) {
        var goa_account = object.get_account ();
        if (goa_account == null)
            return null;

        var mail = object.get_mail ();
        if (mail == null && !goa_is_mail_provider (goa_account.provider_type))
            return null;

        var email = (mail != null ? mail.email_address : null) ?? goa_account.identity;
        var presentation = goa_account.presentation_identity;
        var display = presentation;
        if (display == null || display.length == 0 || (email != null && display == email))
            display = email ?? AccountKind.from_provider (goa_account.provider_type, null).label ();
        var account = new Account () {
            uid = goa_account.id,
            goa_id = goa_account.id,
            display_name = display,
            email = email,
            kind = AccountKind.from_provider (goa_account.provider_type, null),
            provider_icon = goa_account.provider_icon,
            has_mail = mail != null && !goa_account.mail_disabled,
            has_calendar = object.get_calendar () != null && !goa_account.calendar_disabled,
            has_contacts = object.get_contacts () != null && !goa_account.contacts_disabled,
            enabled = !goa_account.attention_needed,
        };

        return account;
    }

    private void apply_goa_extension (E.Source source, Account account) {
        if (!source.has_extension (E.SOURCE_EXTENSION_GOA))
            return;

        var ext = (E.SourceGoa) source.get_extension (E.SOURCE_EXTENSION_GOA);
        var id = ext.dup_account_id ();
        if (id != null && id.length > 0)
            account.goa_id = id;
        var address = ext.dup_address ();
        if (account.email == null && address != null && address.length > 0)
            account.email = address;
        var name = ext.dup_name ();
        if (name != null && name.length > 0 && (account.display_name == null || account.display_name == account.email))
            account.display_name = name;
    }

    private static bool goa_is_mail_provider (string? provider_type) {
        var type = (provider_type ?? "").down ();
        return type == "google"
            || type == "ms_graph"
            || type == "exchange"
            || type == "imap_smtp"
            || type == "windows_live"
            || type.contains ("microsoft");
    }

    private static bool is_builtin (E.Source source) {
        if (source.has_extension (E.SOURCE_EXTENSION_MAIL_ACCOUNT)) {
            var mail = (E.SourceMailAccount) source.get_extension (E.SOURCE_EXTENSION_MAIL_ACCOUNT);
            return mail.get_builtin ();
        }

        return false;
    }
}
